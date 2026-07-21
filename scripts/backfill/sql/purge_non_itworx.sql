-- One-shot purge of non-itworx-domain user_email rows from the interim raw.* tables (#162).
-- The POC backfill (ADR-0006, #131) carried non-itworx-domain emails into interim -- noise in
-- the adoption report's user counts and rosters. This deletes only rows whose user_email has a
-- non-itworx domain; NULL emails are KEPT (they are covered by the existing unknown_email DQ
-- finding, and the decision targets non-itworx *domains* only). Operator-run against interim,
-- locally, then re-run `SELECT marts.refresh_all()` so staging views + marts matviews (all
-- rebuilt from raw) drop the derived rows too. One transaction:
--   1. Collect the distinct non-itworx domains (not full emails) for the DQ finding details.
--   2. Delete the non-itworx rows from raw.metrics and raw.events.
--   3. Log a marts.dq_finding row recording the purge with the total row count.
BEGIN;

DO $$
DECLARE
    n_metrics BIGINT;
    n_events BIGINT;
    domains TEXT [];
BEGIN
    SELECT ARRAY(
        SELECT DISTINCT split_part(user_email, '@', 2) AS domain
        FROM (
            SELECT user_email FROM raw.metrics
            UNION
            SELECT user_email FROM raw.events
        ) q
        WHERE user_email IS NOT NULL
          AND user_email NOT LIKE '%@itworx.com'
        ORDER BY domain
    ) INTO domains;

    DELETE FROM raw.metrics
    WHERE user_email IS NOT NULL AND user_email NOT LIKE '%@itworx.com';
    GET DIAGNOSTICS n_metrics = ROW_COUNT;

    DELETE FROM raw.events
    WHERE user_email IS NOT NULL AND user_email NOT LIKE '%@itworx.com';
    GET DIAGNOSTICS n_events = ROW_COUNT;

    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    VALUES (
        'non_itworx_email_purge',
        n_metrics + n_events,
        jsonb_build_object(
            'note', 'one-shot purge of non-itworx-domain user_email rows from raw (#162)',
            'metrics_deleted', n_metrics,
            'events_deleted', n_events,
            'domains', to_jsonb(domains)
        )
    );

    RAISE NOTICE 'non_itworx_email_purge: deleted % metric rows, % event rows; domains %',
        n_metrics, n_events, domains;
END $$;

COMMIT;
