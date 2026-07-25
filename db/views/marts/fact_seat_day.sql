-- Canonical definition for marts.fact_seat_day.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name fact_seat_day
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.fact_seat_day AS
 SELECT (d.day)::date AS date_day,
    i.user_email,
    i.seat_tier,
    i.anthropic_org_name
   FROM (staging.stg_seat_interval i
     CROSS JOIN LATERAL generate_series((i.valid_from)::timestamp without time zone, ((COALESCE(i.valid_to, (CURRENT_DATE + 1)) - 1))::timestamp without time zone, '1 day'::interval) d(day));

CREATE UNIQUE INDEX fact_seat_day_pk ON marts.fact_seat_day USING btree (date_day, user_email);

GRANT SELECT ON marts.fact_seat_day TO cc_otel_read;
