-- migrate:up

-- The current cycle's DQ findings (#374). marts.dq_finding is an append-only detection
-- log: refresh_all() re-inserts a row for every still-true condition on every hourly
-- cycle, so a row is a *detection*, not a finding, and the row count is
-- cycles x conditions (3,296 rows carrying ~20 conditions when this landed, growing
-- ~150 rows/day). Every consumer that wants "what is wrong now" needs the latest cycle,
-- and reading the table directly answers a different question — one that already misled
-- a ticket (#364 cited a row count as a count of offending session-days). ADR-0019.
--
-- refresh_all() is a FUNCTION with no COMMIT, so it runs in one transaction and
-- detected_at (DEFAULT now(), i.e. transaction time) is identical across every row of a
-- cycle. That makes MAX(detected_at) an exact cycle key with no extra column — contrast
-- mart_refresh_log, which deliberately uses clock_timestamp() to time each matview.
--
-- A plain view, not a matview: it reads ~20 rows off dq_finding_detected_idx, so there is
-- nothing to precompute, and a matview would need a refresh_all() slot and would go stale
-- between cycles — the one failure mode this view exists to prevent.
CREATE VIEW marts.dq_finding_current AS
SELECT
    f.id,
    f.finding_type,
    f.detected_at,
    f.row_count,
    f.details
FROM marts.dq_finding AS f
WHERE f.detected_at = (SELECT MAX(latest.detected_at) FROM marts.dq_finding AS latest);

-- ALTER DEFAULT PRIVILEGES in grant_marts_read already covers plain views created by the
-- migration role; stated explicitly anyway, matching the per-object grants the matview
-- migrations carry (default privileges do not reach materialized views, so the schema has
-- no blanket grant that covers every marts object).
GRANT SELECT ON marts.dq_finding_current TO cc_otel_read;

-- migrate:down

DROP VIEW IF EXISTS marts.dq_finding_current;
