-- migrate:up

-- events/*/user.email: adopt the wording its metrics and resource twins already carry.
--
-- One fact described three ways: the events row said "(normalized)" while metrics/* and
-- resource/* said "(normalized lowercase/trim)". Since #368 the data dictionary names every
-- distinct meaning of a promoted column, so raw.events.user_email rendered the same meaning
-- twice ("events: ... / metrics, resource: ..."). Harmonizing collapses that cell to bare.
-- Hand-authored because spec_sync's registry diff is a set diff over the 10-field
-- RegistryRow -- an in-place description edit reads as a missing_row plus an orphan_row,
-- and generate_migration refuses orphans.

UPDATE meta.column_registry
SET description = 'Developer identity (normalized lowercase/trim).'
WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'user.email';

-- migrate:down

UPDATE meta.column_registry
SET description = 'Developer identity (normalized).'
WHERE signal = 'events' AND signal_name = '*' AND attr_path = 'user.email';
