"""add worker_heartbeats table

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-04

Expand-only: a new table the previous release never touches, so it is safe
to apply while that release is still serving.
"""

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "worker_heartbeats",
        sa.Column("worker_id", sa.String(100), primary_key=True),
        sa.Column("version", sa.String(64), nullable=False),
        sa.Column("environment", sa.String(32), nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen", sa.DateTime(timezone=True), nullable=False),
        sa.Column("tasks_processed", sa.Integer(), nullable=False, server_default="0"),
    )
    op.create_index("ix_worker_heartbeats_last_seen", "worker_heartbeats", ["last_seen"])


def downgrade() -> None:
    op.drop_index("ix_worker_heartbeats_last_seen", table_name="worker_heartbeats")
    op.drop_table("worker_heartbeats")
