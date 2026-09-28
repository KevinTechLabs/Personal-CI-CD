import threading

import pytest

from app.db import get_sessionmaker
from app.models import Task, TaskStatus
from app.worker import MAX_ATTEMPTS, process_one

pytestmark = pytest.mark.db


def _add(session, payload):
    task = Task(payload=payload, status=TaskStatus.pending)
    session.add(task)
    session.commit()
    return task.id


def test_worker_completes_task(db_session):
    task_id = _add(db_session, "one two two")
    assert process_one(db_session) is True

    task = db_session.get(Task, task_id)
    db_session.refresh(task)
    assert task.status == TaskStatus.done
    assert task.result["words"] == 3
    assert task.attempts == 1
    assert task.processed_at is not None


def test_worker_returns_false_when_queue_empty(db_session):
    assert process_one(db_session) is False


def test_invalid_payload_fails_without_retry(db_session):
    task_id = _add(db_session, "   ")
    process_one(db_session)
    task = db_session.get(Task, task_id)
    db_session.refresh(task)
    assert task.status == TaskStatus.failed
    assert task.attempts == 1


def test_unexpected_error_retries_then_fails(db_session, monkeypatch):
    def boom(_payload):
        raise RuntimeError("transient")

    monkeypatch.setattr("app.worker.process_payload", boom)
    task_id = _add(db_session, "retry me")
    for _ in range(MAX_ATTEMPTS):
        process_one(db_session)

    task = db_session.get(Task, task_id)
    db_session.refresh(task)
    assert task.status == TaskStatus.failed
    assert task.attempts == MAX_ATTEMPTS
    assert "gave up" in task.error


def test_concurrent_workers_never_share_a_task(db_session):
    ids = [_add(db_session, f"task {n}") for n in range(20)]
    make_session = get_sessionmaker()
    errors = []

    def drain():
        try:
            with make_session() as session:
                while process_one(session):
                    pass
        except Exception as exc:  # pragma: no cover - surfaced below
            errors.append(exc)

    threads = [threading.Thread(target=drain) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert not errors
    db_session.expire_all()
    tasks = [db_session.get(Task, i) for i in ids]
    assert all(t.status == TaskStatus.done for t in tasks)
    # Each task processed exactly once.
    assert all(t.attempts == 1 for t in tasks)
