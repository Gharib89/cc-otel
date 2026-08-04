-- migrate:up

-- Exact-date a Claude seat closure from IS's revocation date (#419, parent #290).
--
-- #291 anticipated a person-level status column that would let the derivation stop guessing
-- closure dates. What IS actually delivered is narrower, so this replays only the case the data
-- supports: a *per-subscription* revocation event exact-dates a closure when, on the same
-- person's rows in the same drop,
--
--   1. some `revoked_subscription_raw` is a Claude subscription, and
--   2. no `subscription_raw` is -- the person no longer holds any Claude subscription, and
--   3. the interval being closed was itself a Claude seat.
--
-- Everything else stays observation-dated. A Github Copilot revocation is not a seat event; a
-- revoked Claude subscription alongside a still-held one is a tier change, which the interval
-- logic already dates from the new interval's start; and revocation-by-absence is untouched,
-- because an absent person has no row in that drop and therefore no revocation record either
-- (four people vanished from the 2026-08-02 drop with no revocation of any kind).
--
-- The Claude test reads the *raw* subscription values, not `seat_tier`: `normalize_tier` strips
-- the `Claude ` prefix and passes other products through verbatim, so a normalized tier cannot
-- say which product it came from.
--
-- Consequence, intended: the intervals of one person may now have a *gap*. A person whose
-- Claude seat was revoked on the 28th and who still appears in the next drop holding Github
-- Copilot has no seat over the days between -- which is the truth, and what the observation-
-- dated close could not express. A tier change between two Claude tiers still closes exactly
-- where the next interval opens, so no seat-day is counted twice.
--
-- Same output columns as before, so `CREATE OR REPLACE` keeps the three seat marts and the two
-- dependent staging views attached; the down section restores the body at git HEAD.
CREATE OR REPLACE VIEW staging.stg_seat_interval AS
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
    --
    -- The two revocation aggregates are per person per drop, not per sequence, because the
    -- question they answer is "does this person still hold a Claude subscription" -- which
    -- spans the sequences. MAX takes the later date when both sequences were revoked: the
    -- Claude seat ended with the last of them.
    SELECT
        d.as_of_date,
        s.user_email,
        (ARRAY_AGG(s.seat_tier ORDER BY s.subscription_seq))[1] AS seat_tier,
        (ARRAY_AGG(s.anthropic_org_name ORDER BY s.subscription_seq))[1] AS anthropic_org_name,
        (ARRAY_AGG(s.assignment_date ORDER BY s.subscription_seq))[1] AS assignment_date,
        BOOL_OR(COALESCE(s.subscription_raw LIKE 'Claude %', FALSE)) AS holds_claude,
        MAX(CASE WHEN s.revoked_subscription_raw LIKE 'Claude %' THEN s.revoke_date END)
            AS revoked_claude_on
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
        o.holds_claude,
        q.prev_as_of,
        q.next_as_of,
        -- Conditions 1 and 2 together: a Claude revocation the person's own rows do not
        -- contradict. NULL whenever either fails, which is what makes every other shape of
        -- revocation inert to the closure logic below.
        CASE WHEN NOT o.holds_claude THEN o.revoked_claude_on END AS claude_closed_on,
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
        holds_claude,
        claude_closed_on,
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
        holds_claude,
        claude_closed_on,
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
        holds_claude,
        claude_closed_on,
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
        -- Tier is constant within an interval, so the boundary row settles condition 3: was
        -- this a Claude seat at all. `Github Copilot` is stored as a seat_tier today, and a
        -- Claude revocation must not exact-date the close of a non-Claude interval.
        (ARRAY_AGG(holds_claude ORDER BY as_of_date))[1] AS is_claude_seat,
        -- The qualifying revocation seen at the interval's *own* start. LEAD below moves it to
        -- the interval it actually closes -- the preceding one, whose seat it ended.
        (ARRAY_AGG(claude_closed_on ORDER BY as_of_date))[1] AS claude_closed_on,
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
        -- A qualifying revocation dates the close exactly; everything else falls through to
        -- the observation-dated rule. LEAST against next_valid_from clamps a revoke date that
        -- lands after the next interval already opened: marts.fact_seat_day is uniquely
        -- indexed on (date_day, user_email), so an overlap would fail its refresh outright,
        -- and next_valid_from is always present here -- next_claude_closed_on comes from the
        -- next interval's own boundary row.
        --
        -- LEAST ignores NULLs: a tier change closes at the next interval's start, a
        -- disappearance at the as-of of the drop it vanished from, whichever comes first.
        -- Both NULL means the seat is still open. GREATEST clamps a backwards-dated boundary
        -- to a zero-length interval rather than a negative one.
        CASE
            WHEN is_claude_seat AND next_claude_closed_on IS NOT NULL
                THEN GREATEST(valid_from, LEAST(next_claude_closed_on, next_valid_from))
            WHEN LEAST(next_as_of_after_last_seen, next_valid_from) IS NULL THEN NULL
            ELSE GREATEST(valid_from, LEAST(next_as_of_after_last_seen, next_valid_from))
        END AS valid_to
    FROM (
        SELECT
            r.*,
            LEAD(r.valid_from)
                OVER (PARTITION BY r.user_email ORDER BY r.interval_seq) AS next_valid_from,
            LEAD(r.claude_closed_on)
                OVER (PARTITION BY r.user_email ORDER BY r.interval_seq) AS next_claude_closed_on
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

-- migrate:down

CREATE OR REPLACE VIEW staging.stg_seat_interval AS
WITH drop_of_date AS (
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
        (
            prev_seen_on IS NULL
            OR prev_seen_on IS DISTINCT FROM prev_as_of
            OR seat_tier IS DISTINCT FROM prev_tier
            OR anthropic_org_name IS DISTINCT FROM prev_org
        ) AS starts_interval,
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
    SELECT
        user_email,
        interval_seq,
        MIN(as_of_date) AS first_seen_on,
        MAX(as_of_date) AS last_seen_on,
        (ARRAY_AGG(seat_tier ORDER BY as_of_date))[1] AS seat_tier,
        (ARRAY_AGG(anthropic_org_name ORDER BY as_of_date))[1] AS anthropic_org_name,
        (ARRAY_AGG(valid_from ORDER BY as_of_date))[1] AS valid_from,
        (ARRAY_AGG(valid_from_basis ORDER BY as_of_date))[1] AS valid_from_basis,
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
