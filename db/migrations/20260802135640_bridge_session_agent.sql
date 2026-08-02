-- migrate:up
-- matview_sync: bridge_session_agent
-- noqa: disable=all

DROP MATERIALIZED VIEW marts.bridge_session_agent;

-- Canonical definition for marts.bridge_session_agent.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name bridge_session_agent
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.bridge_session_agent AS
 WITH agent_row AS (
         SELECT events.session_id,
            events.agent_name,
            events.event_name,
            NULL::boolean AS subagent_is_async,
            NULL::bigint AS subagent_tool_uses,
            NULL::bigint AS subagent_total_tokens
           FROM raw.events
          WHERE ((events.event_name = 'api_request'::text) AND (events.session_id IS NOT NULL) AND (events.agent_name IS NOT NULL))
        UNION ALL
         SELECT events.session_id,
            events.agent_type,
            events.event_name,
            events.subagent_is_async,
            events.subagent_tool_uses,
            events.subagent_total_tokens
           FROM raw.events
          WHERE ((events.event_name = 'subagent_completed'::text) AND (events.session_id IS NOT NULL) AND (events.agent_type IS NOT NULL))
        )
 SELECT session_id,
    agent_name,
    count(*) FILTER (WHERE (event_name = 'api_request'::text)) AS invocations,
    count(*) FILTER (WHERE (event_name = 'subagent_completed'::text)) AS completions,
    count(*) FILTER (WHERE subagent_is_async) AS async_completions,
    COALESCE(sum(subagent_tool_uses), (0)::numeric) AS tool_uses,
    COALESCE(sum(subagent_total_tokens), (0)::numeric) AS total_tokens
   FROM agent_row
  GROUP BY session_id, agent_name;

CREATE UNIQUE INDEX bridge_session_agent_pk ON marts.bridge_session_agent USING btree (session_id, agent_name);

GRANT SELECT ON marts.bridge_session_agent TO cc_otel_read;

-- migrate:down

DROP MATERIALIZED VIEW marts.bridge_session_agent;

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
