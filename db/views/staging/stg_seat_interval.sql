-- Canonical definition for staging.stg_seat_interval.
-- Source of truth for the view body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name stg_seat_interval
-- Verified against pg_views.definition by --check (CI + local gate).
CREATE OR REPLACE VIEW staging.stg_seat_interval AS
 WITH drop_of_date AS (
         SELECT DISTINCT ON (roster_drop.as_of_date) roster_drop.drop_id,
            roster_drop.as_of_date
           FROM ref.roster_drop
          ORDER BY roster_drop.as_of_date, roster_drop.drop_id DESC
        ), drop_seq AS (
         SELECT drop_of_date.as_of_date,
            lag(drop_of_date.as_of_date) OVER (ORDER BY drop_of_date.as_of_date) AS prev_as_of,
            lead(drop_of_date.as_of_date) OVER (ORDER BY drop_of_date.as_of_date) AS next_as_of
           FROM drop_of_date
        ), observation AS (
         SELECT d.as_of_date,
            s.user_email,
            (array_agg(s.seat_tier ORDER BY s.subscription_seq))[1] AS seat_tier,
            (array_agg(s.anthropic_org_name ORDER BY s.subscription_seq))[1] AS anthropic_org_name,
            (array_agg(s.assignment_date ORDER BY s.subscription_seq))[1] AS assignment_date,
            bool_or(COALESCE((s.subscription_raw ~~ 'Claude %'::text), false)) AS holds_claude,
            max(
                CASE
                    WHEN (s.revoked_subscription_raw ~~ 'Claude %'::text) THEN s.revoke_date
                    ELSE NULL::date
                END) AS revoked_claude_on
           FROM (ref.seat_roster_snapshot s
             JOIN drop_of_date d ON ((s.drop_id = d.drop_id)))
          GROUP BY d.as_of_date, s.user_email
        ), sighting AS (
         SELECT o.as_of_date,
            o.user_email,
            o.seat_tier,
            o.anthropic_org_name,
            o.assignment_date,
            o.holds_claude,
            q.prev_as_of,
            q.next_as_of,
                CASE
                    WHEN (NOT o.holds_claude) THEN o.revoked_claude_on
                    ELSE NULL::date
                END AS claude_closed_on,
            lag(o.as_of_date) OVER (PARTITION BY o.user_email ORDER BY o.as_of_date) AS prev_seen_on,
            lag(o.seat_tier) OVER (PARTITION BY o.user_email ORDER BY o.as_of_date) AS prev_tier,
            lag(o.anthropic_org_name) OVER (PARTITION BY o.user_email ORDER BY o.as_of_date) AS prev_org,
            lag(o.assignment_date) OVER (PARTITION BY o.user_email ORDER BY o.as_of_date) AS prev_assignment_date
           FROM (observation o
             JOIN drop_seq q ON ((o.as_of_date = q.as_of_date)))
        ), boundary AS (
         SELECT sighting.as_of_date,
            sighting.user_email,
            sighting.seat_tier,
            sighting.anthropic_org_name,
            sighting.assignment_date,
            sighting.next_as_of,
            sighting.holds_claude,
            sighting.claude_closed_on,
            ((sighting.prev_seen_on IS NULL) OR (sighting.prev_seen_on IS DISTINCT FROM sighting.prev_as_of) OR (sighting.seat_tier IS DISTINCT FROM sighting.prev_tier) OR (sighting.anthropic_org_name IS DISTINCT FROM sighting.prev_org)) AS starts_interval,
            ((sighting.assignment_date IS NOT NULL) AND ((sighting.prev_seen_on IS NULL) OR (sighting.assignment_date IS DISTINCT FROM sighting.prev_assignment_date))) AS is_source_dated
           FROM sighting
        ), dated AS (
         SELECT boundary.as_of_date,
            boundary.user_email,
            boundary.seat_tier,
            boundary.anthropic_org_name,
            boundary.next_as_of,
            boundary.starts_interval,
            boundary.holds_claude,
            boundary.claude_closed_on,
                CASE
                    WHEN boundary.is_source_dated THEN boundary.assignment_date
                    ELSE boundary.as_of_date
                END AS valid_from,
                CASE
                    WHEN boundary.is_source_dated THEN 'source-dated'::text
                    ELSE 'observation-dated'::text
                END AS valid_from_basis
           FROM boundary
        ), numbered AS (
         SELECT dated.as_of_date,
            dated.user_email,
            dated.seat_tier,
            dated.anthropic_org_name,
            dated.next_as_of,
            dated.valid_from,
            dated.valid_from_basis,
            dated.holds_claude,
            dated.claude_closed_on,
            sum(
                CASE
                    WHEN dated.starts_interval THEN 1
                    ELSE 0
                END) OVER (PARTITION BY dated.user_email ORDER BY dated.as_of_date) AS interval_seq
           FROM dated
        ), interval_run AS (
         SELECT numbered.user_email,
            numbered.interval_seq,
            min(numbered.as_of_date) AS first_seen_on,
            max(numbered.as_of_date) AS last_seen_on,
            (array_agg(numbered.seat_tier ORDER BY numbered.as_of_date))[1] AS seat_tier,
            (array_agg(numbered.anthropic_org_name ORDER BY numbered.as_of_date))[1] AS anthropic_org_name,
            (array_agg(numbered.valid_from ORDER BY numbered.as_of_date))[1] AS valid_from,
            (array_agg(numbered.valid_from_basis ORDER BY numbered.as_of_date))[1] AS valid_from_basis,
            (array_agg(numbered.holds_claude ORDER BY numbered.as_of_date))[1] AS is_claude_seat,
            (array_agg(numbered.claude_closed_on ORDER BY numbered.as_of_date))[1] AS claude_closed_on,
            (array_agg(numbered.next_as_of ORDER BY numbered.as_of_date DESC))[1] AS next_as_of_after_last_seen
           FROM numbered
          GROUP BY numbered.user_email, numbered.interval_seq
        ), successor AS (
         SELECT r.user_email,
            r.interval_seq,
            r.first_seen_on,
            r.last_seen_on,
            r.seat_tier,
            r.anthropic_org_name,
            r.valid_from,
            r.valid_from_basis,
            r.is_claude_seat,
            r.claude_closed_on,
            r.next_as_of_after_last_seen,
            lead(r.valid_from) OVER (PARTITION BY r.user_email ORDER BY r.interval_seq) AS next_valid_from,
            lead(r.claude_closed_on) OVER (PARTITION BY r.user_email ORDER BY r.interval_seq) AS next_claude_closed_on
           FROM interval_run r
        ), closing AS (
         SELECT s.user_email,
            s.interval_seq,
            s.first_seen_on,
            s.last_seen_on,
            s.seat_tier,
            s.anthropic_org_name,
            s.valid_from,
            s.valid_from_basis,
            s.is_claude_seat,
            s.claude_closed_on,
            s.next_as_of_after_last_seen,
            s.next_valid_from,
            s.next_claude_closed_on,
                CASE
                    WHEN (s.is_claude_seat AND (s.next_claude_closed_on IS NOT NULL) AND ((s.next_valid_from IS NULL) OR (s.next_claude_closed_on <= s.next_valid_from))) THEN 'revoke-dated'::text
                    WHEN ((s.next_valid_from IS NOT NULL) AND ((s.next_as_of_after_last_seen IS NULL) OR (s.next_valid_from <= s.next_as_of_after_last_seen))) THEN 'succession-dated'::text
                    WHEN (s.next_as_of_after_last_seen IS NOT NULL) THEN 'observation-dated'::text
                    ELSE NULL::text
                END AS valid_to_basis
           FROM successor s
        ), bounded AS (
         SELECT closing.user_email,
            closing.seat_tier,
            closing.anthropic_org_name,
            closing.valid_from,
            closing.valid_from_basis,
            closing.valid_to_basis,
            closing.first_seen_on,
            closing.last_seen_on,
                CASE closing.valid_to_basis
                    WHEN 'revoke-dated'::text THEN GREATEST(closing.valid_from, closing.next_claude_closed_on)
                    WHEN 'succession-dated'::text THEN GREATEST(closing.valid_from, closing.next_valid_from)
                    WHEN 'observation-dated'::text THEN GREATEST(closing.valid_from, closing.next_as_of_after_last_seen)
                    ELSE NULL::date
                END AS valid_to
           FROM closing
        )
 SELECT user_email,
    seat_tier,
    anthropic_org_name,
    valid_from,
    valid_to,
    valid_from_basis,
    first_seen_on,
    last_seen_on,
    valid_to_basis
   FROM bounded
  WHERE ((valid_to IS NULL) OR (valid_to > valid_from));
