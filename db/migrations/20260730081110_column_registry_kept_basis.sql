-- migrate:up
-- Hand-authored, not spec_sync-generated: spec_sync emits raw.* ADD COLUMNs and registry
-- INSERT/DELETEs, never an ALTER of meta.column_registry's own shape. Its registry diff is
-- a set diff over the 12-field RegistryRow, so while kept_basis is NULL every existing row
-- reads as a missing_row plus an orphan_row and generate_migration refuses orphans.
--
-- The two CHECK constraints are the durable half of #366: from here on a PR adding a `kept`
-- row must declare a basis or the migration fails. The drift tool only re-checks claims that
-- already exist -- this is what stops new unwatched ones being created, so do not relax it
-- as an inconvenience.
-- noqa: disable=LT05,LT14

ALTER TABLE meta.column_registry ADD COLUMN kept_basis TEXT;
ALTER TABLE meta.column_registry ADD COLUMN basis_partner TEXT;

-- Backfilled before the CHECKs go on. Every kept row is 'nature' -- kept for what the key
-- is -- unless the curation evidence says otherwise; the 28 exceptions below carry the
-- measurement-based claims from docs/research/promotion-candidate-profile.md.
UPDATE meta.column_registry SET kept_basis = 'nature' WHERE status = 'kept';

-- collinear (2): functionally determined by the partner on the same record.
UPDATE meta.column_registry SET kept_basis = 'collinear', basis_partner = 'os.type'
WHERE (signal, signal_name, attr_path) IN (
    ('resource', '*', 'os.version'),
    ('resource', '*', 'wsl.version')
);

-- constant (18): one value across the profiled window (Settled by the evidence).
UPDATE meta.column_registry SET kept_basis = 'constant'
WHERE (signal, signal_name, attr_path) IN (
    ('events', '*', 'managed_only'),
    ('events', '*', 'safe_mode'),
    ('events', 'api_refusal', 'server_fallback_hop'),
    ('events', 'api_retries_exhausted', 'total_attempts'),
    ('events', 'auth', 'action'),
    ('events', 'auth', 'auth_method'),
    ('events', 'feedback_survey', 'enabled_via_override'),
    ('events', 'feedback_survey', 'event_origin'),
    ('events', 'feedback_survey', 'event_origin_server'),
    ('events', 'feedback_survey', 'survey_type'),
    ('events', 'hook_registered', 'hook_type'),
    ('events', 'plugin_loaded', 'enabled_via'),
    ('events', 'plugin_loaded', 'host_owned_mcp'),
    ('events', 'skill_activated', 'skill.kind'),
    ('events', 'subagent_completed', 'model_swapped'),
    ('events', 'tool_result', 'decision_type'),
    ('resource', '*', 'claude.deployment_mode'),
    ('resource', '*', 'host.arch')
);

-- redundant (6): the information is already carried elsewhere in the schema (#358/#359).
UPDATE meta.column_registry SET kept_basis = 'redundant'
WHERE (signal, signal_name, attr_path) IN (
    ('events', 'assistant_response', 'message.uuid'),
    ('events', 'subagent_completed', 'final_model'),
    ('events', 'tool_decision', 'tool_source'),
    ('events', 'user_prompt', 'message.uuid'),
    ('metrics', 'claude_code.cost.usage', 'mcp_server.name'),
    ('metrics', 'claude_code.cost.usage', 'mcp_tool.name')
);

-- thin (2): reaches too few seats to argue a value case.
UPDATE meta.column_registry SET kept_basis = 'thin'
WHERE (signal, signal_name, attr_path) IN (
    ('events', '*', 'workspace.host_paths'),
    ('metrics', '*', 'workspace.host_paths')
);

ALTER TABLE meta.column_registry
ADD CONSTRAINT column_registry_kept_basis_chk CHECK (
    (
        status = 'kept' AND kept_basis IS NOT NULL
        AND kept_basis IN ('nature', 'constant', 'collinear', 'thin', 'redundant')
    )
    OR (status <> 'kept' AND kept_basis IS NULL)
);

ALTER TABLE meta.column_registry
ADD CONSTRAINT column_registry_basis_partner_chk CHECK (
    (kept_basis = 'collinear' AND basis_partner IS NOT NULL)
    OR (kept_basis IS DISTINCT FROM 'collinear' AND basis_partner IS NULL)
);

-- migrate:down

ALTER TABLE meta.column_registry DROP CONSTRAINT column_registry_basis_partner_chk;
ALTER TABLE meta.column_registry DROP CONSTRAINT column_registry_kept_basis_chk;
ALTER TABLE meta.column_registry DROP COLUMN basis_partner;
ALTER TABLE meta.column_registry DROP COLUMN kept_basis;
