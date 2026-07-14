-- Create the DB LOGIN users that the sink (ingest) and Power BI (read) connect as,
-- and join each to the matching NOLOGIN group role from migration ...170001.
--
-- Gate G1 (issue #52): logins + passwords are provisioned out of band, never in a
-- dbmate migration (#11 no Key Vault). Run as the Postgres admin. Passwords are
-- supplied as psql variables, never hardcoded:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -v ingest_pw="$CC_OTEL_INGEST_PASSWORD" -v read_pw="$CC_OTEL_READ_PASSWORD" \
--     -f bootstrap/create-db-logins.sql
--
-- Idempotent: each role is created only when absent (re-run no-ops); GRANT of an
-- already-held role is a no-op. To rotate a password, ALTER ROLE by hand.

\set ON_ERROR_STOP on

SELECT format('CREATE ROLE cc_otel_ingest_user LOGIN PASSWORD %L', :'ingest_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cc_otel_ingest_user')
\gexec

SELECT format('CREATE ROLE cc_otel_read_user LOGIN PASSWORD %L', :'read_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cc_otel_read_user')
\gexec

GRANT cc_otel_ingest TO cc_otel_ingest_user;
GRANT cc_otel_read   TO cc_otel_read_user;
