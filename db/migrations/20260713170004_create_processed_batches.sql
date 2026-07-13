-- migrate:up

-- Ingest idempotency ledger (#7). The sink hashes each redacted OTLP batch and records
-- it here inside the same transaction as the row writes; a replayed batch (collector
-- retry, blob re-POST) hits the PK and is skipped. Hashing the redacted payload means
-- replayed content is byte-identical (#8).
CREATE TABLE meta.processed_batches (
    batch_hash TEXT PRIMARY KEY,                    -- hash of the redacted OTLP payload
    processed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT ON meta.processed_batches TO cc_otel_ingest;
GRANT SELECT ON meta.processed_batches TO cc_otel_read;

-- Trim the ledger daily, keeping ~7 days — comfortably longer than the collector's
-- ~1-day persistent-queue retry window (#7), after which a replay can't recur. pg_cron
-- runs inside Postgres (no cron host on ACA). It requires shared_preload_libraries +
-- azure.extensions + cron.database_name = cc_otel, set at server provision (#23/#31);
-- where the extension isn't available (vanilla Postgres, CI, a server whose
-- cron.database_name points elsewhere) scheduling is skipped so the migration still
-- applies cleanly everywhere.
DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_cron;
  PERFORM cron.schedule(
    'trim-processed-batches',
    '17 3 * * *',
    $cron$DELETE FROM meta.processed_batches WHERE processed_at < now() - INTERVAL '7 days'$cron$
  );
EXCEPTION WHEN OTHERS THEN
  -- Tolerated by design so the migration applies cleanly everywhere: pg_cron may be
  -- absent (vanilla Postgres, CI) or present but bound to a different cron.database_name
  -- (e.g. the dev server). Report the real error as a WARNING rather than asserting a
  -- cause, so a genuine scheduling failure on a pg_cron server is visible, not masked.
  RAISE WARNING 'pg_cron trim of meta.processed_batches not scheduled (SQLSTATE %): %. Schedule manually if pg_cron is expected here.', SQLSTATE, SQLERRM;
END
$$;

-- migrate:down

DO $$
BEGIN
  PERFORM cron.unschedule('trim-processed-batches');
EXCEPTION WHEN OTHERS THEN
  NULL;  -- job or extension absent; nothing to unschedule
END
$$;

DROP TABLE IF EXISTS meta.processed_batches;
