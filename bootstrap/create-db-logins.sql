-- Create or converge the DB LOGIN users that the sink (ingest) and Power BI (read)
-- connect as, then join each to the matching NOLOGIN group role from migration
-- ...170001. The orchestrator calls this only when authentication does not match
-- .env, so an already-correct rerun never rewrites the SCRAM password hashes.
--
-- Passwords are inherited from the process environment, never passed in the psql
-- argument list:
--
--   psql "$MIGRATION_DATABASE_URL" -v ON_ERROR_STOP=1 -f bootstrap/create-db-logins.sql

\set ON_ERROR_STOP on
\getenv ingest_pw CC_OTEL_INGEST_PASSWORD
\getenv read_pw CC_OTEL_READ_PASSWORD

SELECT format('CREATE ROLE cc_otel_ingest_user LOGIN PASSWORD %L', :'ingest_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cc_otel_ingest_user')
\gexec

SELECT format('CREATE ROLE cc_otel_read_user LOGIN PASSWORD %L', :'read_pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cc_otel_read_user')
\gexec

SELECT format('ALTER ROLE cc_otel_ingest_user PASSWORD %L', :'ingest_pw')
\gexec
SELECT format('ALTER ROLE cc_otel_read_user PASSWORD %L', :'read_pw')
\gexec

GRANT cc_otel_ingest TO cc_otel_ingest_user;
GRANT cc_otel_read   TO cc_otel_read_user;
