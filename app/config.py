"""Runtime configuration, read once from environment variables."""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    database_url: str
    environment: str
    app_version: str
    worker_poll_seconds: float
    worker_metrics_port: int
    worker_heartbeat_file: str


def get_settings() -> Settings:
    return Settings(
        database_url=os.environ.get(
            "DATABASE_URL",
            "postgresql+psycopg://app:app@localhost:5432/app",
        ),
        environment=os.environ.get("ENVIRONMENT", "local"),
        # Injected at build time (Dockerfile ARG) so every running container
        # can report exactly which commit it was built from.
        app_version=os.environ.get("APP_VERSION", "dev"),
        worker_poll_seconds=float(os.environ.get("WORKER_POLL_SECONDS", "1.0")),
        worker_metrics_port=int(os.environ.get("WORKER_METRICS_PORT", "9100")),
        worker_heartbeat_file=os.environ.get(
            "WORKER_HEARTBEAT_FILE",
            "/tmp/worker-heartbeat",  # noqa: S108  # nosec B108 - tmpfs, read-only container
        ),
    )
