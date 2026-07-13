-- migrate:up

-- Marts operational tables (#19). The marts schema itself is created here — the
-- first marts migration — and holds the matviews (later migrations) plus these two
-- ops tables.
CREATE SCHEMA IF NOT EXISTS marts;

-- Every hourly pg_cron refresh writes one row per matview: freshness signal for the
-- report's data-freshness tile (#7) and the refresh-duration trend (#15). Trimmed to
-- 1 year by pg_cron (see the refresh migration) — a year fully answers that trend.
CREATE TABLE marts.mart_refresh_log (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    mart TEXT NOT NULL,                             -- matview refreshed
    started TIMESTAMPTZ NOT NULL,
    finished TIMESTAMPTZ,
    row_count BIGINT
);

CREATE INDEX mart_refresh_log_started_idx ON marts.mart_refresh_log (started DESC);

-- Data-quality findings — provenance for "why does March look weird" (#15), feeding
-- the Log Analytics alert path. Untrimmed: a finding's useful life matches the data it
-- describes. finding_type is open-ended (cumulative_value_kind, unknown_email, …) — no
-- CHECK enum so new types don't need a migration.
CREATE TABLE marts.dq_finding (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    finding_type TEXT NOT NULL,
    detected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    row_count BIGINT,
    details JSONB
);

CREATE INDEX dq_finding_detected_idx ON marts.dq_finding (detected_at DESC);

-- Reader grants for the whole marts schema (these tables + the matviews) live in the
-- grant_marts_read migration.

-- migrate:down

DROP TABLE IF EXISTS marts.dq_finding;
DROP TABLE IF EXISTS marts.mart_refresh_log;
DROP SCHEMA IF EXISTS marts;
