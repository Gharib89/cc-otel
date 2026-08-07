-- migrate:up
-- spec_sync: promote_installer_stamp
-- noqa: disable=LT05,LT14

ALTER TABLE raw.metrics ADD COLUMN installer_stamp TEXT;
ALTER TABLE raw.metrics ADD COLUMN installer_stamp_on_disk TEXT;
ALTER TABLE raw.events ADD COLUMN installer_stamp TEXT;
ALTER TABLE raw.events ADD COLUMN installer_stamp_on_disk TEXT;
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes, kept_basis, basis_partner) VALUES ('resource', '*', 'installer.stamp', 'promoted', 'installer_stamp', 'TEXT', 'Installer stamp the emitting process started with: SHA256(wrapper + managed-settings + installer schema version).', 'fleet-config convergence: per seat, whether a re-push has reached the running process. A hash says same-or-different, never which of two is newer', '2026-08-06', 'promoted at first emission (#432); resource-only, so kind=derived reaches both raw tables. No reservoir history to replay (ADR-0017) - NULL before the re-push that first ships the attribute', NULL, NULL);
INSERT INTO meta.column_registry (signal, signal_name, attr_path, status, column_name, data_type, description, useful_for, decided_at, notes, kept_basis, basis_partner) VALUES ('resource', '*', 'installer.stamp_on_disk', 'promoted', 'installer_stamp_on_disk', 'TEXT', 'Installer stamp the machine''s managed-settings.json carried at emit time.', 'stale-session detection: a record whose installer_stamp differs from installer_stamp_on_disk is running a config the disk has already replaced', '2026-08-06', 'statusline-wrapper only (#432): the wrapper reads managed-settings.json once per process, which is once per statusline refresh, so it is the one emitter that sees process config and disk config at once. NULL on every natively-exported record', NULL, NULL);

-- migrate:down

DELETE FROM meta.column_registry WHERE signal = 'resource' AND signal_name = '*' AND attr_path = 'installer.stamp_on_disk';
DELETE FROM meta.column_registry WHERE signal = 'resource' AND signal_name = '*' AND attr_path = 'installer.stamp';
ALTER TABLE raw.events DROP COLUMN installer_stamp_on_disk;
ALTER TABLE raw.events DROP COLUMN installer_stamp;
ALTER TABLE raw.metrics DROP COLUMN installer_stamp_on_disk;
ALTER TABLE raw.metrics DROP COLUMN installer_stamp;
