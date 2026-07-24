-- Canonical definition for marts.bridge_session_hook.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name bridge_session_hook
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.bridge_session_hook AS
 SELECT session_id,
    hook_name,
    count(*) AS executions
   FROM raw.events
  WHERE ((event_name = 'hook_execution_complete'::text) AND (session_id IS NOT NULL) AND (hook_name IS NOT NULL))
  GROUP BY session_id, hook_name;

CREATE UNIQUE INDEX bridge_session_hook_pk ON marts.bridge_session_hook USING btree (session_id, hook_name);

GRANT SELECT ON marts.bridge_session_hook TO cc_otel_read;
