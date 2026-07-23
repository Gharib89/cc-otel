-- migrate:up

-- Bucket NULL user_email into the explicit '(unknown)' member at the marts fact grain
-- (#214). dim_user already resolves NULL email to '(unknown)' with an is_unknown flag
-- (20260713170008), but every fact left user_email NULL, so NULL-email fact rows never
-- joined dim_user's '(unknown)' member -- they collapsed into a BLANK that
-- DISTINCTCOUNT(user_email) counted as a distinct user, inflating Active Users by one and
-- orphaning those rows' prompts/sessions into an un-named member. COALESCE to the same
-- '(unknown)' literal dim_user uses, at grain, in all six facts related to dim_user.
-- Matviews can't be replaced in place, so each is DROP + CREATE (grain, index, and reader
-- grant carried forward from each fact's current definition). No matview depends on these
-- facts, so a plain DROP (no CASCADE) is safe.

-- fact_session (current def: 20260713170009).
DROP MATERIALIZED VIEW marts.fact_session;

CREATE MATERIALIZED VIEW marts.fact_session AS
WITH sig AS (
    SELECT
        session_id,
        user_email,
        cc_version,
        ts AS t
    FROM raw.metrics
    WHERE session_id IS NOT NULL
    UNION ALL
    SELECT
        session_id,
        user_email,
        cc_version,
        event_time
    FROM raw.events
    WHERE session_id IS NOT NULL
),

start_type AS (
    SELECT
        session_id,
        (ARRAY_AGG(start_type ORDER BY ts DESC) FILTER (WHERE start_type IS NOT NULL))[1]
            AS start_type
    FROM raw.metrics
    WHERE metric_name = 'claude_code.session.count' AND session_id IS NOT NULL
    GROUP BY session_id
)

SELECT
    sig.session_id,
    st.start_type,
    COALESCE(
        (ARRAY_AGG(sig.user_email ORDER BY sig.t) FILTER (WHERE sig.user_email IS NOT NULL))[1],
        '(unknown)'
    ) AS user_email,
    MIN(sig.t) AS started_at,
    (ARRAY_AGG(sig.cc_version ORDER BY sig.t DESC) FILTER (WHERE sig.cc_version IS NOT NULL))[1]
        AS cc_version,
    EXTRACT(EPOCH FROM (MAX(sig.t) - MIN(sig.t)))::bigint AS duration_s
FROM sig
LEFT JOIN start_type AS st ON sig.session_id = st.session_id
GROUP BY sig.session_id, st.start_type;

CREATE UNIQUE INDEX fact_session_pk ON marts.fact_session (session_id);

GRANT SELECT ON marts.fact_session TO cc_otel_read;

-- fact_session_daily (current def: 20260720120000). Wrap the itworx-preferring CASE, whose
-- ELSE can still be NULL when both m and p emails are NULL.
DROP MATERIALIZED VIEW marts.fact_session_daily;

CREATE MATERIALIZED VIEW marts.fact_session_daily AS
WITH m AS (
    SELECT
        session_id,
        ts::date AS activity_date,
        (
            ARRAY_AGG(
                user_email
                ORDER BY (user_email LIKE '%@itworx.com') DESC NULLS LAST, user_email
            ) FILTER (WHERE user_email IS NOT NULL)
        )[1] AS user_email,
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
    GROUP BY session_id, ts::date
),

p AS (
    SELECT
        session_id,
        event_time::date AS activity_date,
        (
            ARRAY_AGG(
                user_email
                ORDER BY (user_email LIKE '%@itworx.com') DESC NULLS LAST, user_email
            ) FILTER (WHERE user_email IS NOT NULL)
        )[1] AS user_email,
        COUNT(DISTINCT prompt_id) AS prompts
    FROM raw.events
    WHERE prompt_id IS NOT NULL AND session_id IS NOT NULL
    GROUP BY session_id, event_time::date
)

SELECT
    COALESCE(m.session_id, p.session_id) AS session_id,
    COALESCE(
        CASE
            WHEN m.user_email LIKE '%@itworx.com' THEN m.user_email
            WHEN p.user_email LIKE '%@itworx.com' THEN p.user_email
            ELSE COALESCE(m.user_email, p.user_email)
        END,
        '(unknown)'
    ) AS user_email,
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

GRANT SELECT ON marts.fact_session_daily TO cc_otel_read;

-- fact_api_usage (current def: 20260722120000, carries cost_usd).
DROP MATERIALIZED VIEW marts.fact_api_usage;

CREATE MATERIALIZED VIEW marts.fact_api_usage AS
SELECT
    session_id,
    event_time::date AS activity_date,
    model,
    effort,
    query_source,
    COALESCE(
        (ARRAY_AGG(user_email) FILTER (WHERE user_email IS NOT NULL))[1],
        '(unknown)'
    ) AS user_email,
    SUM(input_tokens) AS input_tokens,
    SUM(output_tokens) AS output_tokens,
    SUM(cache_creation_tokens) AS cache_creation_tokens,
    SUM(cache_read_tokens) AS cache_read_tokens,
    SUM(cost_usd) AS cost_usd,
    COUNT(*) AS request_count,
    MAX(event_time) AS last_event_ts
FROM staging.stg_api_request
WHERE session_id IS NOT NULL
GROUP BY session_id, event_time::date, model, effort, query_source;

CREATE UNIQUE INDEX fact_api_usage_pk ON marts.fact_api_usage
(session_id, activity_date, model, effort, query_source);

GRANT SELECT ON marts.fact_api_usage TO cc_otel_read;

-- fact_edit_decision (current def: 20260713170009).
DROP MATERIALIZED VIEW marts.fact_edit_decision;

CREATE MATERIALIZED VIEW marts.fact_edit_decision AS
SELECT
    session_id,
    ts::date AS activity_date,
    tool_name,
    language,
    decision,
    source,
    COALESCE(
        (ARRAY_AGG(user_email) FILTER (WHERE user_email IS NOT NULL))[1],
        '(unknown)'
    ) AS user_email,
    SUM(value) AS decision_count
FROM staging.stg_counter_delta
WHERE metric_name = 'claude_code.code_edit_tool.decision' AND session_id IS NOT NULL
GROUP BY session_id, ts::date, tool_name, language, decision, source;

CREATE UNIQUE INDEX fact_edit_decision_pk ON marts.fact_edit_decision
(session_id, activity_date, tool_name, language, decision, source);

GRANT SELECT ON marts.fact_edit_decision TO cc_otel_read;

-- fact_usage_window (current def: 20260713170010). user_email is part of the PK; the seg
-- CTE already groups the single NULL population into one group, so COALESCE in the outer
-- projection maps it to '(unknown)' without changing uniqueness.
DROP MATERIALIZED VIEW marts.fact_usage_window;

CREATE MATERIALIZED VIEW marts.fact_usage_window AS
WITH seg AS (
    SELECT
        user_email,
        window_type,
        window_end,
        segment_no,
        MIN(ts) AS first_sample_ts,
        MAX(ts) AS last_sample_ts,
        COUNT(*) AS sample_count,
        (ARRAY_AGG(util_pct ORDER BY ts DESC))[1] AS end_pct,
        MAX(util_pct) AS peak_pct,
        (ARRAY_AGG(ts ORDER BY util_pct DESC, ts ASC))[1] AS peak_ts
    FROM staging.stg_utilization_segments
    GROUP BY user_email, window_type, window_end, segment_no
)

SELECT  -- noqa: ST06
    COALESCE(user_email, '(unknown)') AS user_email,
    window_type,
    window_end,
    segment_no,
    end_pct,
    peak_pct,
    peak_ts,
    first_sample_ts,
    last_sample_ts,
    sample_count,
    window_end - CASE window_type
        WHEN '5h' THEN interval '5 hours'
        WHEN '7d' THEN interval '7 days'
        ELSE interval '0'
    END AS window_start,
    MAX(segment_no) OVER (PARTITION BY user_email, window_type, window_end) > 1
        AS is_reset_split,
    peak_pct / NULLIF(EXTRACT(EPOCH FROM (peak_ts - first_sample_ts)) / 3600.0, 0)
        AS pace_pct_per_hour
FROM seg;

CREATE UNIQUE INDEX fact_usage_window_pk ON marts.fact_usage_window
(user_email, window_type, window_end, segment_no);

GRANT SELECT ON marts.fact_usage_window TO cc_otel_read;

-- fact_utilization_hourly (current def: 20260713170010). user_email is part of the PK; the
-- GROUP BY already collapses the single NULL population into one group.
DROP MATERIALIZED VIEW marts.fact_utilization_hourly;

CREATE MATERIALIZED VIEW marts.fact_utilization_hourly AS
SELECT  -- noqa: ST06
    COALESCE(user_email, '(unknown)') AS user_email,
    window_type,
    DATE_TRUNC('hour', ts) AS hour,
    AVG(util_pct) AS avg_pct,
    MAX(util_pct) AS max_pct
FROM staging.stg_utilization_segments
GROUP BY user_email, window_type, DATE_TRUNC('hour', ts);

CREATE UNIQUE INDEX fact_utilization_hourly_pk ON marts.fact_utilization_hourly
(user_email, window_type, hour);

GRANT SELECT ON marts.fact_utilization_hourly TO cc_otel_read;

-- migrate:down

-- Restore each fact's prior definition (user_email left NULL when unresolved).

DROP MATERIALIZED VIEW marts.fact_utilization_hourly;

CREATE MATERIALIZED VIEW marts.fact_utilization_hourly AS
SELECT
    user_email,
    window_type,
    DATE_TRUNC('hour', ts) AS hour,
    AVG(util_pct) AS avg_pct,
    MAX(util_pct) AS max_pct
FROM staging.stg_utilization_segments
GROUP BY user_email, window_type, DATE_TRUNC('hour', ts);

CREATE UNIQUE INDEX fact_utilization_hourly_pk ON marts.fact_utilization_hourly
(user_email, window_type, hour);

GRANT SELECT ON marts.fact_utilization_hourly TO cc_otel_read;

DROP MATERIALIZED VIEW marts.fact_usage_window;

CREATE MATERIALIZED VIEW marts.fact_usage_window AS
WITH seg AS (
    SELECT
        user_email,
        window_type,
        window_end,
        segment_no,
        MIN(ts) AS first_sample_ts,
        MAX(ts) AS last_sample_ts,
        COUNT(*) AS sample_count,
        (ARRAY_AGG(util_pct ORDER BY ts DESC))[1] AS end_pct,
        MAX(util_pct) AS peak_pct,
        (ARRAY_AGG(ts ORDER BY util_pct DESC, ts ASC))[1] AS peak_ts
    FROM staging.stg_utilization_segments
    GROUP BY user_email, window_type, window_end, segment_no
)

SELECT
    user_email,
    window_type,
    window_end,
    segment_no,
    end_pct,
    peak_pct,
    peak_ts,
    first_sample_ts,
    last_sample_ts,
    sample_count,
    window_end - CASE window_type
        WHEN '5h' THEN interval '5 hours'
        WHEN '7d' THEN interval '7 days'
        ELSE interval '0'
    END AS window_start,
    MAX(segment_no) OVER (PARTITION BY user_email, window_type, window_end) > 1
        AS is_reset_split,
    peak_pct / NULLIF(EXTRACT(EPOCH FROM (peak_ts - first_sample_ts)) / 3600.0, 0)
        AS pace_pct_per_hour
FROM seg;

CREATE UNIQUE INDEX fact_usage_window_pk ON marts.fact_usage_window
(user_email, window_type, window_end, segment_no);

GRANT SELECT ON marts.fact_usage_window TO cc_otel_read;

DROP MATERIALIZED VIEW marts.fact_edit_decision;

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

GRANT SELECT ON marts.fact_edit_decision TO cc_otel_read;

DROP MATERIALIZED VIEW marts.fact_api_usage;

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
    SUM(cost_usd) AS cost_usd,
    COUNT(*) AS request_count,
    MAX(event_time) AS last_event_ts
FROM staging.stg_api_request
WHERE session_id IS NOT NULL
GROUP BY session_id, event_time::date, model, effort, query_source;

CREATE UNIQUE INDEX fact_api_usage_pk ON marts.fact_api_usage
(session_id, activity_date, model, effort, query_source);

GRANT SELECT ON marts.fact_api_usage TO cc_otel_read;

DROP MATERIALIZED VIEW marts.fact_session_daily;

CREATE MATERIALIZED VIEW marts.fact_session_daily AS
WITH m AS (
    SELECT
        session_id,
        ts::date AS activity_date,
        (
            ARRAY_AGG(
                user_email
                ORDER BY (user_email LIKE '%@itworx.com') DESC NULLS LAST, user_email
            ) FILTER (WHERE user_email IS NOT NULL)
        )[1] AS user_email,
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
    GROUP BY session_id, ts::date
),

p AS (
    SELECT
        session_id,
        event_time::date AS activity_date,
        (
            ARRAY_AGG(
                user_email
                ORDER BY (user_email LIKE '%@itworx.com') DESC NULLS LAST, user_email
            ) FILTER (WHERE user_email IS NOT NULL)
        )[1] AS user_email,
        COUNT(DISTINCT prompt_id) AS prompts
    FROM raw.events
    WHERE prompt_id IS NOT NULL AND session_id IS NOT NULL
    GROUP BY session_id, event_time::date
)

SELECT
    COALESCE(m.session_id, p.session_id) AS session_id,
    CASE
        WHEN m.user_email LIKE '%@itworx.com' THEN m.user_email
        WHEN p.user_email LIKE '%@itworx.com' THEN p.user_email
        ELSE COALESCE(m.user_email, p.user_email)
    END AS user_email,
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

GRANT SELECT ON marts.fact_session_daily TO cc_otel_read;

DROP MATERIALIZED VIEW marts.fact_session;

CREATE MATERIALIZED VIEW marts.fact_session AS
WITH sig AS (
    SELECT
        session_id,
        user_email,
        cc_version,
        ts AS t
    FROM raw.metrics
    WHERE session_id IS NOT NULL
    UNION ALL
    SELECT
        session_id,
        user_email,
        cc_version,
        event_time
    FROM raw.events
    WHERE session_id IS NOT NULL
),

start_type AS (
    SELECT
        session_id,
        (ARRAY_AGG(start_type ORDER BY ts DESC) FILTER (WHERE start_type IS NOT NULL))[1]
            AS start_type
    FROM raw.metrics
    WHERE metric_name = 'claude_code.session.count' AND session_id IS NOT NULL
    GROUP BY session_id
)

SELECT
    sig.session_id,
    st.start_type,
    (ARRAY_AGG(sig.user_email ORDER BY sig.t) FILTER (WHERE sig.user_email IS NOT NULL))[1]
        AS user_email,
    MIN(sig.t) AS started_at,
    (ARRAY_AGG(sig.cc_version ORDER BY sig.t DESC) FILTER (WHERE sig.cc_version IS NOT NULL))[1]
        AS cc_version,
    EXTRACT(EPOCH FROM (MAX(sig.t) - MIN(sig.t)))::bigint AS duration_s
FROM sig
LEFT JOIN start_type AS st ON sig.session_id = st.session_id
GROUP BY sig.session_id, st.start_type;

CREATE UNIQUE INDEX fact_session_pk ON marts.fact_session (session_id);

GRANT SELECT ON marts.fact_session TO cc_otel_read;
