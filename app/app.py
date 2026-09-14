"""
FastAPI + Redis demo service.

All configuration is read from environment variables so that one immutable
build artifact runs unchanged on a laptop, in Docker, and in Kubernetes.
"""

import os
import socket
from contextlib import asynccontextmanager

import redis.asyncio as redis
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from redis.exceptions import RedisError

# ---------------------------------------------------------------------------
# Configuration
#
# Every value has a sensible local-development default. Nothing here knows
# or cares whether it is running on a laptop or inside a cluster.
# ---------------------------------------------------------------------------

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_DB = int(os.getenv("REDIS_DB", "0"))
REDIS_PASSWORD = os.getenv("REDIS_PASSWORD") or None

APP_NAME = os.getenv("APP_NAME", "fastapi-redis-lab")

# In Kubernetes, HOSTNAME is set to the pod name. Locally it is the machine
# name. Either way this identifies which instance served a given request --
# which becomes very useful once there are multiple replicas behind a Service.
INSTANCE_ID = os.getenv("HOSTNAME", socket.gethostname())


# ---------------------------------------------------------------------------
# Lifespan
#
# The Redis client (and its connection pool) is created once at startup and
# reused for every request. Creating it per-request would add a TCP handshake
# to every call.
#
# Note what this deliberately does NOT do: it does not ping Redis and refuse
# to start if Redis is down. An app that crashes on a missing dependency
# enters CrashLoopBackOff and cannot even report why. Starting successfully
# and reporting "not ready" is strictly better behaviour.
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.redis = redis.Redis(
        host=REDIS_HOST,
        port=REDIS_PORT,
        db=REDIS_DB,
        password=REDIS_PASSWORD,
        decode_responses=True,
        socket_connect_timeout=2,
        socket_timeout=2,
        health_check_interval=30,
    )
    yield
    await app.state.redis.aclose()


app = FastAPI(title=APP_NAME, version="0.1.0", lifespan=lifespan)


class ValueIn(BaseModel):
    value: str
    ttl_seconds: int | None = Field(default=None, ge=1)


# ---------------------------------------------------------------------------
# Informational
# ---------------------------------------------------------------------------


@app.get("/")
async def root():
    return {
        "app": APP_NAME,
        "instance": INSTANCE_ID,
        "redis_target": f"{REDIS_HOST}:{REDIS_PORT}/{REDIS_DB}",
        "auth": "password" if REDIS_PASSWORD else "none",
    }


# ---------------------------------------------------------------------------
# Health endpoints
#
# /healthz -> liveness. Answers "is this process functioning?" It must never
#             check external dependencies. A Redis outage must not cause
#             Kubernetes to restart every API pod.
#
# /readyz  -> readiness. Answers "can this instance serve real traffic?" It
#             must check every dependency required to do useful work.
# ---------------------------------------------------------------------------


@app.get("/healthz")
async def healthz():
    return {"status": "alive", "instance": INSTANCE_ID}


@app.get("/readyz")
async def readyz():
    try:
        await app.state.redis.ping()
    except (RedisError, OSError) as exc:
        raise HTTPException(
            status_code=503,
            detail=f"redis unavailable at {REDIS_HOST}:{REDIS_PORT}: {exc}",
        )
    return {"status": "ready", "instance": INSTANCE_ID}


# ---------------------------------------------------------------------------
# Counter -- demonstrates shared state across replicas
# ---------------------------------------------------------------------------


@app.post("/counter/{name}")
async def increment_counter(name: str):
    try:
        value = await app.state.redis.incr(f"counter:{name}")
    except (RedisError, OSError) as exc:
        raise HTTPException(status_code=503, detail=f"redis error: {exc}")
    return {"counter": name, "value": value, "served_by": INSTANCE_ID}


@app.get("/counter/{name}")
async def read_counter(name: str):
    try:
        raw = await app.state.redis.get(f"counter:{name}")
    except (RedisError, OSError) as exc:
        raise HTTPException(status_code=503, detail=f"redis error: {exc}")
    return {"counter": name, "value": int(raw or 0), "served_by": INSTANCE_ID}


# ---------------------------------------------------------------------------
# Key/value -- demonstrates persistence and TTL
# ---------------------------------------------------------------------------


@app.put("/kv/{key}")
async def set_value(key: str, body: ValueIn):
    try:
        await app.state.redis.set(f"kv:{key}", body.value, ex=body.ttl_seconds)
    except (RedisError, OSError) as exc:
        raise HTTPException(status_code=503, detail=f"redis error: {exc}")
    return {"key": key, "value": body.value, "ttl_seconds": body.ttl_seconds}


@app.get("/kv/{key}")
async def get_value(key: str):
    try:
        value = await app.state.redis.get(f"kv:{key}")
        ttl = await app.state.redis.ttl(f"kv:{key}")
    except (RedisError, OSError) as exc:
        raise HTTPException(status_code=503, detail=f"redis error: {exc}")
    if value is None:
        raise HTTPException(status_code=404, detail=f"key not found: {key}")
    return {"key": key, "value": value, "ttl_seconds": ttl if ttl >= 0 else None}


@app.delete("/kv/{key}")
async def delete_value(key: str):
    try:
        removed = await app.state.redis.delete(f"kv:{key}")
    except (RedisError, OSError) as exc:
        raise HTTPException(status_code=503, detail=f"redis error: {exc}")
    if removed == 0:
        raise HTTPException(status_code=404, detail=f"key not found: {key}")
    return {"key": key, "deleted": True}