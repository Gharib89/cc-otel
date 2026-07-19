-- Runtime-only staging for the POC -> interim backfill (#131, ADR-0006).
-- The mapped POC rows stream into these tables (COPY FROM STDIN); the filtered load
-- (load.sql) reads from here. This schema is created at run time and dropped by
-- backfill.sh at the end -- it is never a migration and never appears in schema.sql.
-- Shape is cloned from the live raw tables so column order / types match exactly.
CREATE SCHEMA IF NOT EXISTS backfill_stg;
CREATE TABLE backfill_stg.metrics (LIKE raw.metrics);
CREATE TABLE backfill_stg.events (LIKE raw.events);
