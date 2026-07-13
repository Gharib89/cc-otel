-- migrate:up

-- Schema-v2 namespaces. `raw` holds the sink-owned base tables (ADR-0005: promoted
-- typed columns only, no attrs/resource JSONB); `meta` holds the column registry and
-- the ingest idempotency ledger. `staging` (views) and `marts` (matviews) arrive in
-- later tickets (#19/#20) and create their own schemas.
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS meta;

-- Group roles only (NOLOGIN). Credentials stay out of migrations (#11 no-Key-Vault
-- secrets, #23 Bicep): LOGIN users + passwords are provisioned out of band, then joined
-- with `GRANT <group> TO <login>`.
--   cc_otel_ingest — the sink write path.
--   cc_otel_read   — read consumers (data-dictionary tooling now; marts SELECT added in #20).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cc_otel_ingest') THEN
    CREATE ROLE cc_otel_ingest NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cc_otel_read') THEN
    CREATE ROLE cc_otel_read NOLOGIN;
  END IF;
END
$$;

GRANT USAGE ON SCHEMA raw, meta TO cc_otel_ingest, cc_otel_read;

-- migrate:down

DROP SCHEMA IF EXISTS meta CASCADE;
DROP SCHEMA IF EXISTS raw CASCADE;

-- Clear any residual default-privilege / grant entries before dropping the roles.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cc_otel_ingest') THEN
    EXECUTE 'DROP OWNED BY cc_otel_ingest';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cc_otel_read') THEN
    EXECUTE 'DROP OWNED BY cc_otel_read';
  END IF;
END
$$;

DROP ROLE IF EXISTS cc_otel_ingest;
DROP ROLE IF EXISTS cc_otel_read;
