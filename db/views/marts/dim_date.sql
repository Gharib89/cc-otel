-- Canonical definition for marts.dim_date.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name dim_date
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.dim_date AS
 SELECT (d)::date AS date_day,
    (EXTRACT(year FROM d))::integer AS year,
    (EXTRACT(quarter FROM d))::integer AS quarter,
    (EXTRACT(month FROM d))::integer AS month,
    to_char(d, 'Mon'::text) AS month_name,
    (EXTRACT(day FROM d))::integer AS day_of_month,
    (EXTRACT(isodow FROM d))::integer AS iso_dow,
    to_char(d, 'Dy'::text) AS day_name,
    (EXTRACT(isodow FROM d) >= (6)::numeric) AS is_weekend,
    (EXTRACT(week FROM d))::integer AS iso_week
   FROM generate_series((COALESCE(LEAST(( SELECT (min(metrics.ts))::date AS min
           FROM raw.metrics), ( SELECT (min(events.event_time))::date AS min
           FROM raw.events)), CURRENT_DATE))::timestamp with time zone, (CURRENT_DATE)::timestamp with time zone, '1 day'::interval) d(d);

CREATE UNIQUE INDEX dim_date_pk ON marts.dim_date USING btree (date_day);

GRANT SELECT ON marts.dim_date TO cc_otel_read;
