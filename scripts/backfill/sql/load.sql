-- Filtered, deduped, idempotent load of the mapped POC rows from backfill_stg into the
-- live interim raw.* tables (#131, ADR-0006). Run on the interim side after the mapped
-- rows have streamed into backfill_stg (see backfill.sh). One transaction:
--   1. Claim a sentinel in meta.processed_batches; a second run finds it and no-ops
--      (mirrors the sink's batch-hash idempotency on append-only raw).
--   2. Snapshot interim's PRE-backfill session set, so dedup drops only POC sessions that
--      overlap LIVE interim data (the cutover sessions that dual-sent) -- not the backfill's
--      own metric/event sessions.
--   3. Insert, applying the scope filter and the session anti-join.
-- The RAISE NOTICEs print the inserted counts and the overlap-window (>= 2026-07-14)
-- session list needed for the documented rollback predicate (see README.md).
BEGIN;

DO $$
DECLARE
    claimed BIGINT;
    n_metrics BIGINT;
    n_events BIGINT;
    overlap_sessions UUID [];
BEGIN
    INSERT INTO meta.processed_batches (batch_hash)
    VALUES ('poc-backfill:interim:v1')
    ON CONFLICT (batch_hash) DO NOTHING;
    GET DIAGNOSTICS claimed = ROW_COUNT;
    IF claimed = 0 THEN
        RAISE NOTICE 'poc-backfill:interim:v1 already applied; load is a no-op.';
        RETURN;
    END IF;

    CREATE TEMP TABLE _existing_sessions ON COMMIT DROP AS
    SELECT session_id FROM raw.metrics WHERE session_id IS NOT NULL
    UNION
    SELECT session_id FROM raw.events WHERE session_id IS NOT NULL;

    INSERT INTO raw.metrics
    SELECT s.*
    FROM backfill_stg.metrics s
    WHERE s.scope_name IS DISTINCT FROM 'github.copilot'
      AND (s.user_email IS NULL OR s.user_email LIKE '%@itworx.com')
      AND (
          s.session_id IS NULL
          OR s.session_id NOT IN (SELECT session_id FROM _existing_sessions)
      );
    GET DIAGNOSTICS n_metrics = ROW_COUNT;

    INSERT INTO raw.events
    SELECT s.*
    FROM backfill_stg.events s
    WHERE s.scope_name IS DISTINCT FROM 'com.anthropic.claude_code.tracing'
      AND (s.user_email IS NULL OR s.user_email LIKE '%@itworx.com')
      AND (
          s.session_id IS NULL
          OR s.session_id NOT IN (SELECT session_id FROM _existing_sessions)
      );
    GET DIAGNOSTICS n_events = ROW_COUNT;

    SELECT ARRAY_AGG(DISTINCT session_id) INTO overlap_sessions
    FROM (
        SELECT s.session_id
        FROM backfill_stg.metrics s
        WHERE s.ts >= DATE '2026-07-14'
          AND s.scope_name IS DISTINCT FROM 'github.copilot'
          AND s.session_id IS NOT NULL
          AND s.session_id NOT IN (SELECT session_id FROM _existing_sessions)
        UNION
        SELECT s.session_id
        FROM backfill_stg.events s
        WHERE s.event_time >= DATE '2026-07-14'
          AND s.scope_name IS DISTINCT FROM 'com.anthropic.claude_code.tracing'
          AND s.session_id IS NOT NULL
          AND s.session_id NOT IN (SELECT session_id FROM _existing_sessions)
    ) q;

    RAISE NOTICE 'poc-backfill: inserted % metric rows, % event rows', n_metrics, n_events;
    -- COALESCE so an empty overlap prints '{}' (a paste-ready uuid[]) rather than NULL.
    RAISE NOTICE 'poc-backfill: overlap-complement sessions (>= 2026-07-14, for rollback): %',
        COALESCE(overlap_sessions, '{}'::UUID []);
END $$;

COMMIT;
