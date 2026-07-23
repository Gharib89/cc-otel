"""Integration: spec_sync converges against a migrated Postgres (#167).

Uses the shared testcontainers harness (conftest) — never the dev DB.
"""

from __future__ import annotations

from cc_otel_sink.column_spec import COLUMN_SPEC, ColumnSpec

from tools.spec_sync import compute_delta, generate_migration


def _up_body(sql: str) -> str:
    return sql.split("-- migrate:up", 1)[1].split("-- migrate:down", 1)[0]


def test_check_is_green_from_zero(conn) -> None:
    # Proves the COLUMN_SPEC transcription matches the applied seed + raw DDL 1:1.
    delta = compute_delta(conn)
    assert delta.empty(), "spec <-> migrations delta:\n" + delta.report()


def test_author_mode_round_trips(conn) -> None:
    # A temp promoted row => a generated migration that closes its own delta.
    extra = ColumnSpec(
        "metrics", "*", "test.synthetic", "promoted", "synthetic_col", "TEXT",
        description="round-trip probe.", decided_at="2026-07-13",
    )
    augmented = (*COLUMN_SPEC, extra)

    before = compute_delta(conn, augmented)
    assert not before.empty()
    assert ("metrics", "synthetic_col", "TEXT") in before.missing_columns

    sql = generate_migration("add_synthetic", before)
    try:
        conn.execute(_up_body(sql))
        assert compute_delta(conn, augmented).empty()
    finally:
        conn.execute("ALTER TABLE raw.metrics DROP COLUMN IF EXISTS synthetic_col")
        conn.execute(
            "DELETE FROM meta.column_registry WHERE attr_path = 'test.synthetic'"
        )
