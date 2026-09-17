#!/usr/bin/env bash
#
# Bring the entire lab up from any starting state: no cluster, a stopped
# cluster, a running cluster, or a partially applied one. Safe to re-run.

# -e           exit immediately if any command fails
# -u           treat unset variables as an error (catches typos in $VARS)
# -o pipefail  a pipeline fails if ANY stage fails, not just the last one
#
# Without pipefail, `docker build ... | tee log` succeeds even when the
# build fails, because tee succeeded. This single option prevents a whole
# category of scripts that lie about their success.
set -euo pipefail

CLUSTER="k8s-lab"
NAMESPACE="lab"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# The Deployment manifest is the single source of truth for which image
# version should be running. The script reads it rather than defining its
# own, so the two can never disagree.
# ---------------------------------------------------------------------------
IMAGE="$(grep -A2 'repository: fastapi-redis-lab' charts/k8s-lab/values.yaml | grep 'tag:' | awk '{print $2}' | tr -d '"')"
IMAGE="fastapi-redis-lab:${IMAGE}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
log "Checking prerequisites"
for tool in docker kind kubectl; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool"; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "Docker is not running"; exit 1; }
echo "docker, kind, kubectl present"

# ---------------------------------------------------------------------------
# Cluster: create if absent, start if stopped, leave alone if healthy.
# ---------------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "Cluster '$CLUSTER' exists"
  # A host reboot leaves the node containers stopped. `docker start` on an
  # already-running container is a no-op, so this is safe unconditionally.
  docker start "${CLUSTER}-control-plane" "${CLUSTER}-worker" >/dev/null 2>&1 || true
  echo "Waiting for the API server to respond..."
  for _ in $(seq 1 60); do
    kubectl --context "kind-${CLUSTER}" get nodes >/dev/null 2>&1 && break
    sleep 2
  done
else
  log "Creating cluster '$CLUSTER'"
  kind create cluster --config kind/kind-cluster.yaml
fi

kubectl config use-context "kind-${CLUSTER}" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# ---------------------------------------------------------------------------
# Image: build, then side-load into the cluster.
#
# This load step is the one people forget. The cluster's containerd is a
# separate image store from your Docker daemon; rebuilding an image does
# not update the cluster's copy.
# ---------------------------------------------------------------------------
log "Building $IMAGE"
docker build -f app/Dockerfile -t "$IMAGE" .

log "Loading $IMAGE into cluster"
kind load docker-image "$IMAGE" --name "$CLUSTER"

# ---------------------------------------------------------------------------
# Ingress controller. Idempotent -- apply on an existing install is a no-op.
# ---------------------------------------------------------------------------
log "Installing ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.0/deploy/static/provider/kind/deploy.yaml

# The upstream manifest does not pin the controller to the node whose ports
# 80/443 are mapped through to the host. Without this it can land on the
# worker, where it runs happily and receives no external traffic.
#
# nodeSelector attracts it to the control plane; the toleration gets it past
# that node's NoSchedule taint. Both are required -- either alone leaves the
# pod Pending.
log "Pinning ingress controller to the control-plane node"
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true","kubernetes.io/os":"linux"},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Equal","effect":"NoSchedule"}]}}}}'

# rollout status, not `kubectl wait` on a label selector: after a patch,
# the old pod still matches the selector and is still Ready, so wait returns
# immediately on a pod that is about to be terminated.
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s

log "Installing/upgrading Helm release"
helm upgrade --install lab charts/k8s-lab \
  --namespace "$NAMESPACE" --create-namespace \
  --set api.image.tag="${IMAGE##*:}" \
  --wait --timeout 5m

# The image tag is unchanged between rebuilds, so Helm sees no diff and pods
# keep the old image. Same mutable-tag problem as before.
log "Restarting API to pick up the freshly loaded image"
kubectl -n "$NAMESPACE" rollout restart deployment/lab-k8s-lab-api
kubectl -n "$NAMESPACE" rollout status deployment/lab-k8s-lab-api --timeout=180s

log "Ready"
kubectl -n "$NAMESPACE" get pods -o wide
echo
echo "Endpoint: http://lab.localhost"
echo "Docs:     http://lab.localhost/docs"