-- migrate:up

-- Reliability marts (#171, map #153 decision Q1): two event-derived facts that turn
-- tool_result / api_request / api_error events into the reliability signals the exec
-- shortlist (#8) and Data Health page need. error_type / status_code / attempt
-- breakdowns are deliberately out of scope until each attr is promoted in
-- meta.column_registry — only the headline rates are adopted here.

-- fact_tool_outcome: session × day × tool over tool_result events. success_bool and
-- duration_ms are already promoted columns on raw.events, so no registry change is
-- needed. Percentiles use PERCENTILE_CONT (ignores NULL duration_ms) rounded to whole
-- milliseconds — interpolated sub-ms precision on a latency signal is noise.
CREATE MATERIALIZED VIEW marts.fact_tool_outcome AS
SELECT
    session_id,
    event_time::date AS activity_date,
    tool_name,
    COUNT(*) AS tool_call_count,
    COUNT(*) FILTER (WHERE success_bool) AS success_count,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY duration_ms)::bigint AS duration_p50_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms)::bigint AS duration_p95_ms
FROM raw.events
WHERE event_name = 'tool_result' AND session_id IS NOT NULL
GROUP BY session_id, event_time::date, tool_name;

CREATE UNIQUE INDEX fact_tool_outcome_pk ON marts.fact_tool_outcome
(session_id, activity_date, tool_name);

GRANT SELECT ON marts.fact_tool_outcome TO cc_otel_read;

-- fact_api_error_rate: one row per day. api_request events are successful requests and
-- api_error events are failed ones (disjoint event_names), so total attempts is their
-- sum and the error rate is errors / total attempts, expressed 0-100 to match the other
-- pct marts. Feeds the Data Health tile.
CREATE MATERIALIZED VIEW marts.fact_api_error_rate AS
SELECT
    event_time::date AS activity_date,
    COUNT(*) FILTER (WHERE event_name = 'api_request') AS api_request_count,
    COUNT(*) FILTER (WHERE event_name = 'api_error') AS api_error_count,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE event_name = 'api_error')
        / NULLIF(COUNT(*), 0),
        2
    ) AS error_rate_pct
FROM raw.events
WHERE event_name IN ('api_request', 'api_error')
GROUP BY event_time::date;

CREATE UNIQUE INDEX fact_api_error_rate_pk ON marts.fact_api_error_rate (activity_date);

GRANT SELECT ON marts.fact_api_error_rate TO cc_otel_read;

-- Register both new matviews with the hourly refresh (#9) — a matview absent from this
-- array never refreshes. Function body is otherwise identical to its prior definition.
CREATE OR REPLACE FUNCTION marts.refresh_all() RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    mv TEXT;
    log_id BIGINT;
    n BIGINT;
    matviews TEXT[] := ARRAY[
        'dim_user', 'dim_date', 'dim_model',
        'fact_session', 'fact_session_daily', 'fact_api_usage', 'fact_edit_decision',
        'fact_usage_window', 'fact_utilization_hourly',
        'fact_tool_outcome', 'fact_api_error_rate',
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

DROP MATERIALIZED VIEW IF EXISTS marts.fact_api_error_rate;
DROP MATERIALIZED VIEW IF EXISTS marts.fact_tool_outcome;
