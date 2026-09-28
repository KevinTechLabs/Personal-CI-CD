import pytest
from alembic import command
from alembic.script import ScriptDirectory
from sqlalchemy import inspect

from app.api import expected_schema_revision
from app.db import get_engine

pytestmark = pytest.mark.db


def test_single_migration_head():
    # Two heads means two branches added migrations in parallel; merge them.
    from tests.conftest import _alembic_config

    heads = ScriptDirectory.from_config(_alembic_config()).get_heads()
    assert len(heads) == 1, f"multiple Alembic heads: {heads}"


def test_code_expects_the_migration_head():
    from tests.conftest import _alembic_config

    head = ScriptDirectory.from_config(_alembic_config()).get_current_head()
    assert expected_schema_revision() == head


def test_downgrade_and_upgrade_round_trip(alembic_cfg):
    command.downgrade(alembic_cfg, "base")
    assert "tasks" not in inspect(get_engine()).get_table_names()
    command.upgrade(alembic_cfg, "head")
    assert "tasks" in inspect(get_engine()).get_table_names()
