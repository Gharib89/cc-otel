-- One-shot purge of empty (NULL) user_email rows the POC backfill carried into the interim
-- raw.* tables (#216, follow-up to #214, ADR-0006/#131). These are backfilled POC rows that
-- never resolved an email; #214 makes them visible as dim_user's '(unknown)' member so the
-- volume can be judged, and this purge removes them once that judgment confirms they are
-- stale POC backfill (not ongoing signal).
--
-- Scoped to the BACKFILL window (ts/event_time < 2026-07-14): the same backfill-vs-live
-- cutoff purge_non_itworx.sql and the README.md Rollback section use (interim's own live
-- telemetry starts 2026-07-14), so live rows are left untouched -- consistent with the #188
-- "surface non-itworx, don't filter live sink" precedent applied to the empty-user case.
-- The complement of purge_non_itworx.sql, which KEPT these NULL rows: it deleted non-itworx
-- *domains* and left NULL emails for this follow-up. Targets user_email IS NULL only -- the
-- exact population dim_user's COALESCE and the unknown_email DQ finding treat as '(unknown)';
-- any empty-string '' email would surface as its own visible member and is out of scope here.
-- Operator-run against interim, locally, ONLY after Ahmed has reviewed the '(unknown)' volume
-- in the report (#216 re-entry condition), then re-run `SELECT marts.refresh_all()` so
-- staging views + marts matviews (all rebuilt from raw) drop the derived rows too.
-- One transaction:
--   1. Delete the backfill-window NULL-email rows from raw.metrics and raw.events.
--   2. Log a marts.dq_finding row recording the purge with the total row count.
-- Assumption (shared with purge_non_itworx.sql): if live interim data ever predates
-- 2026-07-14, raise the cutoff to interim's true first-live day before running -- otherwise a
-- legitimate live NULL-email row in that range would be purged.
BEGIN;

DO $$
DECLARE
    n_metrics BIGINT;
    n_events BIGINT;
BEGIN
    DELETE FROM raw.metrics
    WHERE user_email IS NULL
      AND ts < DATE '2026-07-14';
    GET DIAGNOSTICS n_metrics = ROW_COUNT;

    DELETE FROM raw.events
    WHERE user_email IS NULL
      AND event_time < DATE '2026-07-14';
    GET DIAGNOSTICS n_events = ROW_COUNT;

    -- subject/kind are NOT NULL (#396). A one-shot operator record is dataset-wide and never
    -- drains -- nobody acts on it until it clears -- so it is a gauge under that test, and the
    -- DQ card must not carry it as a permanent defect it can never work off.
    INSERT INTO marts.dq_finding (finding_type, subject, kind, row_count, details)
    VALUES (
        'empty_user_purge',
        '(dataset)',
        'gauge',
        n_metrics + n_events,
        jsonb_build_object(
            'note', 'one-shot purge of NULL user_email backfill rows from raw (#216)',
            'metrics_deleted', n_metrics,
            'events_deleted', n_events,
            'window', 'ts/event_time < 2026-07-14'
        )
    );

    RAISE NOTICE 'empty_user_purge: deleted % metric rows, % event rows', n_metrics, n_events;
END $$;

COMMIT;
