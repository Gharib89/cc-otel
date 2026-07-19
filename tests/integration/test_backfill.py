"""Backfill mapping transform (#131): POC schema-v1 -> interim schema-v2 raw.

Tests the committed SQL transform (scripts/backfill/sql/*) as a unit in a throwaway
Postgres: seed a POC-shape source table, run the mapping + filtered load, and assert
the rows that land in raw.* — never the SQL's internal structure. There is no live
cross-database connection here; the transport pipe is the manual verification gate.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from _helpers import _insert, ins_event

BACKFILL_SQL = Path(__file__).resolve().parents[2] / "scripts" / "backfill" / "sql"

# A POC-only session (must land) and a session that already exists live in interim
# (its POC rows must be dropped by the dedup anti-join).
S_HIST = "dddddddd-1111-1111-1111-111111111111"
S_LIVE = "eeeeeeee-2222-2222-2222-222222222222"

# POC schema-v1 source tables — the columns the mapping SELECT reads (attrs/token_type
# present; the schema-v2 promoted columns absent). Mirrors POC otel public.metrics/events.
POC_METRICS_DDL = """
CREATE TABLE public.metrics (
    ts TIMESTAMPTZ, metric_name TEXT, metric_type TEXT, value DOUBLE PRECISION,
    count BIGINT, value_kind TEXT, user_email TEXT, user_account_id TEXT,
    organization_id TEXT, session_id UUID, model TEXT, token_type TEXT, tool_name TEXT,
    decision TEXT, attrs JSONB, resource JSONB, language TEXT, cc_version TEXT,
    query_source TEXT, effort TEXT, speed TEXT, agent_name TEXT, skill_name TEXT,
    plugin_name TEXT, marketplace_name TEXT, start_type TEXT, scope_name TEXT,
    scope_version TEXT
)
"""

POC_EVENTS_DDL = """
CREATE TABLE public.events (
    event_time TIMESTAMPTZ, event_name TEXT, severity TEXT, body TEXT, user_email TEXT,
    user_account_id TEXT, organization_id TEXT, session_id UUID, prompt_id UUID,
    model TEXT, tool_name TEXT, duration_ms BIGINT, input_tokens BIGINT,
    output_tokens BIGINT, cache_creation_tokens BIGINT, cache_read_tokens BIGINT,
    cost_usd DOUBLE PRECISION, attrs JSONB, resource JSONB, cc_version TEXT,
    event_sequence BIGINT, request_id TEXT, speed TEXT, effort TEXT, query_source TEXT,
    prompt_length BIGINT, command_name TEXT, command_source TEXT, hook_name TEXT,
    hook_event TEXT, from_mode TEXT, to_mode TEXT, trigger TEXT, skill_name TEXT,
    mention_type TEXT, success_bool BOOLEAN, tool_use_id TEXT, source TEXT,
    scope_name TEXT, scope_version TEXT, severity_number SMALLINT, log_trace_id TEXT,
    log_span_id TEXT, dropped_attributes_count INTEGER
)
"""

# An in-window instant (ADR-0006 window: 2026-05-24 .. 2026-07-16 inclusive).
IN_WINDOW = "2026-06-15T10:00:00Z"


def _read(name: str) -> str:
    return (BACKFILL_SQL / name).read_text(encoding="utf-8")


def ins_poc_metric(conn, **cols) -> None:
    _insert(conn, "public.metrics", **cols)


def ins_poc_event(conn, **cols) -> None:
    _insert(conn, "public.events", **cols)


def one(conn, sql):
    return conn.execute(sql).fetchone()


@pytest.fixture
def bf(conn):
    """conn with a fresh POC-shape source and no prior backfill state."""
    conn.execute("DROP TABLE IF EXISTS public.metrics, public.events")
    conn.execute("DROP SCHEMA IF EXISTS backfill_stg CASCADE")
    conn.execute("DELETE FROM meta.processed_batches WHERE batch_hash LIKE 'poc-backfill%'")
    conn.execute(POC_METRICS_DDL)
    conn.execute(POC_EVENTS_DDL)
    yield conn


def run_backfill(conn) -> None:
    conn.execute(_read("00_staging.sql"))
    conn.execute("INSERT INTO backfill_stg.metrics " + _read("map_metrics.sql"))
    conn.execute("INSERT INTO backfill_stg.events " + _read("map_events.sql"))
    conn.execute(_read("load.sql"))


def test_metrics_rename_and_attr_derivation(bf):
    ins_poc_metric(
        bf,
        ts=IN_WINDOW,
        metric_name="claude_code.token.usage",
        metric_type="sum",
        value=10,
        value_kind="sum_delta",
        session_id=S_HIST,
        token_type="input",
        attrs=json.dumps({"window": "5h", "source": "user_temporary"}),
        scope_name="cc-otel.statusline",
    )
    run_backfill(bf)
    assert one(
        bf,
        "SELECT type_label, usage_window, source FROM raw.metrics "
        f"WHERE session_id='{S_HIST}'",
    ) == ("input", "5h", "user_temporary")


def test_events_attr_derivation(bf):
    ins_poc_event(
        bf,
        event_time=IN_WINDOW,
        event_name="api_request",
        session_id=S_HIST,
        attrs=json.dumps(
            {
                "agent.name": "Explore",
                "plugin.name": "acme",
                "marketplace.name": "shop",
                "mcp_server.name": "github",
                "mcp_tool.name": "search",
                "decision": "accept",
            }
        ),
        scope_name="com.anthropic.claude_code.events",
    )
    run_backfill(bf)
    assert one(
        bf,
        "SELECT agent_name, plugin_name, marketplace_name, mcp_server_name, "
        f"mcp_tool_name, decision FROM raw.events WHERE session_id='{S_HIST}'",
    ) == ("Explore", "acme", "shop", "github", "search", "accept")


def test_scope_excludes_copilot_metrics_and_tracing_events(bf):
    ins_poc_metric(
        bf, ts=IN_WINDOW, metric_name="m", metric_type="sum", value=1,
        session_id=S_HIST, scope_name="github.copilot",
    )
    ins_poc_metric(
        bf, ts=IN_WINDOW, metric_name="m", metric_type="sum", value=1,
        session_id=S_HIST, scope_name="com.anthropic.claude_code",
    )
    ins_poc_event(
        bf, event_time=IN_WINDOW, event_name="gen_ai.request.attempt",
        session_id=S_HIST, scope_name="com.anthropic.claude_code.tracing",
    )
    ins_poc_event(
        bf, event_time=IN_WINDOW, event_name="api_request",
        session_id=S_HIST, scope_name="com.anthropic.claude_code.events",
    )
    run_backfill(bf)
    assert one(bf, "SELECT count(*) FROM raw.metrics WHERE scope_name='github.copilot'") == (0,)
    assert one(bf, "SELECT count(*) FROM raw.metrics") == (1,)
    assert one(
        bf, "SELECT count(*) FROM raw.events WHERE scope_name='com.anthropic.claude_code.tracing'"
    ) == (0,)
    assert one(bf, "SELECT count(*) FROM raw.events") == (1,)


def test_dedup_drops_sessions_already_in_interim(bf):
    # A live interim session already present in raw before the backfill runs.
    ins_event(bf, event_time="2026-07-15T09:00:00Z", event_name="api_request", session_id=S_LIVE)
    # POC rows for the same session (must be dropped) and a POC-only session (must land).
    for sess in (S_LIVE, S_HIST):
        ins_poc_metric(
            bf, ts=IN_WINDOW, metric_name="m", metric_type="sum", value=1,
            session_id=sess, scope_name="com.anthropic.claude_code",
        )
        ins_poc_event(
            bf, event_time=IN_WINDOW, event_name="api_request",
            session_id=sess, scope_name="com.anthropic.claude_code.events",
        )
    run_backfill(bf)
    assert one(bf, f"SELECT count(*) FROM raw.metrics WHERE session_id='{S_LIVE}'") == (0,)
    assert one(bf, f"SELECT count(*) FROM raw.metrics WHERE session_id='{S_HIST}'") == (1,)
    # The pre-existing live event stays; the POC dupe for S_LIVE was dropped.
    assert one(bf, f"SELECT count(*) FROM raw.events WHERE session_id='{S_LIVE}'") == (1,)
    assert one(bf, f"SELECT count(*) FROM raw.events WHERE session_id='{S_HIST}'") == (1,)


def test_sum_cumulative_rows_retained(bf):
    ins_poc_metric(
        bf, ts=IN_WINDOW, metric_name="claude_code.commit.count", metric_type="sum",
        value=99, value_kind="sum_cumulative", session_id=S_HIST,
        scope_name="com.anthropic.claude_code",
    )
    run_backfill(bf)
    assert one(
        bf, f"SELECT value_kind FROM raw.metrics WHERE session_id='{S_HIST}'"
    ) == ("sum_cumulative",)


# Note: idempotency (the meta.processed_batches sentinel) is intentionally NOT
# automated here — issue #131's Testing Decisions assign it to the manual
# verification gate. load.sql claims `poc-backfill:interim:v1` and no-ops on re-run.


def test_window_excludes_out_of_range_rows(bf):
    for ts in ("2026-05-23T10:00:00Z", IN_WINDOW, "2026-07-17T10:00:00Z"):
        ins_poc_metric(
            bf, ts=ts, metric_name="m", metric_type="sum", value=1,
            session_id=S_HIST, scope_name="com.anthropic.claude_code",
        )
    run_backfill(bf)
    rows = bf.execute("SELECT ts::date::text FROM raw.metrics ORDER BY ts").fetchall()
    assert rows == [("2026-06-15",)]
