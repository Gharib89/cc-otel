"""Marts layer (#19): dims, facts, bridges, refresh job, ops tables.

Fixture raw rows → expected dim/fact/bridge outputs, per the issue's acceptance
criteria (including the >100% reset-split utilization window).
"""

from __future__ import annotations

from _helpers import ins_event, ins_metric

S1 = "11111111-1111-1111-1111-111111111111"
S2 = "22222222-2222-2222-2222-222222222222"
P1 = "aaaaaaaa-1111-1111-1111-111111111111"
P2 = "bbbbbbbb-2222-2222-2222-222222222222"


def refresh(conn):
    conn.execute("SELECT marts.refresh_all()")


def one(conn, sql):
    return conn.execute(sql).fetchone()


def all_(conn, sql):
    return conn.execute(sql).fetchall()


# --- dimensions -------------------------------------------------------------


def test_dim_user_first_last_seen_and_unknown_member(conn):
    ins_metric(
        conn,
        ts="2026-07-01T10:00:00Z",
        metric_name="claude_code.session.count",
        metric_type="sum",
        value=1,
        value_kind="sum_delta",
        user_email="a@x.com",
        cc_version="2.1.0",
    )
    ins_event(
        conn,
        event_time="2026-07-03T10:00:00Z",
        event_name="api_request",
        user_email="a@x.com",
        cc_version="2.2.0",
    )
    ins_event(
        conn,
        event_time="2026-07-02T10:00:00Z",
        event_name="plugin_loaded",
        user_email=None,
        plugin_name="acme",
    )  # null email → (unknown)
    refresh(conn)
    row = one(
        conn,
        "SELECT is_unknown, first_seen::date::text, last_seen::date::text, "
        "last_cc_version FROM marts.dim_user WHERE user_email = 'a@x.com'",
    )
    assert row == (False, "2026-07-01", "2026-07-03", "2.2.0")
    assert one(conn, "SELECT is_unknown FROM marts.dim_user WHERE user_email='(unknown)'") == (
        True,
    )


def test_dim_model_family_version_long_context(conn):
    for mdl in ("claude-opus-4-8[1m]", "claude-sonnet-5", "claude-haiku-4-5"):
        ins_event(conn, event_time="2026-07-01T10:00:00Z", event_name="api_request", model=mdl)
    refresh(conn)
    rows = all_(
        conn,
        "SELECT model_id, family, version, is_long_context FROM marts.dim_model ORDER BY model_id",
    )
    assert rows == [
        ("claude-haiku-4-5", "haiku", "4-5", False),
        ("claude-opus-4-8[1m]", "opus", "4-8", True),
        ("claude-sonnet-5", "sonnet", "5", False),
    ]


def test_dim_date_spans_data_start_to_present(conn):
    ins_metric(
        conn,
        ts="2026-07-01T10:00:00Z",
        metric_name="claude_code.session.count",
        metric_type="sum",
        value=1,
        value_kind="sum_delta",
        user_email="a@x.com",
    )
    refresh(conn)
    lo, hi = one(conn, "SELECT MIN(date_day)::text, MAX(date_day) FROM marts.dim_date")
    assert lo == "2026-07-01"
    # upper bound tracks "present" (CURRENT_DATE at refresh), never a fixed end.
    assert hi == one(conn, "SELECT CURRENT_DATE")[0]


# --- facts ------------------------------------------------------------------


def test_fact_session_duration_start_type(conn):
    ins_metric(
        conn,
        ts="2026-07-01T10:00:00Z",
        metric_name="claude_code.session.count",
        metric_type="sum",
        value=1,
        value_kind="sum_delta",
        user_email="a@x.com",
        session_id=S1,
        start_type="fresh",
        cc_version="2.1.0",
    )
    ins_event(
        conn,
        event_time="2026-07-01T10:10:00Z",
        event_name="api_request",
        session_id=S1,
        user_email="a@x.com",
    )
    refresh(conn)
    assert one(
        conn,
        "SELECT start_type, duration_s, user_email FROM marts.fact_session "
        f"WHERE session_id='{S1}'",
    ) == ("fresh", 600, "a@x.com")


def test_fact_session_daily_counts_deltas_and_prompts(conn):
    ins_metric(
        conn,
        ts="2026-07-01T10:00:00Z",
        metric_name="claude_code.commit.count",
        metric_type="sum",
        value=2,
        value_kind="sum_delta",
        session_id=S1,
        user_email="a@x.com",
    )
    ins_metric(
        conn,
        ts="2026-07-01T11:00:00Z",
        metric_name="claude_code.commit.count",
        metric_type="sum",
        value=99,
        value_kind="sum_cumulative",
        session_id=S1,
        user_email="a@x.com",
    )  # excluded
    ins_metric(
        conn,
        ts="2026-07-01T10:00:00Z",
        metric_name="claude_code.lines_of_code.count",
        metric_type="sum",
        value=40,
        value_kind="sum_delta",
        session_id=S1,
        user_email="a@x.com",
        type_label="added",
    )
    ins_metric(
        conn,
        ts="2026-07-01T10:00:00Z",
        metric_name="claude_code.active_time.total",
        metric_type="sum",
        value=30,
        value_kind="sum_delta",
        session_id=S1,
        user_email="a@x.com",
        type_label="user",
    )
    # Non-empty signal is DISTINCT prompt_id (not the user_prompt event): two turns,
    # each on an api_request carrying a prompt_id, and no user_prompt event at all.
    for pid in (P1, P2):
        ins_event(
            conn,
            event_time="2026-07-01T10:00:00Z",
            event_name="api_request",
            session_id=S1,
            user_email="a@x.com",
            prompt_id=pid,
        )
    refresh(conn)
    assert one(
        conn,
        "SELECT commits, loc_added, active_time_user_s, active_time_total_s, prompts "
        f"FROM marts.fact_session_daily WHERE session_id='{S1}'",
    ) == (2, 40, 30, 30, 2)


def test_fact_session_daily_prompts_count_distinct_prompt_id(conn):
    """Many events can share one prompt turn (api_request, tool_result, ... all carry
    the same prompt_id) — the prompt count is DISTINCT prompt_id, so one turn counts once."""
    for name in ("api_request", "tool_result", "api_request"):
        ins_event(
            conn,
            event_time="2026-07-01T10:00:00Z",
            event_name=name,
            session_id=S1,
            user_email="a@x.com",
            prompt_id=P1,
        )
    # An event with no prompt_id (e.g. a statusline ping) must not count as a turn.
    ins_event(
        conn,
        event_time="2026-07-01T10:00:00Z",
        event_name="tool_result",
        session_id=S1,
        user_email="a@x.com",
    )
    refresh(conn)
    assert one(conn, f"SELECT prompts FROM marts.fact_session_daily WHERE session_id='{S1}'") == (
        1,
    )


def test_fact_session_daily_multi_email_collapses_and_flags(conn):
    """A session-day logged under a corp + a personal account must not break
    REFRESH CONCURRENTLY (the duplicate-key incident on 2026-07-16): the fact keeps
    one corp-preferred row and the split is captured as a multi_email_session finding."""
    for email, pid in (("dev@itworx.com", P1), ("dev.personal@gmail.com", P2)):
        ins_event(
            conn,
            event_time="2026-07-01T10:00:00Z",
            event_name="api_request",
            session_id=S2,
            user_email=email,
            prompt_id=pid,
        )
    # Cross-source disagreement: metrics carry only the personal email, prompts the corp
    # one — the fact must still prefer corp across the m/p join, not just within a source.
    ins_metric(
        conn,
        ts="2026-07-01T10:00:00Z",
        metric_name="claude_code.commit.count",
        metric_type="sum",
        value=1,
        value_kind="sum_delta",
        session_id=S2,
        user_email="dev.personal@gmail.com",
    )
    refresh(conn)  # must not raise on the duplicate (session_id, activity_date) key
    assert all_(
        conn,
        "SELECT user_email, prompts, commits FROM marts.fact_session_daily "
        f"WHERE session_id='{S2}' AND activity_date='2026-07-01'",
    ) == [("dev@itworx.com", 2, 1)]
    assert one(
        conn,
        "SELECT details->>'corp_emails', details->>'personal_emails' FROM marts.dq_finding "
        f"WHERE finding_type='multi_email_session' AND details->>'session_id'='{S2}' "
        "AND details->>'activity_date'='2026-07-01'",
    ) == ('["dev@itworx.com"]', '["dev.personal@gmail.com"]')


def test_fact_api_usage_grain_and_last_event_ts(conn):
    ins_event(
        conn,
        event_time="2026-07-01T10:00:00Z",
        event_name="api_request",
        session_id=S1,
        user_email="a@x.com",
        model="claude-opus-4-8",
        input_tokens=100,
        output_tokens=50,
        cost_usd=0.10,
        query_source="main",
        effort="high",
    )
    ins_event(
        conn,
        event_time="2026-07-01T10:30:00Z",
        event_name="api_request",
        session_id=S1,
        user_email="a@x.com",
        model="claude-opus-4-8",
        input_tokens=20,
        output_tokens=5,
        cost_usd=0.02,
        query_source="main",
        effort="high",
    )
    refresh(conn)
    assert one(
        conn,
        "SELECT input_tokens, output_tokens, request_count, "
        "round(cost_usd::numeric, 2)::float8, last_event_ts::text "
        "FROM marts.fact_api_usage",
    ) == (120, 55, 2, 0.12, "2026-07-01 10:30:00+00")


def _cost_findings(conn):
    return one(
        conn,
        "SELECT count(*) FROM marts.dq_finding "
        "WHERE finding_type = 'cost_promotion_divergence'",
    )[0]


def test_cost_promotion_divergence_flagged(conn):
    # Promoted api_request cost ($1.00) vs the claude_code.cost.usage counter ($2.00):
    # a 100% gap, far past the 1%/$0.01 tolerance -> one DQ finding. Seeded in the live
    # window (>= 2026-07-17); the reconciliation is scoped there (backfilled POC counter
    # is inflated, see #215/ADR-0007).
    ins_event(
        conn,
        event_time="2026-07-20T10:00:00Z",
        event_name="api_request",
        session_id=S1,
        user_email="a@x.com",
        model="claude-opus-4-8",
        cost_usd=1.00,
        query_source="main",
        effort="high",
    )
    ins_metric(
        conn,
        ts="2026-07-20T10:00:00Z",
        metric_name="claude_code.cost.usage",
        metric_type="sum",
        value=2.00,
        value_kind="sum_delta",
        session_id=S1,
        user_email="a@x.com",
    )
    refresh(conn)
    assert _cost_findings(conn) == 1
    assert one(
        conn,
        "SELECT (details->>'promoted_usd')::float8, (details->>'counter_usd')::float8 "
        "FROM marts.dq_finding WHERE finding_type = 'cost_promotion_divergence'",
    ) == (1.0, 2.0)


def test_cost_promotion_within_tolerance_no_finding(conn):
    # $1.00 promoted vs $1.005 counter: 0.5% relative and $0.005 absolute, inside
    # both tolerance bounds -> no finding. Live-window dates (>= 2026-07-17).
    ins_event(
        conn,
        event_time="2026-07-20T10:00:00Z",
        event_name="api_request",
        session_id=S1,
        user_email="a@x.com",
        model="claude-opus-4-8",
        cost_usd=1.00,
        query_source="main",
        effort="high",
    )
    ins_metric(
        conn,
        ts="2026-07-20T10:00:00Z",
        metric_name="claude_code.cost.usage",
        metric_type="sum",
        value=1.005,
        value_kind="sum_delta",
        session_id=S1,
        user_email="a@x.com",
    )
    refresh(conn)
    assert _cost_findings(conn) == 0


def test_fact_tool_outcome_counts_and_percentiles(conn):
    # 3 Bash tool_result events: 2 succeed, 1 fails; durations 100/200/300ms.
    for dur, ok in ((100, True), (200, True), (300, False)):
        ins_event(
            conn,
            event_time="2026-07-01T10:00:00Z",
            event_name="tool_result",
            session_id=S1,
            tool_name="Bash",
            duration_ms=dur,
            success_bool=ok,
        )
    refresh(conn)
    # p50 of [100,200,300] = 200; p95 (PERCENTILE_CONT) interpolates to 290.
    assert one(
        conn,
        "SELECT tool_call_count, success_count, duration_p50_ms, duration_p95_ms "
        "FROM marts.fact_tool_outcome WHERE tool_name = 'Bash'",
    ) == (3, 2, 200, 290)


def test_fact_api_error_rate_per_day(conn):
    for _ in range(3):
        ins_event(
            conn, event_time="2026-07-01T10:00:00Z", event_name="api_request", session_id=S1
        )
    ins_event(conn, event_time="2026-07-01T11:00:00Z", event_name="api_error", session_id=S1)
    refresh(conn)
    # 1 error out of 4 total attempts = 25.00% (0-100 scale).
    assert one(
        conn,
        "SELECT api_request_count, api_error_count, error_rate_pct::text "
        "FROM marts.fact_api_error_rate WHERE activity_date = '2026-07-01'",
    ) == (3, 1, "25.00")


def test_cost_promotion_ignores_session_less_counter(conn):
    # The counter sum matches fact_api_usage's session_id IS NOT NULL grain, so a
    # session-less cost.usage row is excluded from reconciliation -> no false divergence.
    # Live-window dates (>= 2026-07-17).
    ins_event(
        conn,
        event_time="2026-07-20T10:00:00Z",
        event_name="api_request",
        session_id=S1,
        user_email="a@x.com",
        model="claude-opus-4-8",
        cost_usd=1.00,
        query_source="main",
        effort="high",
    )
    ins_metric(
        conn,
        ts="2026-07-20T10:00:00Z",
        metric_name="claude_code.cost.usage",
        metric_type="sum",
        value=1.00,
        value_kind="sum_delta",
        session_id=S1,
        user_email="a@x.com",
    )
    ins_metric(
        conn,
        ts="2026-07-20T10:00:00Z",
        metric_name="claude_code.cost.usage",
        metric_type="sum",
        value=5.00,
        value_kind="sum_delta",
        session_id=None,
        user_email="a@x.com",
    )
    refresh(conn)
    assert _cost_findings(conn) == 0


def test_fact_edit_decision_language_mix(conn):
    cases = (("Python", "accept", 3), ("Python", "reject", 1), ("TypeScript", "accept", 2))
    for lang, dec, n in cases:
        ins_metric(
            conn,
            ts="2026-07-01T10:00:00Z",
            metric_name="claude_code.code_edit_tool.decision",
            metric_type="sum",
            value=n,
            value_kind="sum_delta",
            session_id=S1,
            user_email="a@x.com",
            tool_name="Edit",
            language=lang,
            decision=dec,
            source="user_temporary",
        )
    refresh(conn)
    rows = all_(
        conn,
        "SELECT language, decision, decision_count FROM marts.fact_edit_decision "
        "ORDER BY language, decision",
    )
    assert rows == [("Python", "accept", 3), ("Python", "reject", 1), ("TypeScript", "accept", 2)]


def test_fact_usage_window_reset_split_can_exceed_100pct(conn):
    """The mandated case: a fleet reset splits one window into segments whose end_pct
    values sum above 100% — reported as-is, never capped."""
    samples = [
        ("10:00:00", 30, 18000),
        ("10:05:00", 80, 17700),
        ("10:10:00", 10, 17400),
        ("10:15:00", 60, 17100),
    ]
    for hhmmss, util, reset in samples:
        for name, val in (("utilization", util), ("reset_in_seconds", reset)):
            ins_metric(
                conn,
                ts=f"2026-07-01T{hhmmss}Z",
                metric_name=f"claude_code.usage.{name}",
                metric_type="gauge",
                value=val,
                value_kind="gauge_last",
                user_email="u@x.com",
                usage_window="5h",
            )
    refresh(conn)
    rows = all_(
        conn,
        "SELECT segment_no, end_pct, peak_pct, is_reset_split, sample_count "
        "FROM marts.fact_usage_window ORDER BY segment_no",
    )
    assert rows == [(1, 80.0, 80.0, True, 2), (2, 60.0, 60.0, True, 2)]
    total = one(conn, "SELECT SUM(end_pct) FROM marts.fact_usage_window")[0]
    assert total == 140.0 and total > 100
    # window_start = window_end − 5h for a 5h window.
    assert one(
        conn,
        "SELECT (window_end - window_start) = INTERVAL '5 hours' "
        "FROM marts.fact_usage_window LIMIT 1",
    ) == (True,)


def test_fact_usage_window_rejects_impossible_reset(conn):
    """A wrapper glitch can emit a reset_in_seconds far beyond the 7d window max
    (604800s); window_end = ts + reset would then land centuries out and pollute
    the fact. Such samples are dropped, leaving only plausible windows."""
    samples = [
        ("10:00:00", 40, 18000),          # legit 5h window: kept
        ("10:05:00", 42, 8_219_674_457),  # impossible reset (> 7d): rejected
    ]
    for hhmmss, util, reset in samples:
        for name, val in (("utilization", util), ("reset_in_seconds", reset)):
            ins_metric(
                conn,
                ts=f"2026-07-01T{hhmmss}Z",
                metric_name=f"claude_code.usage.{name}",
                metric_type="gauge",
                value=val,
                value_kind="gauge_last",
                user_email="u@x.com",
                usage_window="5h",
            )
    refresh(conn)
    assert one(
        conn, "SELECT COUNT(*) FROM marts.fact_usage_window WHERE window_end > '2100-01-01'"
    ) == (0,)
    assert all_(conn, "SELECT segment_no, end_pct FROM marts.fact_usage_window") == [(1, 40.0)]


def test_fact_utilization_hourly_avg_max(conn):
    for hhmmss, util in (("10:00:00", 20), ("10:30:00", 80)):
        ins_metric(
            conn,
            ts=f"2026-07-01T{hhmmss}Z",
            metric_name="claude_code.usage.utilization",
            metric_type="gauge",
            value=util,
            value_kind="gauge_last",
            user_email="u@x.com",
            usage_window="5h",
        )
        ins_metric(
            conn,
            ts=f"2026-07-01T{hhmmss}Z",
            metric_name="claude_code.usage.reset_in_seconds",
            metric_type="gauge",
            value=18000,
            value_kind="gauge_last",
            user_email="u@x.com",
            usage_window="5h",
        )
    refresh(conn)
    assert one(conn, "SELECT avg_pct, max_pct FROM marts.fact_utilization_hourly") == (50.0, 80.0)


# --- bridges ----------------------------------------------------------------


def test_bridges_session_multivalued_fields(conn):
    ins_event(
        conn,
        event_time="2026-07-01T10:00:00Z",
        event_name="skill_activated",
        session_id=S1,
        skill_name="dream",
    )
    ins_event(
        conn,
        event_time="2026-07-01T10:01:00Z",
        event_name="api_request",
        session_id=S1,
        skill_name="research",
        agent_name="Explore",
        mcp_server_name="github",
    )
    ins_event(
        conn,
        event_time="2026-07-01T10:02:00Z",
        event_name="tool_result",
        session_id=S1,
        tool_name="mcp__github__search",
    )
    ins_event(
        conn,
        event_time="2026-07-01T10:03:00Z",
        event_name="plugin_loaded",
        session_id=S1,
        plugin_name="acme",
    )
    ins_event(
        conn,
        event_time="2026-07-01T10:04:00Z",
        event_name="hook_execution_complete",
        session_id=S1,
        hook_name="PreToolUse:Bash",
    )
    refresh(conn)
    assert all_(
        conn, "SELECT skill_name, activations FROM marts.bridge_session_skill ORDER BY skill_name"
    ) == [("dream", 1), ("research", 1)]
    assert all_(conn, "SELECT mcp_name FROM marts.bridge_session_mcp ORDER BY mcp_name") == [
        ("github",),
        ("mcp__github__search",),
    ]
    assert all_(conn, "SELECT plugin_name, load_count FROM marts.bridge_session_plugin") == [
        ("acme", 1)
    ]
    assert all_(conn, "SELECT agent_name, invocations FROM marts.bridge_session_agent") == [
        ("Explore", 1)
    ]
    assert all_(conn, "SELECT hook_name, executions FROM marts.bridge_session_hook") == [
        ("PreToolUse:Bash", 1)
    ]


# --- refresh job + ops tables (acceptance) ----------------------------------


def test_refresh_writes_a_log_row_per_matview(conn):
    refresh(conn)
    marts, complete = one(
        conn,
        "SELECT COUNT(DISTINCT mart), COUNT(*) FILTER "
        "(WHERE finished IS NOT NULL AND row_count IS NOT NULL) "
        "FROM marts.mart_refresh_log",
    )
    assert marts == 16 and complete == 16


def test_cumulative_rows_recorded_as_dq_finding(conn):
    ins_metric(
        conn,
        ts="2026-07-01T10:00:00Z",
        metric_name="claude_code.commit.count",
        metric_type="sum",
        value=99,
        value_kind="sum_cumulative",
        user_email="a@x.com",
    )
    refresh(conn)
    assert one(
        conn, "SELECT row_count FROM marts.dq_finding WHERE finding_type='cumulative_value_kind'"
    ) == (1,)
