-- migrate:up

-- Seat-interval derivation (#293, parent #290, ADR-0009). One shared view over the ref
-- snapshot tables turns the accumulated roster drops into SCD2 seat intervals; three thin
-- marts project it. Routing all three through a view rather than stacking a daily mart on an
-- interval mart keeps marts.refresh_all()'s invariant intact — no mart reads another, so its
-- alphabetical catalog loop needs no dependency ordering.
--
-- History is derived on every refresh, never merged at load time. Ingestion is manual and
-- therefore unordered; derivation sorts by as-of at refresh time, so arrival order is
-- irrelevant and a late drop self-corrects (ADR-0009). It also makes the dating and revocation
-- policy a view-body edit plus a refresh when IS adds a status column (#291), rather than a
-- data migration over already-baked-in intervals.
--
-- Intervals are half-open: [valid_from, valid_to), valid_to NULL while the seat is open. A
-- tier change therefore closes the old interval exactly where the new one opens — no overlap,
-- no gap, and no seat-day counted twice.
--
-- These live in staging, alongside the views over raw, because staging is the transform layer
-- between the landing schemas and the marts. Like them they stay ungranted, feeding matviews
-- and the refresh job only; Power BI reads the marts schema (#19).
CREATE VIEW staging.stg_seat_interval AS
WITH drop_of_date AS (
    -- One observation point per as-of date. ref.roster_drop.as_of_date is deliberately not
    -- unique: a same-day corrected re-export is a legitimate second drop, and correcting means
    -- superseding, so the newest drop_id for a date wins.
    SELECT DISTINCT ON (as_of_date)
        drop_id,
        as_of_date
    FROM ref.roster_drop
    ORDER BY as_of_date ASC, drop_id DESC
),

drop_seq AS (
    SELECT
        as_of_date,
        LAG(as_of_date) OVER (ORDER BY as_of_date) AS prev_as_of,
        LEAD(as_of_date) OVER (ORDER BY as_of_date) AS next_as_of
    FROM drop_of_date
),

observation AS (
    -- Person grain. Landing is assignment grain, which permits a second concurrent
    -- subscription; the reporting grain asserts one active tier per person, so extra
    -- subscriptions collapse to the lowest sequence here and are reported as a dq_finding
    -- rather than silently multiplying seat-days.
    SELECT
        d.as_of_date,
        s.user_email,
        (ARRAY_AGG(s.seat_tier ORDER BY s.subscription_seq))[1] AS seat_tier,
        (ARRAY_AGG(s.anthropic_org_name ORDER BY s.subscription_seq))[1] AS anthropic_org_name,
        (ARRAY_AGG(s.assignment_date ORDER BY s.subscription_seq))[1] AS assignment_date
    FROM ref.seat_roster_snapshot AS s
    INNER JOIN drop_of_date AS d ON s.drop_id = d.drop_id
    GROUP BY d.as_of_date, s.user_email
),

sighting AS (
    SELECT
        o.as_of_date,
        o.user_email,
        o.seat_tier,
        o.anthropic_org_name,
        o.assignment_date,
        q.prev_as_of,
        q.next_as_of,
        LAG(o.as_of_date) OVER (PARTITION BY o.user_email ORDER BY o.as_of_date) AS prev_seen_on,
        LAG(o.seat_tier) OVER (PARTITION BY o.user_email ORDER BY o.as_of_date) AS prev_tier,
        LAG(o.anthropic_org_name)
            OVER (PARTITION BY o.user_email ORDER BY o.as_of_date) AS prev_org,
        LAG(o.assignment_date)
            OVER (PARTITION BY o.user_email ORDER BY o.as_of_date) AS prev_assignment_date
    FROM observation AS o
    INNER JOIN drop_seq AS q ON o.as_of_date = q.as_of_date
),

boundary AS (
    SELECT
        as_of_date,
        user_email,
        seat_tier,
        anthropic_org_name,
        assignment_date,
        next_as_of,
        -- A new interval starts when the seat reappears after an absence (its previous
        -- sighting is not the immediately preceding drop, which also covers a first-ever
        -- sighting) or when tier or organization moved.
        (
            prev_seen_on IS NULL
            OR prev_seen_on IS DISTINCT FROM prev_as_of
            OR seat_tier IS DISTINCT FROM prev_tier
            OR anthropic_org_name IS DISTINCT FROM prev_org
        ) AS starts_interval,
        -- Hybrid dating, self-detecting per row: source-dated whenever IS supplies an
        -- assignment date that is new relative to the person's previous sighting (a first
        -- grant, or a date that moved with a tier change), observation-dated otherwise. This
        -- needs no knowledge of whether IS overwrites the assignment date on upgrade, and
        -- starts producing exact dates by itself if IS's behaviour changes. One predicate,
        -- because the boundary date and the basis recorded for it must never disagree.
        (
            assignment_date IS NOT NULL
            AND (prev_seen_on IS NULL OR assignment_date IS DISTINCT FROM prev_assignment_date)
        ) AS is_source_dated
    FROM sighting
),

dated AS (
    SELECT
        as_of_date,
        user_email,
        seat_tier,
        anthropic_org_name,
        next_as_of,
        starts_interval,
        CASE WHEN is_source_dated THEN assignment_date ELSE as_of_date END AS valid_from,
        CASE
            WHEN is_source_dated THEN 'source-dated' ELSE 'observation-dated'
        END AS valid_from_basis
    FROM boundary
),

numbered AS (
    SELECT
        as_of_date,
        user_email,
        seat_tier,
        anthropic_org_name,
        next_as_of,
        valid_from,
        valid_from_basis,
        SUM(CASE WHEN starts_interval THEN 1 ELSE 0 END)
            OVER (PARTITION BY user_email ORDER BY as_of_date) AS interval_seq
    FROM dated
),

interval_run AS (
    -- Collapse the run of sightings that share an interval. The boundary row is the earliest
    -- one in the run, so ordering the aggregates by as-of picks its dating verdict.
    SELECT
        user_email,
        interval_seq,
        MIN(as_of_date) AS first_seen_on,
        MAX(as_of_date) AS last_seen_on,
        (ARRAY_AGG(seat_tier ORDER BY as_of_date))[1] AS seat_tier,
        (ARRAY_AGG(anthropic_org_name ORDER BY as_of_date))[1] AS anthropic_org_name,
        (ARRAY_AGG(valid_from ORDER BY as_of_date))[1] AS valid_from,
        (ARRAY_AGG(valid_from_basis ORDER BY as_of_date))[1] AS valid_from_basis,
        -- The drop following the last sighting: where the seat closed, if it vanished rather
        -- than changed tier.
        (ARRAY_AGG(next_as_of ORDER BY as_of_date DESC))[1] AS next_as_of_after_last_seen
    FROM numbered
    GROUP BY user_email, interval_seq
),

bounded AS (
    SELECT
        user_email,
        seat_tier,
        anthropic_org_name,
        valid_from,
        valid_from_basis,
        first_seen_on,
        last_seen_on,
        -- LEAST ignores NULLs: a tier change closes at the next interval's start, a
        -- disappearance at the as-of of the drop it vanished from, whichever comes first.
        -- Both NULL means the seat is still open. GREATEST clamps a backwards-dated boundary
        -- to a zero-length interval rather than a negative one.
        CASE
            WHEN LEAST(next_as_of_after_last_seen, next_valid_from) IS NULL THEN NULL
            ELSE GREATEST(valid_from, LEAST(next_as_of_after_last_seen, next_valid_from))
        END AS valid_to
    FROM (
        SELECT
            r.*,
            LEAD(r.valid_from)
                OVER (PARTITION BY r.user_email ORDER BY r.interval_seq) AS next_valid_from
        FROM interval_run AS r
    ) AS x
)

-- A zero-length interval carries no seat-day and no information: it is what remains when a
-- later drop supplies an assignment date that predates the observation-dated boundary the
-- earlier drop could only guess at. Dropping it also keeps valid_from unique per person.
SELECT
    user_email,
    seat_tier,
    anthropic_org_name,
    valid_from,
    valid_to,
    valid_from_basis,
    first_seen_on,
    last_seen_on
FROM bounded
WHERE valid_to IS NULL OR valid_to > valid_from;

-- One row per identity per day it emitted anything. The seat findings compare telemetry to
-- derived intervals through this view rather than through marts.dim_user: a mart reading a
-- mart is exactly the stacking the shared-view design eliminates.
CREATE VIEW staging.stg_telemetry_day AS
SELECT
    user_email,
    ts::date AS activity_date
FROM raw.metrics
WHERE user_email IS NOT NULL
UNION
SELECT
    user_email,
    event_time::date AS activity_date
FROM raw.events
WHERE user_email IS NOT NULL;

-- Activity days no seat interval covers, carrying the most recent close that precedes them.
-- Two findings partition this set — telemetry after a close (`closed_on` present, near-proof
-- the close was an export artefact) and an emitter that never had a seat (`closed_on` null) —
-- so it is derived once here rather than restated in each, where the two could drift and
-- start double-reporting or missing an activity day.
CREATE VIEW staging.stg_seat_uncovered_day AS
SELECT
    t.user_email,
    t.activity_date,
    (
        SELECT MAX(i.valid_to)
        FROM staging.stg_seat_interval AS i
        WHERE i.user_email = t.user_email AND i.valid_to <= t.activity_date
    ) AS closed_on
FROM staging.stg_telemetry_day AS t
WHERE NOT EXISTS (
    SELECT 1
    FROM staging.stg_seat_interval AS i
    WHERE
        i.user_email = t.user_email
        AND i.valid_from <= t.activity_date
        AND (i.valid_to IS NULL OR i.valid_to > t.activity_date)
);

-- migrate:down

DROP VIEW IF EXISTS staging.stg_seat_uncovered_day;
DROP VIEW IF EXISTS staging.stg_telemetry_day;
DROP VIEW IF EXISTS staging.stg_seat_interval;
