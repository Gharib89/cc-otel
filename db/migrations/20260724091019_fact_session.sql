-- migrate:up
-- matview_sync: fact_session
-- noqa: disable=all

DROP MATERIALIZED VIEW marts.fact_session;

-- Canonical definition for marts.fact_session.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name fact_session
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.fact_session AS
 WITH sig AS (
         SELECT metrics.session_id,
            metrics.user_email,
            metrics.cc_version,
            metrics.ts AS t
           FROM raw.metrics
          WHERE (metrics.session_id IS NOT NULL)
        UNION ALL
         SELECT events.session_id,
            events.user_email,
            events.cc_version,
            events.event_time
           FROM raw.events
          WHERE (events.session_id IS NOT NULL)
        ), start_type AS (
         SELECT metrics.session_id,
            (array_agg(metrics.start_type ORDER BY metrics.ts DESC) FILTER (WHERE (metrics.start_type IS NOT NULL)))[1] AS start_type
           FROM raw.metrics
          WHERE ((metrics.metric_name = 'claude_code.session.count'::text) AND (metrics.session_id IS NOT NULL))
          GROUP BY metrics.session_id
        )
 SELECT sig.session_id,
    st.start_type,
    marts.email_bucket((array_agg(sig.user_email ORDER BY sig.t) FILTER (WHERE (sig.user_email IS NOT NULL)))[1]) AS user_email,
    min(sig.t) AS started_at,
    (array_agg(sig.cc_version ORDER BY sig.t DESC) FILTER (WHERE (sig.cc_version IS NOT NULL)))[1] AS cc_version,
    (EXTRACT(epoch FROM (max(sig.t) - min(sig.t))))::bigint AS duration_s
   FROM (sig
     LEFT JOIN start_type st ON ((sig.session_id = st.session_id)))
  GROUP BY sig.session_id, st.start_type;

CREATE UNIQUE INDEX fact_session_pk ON marts.fact_session USING btree (session_id);

GRANT SELECT ON marts.fact_session TO cc_otel_read;

-- migrate:down

DROP MATERIALIZED VIEW marts.fact_session;

-- Canonical definition for marts.fact_session.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name fact_session
-- Verified against pg_matviews.definition by --check (CI + local gate).
CREATE MATERIALIZED VIEW marts.fact_session AS
 WITH sig AS (
         SELECT metrics.session_id,
            metrics.user_email,
            metrics.cc_version,
            metrics.ts AS t
           FROM raw.metrics
          WHERE (metrics.session_id IS NOT NULL)
        UNION ALL
         SELECT events.session_id,
            events.user_email,
            events.cc_version,
            events.event_time
           FROM raw.events
          WHERE (events.session_id IS NOT NULL)
        ), start_type AS (
         SELECT metrics.session_id,
            (array_agg(metrics.start_type ORDER BY metrics.ts DESC) FILTER (WHERE (metrics.start_type IS NOT NULL)))[1] AS start_type
           FROM raw.metrics
          WHERE ((metrics.metric_name = 'claude_code.session.count'::text) AND (metrics.session_id IS NOT NULL))
          GROUP BY metrics.session_id
        )
 SELECT sig.session_id,
    st.start_type,
    COALESCE((array_agg(sig.user_email ORDER BY sig.t) FILTER (WHERE (sig.user_email IS NOT NULL)))[1], '(unknown)'::text) AS user_email,
    min(sig.t) AS started_at,
    (array_agg(sig.cc_version ORDER BY sig.t DESC) FILTER (WHERE (sig.cc_version IS NOT NULL)))[1] AS cc_version,
    (EXTRACT(epoch FROM (max(sig.t) - min(sig.t))))::bigint AS duration_s
   FROM (sig
     LEFT JOIN start_type st ON ((sig.session_id = st.session_id)))
  GROUP BY sig.session_id, st.start_type;

CREATE UNIQUE INDEX fact_session_pk ON marts.fact_session USING btree (session_id);

GRANT SELECT ON marts.fact_session TO cc_otel_read;
