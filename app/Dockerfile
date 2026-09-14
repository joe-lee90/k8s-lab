# ---------------------------------------------------------------------------
# Stage 1: builder
#
# Installs dependencies into a self-contained prefix. Any compiler or header
# package needed here stays in this stage and never reaches the final image.
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

# Dependency manifests are copied alone, BEFORE the source code. This is the
# single most important line ordering in the file: the expensive pip install
# layer is invalidated only when these files change, not when app.py changes.
COPY app/requirements.lock.txt ./

RUN pip install --prefix=/install -r requirements.lock.txt

# ---------------------------------------------------------------------------
# Stage 2: runtime
#
# A fresh, clean base. Only the installed packages and the application source
# are copied in. pip itself, build caches, and any toolchain stay behind.
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS runtime

# PYTHONDONTWRITEBYTECODE: no .pyc files; the filesystem is ephemeral anyway.
# PYTHONUNBUFFERED: stdout/stderr stream immediately instead of being buffered.
#   Without this, `kubectl logs` shows nothing until the buffer flushes or the
#   process dies -- which makes debugging a hanging pod nearly impossible.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Create an unprivileged user to own and run the application.
RUN useradd --create-home --uid 10001 appuser

WORKDIR /srv

COPY --from=builder /install /usr/local
COPY --chown=appuser:appuser app/ /srv/app/

USER appuser

EXPOSE 8000

# Exec form (JSON array), not shell form. Shell form wraps the process in
# /bin/sh, which does not forward SIGTERM -- so Kubernetes' graceful shutdown
# signal is swallowed and every pod deletion takes the full 30s grace period
# before being SIGKILLed.
CMD ["uvicorn", "app.app:app", "--host", "0.0.0.0", "--port", "8000"]