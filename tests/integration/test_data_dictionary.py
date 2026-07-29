"""Integration: gen_data_dictionary against a migrated Postgres (#29).

Proves the registry join + live-stats SQL runs end to end on the real schema: seeded
column_registry rows describe promoted columns, live stats come from raw.*, and kept/denied
keys are listed. Uses the shared testcontainers harness (conftest) — never the dev DB.
"""

from __future__ import annotations

from tools.gen_data_dictionary import build


def test_build_joins_registry_with_live_stats(conn):
    conn.execute(
        "INSERT INTO raw.metrics (ts, metric_name, metric_type, model) VALUES "
        "(now(), 'claude_code.token.usage', 'sum', 'opus'), "
        "(now(), 'claude_code.token.usage', 'sum', NULL)"
    )
    conn.execute(
        "INSERT INTO raw.events (event_time, event_name, model) "
        "VALUES (now(), 'api_request', 'opus')"
    )

    md = build(conn)

    # both raw tables profiled
    assert "## `raw.metrics`" in md
    assert "## `raw.events`" in md
    # promoted column carries its registry description (the join worked)
    assert "OTel instrument name." in md
    # live signal-name counts reflect the inserted rows
    assert "| `claude_code.token.usage` |" in md
    # kept/denied section lists blob-only registry keys
    assert "## Kept & denied attributes (not in Postgres)" in md
    assert "`host.arch`" in md
    # ...and only those: a promoted resource attr belongs to the profiled tables,
    # not the blob-only section (service.name promoted in #357).
    assert "`service.name`" not in md.split("## Kept & denied attributes", 1)[1]
