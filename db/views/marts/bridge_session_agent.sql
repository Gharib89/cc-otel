-- Canonical definition for marts.bridge_session_agent.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name bridge_session_agent
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.bridge_session_agent AS
 SELECT session_id,
    agent_name,
    count(*) AS invocations
   FROM raw.events
  WHERE ((event_name = 'api_request'::text) AND (session_id IS NOT NULL) AND (agent_name IS NOT NULL))
  GROUP BY session_id, agent_name;

CREATE UNIQUE INDEX bridge_session_agent_pk ON marts.bridge_session_agent USING btree (session_id, agent_name);

GRANT SELECT ON marts.bridge_session_agent TO cc_otel_read;
