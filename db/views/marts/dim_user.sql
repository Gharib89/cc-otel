-- Canonical definition for marts.dim_user.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name dim_user
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.dim_user AS
 WITH seen AS (
         SELECT metrics.user_email,
            metrics.user_account_id,
            metrics.organization_id,
            metrics.cc_version,
            metrics.ts AS seen_at
           FROM raw.metrics
        UNION ALL
         SELECT events.user_email,
            events.user_account_id,
            events.organization_id,
            events.cc_version,
            events.event_time
           FROM raw.events
        )
 SELECT marts.email_bucket(user_email) AS user_email,
    (user_email IS NULL) AS is_unknown,
    min(seen_at) AS first_seen,
    max(seen_at) AS last_seen,
    (array_agg(user_account_id) FILTER (WHERE (user_account_id IS NOT NULL)))[1] AS user_account_id,
    (array_agg(organization_id) FILTER (WHERE (organization_id IS NOT NULL)))[1] AS organization_id,
    (array_agg(cc_version ORDER BY seen_at DESC) FILTER (WHERE (cc_version IS NOT NULL)))[1] AS last_cc_version
   FROM seen
  GROUP BY (marts.email_bucket(user_email)), (user_email IS NULL);

CREATE UNIQUE INDEX dim_user_pk ON marts.dim_user USING btree (user_email);

GRANT SELECT ON marts.dim_user TO cc_otel_read;
