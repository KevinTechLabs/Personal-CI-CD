"""Background worker: drains the Postgres-backed task queue.

Each task is claimed, processed and completed inside a single transaction
using SELECT ... FOR UPDATE SKIP LOCKED. That gives us:

* safe concurrency: several workers never pick the same row;
* crash safety: if a worker dies mid-task, its transaction rolls back and the
  row simply becomes pending again, with no stuck "processing" state to clean up.
"""

from __future__ import annotations

import logging
import os
import signal
import socket
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

from prometheus_client import start_http_server
from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import get_sessionmaker
from app.metrics import QUEUE_DEPTH, TASK_DURATION, TASKS_PROCESSED, set_build_info
from app.models import Task, TaskStatus, WorkerHeartbeat
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


class Heartbeat:
    """Publishes this worker's liveness and version to Postgres.

    The API reads these rows for its readiness report, and the GitOps agent
    uses that report to confirm a worker running the *new* release is alive
    before it declares a deploy successful.
    """

    def __init__(
        self, version: str, environment: str, interval: float, worker_id: str | None = None
    ) -> None:
        # In a container the hostname is the container ID: unique per worker.
        self.worker_id = (worker_id or f"{socket.gethostname()}-{os.getpid()}")[:100]
        self.version = version
        self.environment = environment
        self.interval = interval
        self.started_at = datetime.now(UTC)
        self.tasks_processed = 0
        # -inf, not 0: time.monotonic() counts from boot, so on a freshly
        # booted host (CI runners, a rebooted server) it can be smaller than
        # the interval, and a 0 here would silently skip the first heartbeat.
        self._last_beat = float("-inf")

    def beat(self, session: Session, *, force: bool = False) -> bool:
        """Upsert this worker's row, at most once per interval. Returns True if written."""
        now = time.monotonic()
        if not force and now - self._last_beat < self.interval:
            return False
        stmt = insert(WorkerHeartbeat).values(
            worker_id=self.worker_id,
            version=self.version,
            environment=self.environment,
            started_at=self.started_at,
            last_seen=func.now(),
            tasks_processed=self.tasks_processed,
        )
        stmt = stmt.on_conflict_do_update(
            index_elements=[WorkerHeartbeat.worker_id],
            set_={"last_seen": func.now(), "tasks_processed": self.tasks_processed},
        )
        with session.begin():
            session.execute(stmt)
        self._last_beat = now
        return True

    def retire(self, session: Session) -> None:
        """Remove our row on clean shutdown so we stop counting as alive at once."""
        with session.begin():
            session.execute(
                delete(WorkerHeartbeat).where(WorkerHeartbeat.worker_id == self.worker_id)
            )


def prune_heartbeats(session: Session, older_than_hours: int = 24) -> int:
    """Delete heartbeat rows left behind by workers that died without retiring."""
    with session.begin():
        result = session.execute(
            delete(WorkerHeartbeat).where(
                WorkerHeartbeat.last_seen < func.now() - timedelta(hours=older_than_hours)
            )
        )
    return result.rowcount or 0


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

    beat = Heartbeat(settings.app_version, settings.environment, settings.worker_heartbeat_interval)
    try:
        with make_session() as session:
            pruned = prune_heartbeats(session)
            if pruned:
                log.info("pruned %s stale heartbeat rows", pruned)
    except Exception:  # noqa: BLE001 - not fatal; DB may still be starting
        log.exception("could not prune heartbeats")

    log.info(
        "worker %s (%s) started as %s", settings.app_version, settings.environment, beat.worker_id
    )
    while not stopping:
        try:
            with make_session() as session:
                handled = process_one(session)
                if handled:
                    beat.tasks_processed += 1
                if beat.beat(session):
                    update_queue_depth(session)
            heartbeat.touch()
        except Exception:  # noqa: BLE001 - keep the loop alive, e.g. DB restarts
            log.exception("worker loop error")
            handled = False
        if not handled:
            time.sleep(settings.worker_poll_seconds)

    try:
        with make_session() as session:
            beat.retire(session)
    except Exception:  # noqa: BLE001
        log.exception("could not retire heartbeat")
    log.info("worker stopped")


if __name__ == "__main__":
    run()
