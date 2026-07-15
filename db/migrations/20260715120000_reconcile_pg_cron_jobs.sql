-- migrate:up

-- Reconcile the three Azure pg_cron jobs after Bicep has enabled the extension.
-- Earlier migrations deliberately tolerated scheduling failures so vanilla Postgres
-- could apply them; that also meant a transient Azure failure became permanent once
-- dbmate recorded the migration. This corrective migration is strict whenever the
-- extension is available, and named cron.schedule calls update existing jobs in place.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule(
      'trim-processed-batches',
      '17 3 * * *',
      $cron$DELETE FROM meta.processed_batches WHERE processed_at < now() - INTERVAL '7 days'$cron$
    );
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
  ELSE
    RAISE WARNING 'pg_cron is unavailable; Azure bootstrap will treat the missing jobs as a hard failure';
  END IF;
END
$$;

-- migrate:down

-- The jobs are owned by earlier migrations; rolling back this corrective migration
-- must not remove them.
SELECT 1;
