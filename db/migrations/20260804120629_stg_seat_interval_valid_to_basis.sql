-- migrate:up

-- Record the basis for a seat interval's close, not just its opening (#421, parent #290,
-- deferred out of #419 / ADR-0024's *Considered options*).
--
-- `valid_from_basis` has said since #291 whether an interval's opening was source-dated or
-- observation-dated, and the `seat_boundary_basis` dq gauge reports the observation-dated share
-- of openings. Closings had no counterpart, so half the timeline's inferred share was not
-- measurable at all. Since ADR-0024 a close can be dated three ways, and they carry very
-- different confidence:
--
--   revoke-dated      IS supplied the date outright (ADR-0024's three-condition rule). Exact.
--   succession-dated  the close lands where the person's next interval opens -- a tier or
--                     organization change. As exact as that opening's own basis.
--   observation-dated the seat vanished from a drop and closed at that drop's as-of. Inferred;
--                     worst-case error is the drop cadence (~1 week, ADR-0009).
--
-- NULL means the interval is still open, so the column also distinguishes "no close yet" from
-- "closed, basis unknown" -- there is no unknown.
--
-- ADR-0024's overlap clamp is expressed here as a *branch* rather than the LEAST() it used to
-- be, so the basis always names the input that actually produced the date: a revoke date
-- landing after the next interval opened yields that opening, which is a succession, not a
-- revocation. Same reasoning as `is_source_dated` on the opening side -- one predicate chain,
-- because the boundary date and the basis recorded for it must never disagree. `valid_to` is
-- therefore derived *from* `valid_to_basis` rather than alongside it: only one of the two is
-- independently computed, so they cannot drift.
--
-- The dates produced are identical to the previous derivation, branch for branch; only the new
-- output column is added. `dim_seat` gains the column in the following migration, where it sits
-- next to `valid_from_basis`; a matview is rebuilt outright, so it is free to order its columns
-- for readers. Here it must be appended *last*: CREATE OR REPLACE VIEW can only add trailing
-- columns, and dropping the view instead would cascade through `stg_seat_uncovered_day` and the
-- three seat marts. `dim_seat_current` is unaffected either way -- it holds only open intervals,
-- where the basis is NULL by construction.
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

successor AS (
    SELECT
        r.*,
        LEAD(r.valid_from)
            OVER (PARTITION BY r.user_email ORDER BY r.interval_seq) AS next_valid_from,
        LEAD(r.claude_closed_on)
            OVER (PARTITION BY r.user_email ORDER BY r.interval_seq) AS next_claude_closed_on
    FROM interval_run AS r
),

closing AS (
    -- Which of the three candidate dates closes this interval, ordered by confidence. The date
    -- below is selected *by* this verdict, so a branch unreachable here contributes no date
    -- either -- that is what keeps the two from disagreeing.
    SELECT
        s.*,
        CASE
            -- ADR-0024's rule. Conditions 1 and 2 are already folded into claude_closed_on;
            -- is_claude_seat is condition 3. The trailing comparison is ADR-0024's overlap
            -- clamp: a revoke date landing after the next interval opened does not win, and
            -- must not be reported as though it had. next_valid_from is never NULL when
            -- next_claude_closed_on is not -- both come from the next interval's boundary row
            -- -- but guarding it keeps date and basis in lockstep unconditionally.
            WHEN
                s.is_claude_seat
                AND s.next_claude_closed_on IS NOT NULL
                AND (
                    s.next_valid_from IS NULL
                    OR s.next_claude_closed_on <= s.next_valid_from
                )
                THEN 'revoke-dated'
            -- The next interval's own opening: a tier or organization change. It wins a tie
            -- against the absence date, because a seat present in the next drop did not vanish
            -- from it; and an assignment date can never postdate its own drop's as-of (the
            -- loader's impossible_as_of guard), so a succession never loses a tie it should win.
            WHEN
                s.next_valid_from IS NOT NULL
                AND (
                    s.next_as_of_after_last_seen IS NULL
                    OR s.next_valid_from <= s.next_as_of_after_last_seen
                )
                THEN 'succession-dated'
            -- Revocation by absence: the as-of of the first drop the seat was no longer in.
            WHEN s.next_as_of_after_last_seen IS NOT NULL THEN 'observation-dated'
            -- No successor and no later drop: the seat is still open, and stays NULL.
        END AS valid_to_basis
    FROM successor AS s
),

bounded AS (
    SELECT
        user_email,
        seat_tier,
        anthropic_org_name,
        valid_from,
        valid_from_basis,
        valid_to_basis,
        first_seen_on,
        last_seen_on,
        -- GREATEST clamps a backwards-dated boundary to a zero-length interval rather than a
        -- negative one; the final WHERE then drops it. marts.fact_seat_day is uniquely indexed
        -- on (date_day, user_email), so an overlap would fail its refresh outright.
        CASE valid_to_basis
            WHEN 'revoke-dated' THEN GREATEST(valid_from, next_claude_closed_on)
            WHEN 'succession-dated' THEN GREATEST(valid_from, next_valid_from)
            WHEN 'observation-dated' THEN GREATEST(valid_from, next_as_of_after_last_seen)
        END AS valid_to
    FROM closing
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
    last_seen_on,
    valid_to_basis
FROM bounded
WHERE valid_to IS NULL OR valid_to > valid_from;

-- migrate:down

-- Removing a column is the one edit CREATE OR REPLACE VIEW cannot make, so the down has to drop
-- and rebuild -- and dropping this view cascades to everything derived from it. The three seat
-- marts and `stg_seat_uncovered_day` are therefore recreated verbatim from git HEAD below,
-- indexes and grants included. They come back WITH NO DATA, exactly as a fresh migration leaves
-- them; `marts.refresh_all()` repopulates them.
DROP VIEW staging.stg_seat_interval CASCADE;

CREATE VIEW staging.stg_seat_interval AS
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
    SELECT
        user_email,
        interval_seq,
        MIN(as_of_date) AS first_seen_on,
        MAX(as_of_date) AS last_seen_on,
        (ARRAY_AGG(seat_tier ORDER BY as_of_date))[1] AS seat_tier,
        (ARRAY_AGG(anthropic_org_name ORDER BY as_of_date))[1] AS anthropic_org_name,
        (ARRAY_AGG(valid_from ORDER BY as_of_date))[1] AS valid_from,
        (ARRAY_AGG(valid_from_basis ORDER BY as_of_date))[1] AS valid_from_basis,
        (ARRAY_AGG(holds_claude ORDER BY as_of_date))[1] AS is_claude_seat,
        (ARRAY_AGG(claude_closed_on ORDER BY as_of_date))[1] AS claude_closed_on,
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

CREATE MATERIALIZED VIEW marts.dim_seat AS
SELECT
    user_email,
    seat_tier,
    anthropic_org_name,
    valid_from,
    valid_to,
    valid_from_basis
FROM staging.stg_seat_interval
WITH NO DATA;

CREATE UNIQUE INDEX dim_seat_pk ON marts.dim_seat USING btree (user_email, valid_from);

GRANT SELECT ON marts.dim_seat TO cc_otel_read;

CREATE MATERIALIZED VIEW marts.dim_seat_current AS
SELECT
    user_email,
    seat_tier,
    anthropic_org_name,
    valid_from
FROM staging.stg_seat_interval
WHERE valid_to IS NULL
WITH NO DATA;

CREATE UNIQUE INDEX dim_seat_current_pk ON marts.dim_seat_current USING btree (user_email);

GRANT SELECT ON marts.dim_seat_current TO cc_otel_read;

CREATE MATERIALIZED VIEW marts.fact_seat_day AS
SELECT
    d.day::date AS date_day,
    i.user_email,
    i.seat_tier,
    i.anthropic_org_name
FROM staging.stg_seat_interval AS i
CROSS JOIN LATERAL generate_series(
    i.valid_from::timestamp without time zone,
    (COALESCE(i.valid_to, CURRENT_DATE + 1) - 1)::timestamp without time zone,
    '1 day'::interval
) AS d (day)
WITH NO DATA;

CREATE UNIQUE INDEX fact_seat_day_pk ON marts.fact_seat_day USING btree (date_day, user_email);

GRANT SELECT ON marts.fact_seat_day TO cc_otel_read;

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
