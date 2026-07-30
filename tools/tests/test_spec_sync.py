"""Unit coverage for the spec_sync pure layer — projections + SQL generation (#167).

No database: the DB-backed convergence proof lives in tests/integration/test_spec_sync.py.
"""

from __future__ import annotations

import pytest

from tools.spec_sync import (
    Delta,
    generate_migration,
    lint_mart_literals,
    spec_raw_columns,
    spec_registry_rows,
)

_ROW = ("metrics", "*", "x.y", "promoted", "xy", "TEXT", "desc", None, "2026-07-13", None)


def test_spec_raw_columns_map_spec_types_to_pg_types() -> None:
    cols = spec_raw_columns()
    assert cols["metrics"]["cc_version"] == "text"
    assert cols["metrics"]["value"] == "double precision"
    assert cols["events"]["input_tokens"] == "bigint"
    assert cols["events"]["success_bool"] == "boolean"
    assert cols["events"]["session_id"] == "uuid"
    # A promoted resource row creates the column on *both* raw tables: the sink merges
    # the resource block into each signal's flat namespace, so it is written for
    # metrics and events alike (#357 service_name / os_type).
    assert cols["metrics"]["service_name"] == "text"
    assert cols["events"]["service_name"] == "text"


def test_spec_registry_rows_cover_every_spec_row() -> None:
    from cc_otel_sink.column_spec import COLUMN_SPEC

    assert len(spec_registry_rows()) == len(COLUMN_SPEC)


def test_generate_migration_emits_add_column_and_insert() -> None:
    delta = Delta(missing_rows=[_ROW], missing_columns=[("metrics", "xy", "TEXT")])
    sql = generate_migration("add_xy", delta)
    assert "-- migrate:up" in sql and "-- migrate:down" in sql
    # The file lands under db/, which pre-commit lints with sqlfluff: a one-line
    # registry INSERT is long by construction, so the generator waives LT05/LT14.
    assert "-- noqa: disable=LT05,LT14" in sql
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


# --- mart-literal lint (#168) -------------------------------------------------


def test_lint_passes_on_known_literals(tmp_path) -> None:
    (tmp_path / "1.sql").write_text(
        "metric_name = 'claude_code.session.count' AND type_label = 'added'\n"
        "value_kind = 'sum_delta'\n",
        encoding="utf-8",
    )
    assert lint_mart_literals(tmp_path) == []


def test_lint_flags_unknown_metric_name_with_file_line(tmp_path) -> None:
    (tmp_path / "m.sql").write_text(
        "SELECT 1\nWHERE metric_name = 'claude_code.comit.count'\n", encoding="utf-8"
    )
    v = lint_mart_literals(tmp_path)
    assert len(v) == 1
    assert v[0].path.name == "m.sql"
    assert v[0].line == 2
    assert v[0].column == "metric_name"
    assert v[0].literal == "claude_code.comit.count"


def test_lint_flags_unknown_enum_values(tmp_path) -> None:
    (tmp_path / "1.sql").write_text(
        "type_label = 'addded'\nvalue_kind = 'sum_bogus'\n", encoding="utf-8"
    )
    assert {v.literal for v in lint_mart_literals(tmp_path)} == {"addded", "sum_bogus"}


def test_lint_covers_in_and_any_set_forms(tmp_path) -> None:
    (tmp_path / "1.sql").write_text(
        "type_label IN ('user', 'cli', 'bogus')\n"
        "metric_name = ANY (ARRAY['claude_code.commit.count', 'claude_code.nope'])\n",
        encoding="utf-8",
    )
    assert {v.literal for v in lint_mart_literals(tmp_path)} == {"bogus", "claude_code.nope"}


def test_lint_is_green_on_real_migrations() -> None:
    # Acceptance: the catalog covers every literal the live mart SQL references.
    from tools.spec_sync import _MIGRATIONS_DIR

    violations = lint_mart_literals(_MIGRATIONS_DIR)
    assert violations == [], "\n".join(
        f"{v.path.name}:{v.line} {v.column}={v.literal!r}" for v in violations
    )
