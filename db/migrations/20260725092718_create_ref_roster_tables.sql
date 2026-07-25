-- migrate:up

-- Reference schema (#292, parent #290): externally-sourced data that is not telemetry.
-- `raw` stays telemetry-only — the existing definition of raw tables as telemetry archive
-- and drill source depends on it. The roster is the first feed of this class; an
-- install-coverage feed would be the second, so the boundary is reused, not roster-specific.
-- Not granted to `cc_otel_read`: Power BI reads marts only (#19), and the roster reaches it
-- through the seat marts of #293.
CREATE SCHEMA IF NOT EXISTS ref;

-- One row per ingested roster file. IS emails the roster roughly every two weeks as a manual,
-- therefore irregular, process; the file carries no export timestamp, so `as_of_date` is
-- supplied by the operator and validated against what the data can prove (tools/roster_load.py).
-- `file_sha256` is the idempotency key: re-ingesting byte-identical content is refused.
-- `as_of_date` is deliberately NOT unique — a same-day corrected re-export is a legitimate
-- second drop, admitted only through the loader's explicit override.
CREATE TABLE ref.roster_drop (
    drop_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    as_of_date DATE NOT NULL,
    source_filename TEXT NOT NULL,
    file_sha256 TEXT NOT NULL UNIQUE,
    row_count INTEGER NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ingested_by TEXT NOT NULL,
    notes TEXT
);

CREATE INDEX roster_drop_as_of_idx ON ref.roster_drop (as_of_date DESC);

-- Immutable observations at assignment grain — one row per person per subscription, keyed by
-- drop. Assignment grain, not person grain, because IS's numerically suffixed
-- `subscription_1` / `assignment_date_1` columns signal their export tool can emit a second
-- subscription per person; unpivoting at ingest turns that from a migration into a data event.
--
-- Every column IS sends lands verbatim, and any header the loader does not map is captured
-- into `extra`, so a new IS column (the status / revocation date requested in #291) is retained
-- from the moment it first appears rather than discarded until we code for it. `seat_tier` is
-- the normalized form ('Claude Standard' -> 'Standard') matching the semantic model's
-- vocabulary; `subscription_raw` keeps what IS actually sent.
--
-- Snapshots are never updated in normal operation. Deleting one bad drop and re-deriving is
-- the sanctioned repair (ON DELETE CASCADE), and it suffices because seat history is derived
-- from the accumulated observations (#293), never merged into a dimension at load time.
CREATE TABLE ref.seat_roster_snapshot (
    drop_id BIGINT NOT NULL REFERENCES ref.roster_drop (drop_id) ON DELETE CASCADE,
    user_email TEXT NOT NULL,
    subscription_seq SMALLINT NOT NULL,
    subscription_raw TEXT,
    seat_tier TEXT,
    assignment_date DATE,
    anthropic_org_name TEXT,
    person_name TEXT,
    manager_name TEXT,
    department TEXT,
    cost_center TEXT,
    extra JSONB NOT NULL DEFAULT '{}'::JSONB,
    PRIMARY KEY (drop_id, user_email, subscription_seq)
);

-- migrate:down

DROP TABLE IF EXISTS ref.seat_roster_snapshot;
DROP TABLE IF EXISTS ref.roster_drop;
DROP SCHEMA IF EXISTS ref;
