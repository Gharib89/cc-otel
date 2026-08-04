-- Canonical definition for staging.stg_telemetry_day.
-- Source of truth for the view body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name stg_telemetry_day
-- Verified against pg_views.definition by --check (CI + local gate).
CREATE OR REPLACE VIEW staging.stg_telemetry_day AS
 SELECT metrics.user_email,
    (metrics.ts)::date AS activity_date
   FROM raw.metrics
  WHERE (metrics.user_email IS NOT NULL)
UNION
 SELECT events.user_email,
    (events.event_time)::date AS activity_date
   FROM raw.events
  WHERE (events.user_email IS NOT NULL);
