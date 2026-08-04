-- Canonical definition for marts.email_bucket.
-- Source of truth for the function body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name email_bucket
-- Verified against pg_get_functiondef() by --check (CI + local gate).
CREATE OR REPLACE FUNCTION marts.email_bucket(email text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
BEGIN ATOMIC
 SELECT COALESCE(email, '(unknown)'::text) AS "coalesce";
END;
