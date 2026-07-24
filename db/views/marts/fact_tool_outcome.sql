-- Canonical definition for marts.fact_tool_outcome.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name fact_tool_outcome
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.fact_tool_outcome AS
 SELECT session_id,
    (event_time)::date AS activity_date,
    tool_name,
    count(*) AS tool_call_count,
    count(*) FILTER (WHERE success_bool) AS success_count,
    (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((duration_ms)::double precision)))::bigint AS duration_p50_ms,
    (percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((duration_ms)::double precision)))::bigint AS duration_p95_ms
   FROM raw.events
  WHERE ((event_name = 'tool_result'::text) AND (session_id IS NOT NULL))
  GROUP BY session_id, ((event_time)::date), tool_name;

CREATE UNIQUE INDEX fact_tool_outcome_pk ON marts.fact_tool_outcome USING btree (session_id, activity_date, tool_name);

GRANT SELECT ON marts.fact_tool_outcome TO cc_otel_read;
