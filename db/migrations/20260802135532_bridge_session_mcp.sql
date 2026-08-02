-- migrate:up
-- matview_sync: bridge_session_mcp
-- noqa: disable=all

DROP MATERIALIZED VIEW marts.bridge_session_mcp;

-- Canonical definition for marts.bridge_session_mcp.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name bridge_session_mcp
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.bridge_session_mcp AS
 WITH server AS (
         SELECT DISTINCT events.mcp_connection_server_name AS mcp_name,
            regexp_replace(events.mcp_connection_server_name, '[ .:]'::text, '_'::text, 'g'::text) AS mcp_slug
           FROM raw.events
          WHERE ((events.event_name = 'mcp_server_connection'::text) AND (events.mcp_connection_server_name IS NOT NULL))
        ), conn AS (
         SELECT events.session_id,
            events.mcp_connection_server_name AS mcp_name,
            count(*) AS connections,
            count(*) FILTER (WHERE (events.mcp_connection_status = 'failed'::text)) AS connect_failures,
            (array_agg(events.mcp_transport_type ORDER BY events.event_time DESC) FILTER (WHERE (events.mcp_transport_type IS NOT NULL)))[1] AS mcp_transport_type,
            (array_agg(events.mcp_connection_server_scope ORDER BY events.event_time DESC) FILTER (WHERE (events.mcp_connection_server_scope IS NOT NULL)))[1] AS mcp_connection_server_scope
           FROM raw.events
          WHERE ((events.event_name = 'mcp_server_connection'::text) AND (events.session_id IS NOT NULL) AND (events.mcp_connection_server_name IS NOT NULL))
          GROUP BY events.session_id, events.mcp_connection_server_name
        ), calls AS (
         SELECT events.session_id,
            server.mcp_name,
            count(*) AS api_calls
           FROM (raw.events
             JOIN server ON ((server.mcp_slug = events.mcp_server_name)))
          WHERE ((events.event_name = 'api_request'::text) AND (events.session_id IS NOT NULL) AND (events.mcp_server_name IS NOT NULL))
          GROUP BY events.session_id, server.mcp_name
        )
 SELECT COALESCE(conn.session_id, calls.session_id) AS session_id,
    COALESCE(conn.mcp_name, calls.mcp_name) AS mcp_name,
    COALESCE(conn.connections, (0)::bigint) AS connections,
    COALESCE(conn.connect_failures, (0)::bigint) AS connect_failures,
    COALESCE(calls.api_calls, (0)::bigint) AS api_calls,
    conn.mcp_transport_type,
    conn.mcp_connection_server_scope
   FROM (conn
     FULL JOIN calls ON (((calls.session_id = conn.session_id) AND (calls.mcp_name = conn.mcp_name))));

CREATE UNIQUE INDEX bridge_session_mcp_pk ON marts.bridge_session_mcp USING btree (session_id, mcp_name);

GRANT SELECT ON marts.bridge_session_mcp TO cc_otel_read;

-- migrate:down

DROP MATERIALIZED VIEW marts.bridge_session_mcp;

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
