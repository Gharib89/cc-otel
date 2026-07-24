-- migrate:up
-- matview_sync: fact_utilization_hourly
-- noqa: disable=all

DROP MATERIALIZED VIEW marts.fact_utilization_hourly;

-- Canonical definition for marts.fact_utilization_hourly.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name fact_utilization_hourly
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.fact_utilization_hourly AS
 SELECT marts.email_bucket(user_email) AS user_email,
    window_type,
    date_trunc('hour'::text, ts) AS hour,
    avg(util_pct) AS avg_pct,
    max(util_pct) AS max_pct
   FROM staging.stg_utilization_segments
  GROUP BY user_email, window_type, (date_trunc('hour'::text, ts));

CREATE UNIQUE INDEX fact_utilization_hourly_pk ON marts.fact_utilization_hourly USING btree (user_email, window_type, hour);

GRANT SELECT ON marts.fact_utilization_hourly TO cc_otel_read;

-- migrate:down

DROP MATERIALIZED VIEW marts.fact_utilization_hourly;

-- Canonical definition for marts.fact_utilization_hourly.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name fact_utilization_hourly
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.fact_utilization_hourly AS
 SELECT COALESCE(user_email, '(unknown)'::text) AS user_email,
    window_type,
    date_trunc('hour'::text, ts) AS hour,
    avg(util_pct) AS avg_pct,
    max(util_pct) AS max_pct
   FROM staging.stg_utilization_segments
  GROUP BY user_email, window_type, (date_trunc('hour'::text, ts));

CREATE UNIQUE INDEX fact_utilization_hourly_pk ON marts.fact_utilization_hourly USING btree (user_email, window_type, hour);

GRANT SELECT ON marts.fact_utilization_hourly TO cc_otel_read;
