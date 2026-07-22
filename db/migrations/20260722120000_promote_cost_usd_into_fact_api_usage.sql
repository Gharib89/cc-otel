-- migrate:up

-- Promote cost into the marts (adopt-findings #158, decision Q1; map #153, issue #170;
-- ADR-0007 supersedes ADR-0002's "no cost columns in marts"). ITWorx pays flat per-seat, so
-- cost_usd is API-EQUIVALENT VALUE CONSUMED — what the same usage would cost on metered
-- API pricing — not marginal spend. Sourced from the cost_usd already promoted onto
-- api_request events in raw.events, surfaced through staging first, then summed per
-- api-usage grain.

-- Expose cost_usd on the staging projection. CREATE OR REPLACE appends the column at
-- the end without dropping the view, so the dependent fact matview stays valid.
CREATE OR REPLACE VIEW staging.stg_api_request AS
SELECT
    event_time,
    session_id,
    user_email,
    model,
    input_tokens,
    output_tokens,
    cache_creation_tokens,
    cache_read_tokens,
    query_source,
    effort,
    speed,
    agent_name,
    skill_name,
    mcp_server_name,
    mcp_tool_name,
    cc_version,
    cost_usd
FROM raw.events
WHERE event_name = 'api_request';

-- Add SUM(cost_usd) to fact_api_usage. A matview can't be replaced in place, so drop
-- and recreate (grain, index, and reader grant unchanged from the facts migration).
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

-- Cross-check the promoted cost against the claude_code.cost.usage counter: two
-- independent measures of the same API-equivalent value that should agree closely. A
-- systematic gap means the api_request cost_usd promotion drifted from the counter —
-- surface it as a DQ finding rather than silently trusting the promoted sum. Tolerance:
-- fire only when BOTH >1% relative AND >$0.01 absolute, so floating-point noise and
-- empty windows don't trip it. Emitted per refresh cycle (point-in-time), matching the
-- other refresh_all
-- DQ inserts. Only the DQ insert is new; the refresh loop is verbatim from the
-- multi-email-grain migration.
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

    -- DQ: promoted cost_usd vs the claude_code.cost.usage counter. Both measure the
    -- same API-equivalent value; a gap past tolerance means the api_request cost
    -- promotion diverged from the counter. Fire only when BOTH >1% relative AND >$0.01
    -- absolute.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'cost_promotion_divergence',
           NULL,
           jsonb_build_object(
               'promoted_usd', round(promoted::numeric, 6),
               'counter_usd', round(counter::numeric, 6),
               'abs_diff_usd', round(abs(promoted - counter)::numeric, 6),
               'rel_diff', round((abs(promoted - counter) / GREATEST(counter, 0.01))::numeric, 6),
               'tolerance', '>1% relative and >$0.01 absolute'
           )
    FROM (
        SELECT
            (SELECT COALESCE(SUM(cost_usd), 0) FROM marts.fact_api_usage) AS promoted,
            -- Match fact_api_usage's session_id IS NOT NULL grain filter, so the two
            -- sides reconcile on the same population (a session-less counter row would
            -- otherwise register as spurious divergence).
            (SELECT COALESCE(SUM(value), 0) FROM staging.stg_counter_delta
                 WHERE metric_name = 'claude_code.cost.usage'
                   AND session_id IS NOT NULL) AS counter
    ) c
    WHERE abs(promoted - counter) > 0.01
      AND abs(promoted - counter) / GREATEST(counter, 0.01) > 0.01;
END
$fn$;

-- migrate:down

-- Restore refresh_all() without the cost cross-check.
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

-- Drop the cost column from the fact, then from the staging view.
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
    COUNT(*) AS request_count,
    MAX(event_time) AS last_event_ts
FROM staging.stg_api_request
WHERE session_id IS NOT NULL
GROUP BY session_id, event_time::date, model, effort, query_source;

CREATE UNIQUE INDEX fact_api_usage_pk ON marts.fact_api_usage
(session_id, activity_date, model, effort, query_source);

GRANT SELECT ON marts.fact_api_usage TO cc_otel_read;

DROP VIEW staging.stg_api_request;

CREATE VIEW staging.stg_api_request AS
SELECT
    event_time,
    session_id,
    user_email,
    model,
    input_tokens,
    output_tokens,
    cache_creation_tokens,
    cache_read_tokens,
    query_source,
    effort,
    speed,
    agent_name,
    skill_name,
    mcp_server_name,
    mcp_tool_name,
    cc_version
FROM raw.events
WHERE event_name = 'api_request';
