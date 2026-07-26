-- migrate:up

-- Linked identities (#320, parent #303, ADR-0011), the refresh half: marts.refresh_all() now
-- derives the session-based personal -> corporate pairs into staging.stg_identity_alias before
-- refreshing any mart, and reports a personal identity no rule could resolve as a dq_finding.
--
-- The derivation runs before the matview loop because marts.dim_user reads the pair set for its
-- scoping address (rls_email). That is a mart reading staging, not a mart reading a mart, so the
-- catalog loop's order-independence is intact.

CREATE OR REPLACE FUNCTION marts.refresh_all() RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    mv TEXT;
    log_id BIGINT;
    n BIGINT;
BEGIN
    -- Derived identity aliases (#320, ADR-0011), materialised before the marts that read
    -- them: dim_user joins the pair set and the unresolved-identity finding below scans it,
    -- so it is derived once per cycle rather than once per consumer. Corporate means
    -- '@itworx.com'.
    TRUNCATE staging.stg_identity_alias;

    INSERT INTO staging.stg_identity_alias (personal_email, corporate_email, shared_sessions)
    WITH session_email AS (
        -- A session_id is one Claude Code process, so two addresses inside one session is one
        -- human re-authenticating. UNION (not UNION ALL): the pair counts below are per
        -- session, so duplicate rows for the same address in the same session must collapse.
        SELECT session_id, user_email
        FROM raw.metrics
        WHERE session_id IS NOT NULL AND user_email IS NOT NULL
        UNION
        SELECT session_id, user_email
        FROM raw.events
        WHERE session_id IS NOT NULL AND user_email IS NOT NULL
    ), pair AS (
        -- Direction is fixed personal -> corporate, so corporate-to-corporate never links: on
        -- a shared terminal both addresses are corporate and both already have an HR row.
        SELECT p.user_email AS personal_email,
               c.user_email AS corporate_email,
               COUNT(DISTINCT p.session_id) AS shared_sessions
        FROM session_email p
        JOIN session_email c ON c.session_id = p.session_id
        WHERE p.user_email NOT LIKE '%@itworx.com'
          AND c.user_email LIKE '%@itworx.com'
        GROUP BY p.user_email, c.user_email
    )
    SELECT candidate.personal_email, candidate.corporate_email, candidate.shared_sessions
    FROM pair candidate
    -- Two shared sessions, because one would link on a single accident; and exactly one
    -- corporate partner across the address's sessions, tested against every partner rather
    -- than only those over the threshold, so any conflict yields no link at all.
    WHERE candidate.shared_sessions >= 2
      AND NOT EXISTS (
          SELECT 1 FROM pair other
          WHERE other.personal_email = candidate.personal_email
            AND other.corporate_email <> candidate.corporate_email
      );

    -- Catalog-driven (#262): every matview in marts refreshes, alphabetically.
    -- No mart reads another mart today, so order is irrelevant; if mart-on-mart
    -- stacking ever appears, switch to pg_depend dependency ordering (see
    -- docs/research/mart-definition-management.md §3).
    FOR mv IN
        SELECT matviewname FROM pg_matviews
        WHERE schemaname = 'marts'
        ORDER BY matviewname
    LOOP
        INSERT INTO marts.mart_refresh_log (mart, started)
        VALUES (mv, clock_timestamp())
        RETURNING id INTO log_id;

        EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY marts.%I', mv);
        EXECUTE format('SELECT count(*) FROM marts.%I', mv) INTO n;

        UPDATE marts.mart_refresh_log
        SET finished = clock_timestamp(), row_count = n
        WHERE id = log_id;
    END LOOP;

    -- DQ: sum_cumulative rows are excluded from staging (delta-only), never silently
    -- dropped — record how many were skipped this cycle.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'cumulative_value_kind', COUNT(*),
           jsonb_build_object('note', 'sum_cumulative metric rows excluded from staging')
    FROM raw.metrics
    WHERE metric_type = 'sum' AND value_kind = 'sum_cumulative'
    HAVING COUNT(*) > 0;

    -- DQ: null-email rows collapse into dim_user's '(unknown)' member — surface the count.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'unknown_email', COUNT(*),
           jsonb_build_object('note', 'raw rows with null user_email')
    FROM (
        SELECT 1 FROM raw.metrics WHERE user_email IS NULL
        UNION ALL
        SELECT 1 FROM raw.events WHERE user_email IS NULL
    ) q
    HAVING COUNT(*) > 0;

    -- DQ: session-days logged under more than one account. fact_session_daily keeps a
    -- single (corp-preferred) email, so this is where multi-account usage is recorded —
    -- one finding per offending session-day, corp vs personal split out.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'multi_email_session',
           cardinality(all_emails),
           jsonb_build_object(
               'session_id', session_id,
               'activity_date', activity_date,
               'corp_emails', to_jsonb(corp_emails),
               'personal_emails', to_jsonb(personal_emails),
               'all_emails', to_jsonb(all_emails)
           )
    FROM (
        SELECT
            session_id,
            activity_date,
            ARRAY_AGG(DISTINCT user_email ORDER BY user_email) AS all_emails,
            COALESCE(
                ARRAY_AGG(DISTINCT user_email ORDER BY user_email)
                    FILTER (WHERE user_email LIKE '%@itworx.com'),
                '{}'::text[]
            ) AS corp_emails,
            COALESCE(
                ARRAY_AGG(DISTINCT user_email ORDER BY user_email)
                    FILTER (WHERE user_email NOT LIKE '%@itworx.com'),
                '{}'::text[]
            ) AS personal_emails
        FROM (
            -- UNION ALL, not UNION: the outer COUNT(DISTINCT)/ARRAY_AGG(DISTINCT)
            -- already de-dupe, so a set UNION here is a wasted sort each refresh.
            SELECT session_id, ts::date AS activity_date, user_email
            FROM staging.stg_counter_delta
            WHERE session_id IS NOT NULL AND user_email IS NOT NULL
            UNION ALL
            SELECT session_id, event_time::date AS activity_date, user_email
            FROM raw.events
            WHERE session_id IS NOT NULL AND user_email IS NOT NULL
        ) e
        GROUP BY session_id, activity_date
        HAVING COUNT(DISTINCT user_email) > 1
    ) x;

    -- DQ: promoted cost_usd vs the claude_code.cost.usage counter. Both measure the
    -- same API-equivalent value; a gap past tolerance means the api_request cost
    -- promotion diverged from the counter. Fire only when BOTH >1% relative AND >$0.01
    -- absolute.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'cost_promotion_divergence',
           NULL,
           jsonb_build_object(
               'promoted_usd', round(promoted::numeric, 6),
               'counter_usd', round(counter::numeric, 6),
               'abs_diff_usd', round(abs(promoted - counter)::numeric, 6),
               'rel_diff', round((abs(promoted - counter) / GREATEST(counter, 0.01))::numeric, 6),
               'tolerance', '>1% relative and >$0.01 absolute'
           )
    FROM (
        SELECT
            (SELECT COALESCE(SUM(cost_usd), 0) FROM marts.fact_api_usage
                 WHERE activity_date >= DATE '2026-07-17') AS promoted,
            -- Match fact_api_usage's session_id IS NOT NULL grain filter, so the two
            -- sides reconcile on the same population (a session-less counter row would
            -- otherwise register as spurious divergence).
            (SELECT COALESCE(SUM(value), 0) FROM staging.stg_counter_delta
                 WHERE metric_name = 'claude_code.cost.usage'
                   AND session_id IS NOT NULL
                   AND ts >= DATE '2026-07-17') AS counter
    ) c
    WHERE abs(promoted - counter) > 0.01
      AND abs(promoted - counter) / GREATEST(counter, 0.01) > 0.01;

    -- DQ (#293): telemetry from a seat after its close date — the strongest detector in the
    -- seat set. Anthropic enforces licensing server-side, so a genuinely revoked seat cannot
    -- emit; telemetry after a close is near-proof the close was an export artefact rather than
    -- a real revocation. This catches the plausible-looking bad export that the loader's
    -- truncation guards let through.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'seat_telemetry_after_close', COUNT(*),
           jsonb_build_object(
               'user_email', user_email,
               'closed_on', MAX(closed_on),
               'first_activity_after_close', MIN(activity_date),
               'last_activity_after_close', MAX(activity_date)
           )
    FROM staging.stg_seat_uncovered_day
    WHERE closed_on IS NOT NULL
    GROUP BY user_email;

    -- DQ (#293): an identity emitting telemetry with no open seat on that date and no prior
    -- close — the complement of the finding above, so every uncovered activity day is reported
    -- exactly once. Computed against raw telemetry (through the staging view), never against
    -- marts.dim_user.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'seat_emitter_without_seat', COUNT(*),
           jsonb_build_object(
               'user_email', user_email,
               'first_activity_date', MIN(activity_date),
               'last_activity_date', MAX(activity_date)
           )
    FROM staging.stg_seat_uncovered_day
    WHERE closed_on IS NULL
    GROUP BY user_email;

    -- DQ (#293): a seat closing and reopening with exactly one drop missed in between —
    -- almost certainly an export artefact, not a genuine revoke-and-regrant.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    WITH chained AS (
        SELECT
            user_email,
            valid_to,
            last_seen_on,
            LEAD(first_seen_on) OVER (PARTITION BY user_email ORDER BY valid_from)
                AS next_first_seen_on,
            LEAD(valid_from) OVER (PARTITION BY user_email ORDER BY valid_from)
                AS next_valid_from
        FROM staging.stg_seat_interval
    )
    SELECT 'seat_reopened_within_cadence', 1,
           jsonb_build_object(
               'user_email', c.user_email,
               'closed_on', c.valid_to,
               'reopened_on', c.next_valid_from,
               'missed_drops', 1
           )
    FROM chained c
    WHERE c.valid_to IS NOT NULL
      AND c.next_first_seen_on IS NOT NULL
      AND (SELECT COUNT(DISTINCT d.as_of_date)
           FROM ref.roster_drop d
           WHERE d.as_of_date > c.last_seen_on AND d.as_of_date < c.next_first_seen_on) = 1;

    -- DQ (#293): an assignment date present with no tier — a real pending-provisioning state
    -- (one such row in the first drop); #291 asks IS whether it is intentional.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'seat_assignment_without_tier', COUNT(*),
           jsonb_build_object(
               'user_email', s.user_email,
               'assignment_date', MAX(s.assignment_date),
               'first_drop_as_of', MIN(d.as_of_date),
               'last_drop_as_of', MAX(d.as_of_date)
           )
    FROM ref.seat_roster_snapshot s
    JOIN ref.roster_drop d ON s.drop_id = d.drop_id
    WHERE s.assignment_date IS NOT NULL AND s.seat_tier IS NULL
    GROUP BY s.user_email;

    -- DQ (#293): one person holding more than one concurrent subscription — the grain
    -- assertion. The landing grain permits it; the reporting dimension asserts one active tier
    -- per person, so a violation is reported rather than silently multiplying seat-days.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'seat_multi_subscription', COUNT(*),
           jsonb_build_object(
               'user_email', s.user_email,
               'as_of_date', d.as_of_date,
               'tiers', to_jsonb(ARRAY_AGG(s.seat_tier ORDER BY s.subscription_seq))
           )
    FROM ref.seat_roster_snapshot s
    JOIN ref.roster_drop d ON s.drop_id = d.drop_id
    GROUP BY s.user_email, d.as_of_date
    HAVING COUNT(*) > 1;

    -- DQ (#293): the share of interval boundaries that are observation-dated rather than
    -- source-dated. Not an error — it makes the inferred share of the timeline measurable
    -- rather than invisible, so the request for a revocation column (#291) carries a number.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'seat_boundary_basis',
           COUNT(*) FILTER (WHERE valid_from_basis = 'observation-dated'),
           jsonb_build_object(
               'observation_dated', COUNT(*) FILTER (WHERE valid_from_basis = 'observation-dated'),
               'source_dated', COUNT(*) FILTER (WHERE valid_from_basis = 'source-dated'),
               'total', COUNT(*),
               'observation_dated_share',
               round((COUNT(*) FILTER (WHERE valid_from_basis = 'observation-dated'))::numeric
                     / COUNT(*), 4)
           )
    FROM staging.stg_seat_interval
    HAVING COUNT(*) > 0;

    -- DQ (#320, ADR-0011): a personal-address identity emitting telemetry that neither the
    -- derived rule nor ref.identity_alias could resolve to a corporate one — it stays invisible
    -- to every OrgScope viewer, and silence is the wrong output for "a human needs to look at
    -- this". An address the operator has already ruled on is resolved either way, including a
    -- suppression, so the worklist drains. Corporate emitters are out of scope: no alias rule
    -- can resolve one, and seat_emitter_without_seat already reports them.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'identity_alias_unresolved', COUNT(*),
           jsonb_build_object(
               'user_email', t.user_email,
               'first_activity_date', MIN(t.activity_date),
               'last_activity_date', MAX(t.activity_date)
           )
    FROM staging.stg_telemetry_day t
    WHERE t.user_email NOT LIKE '%@itworx.com'
      AND NOT EXISTS (SELECT 1 FROM staging.stg_identity_alias d
                      WHERE d.personal_email = t.user_email)
      AND NOT EXISTS (SELECT 1 FROM ref.identity_alias m
                      WHERE m.personal_email = t.user_email)
      AND NOT EXISTS (SELECT 1 FROM ref.seat_roster_snapshot s
                      WHERE s.user_email = t.user_email)
    GROUP BY t.user_email;
END
$fn$;

-- migrate:down

CREATE OR REPLACE FUNCTION marts.refresh_all() RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    mv TEXT;
    log_id BIGINT;
    n BIGINT;
BEGIN
    -- Catalog-driven (#262): every matview in marts refreshes, alphabetically.
    -- No mart reads another mart today, so order is irrelevant; if mart-on-mart
    -- stacking ever appears, switch to pg_depend dependency ordering (see
    -- docs/research/mart-definition-management.md §3).
    FOR mv IN
        SELECT matviewname FROM pg_matviews
        WHERE schemaname = 'marts'
        ORDER BY matviewname
    LOOP
        INSERT INTO marts.mart_refresh_log (mart, started)
        VALUES (mv, clock_timestamp())
        RETURNING id INTO log_id;

        EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY marts.%I', mv);
        EXECUTE format('SELECT count(*) FROM marts.%I', mv) INTO n;

        UPDATE marts.mart_refresh_log
        SET finished = clock_timestamp(), row_count = n
        WHERE id = log_id;
    END LOOP;

    -- DQ: sum_cumulative rows are excluded from staging (delta-only), never silently
    -- dropped — record how many were skipped this cycle.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'cumulative_value_kind', COUNT(*),
           jsonb_build_object('note', 'sum_cumulative metric rows excluded from staging')
    FROM raw.metrics
    WHERE metric_type = 'sum' AND value_kind = 'sum_cumulative'
    HAVING COUNT(*) > 0;

    -- DQ: null-email rows collapse into dim_user's '(unknown)' member — surface the count.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'unknown_email', COUNT(*),
           jsonb_build_object('note', 'raw rows with null user_email')
    FROM (
        SELECT 1 FROM raw.metrics WHERE user_email IS NULL
        UNION ALL
        SELECT 1 FROM raw.events WHERE user_email IS NULL
    ) q
    HAVING COUNT(*) > 0;

    -- DQ: session-days logged under more than one account. fact_session_daily keeps a
    -- single (corp-preferred) email, so this is where multi-account usage is recorded —
    -- one finding per offending session-day, corp vs personal split out.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'multi_email_session',
           cardinality(all_emails),
           jsonb_build_object(
               'session_id', session_id,
               'activity_date', activity_date,
               'corp_emails', to_jsonb(corp_emails),
               'personal_emails', to_jsonb(personal_emails),
               'all_emails', to_jsonb(all_emails)
           )
    FROM (
        SELECT
            session_id,
            activity_date,
            ARRAY_AGG(DISTINCT user_email ORDER BY user_email) AS all_emails,
            COALESCE(
                ARRAY_AGG(DISTINCT user_email ORDER BY user_email)
                    FILTER (WHERE user_email LIKE '%@itworx.com'),
                '{}'::text[]
            ) AS corp_emails,
            COALESCE(
                ARRAY_AGG(DISTINCT user_email ORDER BY user_email)
                    FILTER (WHERE user_email NOT LIKE '%@itworx.com'),
                '{}'::text[]
            ) AS personal_emails
        FROM (
            -- UNION ALL, not UNION: the outer COUNT(DISTINCT)/ARRAY_AGG(DISTINCT)
            -- already de-dupe, so a set UNION here is a wasted sort each refresh.
            SELECT session_id, ts::date AS activity_date, user_email
            FROM staging.stg_counter_delta
            WHERE session_id IS NOT NULL AND user_email IS NOT NULL
            UNION ALL
            SELECT session_id, event_time::date AS activity_date, user_email
            FROM raw.events
            WHERE session_id IS NOT NULL AND user_email IS NOT NULL
        ) e
        GROUP BY session_id, activity_date
        HAVING COUNT(DISTINCT user_email) > 1
    ) x;

    -- DQ: promoted cost_usd vs the claude_code.cost.usage counter. Both measure the
    -- same API-equivalent value; a gap past tolerance means the api_request cost
    -- promotion diverged from the counter. Fire only when BOTH >1% relative AND >$0.01
    -- absolute.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'cost_promotion_divergence',
           NULL,
           jsonb_build_object(
               'promoted_usd', round(promoted::numeric, 6),
               'counter_usd', round(counter::numeric, 6),
               'abs_diff_usd', round(abs(promoted - counter)::numeric, 6),
               'rel_diff', round((abs(promoted - counter) / GREATEST(counter, 0.01))::numeric, 6),
               'tolerance', '>1% relative and >$0.01 absolute'
           )
    FROM (
        SELECT
            (SELECT COALESCE(SUM(cost_usd), 0) FROM marts.fact_api_usage
                 WHERE activity_date >= DATE '2026-07-17') AS promoted,
            -- Match fact_api_usage's session_id IS NOT NULL grain filter, so the two
            -- sides reconcile on the same population (a session-less counter row would
            -- otherwise register as spurious divergence).
            (SELECT COALESCE(SUM(value), 0) FROM staging.stg_counter_delta
                 WHERE metric_name = 'claude_code.cost.usage'
                   AND session_id IS NOT NULL
                   AND ts >= DATE '2026-07-17') AS counter
    ) c
    WHERE abs(promoted - counter) > 0.01
      AND abs(promoted - counter) / GREATEST(counter, 0.01) > 0.01;

    -- DQ (#293): telemetry from a seat after its close date — the strongest detector in the
    -- seat set. Anthropic enforces licensing server-side, so a genuinely revoked seat cannot
    -- emit; telemetry after a close is near-proof the close was an export artefact rather than
    -- a real revocation. This catches the plausible-looking bad export that the loader's
    -- truncation guards let through.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'seat_telemetry_after_close', COUNT(*),
           jsonb_build_object(
               'user_email', user_email,
               'closed_on', MAX(closed_on),
               'first_activity_after_close', MIN(activity_date),
               'last_activity_after_close', MAX(activity_date)
           )
    FROM staging.stg_seat_uncovered_day
    WHERE closed_on IS NOT NULL
    GROUP BY user_email;

    -- DQ (#293): an identity emitting telemetry with no open seat on that date and no prior
    -- close — the complement of the finding above, so every uncovered activity day is reported
    -- exactly once. Computed against raw telemetry (through the staging view), never against
    -- marts.dim_user.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'seat_emitter_without_seat', COUNT(*),
           jsonb_build_object(
               'user_email', user_email,
               'first_activity_date', MIN(activity_date),
               'last_activity_date', MAX(activity_date)
           )
    FROM staging.stg_seat_uncovered_day
    WHERE closed_on IS NULL
    GROUP BY user_email;

    -- DQ (#293): a seat closing and reopening with exactly one drop missed in between —
    -- almost certainly an export artefact, not a genuine revoke-and-regrant.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    WITH chained AS (
        SELECT
            user_email,
            valid_to,
            last_seen_on,
            LEAD(first_seen_on) OVER (PARTITION BY user_email ORDER BY valid_from)
                AS next_first_seen_on,
            LEAD(valid_from) OVER (PARTITION BY user_email ORDER BY valid_from)
                AS next_valid_from
        FROM staging.stg_seat_interval
    )
    SELECT 'seat_reopened_within_cadence', 1,
           jsonb_build_object(
               'user_email', c.user_email,
               'closed_on', c.valid_to,
               'reopened_on', c.next_valid_from,
               'missed_drops', 1
           )
    FROM chained c
    WHERE c.valid_to IS NOT NULL
      AND c.next_first_seen_on IS NOT NULL
      AND (SELECT COUNT(DISTINCT d.as_of_date)
           FROM ref.roster_drop d
           WHERE d.as_of_date > c.last_seen_on AND d.as_of_date < c.next_first_seen_on) = 1;

    -- DQ (#293): an assignment date present with no tier — a real pending-provisioning state
    -- (one such row in the first drop); #291 asks IS whether it is intentional.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'seat_assignment_without_tier', COUNT(*),
           jsonb_build_object(
               'user_email', s.user_email,
               'assignment_date', MAX(s.assignment_date),
               'first_drop_as_of', MIN(d.as_of_date),
               'last_drop_as_of', MAX(d.as_of_date)
           )
    FROM ref.seat_roster_snapshot s
    JOIN ref.roster_drop d ON s.drop_id = d.drop_id
    WHERE s.assignment_date IS NOT NULL AND s.seat_tier IS NULL
    GROUP BY s.user_email;

    -- DQ (#293): one person holding more than one concurrent subscription — the grain
    -- assertion. The landing grain permits it; the reporting dimension asserts one active tier
    -- per person, so a violation is reported rather than silently multiplying seat-days.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'seat_multi_subscription', COUNT(*),
           jsonb_build_object(
               'user_email', s.user_email,
               'as_of_date', d.as_of_date,
               'tiers', to_jsonb(ARRAY_AGG(s.seat_tier ORDER BY s.subscription_seq))
           )
    FROM ref.seat_roster_snapshot s
    JOIN ref.roster_drop d ON s.drop_id = d.drop_id
    GROUP BY s.user_email, d.as_of_date
    HAVING COUNT(*) > 1;

    -- DQ (#293): the share of interval boundaries that are observation-dated rather than
    -- source-dated. Not an error — it makes the inferred share of the timeline measurable
    -- rather than invisible, so the request for a revocation column (#291) carries a number.
    INSERT INTO marts.dq_finding (finding_type, row_count, details)
    SELECT 'seat_boundary_basis',
           COUNT(*) FILTER (WHERE valid_from_basis = 'observation-dated'),
           jsonb_build_object(
               'observation_dated', COUNT(*) FILTER (WHERE valid_from_basis = 'observation-dated'),
               'source_dated', COUNT(*) FILTER (WHERE valid_from_basis = 'source-dated'),
               'total', COUNT(*),
               'observation_dated_share',
               round((COUNT(*) FILTER (WHERE valid_from_basis = 'observation-dated'))::numeric
                     / COUNT(*), 4)
           )
    FROM staging.stg_seat_interval
    HAVING COUNT(*) > 0;
END
$fn$;
