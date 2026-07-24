-- Canonical definition for marts.fact_api_usage.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name fact_api_usage
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.fact_api_usage AS
 SELECT session_id,
    (event_time)::date AS activity_date,
    model,
    effort,
    query_source,
    marts.email_bucket((array_agg(user_email) FILTER (WHERE (user_email IS NOT NULL)))[1]) AS user_email,
    sum(input_tokens) AS input_tokens,
    sum(output_tokens) AS output_tokens,
    sum(cache_creation_tokens) AS cache_creation_tokens,
    sum(cache_read_tokens) AS cache_read_tokens,
    sum(cost_usd) AS cost_usd,
    count(*) AS request_count,
    max(event_time) AS last_event_ts
   FROM staging.stg_api_request
  WHERE (session_id IS NOT NULL)
  GROUP BY session_id, ((event_time)::date), model, effort, query_source;

CREATE UNIQUE INDEX fact_api_usage_pk ON marts.fact_api_usage USING btree (session_id, activity_date, model, effort, query_source);

GRANT SELECT ON marts.fact_api_usage TO cc_otel_read;
