-- migrate:up
-- spec_sync: registry_truth
-- noqa: disable=LT05,LT14

ALTER TABLE raw.metrics ADD COLUMN process_owner TEXT;
ALTER TABLE raw.events ADD COLUMN process_owner TEXT;
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('events', '*', 'process.owner', 'promoted', 'process_owner', 'TEXT', 'OS account the Claude Code process runs under (e.g. a Windows username).', 'account sharing: a row whose process_owner disagrees with user_email is one person emitting under another person''s account', '2026-07-28', 'promoted, not denied: discloses strictly less than the promoted user.email (#353)');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('events', 'compaction', 'duration_ms', 'promoted', 'duration_ms', 'BIGINT', 'Compaction duration.', NULL, '2026-07-28', 'already stored: 56 rows 100% populated before the row existed (#353)');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('events', 'mcp_server_connection', 'duration_ms', 'promoted', 'duration_ms', 'BIGINT', 'MCP server connection duration.', NULL, '2026-07-28', 'already stored: 1,164 rows 100% populated before the row existed (#353)');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('metrics', '*', 'process.owner', 'promoted', 'process_owner', 'TEXT', 'OS account the Claude Code process runs under (e.g. a Windows username).', 'account sharing: a row whose process_owner disagrees with user_email is one person emitting under another person''s account', '2026-07-28', 'promoted, not denied: discloses strictly less than the promoted user.email (#353)');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('resource', '*', 'process.owner', 'promoted', 'process_owner', 'TEXT', 'OS account the Claude Code process runs under (e.g. a Windows username).', 'account sharing: a row whose process_owner disagrees with user_email is one person emitting under another person''s account', '2026-07-28', 'promoted, not denied: discloses strictly less than the promoted user.email (#353)');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('resource', '*', 'session.id', 'promoted', 'session_id', 'UUID', 'Claude Code session UUID.', 'session facts', '2026-07-28', 'ADR-0003 wrapper contract: identity on the resource block');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('resource', '*', 'user.account_id', 'promoted', 'user_account_id', 'TEXT', 'Anthropic tagged account id.', NULL, '2026-07-28', 'ADR-0003 wrapper contract; coalesced into user_account_id under user.account_uuid');
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes) VALUES ('resource', '*', 'user.email', 'promoted', 'user_email', 'TEXT', 'Developer identity (normalized lowercase/trim).', 'dim_user join', '2026-07-28', 'ADR-0003 wrapper contract: identity on the resource block');

-- migrate:down

DELETE FROM meta.column_registry WHERE signal = 'resource' AND signal_name = '*' AND attr_path = 'user.email';
DELETE FROM meta.column_registry WHERE signal = 'resource' AND signal_name = '*' AND attr_path = 'user.account_id';
DELETE FROM meta.column_registry WHERE signal = 'resource' AND signal_name = '*' AND attr_path = 'session.id';
DELETE FROM meta.column_registry WHERE signal = 'resource' AND signal_name = '*' AND attr_path = 'process.owner';
DELETE FROM meta.column_registry WHERE signal = 'metrics' AND signal_name = '*' AND attr_path = 'process.owner';
DELETE FROM meta.column_registry WHERE signal = 'events' AND signal_name = 'mcp_server_connection' AND attr_path = 'duration_ms';
DELETE FROM meta.column_registry WHERE signal = 'events' AND signal_name = 'compaction' AND attr_path = 'duration_ms';
DELETE FROM meta.column_registry WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'process.owner';
ALTER TABLE raw.events DROP COLUMN process_owner;
ALTER TABLE raw.metrics DROP COLUMN process_owner;
