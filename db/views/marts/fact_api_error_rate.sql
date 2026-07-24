-- Canonical definition for marts.fact_api_error_rate.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name fact_api_error_rate
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.fact_api_error_rate AS
 SELECT (event_time)::date AS activity_date,
    count(*) FILTER (WHERE (event_name = 'api_request'::text)) AS api_request_count,
    count(*) FILTER (WHERE (event_name = 'api_error'::text)) AS api_error_count,
    round(((100.0 * (count(*) FILTER (WHERE (event_name = 'api_error'::text)))::numeric) / (NULLIF(count(*), 0))::numeric), 2) AS error_rate_pct
   FROM raw.events
  WHERE (event_name = ANY (ARRAY['api_request'::text, 'api_error'::text]))
  GROUP BY ((event_time)::date);

CREATE UNIQUE INDEX fact_api_error_rate_pk ON marts.fact_api_error_rate USING btree (activity_date);

GRANT SELECT ON marts.fact_api_error_rate TO cc_otel_read;
