"""Unit coverage for the spec_sync pure layer — projections + SQL generation (#167).

No database: the DB-backed convergence proof lives in tests/integration/test_spec_sync.py.
"""

from __future__ import annotations

import pytest

from tools.spec_sync import Delta, generate_migration, spec_raw_columns, spec_registry_rows

_ROW = ("metrics", "*", "x.y", "promoted", "xy", "TEXT", "desc", None, "2026-07-13", None)


def test_spec_raw_columns_map_spec_types_to_pg_types() -> None:
    cols = spec_raw_columns()
    assert cols["metrics"]["cc_version"] == "text"
    assert cols["metrics"]["value"] == "double precision"
    assert cols["events"]["input_tokens"] == "bigint"
    assert cols["events"]["success_bool"] == "boolean"
    assert cols["events"]["session_id"] == "uuid"
    # resource-only rows never create a raw table column.
    assert "service_name" not in cols["metrics"] and "service_name" not in cols["events"]


def test_spec_registry_rows_cover_every_spec_row() -> None:
    from cc_otel_sink.column_spec import COLUMN_SPEC

    assert len(spec_registry_rows()) == len(COLUMN_SPEC)


def test_generate_migration_emits_add_column_and_insert() -> None:
    delta = Delta(missing_rows=[_ROW], missing_columns=[("metrics", "xy", "TEXT")])
    sql = generate_migration("add_xy", delta)
    assert "-- migrate:up" in sql and "-- migrate:down" in sql
    assert "ALTER TABLE raw.metrics ADD COLUMN xy TEXT;" in sql
    assert "INSERT INTO meta.column_registry" in sql and "'xy'" in sql
    # down reverses both
    down = sql.split("-- migrate:down", 1)[1]
    assert "DROP COLUMN xy" in down
    assert "DELETE FROM meta.column_registry" in down


def test_generate_migration_refuses_type_change() -> None:
    delta = Delta(mismatched_columns=[("metrics", "a", "text", "double precision")])
    with pytest.raises(ValueError, match="type change refused"):
        generate_migration("x", delta)


def test_generate_migration_refuses_orphan_rows() -> None:
    delta = Delta(orphan_rows=[_ROW])
    with pytest.raises(ValueError, match="absent from the spec"):
        generate_migration("x", delta)


def test_generate_migration_gates_column_drop_behind_flag() -> None:
    delta = Delta(orphan_columns=[("metrics", "stale")])
    with pytest.raises(ValueError, match="allow-destructive"):
        generate_migration("x", delta)
    sql = generate_migration("x", delta, allow_destructive=True)
    assert "ALTER TABLE raw.metrics DROP COLUMN stale;" in sql


def test_sql_literal_escapes_quotes() -> None:
    delta = Delta(missing_rows=[_ROW[:6] + ("it's a note", None, "2026-07-13", None)])
    sql = generate_migration("x", delta)
    assert "'it''s a note'" in sql
