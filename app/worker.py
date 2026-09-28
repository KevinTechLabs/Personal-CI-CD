"""Background worker: drains the Postgres-backed task queue.

Each task is claimed, processed and completed inside a single transaction
using SELECT ... FOR UPDATE SKIP LOCKED. That gives us:

* safe concurrency: several workers never pick the same row;
* crash safety: if a worker dies mid-task, its transaction rolls back and the
  row simply becomes pending again, with no stuck "processing" state to clean up.
"""

from __future__ import annotations

import logging
import signal
import time
from datetime import UTC, datetime
from pathlib import Path

from prometheus_client import start_http_server
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import get_sessionmaker
from app.metrics import QUEUE_DEPTH, TASK_DURATION, TASKS_PROCESSED, set_build_info
from app.models import Task, TaskStatus
from app.processing import TaskError, process_payload

log = logging.getLogger("worker")
MAX_ATTEMPTS = 3


def process_one(session: Session) -> bool:
    """Process at most one pending task. Returns True if a task was handled."""
    with session.begin():
        task = session.scalars(
            select(Task)
            .where(Task.status == TaskStatus.pending)
            .order_by(Task.id)
            .limit(1)
            .with_for_update(skip_locked=True)
        ).first()
        if task is None:
            return False

        task.attempts += 1
        started = time.perf_counter()
        try:
            task.result = process_payload(task.payload)
            task.status = TaskStatus.done
            outcome = "done"
        except TaskError as exc:
            task.status = TaskStatus.failed
            task.error = str(exc)[:500]
            outcome = "failed"
        except Exception as exc:  # noqa: BLE001 - retry unexpected errors
            log.exception("task %s attempt %s errored", task.id, task.attempts)
            if task.attempts >= MAX_ATTEMPTS:
                task.status = TaskStatus.failed
                task.error = f"gave up after {task.attempts} attempts: {exc}"[:500]
                outcome = "failed"
            else:
                outcome = "retried"
        finally:
            TASK_DURATION.observe(time.perf_counter() - started)

        if task.status != TaskStatus.pending:
            task.processed_at = datetime.now(UTC)
        TASKS_PROCESSED.labels(outcome).inc()
        log.info("task %s -> %s", task.id, outcome)
        return True


def update_queue_depth(session: Session) -> None:
    with session.begin():
        depth = session.scalar(
            select(func.count()).select_from(Task).where(Task.status == TaskStatus.pending)
        )
    QUEUE_DEPTH.set(depth or 0)


def run() -> None:  # pragma: no cover - exercised end-to-end by the CI smoke test
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    settings = get_settings()
    set_build_info(settings.app_version, settings.environment, "worker")
    start_http_server(settings.worker_metrics_port)
    heartbeat = Path(settings.worker_heartbeat_file)
    make_session = get_sessionmaker()

    stopping = False

    def stop(signum, _frame):
        nonlocal stopping
        log.info("received signal %s, finishing current task", signum)
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    log.info("worker %s started (%s)", settings.app_version, settings.environment)
    while not stopping:
        try:
            with make_session() as session:
                handled = process_one(session)
                update_queue_depth(session)
            heartbeat.touch()
        except Exception:  # noqa: BLE001 - keep the loop alive, e.g. DB restarts
            log.exception("worker loop error")
            handled = False
        if not handled:
            time.sleep(settings.worker_poll_seconds)
    log.info("worker stopped")


if __name__ == "__main__":
    run()
