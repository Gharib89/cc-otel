-- migrate:up

-- fact_session_daily's grain is (session_id, activity_date) — enforced by
-- fact_session_daily_pk. But the original m/p CTEs also grouped by user_email, so a
-- session-day logged under two accounts (e.g. a corp @itworx.com login and a personal
-- one) produced two rows sharing that key, which made REFRESH MATERIALIZED VIEW
-- CONCURRENTLY fail with a duplicate-key error and abort the whole hourly
-- marts.refresh_all() run (every mart froze). Fix: group only by the true grain and
-- collapse user_email with a corp-preferring pick, so adoption attributes to the
-- @itworx.com identity. Borrows fact_api_usage's ARRAY_AGG(...)[1] collapse technique,
-- adding a corp-preferring ORDER BY (and a final corp-preferring pick across sources).
DROP MATERIALIZED VIEW marts.fact_session_daily;

CREATE MATERIALIZED VIEW marts.fact_session_daily AS
WITH m AS (
    SELECT
        session_id,
        ts::date AS activity_date,
        (
            ARRAY_AGG(user_email ORDER BY (user_email LIKE '%@itworx.com') DESC NULLS LAST)
            FILTER (WHERE user_email IS NOT NULL)
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
            ARRAY_AGG(user_email ORDER BY (user_email LIKE '%@itworx.com') DESC NULLS LAST)
            FILTER (WHERE user_email IS NOT NULL)
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

-- Collapsing user_email hides multi-account usage from the facts, so capture it as a DQ
-- finding: one row per session-day seen under more than one email, splitting corp from
-- personal so we know which employees signed in with a personal account. Emitted each
-- refresh cycle (point-in-time observation), matching the other refresh_all DQ inserts.
CREATE OR REPLACE FUNCTION marts.refresh_all() RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    mv TEXT;
    log_id BIGINT;
    n BIGINT;
    matviews TEXT[] := ARRAY[
        'dim_user', 'dim_date', 'dim_model',
        'fact_session', 'fact_session_daily', 'fact_api_usage', 'fact_edit_decision',
        'fact_usage_window', 'fact_utilization_hourly',
        'bridge_session_skill', 'bridge_session_mcp', 'bridge_session_plugin',
        'bridge_session_agent', 'bridge_session_hook'
    ];
BEGIN
    FOREACH mv IN ARRAY matviews LOOP
        INSERT INTO marts.mart_refresh_log (mart, started)
        VALUES (mv, clock_timestamp())
        RETURNING id INTO log_id;

        EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY marts.%I', mv);
        EXECUTE format('SELECT count(*) FROM marts.%I', mv) INTO n;

        UPDATE marts.mart_refresh_log
        SET finished = clock_timestamp(), row_count = n
        WHERE id = log_id;
    END LOOP;

    -- DQ: sum_cumulative rows are excluded from staging (delta-only), never silently
    -- dropped — record how many were skipped this cycle.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'cumulative_value_kind', COUNT(*),
           jsonb_build_object('note', 'sum_cumulative metric rows excluded from staging')
    FROM raw.metrics
    WHERE metric_type = 'sum' AND value_kind = 'sum_cumulative'
    HAVING COUNT(*) > 0;

    -- DQ: null-email rows collapse into dim_user's '(unknown)' member — surface the count.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'unknown_email', COUNT(*),
           jsonb_build_object('note', 'raw rows with null user_email')
    FROM (
        SELECT 1 FROM raw.metrics WHERE user_email IS NULL
        UNION ALL
        SELECT 1 FROM raw.events WHERE user_email IS NULL
    ) q
    HAVING COUNT(*) > 0;

    -- DQ: session-days logged under more than one account. fact_session_daily keeps a
    -- single (corp-preferred) email, so this is where multi-account usage is recorded —
    -- one finding per offending session-day, corp vs personal split out.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'multi_email_session',
           cardinality(all_emails),
           jsonb_build_object(
               'session_id', session_id,
               'activity_date', activity_date,
               'corp_emails', to_jsonb(corp_emails),
               'personal_emails', to_jsonb(personal_emails),
               'all_emails', to_jsonb(all_emails)
           )
    FROM (
        SELECT
            session_id,
            activity_date,
            ARRAY_AGG(DISTINCT user_email ORDER BY user_email) AS all_emails,
            COALESCE(
                ARRAY_AGG(DISTINCT user_email ORDER BY user_email)
                    FILTER (WHERE user_email LIKE '%@itworx.com'),
                '{}'::text[]
            ) AS corp_emails,
            COALESCE(
                ARRAY_AGG(DISTINCT user_email ORDER BY user_email)
                    FILTER (WHERE user_email NOT LIKE '%@itworx.com'),
                '{}'::text[]
            ) AS personal_emails
        FROM (
            -- UNION ALL, not UNION: the outer COUNT(DISTINCT)/ARRAY_AGG(DISTINCT)
            -- already de-dupe, so a set UNION here is a wasted sort each refresh.
            SELECT session_id, ts::date AS activity_date, user_email
            FROM staging.stg_counter_delta
            WHERE session_id IS NOT NULL AND user_email IS NOT NULL
            UNION ALL
            SELECT session_id, event_time::date AS activity_date, user_email
            FROM raw.events
            WHERE session_id IS NOT NULL AND user_email IS NOT NULL
        ) e
        GROUP BY session_id, activity_date
        HAVING COUNT(DISTINCT user_email) > 1
    ) x;
END
$fn$;

-- migrate:down

DROP FUNCTION marts.refresh_all();

CREATE FUNCTION marts.refresh_all() RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    mv TEXT;
    log_id BIGINT;
    n BIGINT;
    matviews TEXT[] := ARRAY[
        'dim_user', 'dim_date', 'dim_model',
        'fact_session', 'fact_session_daily', 'fact_api_usage', 'fact_edit_decision',
        'fact_usage_window', 'fact_utilization_hourly',
        'bridge_session_skill', 'bridge_session_mcp', 'bridge_session_plugin',
        'bridge_session_agent', 'bridge_session_hook'
    ];
BEGIN
    FOREACH mv IN ARRAY matviews LOOP
        INSERT INTO marts.mart_refresh_log (mart, started)
        VALUES (mv, clock_timestamp())
        RETURNING id INTO log_id;

        EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY marts.%I', mv);
        EXECUTE format('SELECT count(*) FROM marts.%I', mv) INTO n;

        UPDATE marts.mart_refresh_log
        SET finished = clock_timestamp(), row_count = n
        WHERE id = log_id;
    END LOOP;

    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'cumulative_value_kind', COUNT(*),
           jsonb_build_object('note', 'sum_cumulative metric rows excluded from staging')
    FROM raw.metrics
    WHERE metric_type = 'sum' AND value_kind = 'sum_cumulative'
    HAVING COUNT(*) > 0;

    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'unknown_email', COUNT(*),
           jsonb_build_object('note', 'raw rows with null user_email')
    FROM (
        SELECT 1 FROM raw.metrics WHERE user_email IS NULL
        UNION ALL
        SELECT 1 FROM raw.events WHERE user_email IS NULL
    ) q
    HAVING COUNT(*) > 0;
END
$fn$;

DROP MATERIALIZED VIEW marts.fact_session_daily;

CREATE MATERIALIZED VIEW marts.fact_session_daily AS
WITH m AS (
    SELECT
        session_id,
        user_email,
        ts::date AS activity_date,
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
    SELECT
        session_id,
        user_email,
        event_time::date AS activity_date,
        COUNT(*) AS prompts
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

GRANT SELECT ON marts.fact_session_daily TO cc_otel_read;
