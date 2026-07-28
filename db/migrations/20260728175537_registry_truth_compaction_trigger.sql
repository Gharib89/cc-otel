-- migrate:up
-- noqa: disable=LT05

-- events/compaction/trigger: kept -> promoted (#353, #362).
--
-- The registry said "blob reservoir only, no Postgres column" while raw.events.trigger
-- already carried 57 compaction rows (manual 29, auto 28): attr_columns(signal) drops
-- signal_name, so the promoted permission_mode_changed row writes the column under every
-- event name. Hand-authored because spec_sync's registry diff is a set diff over the
-- 10-field RegistryRow -- an in-place status edit reads as a missing_row plus an
-- orphan_row, and generate_migration refuses orphans.

UPDATE meta.column_registry
SET
    status = 'promoted',
    column_name = 'trigger',
    data_type = 'TEXT',
    decided_at = '2026-07-28',
    notes = 'promoted from kept: raw.events.trigger already carried 57 compaction rows (#353)'
WHERE signal = 'events' AND signal_name = 'compaction' AND attr_path = 'trigger';

-- migrate:down

UPDATE meta.column_registry
SET
    status = 'kept',
    column_name = NULL,
    data_type = NULL,
    decided_at = '2026-07-13',
    notes = NULL
WHERE signal = 'events' AND signal_name = 'compaction' AND attr_path = 'trigger';
