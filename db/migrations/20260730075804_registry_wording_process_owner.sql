-- migrate:up

-- process.owner (all three rows): the registry claimed the column is an account-sharing
-- control. #364 retired that reading — the attribute reaches only the Claude Code Desktop /
-- Cowork surface (the CLI never emits it), so it is structurally blind to 99.6% of records
-- and cannot control anything fleet-wide. It survives as an observation, named for the
-- finding it now feeds.
--
-- Hand-authored because spec_sync's registry diff is a set diff over the 10-field
-- RegistryRow — an in-place useful_for edit reads as a missing_row plus an orphan_row, and
-- generate_migration refuses orphans (#377).

UPDATE meta.column_registry
SET
    useful_for = 'owner_email_mismatch: a session whose process_owner disagrees with the '
    'local-part of an ITWorx user_email. An observation, not an account-sharing control '
    '— the CLI never emits process.owner, so 99.6% of records are blind to it (#364)'
WHERE attr_path = 'process.owner';

-- migrate:down

UPDATE meta.column_registry
SET
    useful_for = 'account sharing: a row whose process_owner disagrees with user_email is '
    'one person emitting under another person''s account'
WHERE attr_path = 'process.owner';
