-- Canonical definition for marts.bridge_session_skill.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name bridge_session_skill
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.bridge_session_skill AS
 SELECT session_id,
    skill_name,
    count(*) AS activations
   FROM raw.events
  WHERE ((event_name = ANY (ARRAY['skill_activated'::text, 'api_request'::text])) AND (session_id IS NOT NULL) AND (skill_name IS NOT NULL))
  GROUP BY session_id, skill_name;

CREATE UNIQUE INDEX bridge_session_skill_pk ON marts.bridge_session_skill USING btree (session_id, skill_name);

GRANT SELECT ON marts.bridge_session_skill TO cc_otel_read;
