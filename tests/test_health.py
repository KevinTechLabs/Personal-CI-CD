"""Dependency checks behind /ready (app/health.py) against real Postgres."""

from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import text

from app.config import get_settings
from app.models import Task, TaskStatus, WorkerHeartbeat
from app.worker import Heartbeat, prune_heartbeats

pytestmark = pytest.mark.db


def _beat(session, version="test-sha"):
    hb = Heartbeat(version, "test", interval=0, worker_id=f"worker-{version}")
    hb.beat(session, force=True)
    return hb


def test_no_worker_is_degraded_but_still_serving(client):
    response = client.get("/ready")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "degraded"
    worker = body["checks"]["worker"]
    assert worker["status"] == "degraded"
    assert worker["active_workers"] == 0
    assert worker["versions"] == []


def test_fresh_heartbeat_makes_ready(client, db_session):
    _beat(db_session)
    body = client.get("/ready").json()
    assert body["status"] == "ready"
    worker = body["checks"]["worker"]
    assert worker == {
        "status": "ok",
        "active_workers": 1,
        "versions": ["test-sha"],
        "last_heartbeat_seconds": worker["last_heartbeat_seconds"],
        "stale_after_seconds": get_settings().worker_stale_seconds,
    }
    assert worker["last_heartbeat_seconds"] < 5


def test_reports_each_live_worker_version(client, db_session):
    # Mid-deploy both releases can be alive; the agent needs to see the new one.
    _beat(db_session, "old-sha")
    _beat(db_session, "new-sha")
    worker = client.get("/ready").json()["checks"]["worker"]
    assert worker["versions"] == ["new-sha", "old-sha"]
    assert worker["active_workers"] == 2


def test_stale_heartbeat_is_degraded(client, db_session):
    _beat(db_session)
    db_session.execute(
        text("UPDATE worker_heartbeats SET last_seen = now() - interval '5 minutes'")
    )
    db_session.commit()
    worker = client.get("/ready").json()["checks"]["worker"]
    assert worker["status"] == "degraded"
    assert worker["versions"] == []
    assert worker["last_heartbeat_seconds"] >= 300


def test_retired_worker_disappears_immediately(client, db_session):
    hb = _beat(db_session)
    hb.retire(db_session)
    assert client.get("/ready").json()["checks"]["worker"]["active_workers"] == 0


def test_heartbeat_is_throttled(db_session):
    hb = Heartbeat("test-sha", "test", interval=60)
    assert hb.beat(db_session) is True
    assert hb.beat(db_session) is False
    assert hb.beat(db_session, force=True) is True


def test_first_heartbeat_is_never_throttled_on_a_fresh_boot(db_session, monkeypatch):
    # Regression: time.monotonic() is seconds since boot; a host up for less
    # than the interval used to skip the first beat.
    monkeypatch.setattr("app.worker.time.monotonic", lambda: 3.0)
    hb = Heartbeat("test-sha", "test", interval=60)
    assert hb.beat(db_session) is True
    assert hb.beat(db_session) is False


def test_heartbeat_upsert_tracks_processed_count(db_session):
    hb = _beat(db_session)
    hb.tasks_processed = 7
    hb.beat(db_session, force=True)
    row = db_session.get(WorkerHeartbeat, hb.worker_id)
    db_session.refresh(row)
    assert row.tasks_processed == 7
    assert db_session.query(WorkerHeartbeat).count() == 1


def test_prune_removes_only_abandoned_rows(db_session):
    _beat(db_session, "alive")
    db_session.add(
        WorkerHeartbeat(
            worker_id="ghost",
            version="dead",
            environment="test",
            started_at=datetime.now(UTC) - timedelta(days=3),
            last_seen=datetime.now(UTC) - timedelta(days=2),
        )
    )
    db_session.commit()
    assert prune_heartbeats(db_session) == 1
    assert [r.version for r in db_session.query(WorkerHeartbeat)] == ["alive"]


def test_old_pending_task_degrades_queue(client, db_session):
    _beat(db_session)
    db_session.add(Task(payload="waiting", status=TaskStatus.pending))
    db_session.commit()
    assert client.get("/ready").json()["checks"]["queue"]["status"] == "ok"

    db_session.execute(text("UPDATE tasks SET created_at = now() - interval '10 minutes'"))
    db_session.commit()
    body = client.get("/ready").json()
    queue = body["checks"]["queue"]
    assert queue["status"] == "degraded"
    assert queue["pending"] == 1
    assert queue["oldest_pending_seconds"] >= 600
    assert body["status"] == "degraded"


def test_database_outage_is_not_ready(client, monkeypatch):
    import app.health as health

    monkeypatch.setattr(health, "check_database", lambda *_: health.CheckResult("fail", {}))
    response = client.get("/ready")
    assert response.status_code == 503
    body = response.json()
    assert body["status"] == "not_ready"
    for name in ("schema", "worker", "queue"):
        assert body["checks"][name]["status"] == "skipped"


def test_slow_database_is_degraded(client, db_session, monkeypatch):
    _beat(db_session)
    monkeypatch.setenv("DB_LATENCY_BUDGET_MS", "0")
    import app.api

    monkeypatch.setattr(app.api, "settings", get_settings())
    body = client.get("/ready").json()
    assert body["checks"]["database"]["status"] == "degraded"
    assert body["status"] == "degraded"
    assert client.get("/ready").status_code == 200


def test_readiness_metrics_exported(client, db_session):
    _beat(db_session)
    client.get("/ready")
    metrics = client.get("/metrics").text
    assert 'readiness_check_state{check="database"} 2.0' in metrics
    assert 'readiness_check_state{check="worker"} 2.0' in metrics
    assert "worker_heartbeat_age_seconds" in metrics
    assert "queue_oldest_pending_age_seconds" in metrics


def test_heartbeat_age_metric_is_infinite_without_workers(client, db_session):
    hb = _beat(db_session)
    client.get("/ready")
    assert "worker_heartbeat_age_seconds 0" in client.get("/metrics").text
    hb.retire(db_session)
    client.get("/ready")
    assert "worker_heartbeat_age_seconds +Inf" in client.get("/metrics").text
