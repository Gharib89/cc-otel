-- migrate:up

-- Facts, part 1 (#9): the session/usage facts. session_id is a degenerate dimension
-- shared across facts — never join fact-to-fact on it. user_email carries the FK to
-- dim_user (the report's user page relates dim_user directly to these facts, #10).
-- Counter measures come through staging.stg_counter_delta (delta-only, temporality
-- already resolved); api usage comes through staging.stg_api_request.

-- fact_session: one row per session — the drill landing row. duration_s is the observed
-- signal span (MAX−MIN timestamp); the POC's session.duration_ms wrapper metric does not
-- exist in production (ADR-0003).
CREATE MATERIALIZED VIEW marts.fact_session AS
WITH sig AS (
    SELECT session_id, user_email, cc_version, ts AS t FROM raw.metrics
    WHERE session_id IS NOT NULL
    UNION ALL
    SELECT session_id, user_email, cc_version, event_time FROM raw.events
    WHERE session_id IS NOT NULL
),
start_type AS (
    SELECT session_id,
           (ARRAY_AGG(start_type ORDER BY ts DESC) FILTER (WHERE start_type IS NOT NULL))[1]
               AS start_type
    FROM raw.metrics
    WHERE metric_name = 'claude_code.session.count' AND session_id IS NOT NULL
    GROUP BY session_id
)
SELECT
    sig.session_id,
    (ARRAY_AGG(sig.user_email ORDER BY sig.t) FILTER (WHERE sig.user_email IS NOT NULL))[1]
        AS user_email,
    MIN(sig.t) AS started_at,
    st.start_type,
    (ARRAY_AGG(sig.cc_version ORDER BY sig.t DESC) FILTER (WHERE sig.cc_version IS NOT NULL))[1]
        AS cc_version,
    EXTRACT(EPOCH FROM (MAX(sig.t) - MIN(sig.t)))::bigint AS duration_s
FROM sig
LEFT JOIN start_type st USING (session_id)
GROUP BY sig.session_id, st.start_type;

CREATE UNIQUE INDEX fact_session_pk ON marts.fact_session (session_id);

-- fact_session_daily: session × day. Day is part of the grain — sessions cross midnight,
-- so a session-only grain would corrupt active-day and daily-trend measures (#9).
CREATE MATERIALIZED VIEW marts.fact_session_daily AS
WITH m AS (
    SELECT
        session_id, user_email, ts::date AS activity_date,
        SUM(value) FILTER (WHERE metric_name = 'claude_code.commit.count') AS commits,
        SUM(value) FILTER (WHERE metric_name = 'claude_code.pull_request.count') AS prs,
        SUM(value) FILTER (
            WHERE metric_name = 'claude_code.lines_of_code.count' AND type_label = 'added'
        ) AS loc_added,
        SUM(value) FILTER (
            WHERE metric_name = 'claude_code.lines_of_code.count' AND type_label = 'removed'
        ) AS loc_removed,
        SUM(value) FILTER (
            WHERE metric_name = 'claude_code.active_time.total' AND type_label = 'user'
        ) AS active_time_user_s,
        SUM(value) FILTER (
            WHERE metric_name = 'claude_code.active_time.total' AND type_label = 'cli'
        ) AS active_time_cli_s
    FROM staging.stg_counter_delta
    WHERE session_id IS NOT NULL
    GROUP BY session_id, user_email, ts::date
),
p AS (
    SELECT session_id, user_email, event_time::date AS activity_date, COUNT(*) AS prompts
    FROM raw.events
    WHERE event_name = 'user_prompt' AND session_id IS NOT NULL
    GROUP BY session_id, user_email, event_time::date
)
SELECT
    COALESCE(m.session_id, p.session_id) AS session_id,
    COALESCE(m.user_email, p.user_email) AS user_email,
    COALESCE(m.activity_date, p.activity_date) AS activity_date,
    COALESCE(p.prompts, 0) AS prompts,
    COALESCE(m.commits, 0) AS commits,
    COALESCE(m.prs, 0) AS prs,
    COALESCE(m.loc_added, 0) AS loc_added,
    COALESCE(m.loc_removed, 0) AS loc_removed,
    COALESCE(m.active_time_user_s, 0) AS active_time_user_s,
    COALESCE(m.active_time_cli_s, 0) AS active_time_cli_s,
    COALESCE(m.active_time_user_s, 0) + COALESCE(m.active_time_cli_s, 0) AS active_time_total_s
FROM m
FULL OUTER JOIN p
    ON m.session_id = p.session_id AND m.activity_date = p.activity_date;

CREATE UNIQUE INDEX fact_session_daily_pk
    ON marts.fact_session_daily (session_id, activity_date);

-- fact_api_usage: session × day × model × effort × query_source. Sourced from api_request
-- events (richer than the token.usage metric). last_event_ts (max api_request timestamp per
-- grain row) feeds the report's data-freshness tile (#10).
CREATE MATERIALIZED VIEW marts.fact_api_usage AS
SELECT
    session_id,
    event_time::date AS activity_date,
    model,
    effort,
    query_source,
    (ARRAY_AGG(user_email) FILTER (WHERE user_email IS NOT NULL))[1] AS user_email,
    SUM(input_tokens) AS input_tokens,
    SUM(output_tokens) AS output_tokens,
    SUM(cache_creation_tokens) AS cache_creation_tokens,
    SUM(cache_read_tokens) AS cache_read_tokens,
    COUNT(*) AS request_count,
    MAX(event_time) AS last_event_ts
FROM staging.stg_api_request
WHERE session_id IS NOT NULL
GROUP BY session_id, event_time::date, model, effort, query_source;

CREATE UNIQUE INDEX fact_api_usage_pk ON marts.fact_api_usage
    (session_id, activity_date, model, effort, query_source);

-- fact_edit_decision: session × day × tool × language × decision × source. Drives edit
-- acceptance rate AND language mix — language mix is edit-decision counts only, never
-- fabricated into LOC (lines_of_code.count has no language attribute, #9).
CREATE MATERIALIZED VIEW marts.fact_edit_decision AS
SELECT
    session_id,
    ts::date AS activity_date,
    tool_name,
    language,
    decision,
    source,
    (ARRAY_AGG(user_email) FILTER (WHERE user_email IS NOT NULL))[1] AS user_email,
    SUM(value) AS decision_count
FROM staging.stg_counter_delta
WHERE metric_name = 'claude_code.code_edit_tool.decision' AND session_id IS NOT NULL
GROUP BY session_id, ts::date, tool_name, language, decision, source;

CREATE UNIQUE INDEX fact_edit_decision_pk ON marts.fact_edit_decision
    (session_id, activity_date, tool_name, language, decision, source);

-- migrate:down

DROP MATERIALIZED VIEW IF EXISTS marts.fact_edit_decision;
DROP MATERIALIZED VIEW IF EXISTS marts.fact_api_usage;
DROP MATERIALIZED VIEW IF EXISTS marts.fact_session_daily;
DROP MATERIALIZED VIEW IF EXISTS marts.fact_session;
