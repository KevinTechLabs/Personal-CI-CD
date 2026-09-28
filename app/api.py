"""HTTP API."""

from __future__ import annotations

import os
import random
import time
from functools import lru_cache

from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel, Field
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import get_session
from app.metrics import HTTP_LATENCY, HTTP_REQUESTS, set_build_info
from app.models import Task, TaskStatus
from app.processing import MAX_PAYLOAD_CHARS

settings = get_settings()
set_build_info(settings.app_version, settings.environment, "api")

app = FastAPI(title="Personal CI/CD Demo", version=settings.app_version)

# Probe and scrape endpoints are excluded from request metrics so they do not
# dilute the error-ratio SLO that drives automatic rollback.
UNMETERED_PATHS = {"/metrics", "/health", "/ready"}
CHAOS_EXEMPT_PATHS = UNMETERED_PATHS | {"/version"}


def _chaos_error_rate() -> float:
    """Fraction of requests to fail on purpose (0 disables).

    Exists only so the auto-rollback path can be demonstrated: set
    CHAOS_ERROR_RATE=0.5 for staging, promote, and watch the GitOps agent
    detect the SLO breach and roll back. Health probes are never affected, so
    this exercises the SLO check rather than the health check.
    """
    try:
        return max(0.0, min(1.0, float(os.environ.get("CHAOS_ERROR_RATE", "0"))))
    except ValueError:
        return 0.0


@app.middleware("http")
async def observe_requests(request: Request, call_next):
    path = request.url.path
    rate = _chaos_error_rate()
    # Not used for security; plain PRNG is fine for fault injection.
    if rate and path not in CHAOS_EXEMPT_PATHS and random.random() < rate:  # noqa: S311  # nosec B311
        response = JSONResponse({"detail": "injected failure"}, status_code=500)
        HTTP_REQUESTS.labels(request.method, "chaos", "500").inc()
        return response

    start = time.perf_counter()
    status = "500"
    try:
        response = await call_next(request)
        status = str(response.status_code)
        return response
    finally:
        if path not in UNMETERED_PATHS:
            route = request.scope.get("route")
            template = getattr(route, "path", "unmatched")
            HTTP_REQUESTS.labels(request.method, template, status).inc()
            HTTP_LATENCY.labels(request.method, template).observe(time.perf_counter() - start)


@lru_cache(maxsize=1)
def expected_schema_revision() -> str:
    """The Alembic head this build of the code expects."""
    from alembic.config import Config
    from alembic.script import ScriptDirectory

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cfg = Config(os.path.join(root, "alembic.ini"))
    cfg.set_main_option("script_location", os.path.join(root, "migrations"))
    head = ScriptDirectory.from_config(cfg).get_current_head()
    if head is None:
        raise RuntimeError("no Alembic head revision found")
    return head


class TaskCreate(BaseModel):
    payload: str = Field(min_length=1, max_length=MAX_PAYLOAD_CHARS)


class TaskOut(BaseModel):
    id: int
    payload: str
    status: TaskStatus
    result: dict | None
    error: str | None
    attempts: int

    model_config = {"from_attributes": True}


@app.get("/")
def root() -> dict:
    return {
        "application": "Personal CI/CD Demo",
        "environment": settings.environment,
        "version": settings.app_version,
        "status": "running",
    }


@app.get("/health")
def health() -> dict:
    """Liveness: the process is up. Never touches dependencies."""
    return {"status": "healthy"}


@app.get("/ready")
def ready(response: Response, session: Session = Depends(get_session)) -> dict:
    """Readiness: database reachable and schema at the revision we expect."""
    try:
        current = session.execute(
            text("SELECT version_num FROM alembic_version")
        ).scalar_one_or_none()
    except Exception:  # noqa: BLE001 - any DB failure means not ready
        response.status_code = 503
        return {"status": "not_ready", "reason": "database unavailable"}

    expected = expected_schema_revision()
    if current != expected:
        response.status_code = 503
        return {
            "status": "not_ready",
            "reason": "schema revision mismatch",
            "database": current,
            "expected": expected,
        }
    return {"status": "ready", "schema": current}


@app.get("/version")
def version() -> dict:
    return {"version": settings.app_version, "environment": settings.environment}


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/api/tasks", response_model=TaskOut, status_code=201)
def create_task(body: TaskCreate, session: Session = Depends(get_session)) -> Task:
    task = Task(payload=body.payload, status=TaskStatus.pending)
    session.add(task)
    session.commit()
    session.refresh(task)
    return task


@app.get("/api/tasks", response_model=list[TaskOut])
def list_tasks(
    status: TaskStatus | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    session: Session = Depends(get_session),
) -> list[Task]:
    query = select(Task).order_by(Task.id.desc()).limit(limit)
    if status is not None:
        query = query.where(Task.status == status)
    return list(session.scalars(query))


@app.get("/api/tasks/{task_id}", response_model=TaskOut)
def get_task(task_id: int, session: Session = Depends(get_session)) -> Task:
    task = session.get(Task, task_id)
    if task is None:
        raise HTTPException(status_code=404, detail="task not found")
    return task
