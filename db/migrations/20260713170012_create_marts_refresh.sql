-- migrate:up

-- Hourly full refresh of every matview (#9). marts.refresh_all() refreshes each matview
-- CONCURRENTLY (unique index per matview lets readers keep querying during refresh),
-- logs one mart_refresh_log row per matview, and records data-quality findings. It uses
-- clock_timestamp() (not now(), which is frozen at transaction start) so started/finished
-- capture real per-matview duration.
--
-- Full rebuild is fine at current volume. Revisit trigger (#15): if the hourly refresh
-- exceeds ~2–3 minutes, move to incremental marts (and only then discuss a raw horizon).
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
END
$fn$;

-- Schedule the hourly refresh and the 1-year mart_refresh_log trim (#15) via pg_cron.
-- Guarded exactly like meta.processed_batches: where pg_cron is absent (vanilla Postgres,
-- CI) or bound to a different cron.database_name, scheduling is skipped with a WARNING so
-- the migration still applies cleanly everywhere. dq_finding is intentionally NOT trimmed.
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule(
        'refresh-marts',
        '0 * * * *',
        $cron$SELECT marts.refresh_all()$cron$
    );
    PERFORM cron.schedule(
        'trim-mart-refresh-log',
        '23 3 * * *',
        $cron$DELETE FROM marts.mart_refresh_log WHERE started < now() - INTERVAL '1 year'$cron$
    );
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'pg_cron marts jobs not scheduled (SQLSTATE %): %. Schedule manually if pg_cron is expected here.', SQLSTATE, SQLERRM;
END
$$;

-- migrate:down

DO $$
BEGIN
    PERFORM cron.unschedule('refresh-marts');
    PERFORM cron.unschedule('trim-mart-refresh-log');
EXCEPTION WHEN OTHERS THEN
    NULL;  -- jobs or extension absent; nothing to unschedule
END
$$;

DROP FUNCTION IF EXISTS marts.refresh_all();
