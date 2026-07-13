"""Staging layer (#19): delta-only counter view, api_request projection.

Temporality is resolved once here — facts never see `value_kind` (design #9).
"""

from __future__ import annotations

from _helpers import ins_event, ins_metric


def test_stg_counter_delta_keeps_delta_excludes_cumulative(conn):
    ins_metric(
        conn, ts="2026-07-01T10:00:00Z", metric_name="claude_code.commit.count",
        metric_type="sum", value=3, value_kind="sum_delta", user_email="a@x.com",
    )
    ins_metric(
        conn, ts="2026-07-01T10:05:00Z", metric_name="claude_code.commit.count",
        metric_type="sum", value=99, value_kind="sum_cumulative", user_email="a@x.com",
    )
    rows = conn.execute(
        "SELECT metric_name, value, user_email FROM staging.stg_counter_delta"
    ).fetchall()
    assert rows == [("claude_code.commit.count", 3.0, "a@x.com")]


def test_stg_api_request_projects_only_api_request_events(conn):
    ins_event(
        conn, event_time="2026-07-01T10:00:00Z", event_name="api_request",
        session_id="11111111-1111-1111-1111-111111111111", user_email="a@x.com",
        model="claude-opus-4-8", input_tokens=100, output_tokens=50,
        query_source="main", effort="high",
    )
    ins_event(
        conn, event_time="2026-07-01T10:01:00Z", event_name="tool_result",
        session_id="11111111-1111-1111-1111-111111111111", tool_name="Bash",
    )
    rows = conn.execute(
        "SELECT model, input_tokens, output_tokens, query_source, effort "
        "FROM staging.stg_api_request"
    ).fetchall()
    assert rows == [("claude-opus-4-8", 100, 50, "main", "high")]
