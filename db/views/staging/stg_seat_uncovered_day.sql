-- Canonical definition for staging.stg_seat_uncovered_day.
-- Source of truth for the view body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name stg_seat_uncovered_day
-- Verified against pg_views.definition by --check (CI + local gate).
CREATE OR REPLACE VIEW staging.stg_seat_uncovered_day AS
 SELECT user_email,
    activity_date,
    ( SELECT max(i.valid_to) AS max
           FROM staging.stg_seat_interval i
          WHERE ((i.user_email = t.user_email) AND (i.valid_to <= t.activity_date))) AS closed_on
   FROM staging.stg_telemetry_day t
  WHERE (NOT (EXISTS ( SELECT 1
           FROM staging.stg_seat_interval i
          WHERE ((i.user_email = t.user_email) AND (i.valid_from <= t.activity_date) AND ((i.valid_to IS NULL) OR (i.valid_to > t.activity_date))))));
