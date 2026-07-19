-- migrate:up

-- Non-empty-session signal moves from the `user_prompt` event to DISTINCT prompt_id
-- (#131). Older Claude Code builds almost never emitted `user_prompt` (the POC logged 42
-- in six weeks), but every human turn carries a prompt_id on api_request and friends, so
-- prompt_id is the durable turn signal across both backfilled history and live data. Only
-- the fact_session_daily `p` CTE changes; refresh_all() and every other object are
-- untouched. fact_session_daily is a matview, so this is a DROP + CREATE, not REPLACE.
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

-- migrate:down

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
        COUNT(*) AS prompts
    FROM raw.events
    WHERE event_name = 'user_prompt' AND session_id IS NOT NULL
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
