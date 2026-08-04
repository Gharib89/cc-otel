-- migrate:up
-- matview_sync: dim_seat
-- noqa: disable=all

DROP MATERIALIZED VIEW marts.dim_seat;

-- Canonical definition for marts.dim_seat.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name dim_seat
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.dim_seat AS
 SELECT user_email,
    seat_tier,
    anthropic_org_name,
    valid_from,
    valid_to,
    valid_from_basis,
    valid_to_basis
   FROM staging.stg_seat_interval;

CREATE UNIQUE INDEX dim_seat_pk ON marts.dim_seat USING btree (user_email, valid_from);

GRANT SELECT ON marts.dim_seat TO cc_otel_read;

-- migrate:down

DROP MATERIALIZED VIEW marts.dim_seat;

-- Canonical definition for marts.dim_seat.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name dim_seat
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.dim_seat AS
 SELECT user_email,
    seat_tier,
    anthropic_org_name,
    valid_from,
    valid_to,
    valid_from_basis
   FROM staging.stg_seat_interval;

CREATE UNIQUE INDEX dim_seat_pk ON marts.dim_seat USING btree (user_email, valid_from);

GRANT SELECT ON marts.dim_seat TO cc_otel_read;
