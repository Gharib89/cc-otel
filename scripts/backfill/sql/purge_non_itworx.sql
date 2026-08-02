-- One-shot purge of non-itworx-domain user_email rows the POC backfill carried into the interim
-- raw.* tables (#162, ADR-0006/#131) -- noise in the adoption report's user counts and rosters.
-- Scoped to the BACKFILL window (ts/event_time < 2026-07-14): the same backfill-vs-live cutoff
-- the Rollback section of README.md uses (interim's own live telemetry starts 2026-07-14), so
-- live non-itworx rows are left untouched. Deletes only rows whose user_email has a non-itworx
-- domain; NULL emails are KEPT (covered by the existing unknown_email DQ finding, and the
-- decision targets non-itworx *domains* only). The itworx domain is matched case- and
-- whitespace-insensitively (lower(trim(user_email))) so a mixed-case ITWORX address is never
-- wrongly purged. Operator-run against interim, locally, then re-run
-- `SELECT marts.refresh_all()` so staging views + marts matviews (all rebuilt from raw) drop the
-- derived rows too. One transaction:
--   1. Collect the distinct non-itworx domains (not full emails) for the DQ finding details.
--   2. Delete the backfill-window non-itworx rows from raw.metrics and raw.events.
--   3. Log a marts.dq_finding row recording the purge with the total row count.
-- Assumption (shared with the README rollback): if live interim data ever predates 2026-07-14,
-- raise the cutoff to interim's true first-live day before running -- otherwise a legitimate live
-- non-itworx row in that range would be purged.
BEGIN;

DO $$
DECLARE
    n_metrics BIGINT;
    n_events BIGINT;
    domains TEXT [];
BEGIN
    SELECT ARRAY(
        SELECT DISTINCT split_part(lower(trim(user_email)), '@', 2) AS domain
        FROM (
            SELECT user_email FROM raw.metrics WHERE ts < DATE '2026-07-14'
            UNION
            SELECT user_email FROM raw.events WHERE event_time < DATE '2026-07-14'
        ) q
        WHERE user_email IS NOT NULL
          AND lower(trim(user_email)) NOT LIKE '%@itworx.com'
        ORDER BY domain
    ) INTO domains;

    DELETE FROM raw.metrics
    WHERE user_email IS NOT NULL AND lower(trim(user_email)) NOT LIKE '%@itworx.com'
      AND ts < DATE '2026-07-14';
    GET DIAGNOSTICS n_metrics = ROW_COUNT;

    DELETE FROM raw.events
    WHERE user_email IS NOT NULL AND lower(trim(user_email)) NOT LIKE '%@itworx.com'
      AND event_time < DATE '2026-07-14';
    GET DIAGNOSTICS n_events = ROW_COUNT;

    -- subject/kind are NOT NULL (#396). A one-shot operator record is dataset-wide and never
    -- drains -- nobody acts on it until it clears -- so it is a gauge under that test, and the
    -- DQ card must not carry it as a permanent defect it can never work off.
    INSERT INTO marts.dq_finding (finding_type, subject, kind, row_count, details)
    VALUES (
        'non_itworx_email_purge',
        '(dataset)',
        'gauge',
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
