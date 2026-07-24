-- Canonical definition for marts.dim_model.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name dim_model
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.dim_model AS
 WITH ids AS (
         SELECT metrics.model
           FROM raw.metrics
          WHERE (metrics.model IS NOT NULL)
        UNION
         SELECT events.model
           FROM raw.events
          WHERE (events.model IS NOT NULL)
        )
 SELECT model AS model_id,
        CASE
            WHEN (model ~~* '%opus%'::text) THEN 'opus'::text
            WHEN (model ~~* '%sonnet%'::text) THEN 'sonnet'::text
            WHEN (model ~~* '%haiku%'::text) THEN 'haiku'::text
            WHEN (model ~~* '%fable%'::text) THEN 'fable'::text
            ELSE 'other'::text
        END AS family,
    regexp_replace(regexp_replace(model, '\[1m\]$'::text, ''::text), '^claude-(opus|sonnet|haiku|fable)-'::text, ''::text) AS version,
    (model ~~ '%[1m]%'::text) AS is_long_context
   FROM ids;

CREATE UNIQUE INDEX dim_model_pk ON marts.dim_model USING btree (model_id);

GRANT SELECT ON marts.dim_model TO cc_otel_read;
