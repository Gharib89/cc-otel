"""Integration: gen_data_dictionary against a migrated Postgres (#29).

Proves the registry join + live-stats SQL runs end to end on the real schema: seeded
column_registry rows describe promoted columns, live stats come from raw.*, and kept/denied
keys are listed. Uses the shared testcontainers harness (conftest) — never the dev DB.
"""

from __future__ import annotations

from urllib.parse import urlsplit

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
    heading = "## Kept & denied attributes (not in Postgres)"
    assert heading in md
    assert "`host.arch`" in md
    # ...and only those: a promoted resource attr belongs to the profiled tables, not the
    # blob-only section (service.name promoted in #357). Split on the asserted heading, so
    # a renamed heading fails on the line above rather than silently emptying the tail.
    assert "`service.name`" not in md.split(heading, 1)[1]
    # every kept row publishes its basis, and a collinear row names its partner (#366) —
    # this is where the reasoning stops living only in docs/research/ and becomes published
    kept_denied = md.split(heading, 1)[1]
    assert "| constant |" in kept_denied  # host.arch
    assert "| collinear(os.type) |" in kept_denied  # os.version / wsl.version
    # a denied row has no basis to publish
    assert "| denied | — |" in kept_denied


def test_build_records_the_server_it_connected_to(conn, pg_url):
    """`build` reads the host off the live connection rather than rendering a placeholder.

    Which environment a regeneration profiled is otherwise unrecoverable from the document —
    every environment names its database `cc_otel` (#436). The expected host comes from the
    fixture's own URL, so a hardcoded one in `render` fails here.
    """
    expected_host = urlsplit(pg_url).hostname

    md = build(conn)

    assert f"on `{expected_host}`." in md
