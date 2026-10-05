"""Test fixtures.

Database tests run against a real PostgreSQL (the queue relies on
FOR UPDATE SKIP LOCKED, which SQLite cannot emulate). Point DATABASE_URL at
a throwaway database; in CI this is a Postgres service container.
If DATABASE_URL is unset, database tests are skipped locally but fail in CI
(REQUIRE_DATABASE=1) so they can never be skipped silently.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
HAS_DB = "DATABASE_URL" in os.environ

os.environ.setdefault("ENVIRONMENT", "test")
os.environ.setdefault("APP_VERSION", "test-sha")


def pytest_collection_modifyitems(config, items):
    if HAS_DB:
        return
    if os.environ.get("REQUIRE_DATABASE") == "1":
        raise pytest.UsageError("REQUIRE_DATABASE=1 but DATABASE_URL is not set")
    skip = pytest.mark.skip(reason="DATABASE_URL not set")
    for item in items:
        if "db" in item.keywords:
            item.add_marker(skip)


def _alembic_config():
    from alembic.config import Config

    cfg = Config(str(ROOT / "alembic.ini"))
    cfg.set_main_option("script_location", str(ROOT / "migrations"))
    return cfg


@pytest.fixture(scope="session")
def migrated_db():
    from alembic import command

    cfg = _alembic_config()
    command.downgrade(cfg, "base")
    command.upgrade(cfg, "head")
    yield cfg


@pytest.fixture()
def db_session(migrated_db):
    from sqlalchemy import text

    from app.db import get_sessionmaker

    session = get_sessionmaker()()
    session.execute(text("TRUNCATE tasks, worker_heartbeats RESTART IDENTITY"))
    session.commit()
    try:
        yield session
    finally:
        session.close()


@pytest.fixture()
def client(db_session):
    from fastapi.testclient import TestClient

    from app.api import app

    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture()
def alembic_cfg(migrated_db):
    return migrated_db
