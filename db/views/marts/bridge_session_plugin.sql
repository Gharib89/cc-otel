-- Canonical definition for marts.bridge_session_plugin.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name bridge_session_plugin
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.bridge_session_plugin AS
 SELECT session_id,
    plugin_name,
    count(*) AS load_count
   FROM raw.events
  WHERE ((event_name = 'plugin_loaded'::text) AND (session_id IS NOT NULL) AND (plugin_name IS NOT NULL))
  GROUP BY session_id, plugin_name;

CREATE UNIQUE INDEX bridge_session_plugin_pk ON marts.bridge_session_plugin USING btree (session_id, plugin_name);

GRANT SELECT ON marts.bridge_session_plugin TO cc_otel_read;
