-- migrate:up

-- events/tool_result/tool_input: kept -> denied, and retire the three
-- tool_parameters.<leaf> rows (#359, #369).
--
-- redaction._sweep_tool_parameters only descended OTLP kvlistValue, while the fleet emits
-- tool_parameters as a JSON stringValue -- so the leaf sweep those three rows drove was a
-- no-op and full command lines plus absolute developer paths sat at rest. Denying the
-- parent attributes whole makes the leaves unreachable. Hand-authored because spec_sync's
-- registry diff is a set diff over the 10-field RegistryRow: an in-place status edit reads
-- as a missing_row plus an orphan_row, and a DB ahead of the spec (the three leaf rows) is
-- never a generated DELETE.

UPDATE meta.column_registry
SET
    status = 'denied',
    decided_at = '2026-07-29',
    notes = '#369: full command lines + absolute developer paths; was kept until measured'
WHERE signal = 'events' AND signal_name = 'tool_result' AND attr_path = 'tool_input';

DELETE FROM meta.column_registry
WHERE
    signal = 'events'
    AND signal_name = '*'
    AND attr_path IN (
        'tool_parameters.full_command',
        'tool_parameters.bash_command',
        'tool_parameters.file_path'
    );

-- migrate:down

UPDATE meta.column_registry
SET
    status = 'kept',
    decided_at = '2026-07-13',
    notes = 'not in #8 denylist; revisit if PII review flags'
WHERE signal = 'events' AND signal_name = 'tool_result' AND attr_path = 'tool_input';

INSERT INTO meta.column_registry (
    signal, signal_name, attr_path, status, column_name, data_type, description,
    useful_for, decided_at, notes
) VALUES
('events', '*', 'tool_parameters.full_command', 'denied', NULL, NULL,
 'Full command inside tool_parameters.', NULL, '2026-07-13',
 '#8 recursive tool_parameters sweep (tool_result + tool_decision)'),
('events', '*', 'tool_parameters.bash_command', 'denied', NULL, NULL,
 'Bash command inside tool_parameters.', NULL, '2026-07-13',
 '#8 recursive tool_parameters sweep'),
('events', '*', 'tool_parameters.file_path', 'denied', NULL, NULL,
 'File path inside tool_parameters.', NULL, '2026-07-13',
 '#8 recursive tool_parameters sweep');
