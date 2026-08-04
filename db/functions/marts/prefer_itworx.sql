-- Canonical definition for marts.prefer_itworx.
-- Source of truth for the function body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name prefer_itworx
-- Verified against pg_get_functiondef() by --check (CI + local gate).
CREATE OR REPLACE FUNCTION marts.prefer_itworx(a text, b text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
BEGIN ATOMIC
 SELECT
         CASE
             WHEN (a ~~ '%@itworx.com'::text) THEN a
             WHEN (b ~~ '%@itworx.com'::text) THEN b
             ELSE COALESCE(a, b)
         END AS "coalesce";
END;
