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
IMAGE="$(grep -m1 'image: fastapi-redis-lab' k8s/api/deployment.yaml | awk '{print $2}')"

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
# Manifests. Namespace first -- everything else declares `namespace: lab`
# and fails to apply if the namespace does not exist yet.
# ---------------------------------------------------------------------------
log "Applying namespace"
kubectl apply -f k8s/namespace.yaml

log "Applying Redis"
kubectl apply -f k8s/redis/
# Redis first, and waited on, so that the API pods come up with a reachable
# dependency. Not required for correctness -- they would eventually become
# ready on their own -- but it makes failures legible instead of confusing.
kubectl -n "$NAMESPACE" rollout status deployment/redis --timeout=180s

log "Applying FastAPI"
kubectl apply -f k8s/api/
kubectl -n "$NAMESPACE" rollout status deployment/fastapi --timeout=180s

# ---------------------------------------------------------------------------
# If the image tag did not change, `apply` is a no-op and pods keep running
# the OLD image even though a new one was just loaded. Restarting the
# rollout forces them to pick it up.
#
# This is the correct fix for a LAB. In production you change the tag
# instead, so that what is running is always identifiable.
# ---------------------------------------------------------------------------
log "Restarting FastAPI to pick up the freshly loaded image"
kubectl -n "$NAMESPACE" rollout restart deployment/fastapi
kubectl -n "$NAMESPACE" rollout status deployment/fastapi --timeout=180s

log "Ready"
kubectl -n "$NAMESPACE" get pods -o wide
echo
echo "Endpoint: http://localhost:30080"
echo "Docs:     http://localhost:30080/docs"