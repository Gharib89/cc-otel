-- migrate:up
-- matview_sync: seat_config_convergence
-- noqa: disable=all

-- Canonical definition for marts.seat_config_convergence.
-- Source of truth for the view body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name seat_config_convergence
-- Verified against pg_views.definition by --check (CI + local gate).
CREATE OR REPLACE VIEW marts.seat_config_convergence AS
 WITH stamped AS (
         SELECT m.user_email,
            m.ts AS seen_at,
            m.installer_stamp,
            m.installer_stamp_on_disk
           FROM raw.metrics m
        UNION ALL
         SELECT e.user_email,
            e.event_time,
            e.installer_stamp,
            e.installer_stamp_on_disk
           FROM raw.events e
        ), per_seat AS (
         SELECT marts.email_bucket(s.user_email) AS user_email,
            (s.user_email IS NULL) AS is_unknown,
            max(s.seen_at) AS last_seen,
            (array_agg(s.installer_stamp ORDER BY s.seen_at DESC) FILTER (WHERE (s.installer_stamp IS NOT NULL)))[1] AS installer_stamp,
            max(s.seen_at) FILTER (WHERE (s.installer_stamp IS NOT NULL)) AS stamp_seen_at,
            (array_agg(s.installer_stamp_on_disk ORDER BY s.seen_at DESC) FILTER (WHERE (s.installer_stamp_on_disk IS NOT NULL)))[1] AS installer_stamp_on_disk,
            max(s.seen_at) FILTER (WHERE (s.installer_stamp_on_disk IS NOT NULL)) AS disk_stamp_seen_at
           FROM stamped s
          GROUP BY (marts.email_bucket(s.user_email)), (s.user_email IS NULL)
        )
 SELECT user_email,
    last_seen,
    (last_seen)::date AS last_seen_date,
    installer_stamp,
    stamp_seen_at,
    installer_stamp_on_disk,
    disk_stamp_seen_at,
    (installer_stamp = installer_stamp_on_disk) AS is_converged,
    is_unknown
   FROM per_seat;

GRANT SELECT ON marts.seat_config_convergence TO cc_otel_read;

-- migrate:down

-- Canonical definition for marts.seat_config_convergence.
-- Source of truth for the view body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name seat_config_convergence
-- Verified against pg_views.definition by --check (CI + local gate).
CREATE OR REPLACE VIEW marts.seat_config_convergence AS
 WITH stamped AS (
         SELECT m.user_email,
            m.ts AS seen_at,
            m.installer_stamp,
            m.installer_stamp_on_disk
           FROM raw.metrics m
        UNION ALL
         SELECT e.user_email,
            e.event_time,
            e.installer_stamp,
            e.installer_stamp_on_disk
           FROM raw.events e
        ), per_seat AS (
         SELECT marts.email_bucket(s.user_email) AS user_email,
            max(s.seen_at) AS last_seen,
            (array_agg(s.installer_stamp ORDER BY s.seen_at DESC) FILTER (WHERE (s.installer_stamp IS NOT NULL)))[1] AS installer_stamp,
            max(s.seen_at) FILTER (WHERE (s.installer_stamp IS NOT NULL)) AS stamp_seen_at,
            (array_agg(s.installer_stamp_on_disk ORDER BY s.seen_at DESC) FILTER (WHERE (s.installer_stamp_on_disk IS NOT NULL)))[1] AS installer_stamp_on_disk,
            max(s.seen_at) FILTER (WHERE (s.installer_stamp_on_disk IS NOT NULL)) AS disk_stamp_seen_at
           FROM stamped s
          GROUP BY (marts.email_bucket(s.user_email))
        )
 SELECT user_email,
    last_seen,
    (last_seen)::date AS last_seen_date,
    installer_stamp,
    stamp_seen_at,
    installer_stamp_on_disk,
    disk_stamp_seen_at,
    (installer_stamp = installer_stamp_on_disk) AS is_converged
   FROM per_seat;

GRANT SELECT ON marts.seat_config_convergence TO cc_otel_read;
