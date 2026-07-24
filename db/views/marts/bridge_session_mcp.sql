-- Canonical definition for marts.bridge_session_mcp.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name bridge_session_mcp
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.bridge_session_mcp AS
 WITH names AS (
         SELECT events.session_id,
            events.tool_name AS mcp_name
           FROM raw.events
          WHERE ((events.event_name = 'tool_result'::text) AND (events.session_id IS NOT NULL) AND (events.tool_name ~~ 'mcp__%'::text))
        UNION ALL
         SELECT events.session_id,
            events.mcp_server_name
           FROM raw.events
          WHERE ((events.event_name = 'api_request'::text) AND (events.session_id IS NOT NULL) AND (events.mcp_server_name IS NOT NULL))
        )
 SELECT session_id,
    mcp_name,
    count(*) AS tool_calls
   FROM names
  GROUP BY session_id, mcp_name;

CREATE UNIQUE INDEX bridge_session_mcp_pk ON marts.bridge_session_mcp USING btree (session_id, mcp_name);

GRANT SELECT ON marts.bridge_session_mcp TO cc_otel_read;
