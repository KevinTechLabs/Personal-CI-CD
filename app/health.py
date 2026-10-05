"""Dependency checks behind GET /ready.

Each check reports one of three states:

  ok        working normally
  degraded  working, but something needs attention; traffic is still served
  fail      this instance cannot do its job

Only *critical* checks can make the instance not ready (HTTP 503):

  database  reachable, answering within the latency budget
  schema    at the Alembic revision this build of the code expects

The others are informational, so a stuck worker never takes the API out of
rotation (the API can still accept tasks), but they are visible to people
(Grafana, alerts) and to the GitOps agent, which refuses to finish a deploy
until a worker *running the new version* is heartbeating:

  worker    at least one worker heartbeat newer than WORKER_STALE_SECONDS
  queue     oldest pending task younger than QUEUE_MAX_AGE_SECONDS
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any

from prometheus_client import Gauge
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.config import Settings

# Defined here rather than in app/metrics.py so only the API process exports
# them (the worker imports app.metrics too, and would otherwise publish a
# misleading constant 0).
# Updated on every GET /ready. The blackbox exporter probes /ready every
# 15s, which keeps these fresh even when no one is looking.
READINESS_CHECK = Gauge(
    "readiness_check_state",
    "Dependency check result: 2=ok, 1=degraded, 0=fail",
    ["check"],
)

READINESS_CHECK_LATENCY = Gauge(
    "readiness_check_duration_seconds",
    "Time taken by a readiness dependency check",
    ["check"],
)

WORKER_HEARTBEAT_AGE = Gauge(
    "worker_heartbeat_age_seconds",
    "Seconds since the most recent worker heartbeat, as seen by the API",
)

QUEUE_OLDEST_AGE = Gauge(
    "queue_oldest_pending_age_seconds",
    "Age of the oldest task still waiting for a worker",
)

OK, DEGRADED, FAIL, SKIPPED = "ok", "degraded", "fail", "skipped"
CRITICAL_CHECKS = ("database", "schema")
_STATE_VALUE = {OK: 2, DEGRADED: 1, FAIL: 0}


@dataclass
class CheckResult:
    status: str
    detail: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {"status": self.status, **self.detail}


def _timed(fn):
    start = time.perf_counter()
    result = fn()
    return result, round((time.perf_counter() - start) * 1000, 1)


def check_database(session: Session, settings: Settings) -> CheckResult:
    try:
        _, latency_ms = _timed(lambda: session.execute(text("SELECT 1")).scalar_one())
    except Exception as exc:  # noqa: BLE001 - any failure means unreachable
        return CheckResult(FAIL, {"error": type(exc).__name__})
    status = OK if latency_ms <= settings.db_latency_budget_ms else DEGRADED
    return CheckResult(status, {"latency_ms": latency_ms})


def check_schema(session: Session, expected: str) -> CheckResult:
    try:
        current = session.execute(text("SELECT version_num FROM alembic_version")).scalar()
    except Exception as exc:  # noqa: BLE001
        return CheckResult(FAIL, {"error": type(exc).__name__, "expected": expected})
    status = OK if current == expected else FAIL
    return CheckResult(status, {"current": current, "expected": expected})


def check_worker(session: Session, settings: Settings) -> CheckResult:
    rows = session.execute(
        text(
            "SELECT version, EXTRACT(EPOCH FROM now() - last_seen) AS age "
            "FROM worker_heartbeats WHERE last_seen > now() - interval '1 hour'"
        )
    ).all()
    fresh = [r for r in rows if float(r.age) < settings.worker_stale_seconds]
    newest = min((float(r.age) for r in rows), default=None)
    detail = {
        "active_workers": len(fresh),
        # The GitOps agent requires its new release to appear here.
        "versions": sorted({r.version for r in fresh}),
        "last_heartbeat_seconds": None if newest is None else round(newest, 1),
        "stale_after_seconds": settings.worker_stale_seconds,
    }
    return CheckResult(OK if fresh else DEGRADED, detail)


def check_queue(session: Session, settings: Settings) -> CheckResult:
    row = session.execute(
        text(
            "SELECT count(*) AS pending, "
            "COALESCE(EXTRACT(EPOCH FROM now() - min(created_at)), 0) AS oldest "
            "FROM tasks WHERE status = 'pending'"
        )
    ).one()
    oldest = round(float(row.oldest), 1)
    status = OK if oldest <= settings.queue_max_age_seconds else DEGRADED
    return CheckResult(
        status,
        {
            "pending": int(row.pending),
            "oldest_pending_seconds": oldest,
            "max_age_seconds": settings.queue_max_age_seconds,
        },
    )


def run_checks(session: Session, settings: Settings, expected_schema: str) -> tuple[int, dict]:
    """Run every check; return (http_status, body). Never raises."""
    checks: dict[str, CheckResult] = {}

    (checks["database"], db_ms) = _timed(lambda: check_database(session, settings))
    READINESS_CHECK_LATENCY.labels("database").set(db_ms / 1000)

    if checks["database"].status == FAIL:
        session.rollback()
        for name in ("schema", "worker", "queue"):
            checks[name] = CheckResult(SKIPPED, {"reason": "database unavailable"})
    else:
        checks["schema"] = check_schema(session, expected_schema)
        for name, fn in (("worker", check_worker), ("queue", check_queue)):
            try:
                checks[name] = fn(session, settings)
            except Exception as exc:  # noqa: BLE001 - e.g. table not migrated yet
                session.rollback()
                checks[name] = CheckResult(FAIL, {"error": type(exc).__name__})
        session.rollback()  # read-only; end the transaction

    _export_metrics(checks)

    if any(checks[name].status == FAIL for name in CRITICAL_CHECKS):
        overall, code = "not_ready", 503
    elif any(c.status in (DEGRADED, FAIL) for c in checks.values()):
        overall, code = "degraded", 200
    else:
        overall, code = "ready", 200

    body = {
        "status": overall,
        "version": settings.app_version,
        "environment": settings.environment,
        "checks": {name: c.as_dict() for name, c in checks.items()},
    }
    return code, body


def _export_metrics(checks: dict[str, CheckResult]) -> None:
    for name, result in checks.items():
        if result.status in _STATE_VALUE:
            READINESS_CHECK.labels(name).set(_STATE_VALUE[result.status])
    if checks["worker"].status in (OK, DEGRADED):
        # No live heartbeat at all -> +Inf, so "age > N" alerts fire instead of
        # the gauge silently keeping its last value.
        worker_age = checks["worker"].detail.get("last_heartbeat_seconds")
        WORKER_HEARTBEAT_AGE.set(float("inf") if worker_age is None else worker_age)
    queue_age = checks["queue"].detail.get("oldest_pending_seconds")
    if queue_age is not None:
        QUEUE_OLDEST_AGE.set(queue_age)
