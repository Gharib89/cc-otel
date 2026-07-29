-- migrate:up
-- spec_sync: deny_tool_parameters
-- noqa: disable=LT05,LT14

INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('events', 'tool_decision', 'tool_parameters', 'denied', NULL, NULL, 'Tool args JSON (details-gated).', NULL, '2026-07-29', '#369: emitted as a JSON string, so the leaf sweep never reached it');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('events', 'tool_result', 'tool_parameters', 'denied', NULL, NULL, 'Tool args JSON (details-gated).', NULL, '2026-07-29', '#369: emitted as a JSON string, so the leaf sweep never reached it');

-- migrate:down

DELETE FROM meta.column_registry WHERE signal = 'events' AND signal_name = 'tool_result' AND attr_path = 'tool_parameters';
DELETE FROM meta.column_registry WHERE signal = 'events' AND signal_name = 'tool_decision' AND attr_path = 'tool_parameters';
