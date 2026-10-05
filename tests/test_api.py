import pytest
from sqlalchemy import text

pytestmark = pytest.mark.db


def test_root_reports_version_and_environment(client):
    body = client.get("/").json()
    assert body["status"] == "running"
    assert body["version"] == "test-sha"
    assert body["environment"] == "test"


def test_health_is_dependency_free(client):
    assert client.get("/health").json() == {"status": "healthy"}


def test_ready_reports_every_dependency(client):
    body = client.get("/ready").json()
    assert set(body["checks"]) == {"database", "schema", "worker", "queue"}
    assert body["checks"]["database"]["status"] == "ok"
    assert body["checks"]["schema"]["status"] == "ok"
    assert body["version"] == "test-sha"


def test_ready_fails_on_schema_mismatch(client, db_session):
    current = db_session.execute(text("SELECT version_num FROM alembic_version")).scalar()
    db_session.execute(text("UPDATE alembic_version SET version_num = 'stale'"))
    db_session.commit()
    try:
        response = client.get("/ready")
        assert response.status_code == 503
        body = response.json()
        assert body["status"] == "not_ready"
        assert body["checks"]["schema"] == {
            "status": "fail",
            "current": "stale",
            "expected": current,
        }
    finally:
        db_session.execute(text("UPDATE alembic_version SET version_num = :v"), {"v": current})
        db_session.commit()


def test_create_and_fetch_task(client):
    created = client.post("/api/tasks", json={"payload": "ship it"})
    assert created.status_code == 201
    task = created.json()
    assert task["status"] == "pending"

    fetched = client.get(f"/api/tasks/{task['id']}")
    assert fetched.status_code == 200
    assert fetched.json()["payload"] == "ship it"


def test_list_tasks_filters_by_status(client):
    client.post("/api/tasks", json={"payload": "one"})
    client.post("/api/tasks", json={"payload": "two"})
    assert len(client.get("/api/tasks?status=pending").json()) == 2
    assert client.get("/api/tasks?status=done").json() == []


def test_rejects_empty_payload(client):
    assert client.post("/api/tasks", json={"payload": ""}).status_code == 422


def test_missing_task_is_404(client):
    assert client.get("/api/tasks/999999").status_code == 404


def test_metrics_use_route_templates(client):
    client.get("/api/tasks/424242")
    metrics = client.get("/metrics").text
    assert 'route="/api/tasks/{task_id}"' in metrics
    assert "424242" not in metrics
    assert "app_build_info" in metrics


def test_chaos_injection_spares_probes(client, monkeypatch):
    monkeypatch.setenv("CHAOS_ERROR_RATE", "1")
    assert client.get("/api/tasks").status_code == 500
    assert client.get("/health").status_code == 200
    assert client.get("/ready").status_code == 200  # degraded (no worker), not failed
    assert client.get("/version").status_code == 200
