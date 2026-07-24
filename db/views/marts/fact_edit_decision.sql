-- Canonical definition for marts.fact_edit_decision.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name fact_edit_decision
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.fact_edit_decision AS
 SELECT session_id,
    (ts)::date AS activity_date,
    tool_name,
    language,
    decision,
    source,
    marts.email_bucket((array_agg(user_email) FILTER (WHERE (user_email IS NOT NULL)))[1]) AS user_email,
    sum(value) AS decision_count
   FROM staging.stg_counter_delta
  WHERE ((metric_name = 'claude_code.code_edit_tool.decision'::text) AND (session_id IS NOT NULL))
  GROUP BY session_id, ((ts)::date), tool_name, language, decision, source;

CREATE UNIQUE INDEX fact_edit_decision_pk ON marts.fact_edit_decision USING btree (session_id, activity_date, tool_name, language, decision, source);

GRANT SELECT ON marts.fact_edit_decision TO cc_otel_read;
