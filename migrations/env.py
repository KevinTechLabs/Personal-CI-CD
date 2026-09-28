"""Alembic environment: online migrations only, URL from DATABASE_URL."""

from __future__ import annotations

from logging.config import fileConfig

from alembic import context
from sqlalchemy import create_engine, pool

from app.config import get_settings
from app.models import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name, disable_existing_loggers=False)

target_metadata = Base.metadata


def run_migrations_online() -> None:
    engine = create_engine(get_settings().database_url, poolclass=pool.NullPool)
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            # Serialise concurrent migration runs (e.g. two deploys racing).
            connection.exec_driver_sql("SELECT pg_advisory_xact_lock(727274)")
            context.run_migrations()


if context.is_offline_mode():
    raise SystemExit("Offline migrations are not supported; set DATABASE_URL.")
run_migrations_online()
