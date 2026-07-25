-- migrate:up
-- matview_sync: dim_seat_current
-- noqa: disable=all

-- Canonical definition for marts.dim_seat_current.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name dim_seat_current
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.dim_seat_current AS
 SELECT user_email,
    seat_tier,
    anthropic_org_name,
    valid_from
   FROM staging.stg_seat_interval
  WHERE (valid_to IS NULL);

CREATE UNIQUE INDEX dim_seat_current_pk ON marts.dim_seat_current USING btree (user_email);

GRANT SELECT ON marts.dim_seat_current TO cc_otel_read;

-- migrate:down

DROP MATERIALIZED VIEW IF EXISTS marts.dim_seat_current;
