\restrict dbmate

-- Dumped from database version 16.14 (Debian 16.14-1.pgdg13+1)
-- Dumped by pg_dump version 17.10

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: marts; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA marts;


--
-- Name: meta; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA meta;


--
-- Name: raw; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA raw;


--
-- Name: ref; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ref;


--
-- Name: staging; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA staging;


--
-- Name: email_bucket(text); Type: FUNCTION; Schema: marts; Owner: -
--

CREATE FUNCTION marts.email_bucket(email text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    BEGIN ATOMIC
 SELECT COALESCE(email, '(unknown)'::text) AS "coalesce";
END;


--
-- Name: prefer_itworx(text, text); Type: FUNCTION; Schema: marts; Owner: -
--

CREATE FUNCTION marts.prefer_itworx(a text, b text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    BEGIN ATOMIC
 SELECT
         CASE
             WHEN (a ~~ '%@itworx.com'::text) THEN a
             WHEN (b ~~ '%@itworx.com'::text) THEN b
             ELSE COALESCE(a, b)
         END AS "coalesce";
END;


--
-- Name: refresh_all(); Type: FUNCTION; Schema: marts; Owner: -
--

CREATE FUNCTION marts.refresh_all() RETURNS void
    LANGUAGE plpgsql
    AS $_$
DECLARE
    mv TEXT;
    log_id BIGINT;
    n BIGINT;
BEGIN
    -- Derived identity aliases (#320, ADR-0011), materialised before the marts that read
    -- them: dim_user joins the pair set and the unresolved-identity finding below scans it,
    -- so it is derived once per cycle rather than once per consumer. Corporate means
    -- '@itworx.com', inline here as it is elsewhere in this function; #278 tracks extracting
    -- the predicate into a shared rule function across every site at once.
    TRUNCATE staging.stg_identity_alias;

    INSERT INTO staging.stg_identity_alias (personal_email, corporate_email, shared_sessions)
    WITH session_email AS (
        -- A session_id is one Claude Code process, so two addresses inside one session is one
        -- human re-authenticating. UNION (not UNION ALL) because the next CTE self-joins this
        -- one on session_id: an address emitting thousands of rows in a session would otherwise
        -- fan the join out by their product. The counts below are DISTINCT either way.
        --
        -- Deliberately unwindowed, unlike the cost finding further down: the evidence is
        -- historical, so a window would silently unlink a person once their shared sessions
        -- aged past it.
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
    -- can resolve one, and seat_emitter_without_seat already reports them. The roster clause
    -- makes "off-roster" literal rather than assumed — a personal address IS listed as a seat
    -- would be on-roster, and the finding says nothing about it.
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
$_$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: events; Type: TABLE; Schema: raw; Owner: -
--

CREATE TABLE raw.events (
    event_time timestamp with time zone NOT NULL,
    event_name text NOT NULL,
    severity text,
    body text,
    user_email text,
    user_account_id text,
    organization_id text,
    session_id uuid,
    prompt_id uuid,
    model text,
    tool_name text,
    duration_ms bigint,
    input_tokens bigint,
    output_tokens bigint,
    cache_creation_tokens bigint,
    cache_read_tokens bigint,
    cost_usd double precision,
    cc_version text,
    event_sequence bigint,
    request_id text,
    speed text,
    effort text,
    query_source text,
    prompt_length bigint,
    command_name text,
    command_source text,
    hook_name text,
    hook_event text,
    from_mode text,
    to_mode text,
    trigger text,
    skill_name text,
    agent_name text,
    plugin_name text,
    marketplace_name text,
    mcp_server_name text,
    mcp_tool_name text,
    mention_type text,
    success_bool boolean,
    tool_use_id text,
    decision text,
    source text,
    scope_name text,
    scope_version text,
    severity_number smallint,
    log_trace_id text,
    log_span_id text,
    dropped_attributes_count integer
);


--
-- Name: bridge_session_agent; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.bridge_session_agent AS
 SELECT session_id,
    agent_name,
    count(*) AS invocations
   FROM raw.events
  WHERE ((event_name = 'api_request'::text) AND (session_id IS NOT NULL) AND (agent_name IS NOT NULL))
  GROUP BY session_id, agent_name
  WITH NO DATA;


--
-- Name: bridge_session_hook; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.bridge_session_hook AS
 SELECT session_id,
    hook_name,
    count(*) AS executions
   FROM raw.events
  WHERE ((event_name = 'hook_execution_complete'::text) AND (session_id IS NOT NULL) AND (hook_name IS NOT NULL))
  GROUP BY session_id, hook_name
  WITH NO DATA;


--
-- Name: bridge_session_mcp; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.bridge_session_mcp AS
 WITH names AS (
         SELECT events.session_id,
            events.tool_name AS mcp_name
           FROM raw.events
          WHERE ((events.event_name = 'tool_result'::text) AND (events.session_id IS NOT NULL) AND (events.tool_name ~~ 'mcp__%'::text))
        UNION ALL
         SELECT events.session_id,
            events.mcp_server_name
           FROM raw.events
          WHERE ((events.event_name = 'api_request'::text) AND (events.session_id IS NOT NULL) AND (events.mcp_server_name IS NOT NULL))
        )
 SELECT session_id,
    mcp_name,
    count(*) AS tool_calls
   FROM names
  GROUP BY session_id, mcp_name
  WITH NO DATA;


--
-- Name: bridge_session_plugin; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.bridge_session_plugin AS
 SELECT session_id,
    plugin_name,
    count(*) AS load_count
   FROM raw.events
  WHERE ((event_name = 'plugin_loaded'::text) AND (session_id IS NOT NULL) AND (plugin_name IS NOT NULL))
  GROUP BY session_id, plugin_name
  WITH NO DATA;


--
-- Name: bridge_session_skill; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.bridge_session_skill AS
 SELECT session_id,
    skill_name,
    count(*) AS activations
   FROM raw.events
  WHERE ((event_name = ANY (ARRAY['skill_activated'::text, 'api_request'::text])) AND (session_id IS NOT NULL) AND (skill_name IS NOT NULL))
  GROUP BY session_id, skill_name
  WITH NO DATA;


--
-- Name: metrics; Type: TABLE; Schema: raw; Owner: -
--

CREATE TABLE raw.metrics (
    ts timestamp with time zone NOT NULL,
    metric_name text NOT NULL,
    metric_type text NOT NULL,
    value double precision,
    count bigint,
    value_kind text,
    user_email text,
    user_account_id text,
    organization_id text,
    session_id uuid,
    model text,
    type_label text,
    tool_name text,
    decision text,
    source text,
    language text,
    usage_window text,
    cc_version text,
    query_source text,
    effort text,
    speed text,
    agent_name text,
    skill_name text,
    plugin_name text,
    marketplace_name text,
    start_type text,
    scope_name text,
    scope_version text
);


--
-- Name: roster_drop; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.roster_drop (
    drop_id bigint NOT NULL,
    as_of_date date NOT NULL,
    source_filename text NOT NULL,
    file_sha256 text NOT NULL,
    row_count integer NOT NULL,
    ingested_at timestamp with time zone DEFAULT now() NOT NULL,
    ingested_by text NOT NULL,
    notes text
);


--
-- Name: seat_roster_snapshot; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.seat_roster_snapshot (
    drop_id bigint NOT NULL,
    user_email text NOT NULL,
    subscription_seq smallint NOT NULL,
    subscription_raw text,
    seat_tier text,
    assignment_date date,
    anthropic_org_name text,
    person_name text,
    manager_name text,
    department text,
    cost_center text,
    extra jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: dim_date; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.dim_date AS
 SELECT (d)::date AS date_day,
    (EXTRACT(year FROM d))::integer AS year,
    (EXTRACT(quarter FROM d))::integer AS quarter,
    (EXTRACT(month FROM d))::integer AS month,
    to_char(d, 'Mon'::text) AS month_name,
    (EXTRACT(day FROM d))::integer AS day_of_month,
    (EXTRACT(isodow FROM d))::integer AS iso_dow,
    to_char(d, 'Dy'::text) AS day_name,
    (EXTRACT(isodow FROM d) >= (6)::numeric) AS is_weekend,
    (EXTRACT(week FROM d))::integer AS iso_week
   FROM generate_series((COALESCE(LEAST(( SELECT (min(metrics.ts))::date AS min
           FROM raw.metrics), ( SELECT (min(events.event_time))::date AS min
           FROM raw.events), ( SELECT min(seat_roster_snapshot.assignment_date) AS min
           FROM ref.seat_roster_snapshot), ( SELECT min(roster_drop.as_of_date) AS min
           FROM ref.roster_drop)), CURRENT_DATE))::timestamp with time zone, (CURRENT_DATE)::timestamp with time zone, '1 day'::interval) d(d)
  WITH NO DATA;


--
-- Name: dim_model; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.dim_model AS
 WITH ids AS (
         SELECT metrics.model
           FROM raw.metrics
          WHERE (metrics.model IS NOT NULL)
        UNION
         SELECT events.model
           FROM raw.events
          WHERE (events.model IS NOT NULL)
        )
 SELECT model AS model_id,
        CASE
            WHEN (model ~~* '%opus%'::text) THEN 'opus'::text
            WHEN (model ~~* '%sonnet%'::text) THEN 'sonnet'::text
            WHEN (model ~~* '%haiku%'::text) THEN 'haiku'::text
            WHEN (model ~~* '%fable%'::text) THEN 'fable'::text
            ELSE 'other'::text
        END AS family,
    regexp_replace(regexp_replace(model, '\[1m\]$'::text, ''::text), '^claude-(opus|sonnet|haiku|fable)-'::text, ''::text) AS version,
    (model ~~ '%[1m]%'::text) AS is_long_context
   FROM ids
  WITH NO DATA;


--
-- Name: stg_seat_interval; Type: VIEW; Schema: staging; Owner: -
--

CREATE VIEW staging.stg_seat_interval AS
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
            (array_agg(s.assignment_date ORDER BY s.subscription_seq))[1] AS assignment_date
           FROM (ref.seat_roster_snapshot s
             JOIN drop_of_date d ON ((s.drop_id = d.drop_id)))
          GROUP BY d.as_of_date, s.user_email
        ), sighting AS (
         SELECT o.as_of_date,
            o.user_email,
            o.seat_tier,
            o.anthropic_org_name,
            o.assignment_date,
            q.prev_as_of,
            q.next_as_of,
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
            (array_agg(numbered.next_as_of ORDER BY numbered.as_of_date DESC))[1] AS next_as_of_after_last_seen
           FROM numbered
          GROUP BY numbered.user_email, numbered.interval_seq
        ), bounded AS (
         SELECT x.user_email,
            x.seat_tier,
            x.anthropic_org_name,
            x.valid_from,
            x.valid_from_basis,
            x.first_seen_on,
            x.last_seen_on,
                CASE
                    WHEN (LEAST(x.next_as_of_after_last_seen, x.next_valid_from) IS NULL) THEN NULL::date
                    ELSE GREATEST(x.valid_from, LEAST(x.next_as_of_after_last_seen, x.next_valid_from))
                END AS valid_to
           FROM ( SELECT r.user_email,
                    r.interval_seq,
                    r.first_seen_on,
                    r.last_seen_on,
                    r.seat_tier,
                    r.anthropic_org_name,
                    r.valid_from,
                    r.valid_from_basis,
                    r.next_as_of_after_last_seen,
                    lead(r.valid_from) OVER (PARTITION BY r.user_email ORDER BY r.interval_seq) AS next_valid_from
                   FROM interval_run r) x
        )
 SELECT user_email,
    seat_tier,
    anthropic_org_name,
    valid_from,
    valid_to,
    valid_from_basis,
    first_seen_on,
    last_seen_on
   FROM bounded
  WHERE ((valid_to IS NULL) OR (valid_to > valid_from));


--
-- Name: dim_seat; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.dim_seat AS
 SELECT user_email,
    seat_tier,
    anthropic_org_name,
    valid_from,
    valid_to,
    valid_from_basis
   FROM staging.stg_seat_interval
  WITH NO DATA;


--
-- Name: dim_seat_current; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.dim_seat_current AS
 SELECT user_email,
    seat_tier,
    anthropic_org_name,
    valid_from
   FROM staging.stg_seat_interval
  WHERE (valid_to IS NULL)
  WITH NO DATA;


--
-- Name: identity_alias; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.identity_alias (
    personal_email text NOT NULL,
    corporate_email text,
    added_at timestamp with time zone DEFAULT now() NOT NULL,
    added_by text DEFAULT CURRENT_USER NOT NULL,
    notes text
);


--
-- Name: stg_identity_alias; Type: TABLE; Schema: staging; Owner: -
--

CREATE TABLE staging.stg_identity_alias (
    personal_email text NOT NULL,
    corporate_email text NOT NULL,
    shared_sessions integer NOT NULL,
    CONSTRAINT stg_identity_alias_corporate_side CHECK ((corporate_email ~~ '%@itworx.com'::text)),
    CONSTRAINT stg_identity_alias_personal_side CHECK ((personal_email !~~ '%@itworx.com'::text)),
    CONSTRAINT stg_identity_alias_two_shared_sessions CHECK ((shared_sessions >= 2))
);


--
-- Name: dim_user; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.dim_user AS
 WITH seen AS (
         SELECT metrics.user_email,
            metrics.user_account_id,
            metrics.organization_id,
            metrics.cc_version,
            metrics.ts AS seen_at
           FROM raw.metrics
        UNION ALL
         SELECT events.user_email,
            events.user_account_id,
            events.organization_id,
            events.cc_version,
            events.event_time
           FROM raw.events
        ), identity AS (
         SELECT marts.email_bucket(seen.user_email) AS user_email,
            (seen.user_email IS NULL) AS is_unknown,
            min(seen.seen_at) AS first_seen,
            max(seen.seen_at) AS last_seen,
            (array_agg(seen.user_account_id) FILTER (WHERE (seen.user_account_id IS NOT NULL)))[1] AS user_account_id,
            (array_agg(seen.organization_id) FILTER (WHERE (seen.organization_id IS NOT NULL)))[1] AS organization_id,
            (array_agg(seen.cc_version ORDER BY seen.seen_at DESC) FILTER (WHERE (seen.cc_version IS NOT NULL)))[1] AS last_cc_version
           FROM seen
          GROUP BY (marts.email_bucket(seen.user_email)), (seen.user_email IS NULL)
        )
 SELECT i.user_email,
    i.is_unknown,
    i.first_seen,
    i.last_seen,
    i.user_account_id,
    i.organization_id,
    i.last_cc_version,
        CASE
            WHEN (m.personal_email IS NOT NULL) THEN COALESCE(m.corporate_email, i.user_email)
            ELSE COALESCE(d.corporate_email, i.user_email)
        END AS rls_email
   FROM ((identity i
     LEFT JOIN ref.identity_alias m ON ((m.personal_email = i.user_email)))
     LEFT JOIN staging.stg_identity_alias d ON ((d.personal_email = i.user_email)))
  WITH NO DATA;


--
-- Name: dq_finding; Type: TABLE; Schema: marts; Owner: -
--

CREATE TABLE marts.dq_finding (
    id bigint NOT NULL,
    finding_type text NOT NULL,
    detected_at timestamp with time zone DEFAULT now() NOT NULL,
    row_count bigint,
    details jsonb
);


--
-- Name: dq_finding_id_seq; Type: SEQUENCE; Schema: marts; Owner: -
--

ALTER TABLE marts.dq_finding ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME marts.dq_finding_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: fact_api_error_rate; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.fact_api_error_rate AS
 SELECT (event_time)::date AS activity_date,
    count(*) FILTER (WHERE (event_name = 'api_request'::text)) AS api_request_count,
    count(*) FILTER (WHERE (event_name = 'api_error'::text)) AS api_error_count,
    round(((100.0 * (count(*) FILTER (WHERE (event_name = 'api_error'::text)))::numeric) / (NULLIF(count(*), 0))::numeric), 2) AS error_rate_pct
   FROM raw.events
  WHERE (event_name = ANY (ARRAY['api_request'::text, 'api_error'::text]))
  GROUP BY ((event_time)::date)
  WITH NO DATA;


--
-- Name: stg_api_request; Type: VIEW; Schema: staging; Owner: -
--

CREATE VIEW staging.stg_api_request AS
 SELECT event_time,
    session_id,
    user_email,
    model,
    input_tokens,
    output_tokens,
    cache_creation_tokens,
    cache_read_tokens,
    query_source,
    effort,
    speed,
    agent_name,
    skill_name,
    mcp_server_name,
    mcp_tool_name,
    cc_version,
    cost_usd
   FROM raw.events
  WHERE (event_name = 'api_request'::text);


--
-- Name: fact_api_usage; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.fact_api_usage AS
 SELECT session_id,
    (event_time)::date AS activity_date,
    model,
    effort,
    query_source,
    marts.email_bucket((array_agg(user_email) FILTER (WHERE (user_email IS NOT NULL)))[1]) AS user_email,
    sum(input_tokens) AS input_tokens,
    sum(output_tokens) AS output_tokens,
    sum(cache_creation_tokens) AS cache_creation_tokens,
    sum(cache_read_tokens) AS cache_read_tokens,
    sum(cost_usd) AS cost_usd,
    count(*) AS request_count,
    max(event_time) AS last_event_ts
   FROM staging.stg_api_request
  WHERE (session_id IS NOT NULL)
  GROUP BY session_id, ((event_time)::date), model, effort, query_source
  WITH NO DATA;


--
-- Name: stg_counter_delta; Type: VIEW; Schema: staging; Owner: -
--

CREATE VIEW staging.stg_counter_delta AS
 SELECT ts,
    metric_name,
    value,
    user_email,
    session_id,
    model,
    type_label,
    tool_name,
    decision,
    source,
    language,
    usage_window,
    cc_version,
    query_source,
    effort,
    speed,
    agent_name,
    skill_name,
    start_type
   FROM raw.metrics
  WHERE ((metric_type = 'sum'::text) AND (value_kind = 'sum_delta'::text));


--
-- Name: fact_edit_decision; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.fact_edit_decision AS
 SELECT session_id,
    (ts)::date AS activity_date,
    tool_name,
    language,
    decision,
    source,
    marts.email_bucket((array_agg(user_email) FILTER (WHERE (user_email IS NOT NULL)))[1]) AS user_email,
    sum(value) AS decision_count
   FROM staging.stg_counter_delta
  WHERE ((metric_name = 'claude_code.code_edit_tool.decision'::text) AND (session_id IS NOT NULL))
  GROUP BY session_id, ((ts)::date), tool_name, language, decision, source
  WITH NO DATA;


--
-- Name: fact_seat_day; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.fact_seat_day AS
 SELECT (d.day)::date AS date_day,
    i.user_email,
    i.seat_tier,
    i.anthropic_org_name
   FROM (staging.stg_seat_interval i
     CROSS JOIN LATERAL generate_series((i.valid_from)::timestamp without time zone, ((COALESCE(i.valid_to, (CURRENT_DATE + 1)) - 1))::timestamp without time zone, '1 day'::interval) d(day))
  WITH NO DATA;


--
-- Name: fact_session; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

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
  GROUP BY sig.session_id, st.start_type
  WITH NO DATA;


--
-- Name: fact_session_daily; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.fact_session_daily AS
 WITH m AS (
         SELECT stg_counter_delta.session_id,
            (stg_counter_delta.ts)::date AS activity_date,
            (array_agg(stg_counter_delta.user_email ORDER BY (stg_counter_delta.user_email ~~ '%@itworx.com'::text) DESC NULLS LAST, stg_counter_delta.user_email) FILTER (WHERE (stg_counter_delta.user_email IS NOT NULL)))[1] AS user_email,
            sum(stg_counter_delta.value) FILTER (WHERE (stg_counter_delta.metric_name = 'claude_code.commit.count'::text)) AS commits,
            sum(stg_counter_delta.value) FILTER (WHERE (stg_counter_delta.metric_name = 'claude_code.pull_request.count'::text)) AS prs,
            sum(stg_counter_delta.value) FILTER (WHERE ((stg_counter_delta.metric_name = 'claude_code.lines_of_code.count'::text) AND (stg_counter_delta.type_label = 'added'::text))) AS loc_added,
            sum(stg_counter_delta.value) FILTER (WHERE ((stg_counter_delta.metric_name = 'claude_code.lines_of_code.count'::text) AND (stg_counter_delta.type_label = 'removed'::text))) AS loc_removed,
            sum(stg_counter_delta.value) FILTER (WHERE ((stg_counter_delta.metric_name = 'claude_code.active_time.total'::text) AND (stg_counter_delta.type_label = 'user'::text))) AS active_time_user_s,
            sum(stg_counter_delta.value) FILTER (WHERE ((stg_counter_delta.metric_name = 'claude_code.active_time.total'::text) AND (stg_counter_delta.type_label = 'cli'::text))) AS active_time_cli_s
           FROM staging.stg_counter_delta
          WHERE (stg_counter_delta.session_id IS NOT NULL)
          GROUP BY stg_counter_delta.session_id, ((stg_counter_delta.ts)::date)
        ), p AS (
         SELECT events.session_id,
            (events.event_time)::date AS activity_date,
            (array_agg(events.user_email ORDER BY (events.user_email ~~ '%@itworx.com'::text) DESC NULLS LAST, events.user_email) FILTER (WHERE (events.user_email IS NOT NULL)))[1] AS user_email,
            count(DISTINCT events.prompt_id) AS prompts
           FROM raw.events
          WHERE ((events.prompt_id IS NOT NULL) AND (events.session_id IS NOT NULL))
          GROUP BY events.session_id, ((events.event_time)::date)
        )
 SELECT COALESCE(m.session_id, p.session_id) AS session_id,
    marts.email_bucket(marts.prefer_itworx(m.user_email, p.user_email)) AS user_email,
    COALESCE(m.activity_date, p.activity_date) AS activity_date,
    COALESCE(p.prompts, (0)::bigint) AS prompts,
    COALESCE(m.commits, (0)::double precision) AS commits,
    COALESCE(m.prs, (0)::double precision) AS prs,
    COALESCE(m.loc_added, (0)::double precision) AS loc_added,
    COALESCE(m.loc_removed, (0)::double precision) AS loc_removed,
    COALESCE(m.active_time_user_s, (0)::double precision) AS active_time_user_s,
    COALESCE(m.active_time_cli_s, (0)::double precision) AS active_time_cli_s,
    (COALESCE(m.active_time_user_s, (0)::double precision) + COALESCE(m.active_time_cli_s, (0)::double precision)) AS active_time_total_s
   FROM (m
     FULL JOIN p ON (((m.session_id = p.session_id) AND (m.activity_date = p.activity_date))))
  WITH NO DATA;


--
-- Name: fact_tool_outcome; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.fact_tool_outcome AS
 SELECT session_id,
    (event_time)::date AS activity_date,
    tool_name,
    count(*) AS tool_call_count,
    count(*) FILTER (WHERE success_bool) AS success_count,
    (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((duration_ms)::double precision)))::bigint AS duration_p50_ms,
    (percentile_cont((0.95)::double precision) WITHIN GROUP (ORDER BY ((duration_ms)::double precision)))::bigint AS duration_p95_ms
   FROM raw.events
  WHERE ((event_name = 'tool_result'::text) AND (session_id IS NOT NULL))
  GROUP BY session_id, ((event_time)::date), tool_name
  WITH NO DATA;


--
-- Name: stg_utilization_segments; Type: VIEW; Schema: staging; Owner: -
--

CREATE VIEW staging.stg_utilization_segments AS
 WITH samples AS (
         SELECT u.user_email,
            u.usage_window AS window_type,
            u.ts,
            u.value AS util_pct,
            date_bin('00:05:00'::interval, (u.ts + make_interval(secs => r.value)), '2000-01-01 00:00:00+00'::timestamp with time zone) AS window_end
           FROM (raw.metrics u
             JOIN raw.metrics r ON (((r.metric_name = 'claude_code.usage.reset_in_seconds'::text) AND (NOT (r.user_email IS DISTINCT FROM u.user_email)) AND (NOT (r.usage_window IS DISTINCT FROM u.usage_window)) AND (u.ts = r.ts))))
          WHERE ((u.metric_name = 'claude_code.usage.utilization'::text) AND (u.value_kind = 'gauge_last'::text) AND ((r.value >= (0)::double precision) AND (r.value <= (604800)::double precision)))
        ), flagged AS (
         SELECT samples.user_email,
            samples.window_type,
            samples.ts,
            samples.util_pct,
            samples.window_end,
            lag(samples.util_pct) OVER w AS prev_pct
           FROM samples
          WINDOW w AS (PARTITION BY samples.user_email, samples.window_type, samples.window_end ORDER BY samples.ts)
        )
 SELECT user_email,
    window_type,
    window_end,
    ts,
    util_pct,
    (1 + sum(
        CASE
            WHEN ((prev_pct IS NOT NULL) AND (util_pct < ((0.8)::double precision * prev_pct)) AND ((prev_pct - util_pct) >= (5)::double precision)) THEN 1
            ELSE 0
        END) OVER (PARTITION BY user_email, window_type, window_end ORDER BY ts)) AS segment_no
   FROM flagged;


--
-- Name: fact_usage_window; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.fact_usage_window AS
 WITH seg AS (
         SELECT stg_utilization_segments.user_email,
            stg_utilization_segments.window_type,
            stg_utilization_segments.window_end,
            stg_utilization_segments.segment_no,
            min(stg_utilization_segments.ts) AS first_sample_ts,
            max(stg_utilization_segments.ts) AS last_sample_ts,
            count(*) AS sample_count,
            (array_agg(stg_utilization_segments.util_pct ORDER BY stg_utilization_segments.ts DESC))[1] AS end_pct,
            max(stg_utilization_segments.util_pct) AS peak_pct,
            (array_agg(stg_utilization_segments.ts ORDER BY stg_utilization_segments.util_pct DESC, stg_utilization_segments.ts))[1] AS peak_ts
           FROM staging.stg_utilization_segments
          GROUP BY stg_utilization_segments.user_email, stg_utilization_segments.window_type, stg_utilization_segments.window_end, stg_utilization_segments.segment_no
        )
 SELECT marts.email_bucket(user_email) AS user_email,
    window_type,
    window_end,
    segment_no,
    end_pct,
    peak_pct,
    peak_ts,
    first_sample_ts,
    last_sample_ts,
    sample_count,
    (window_end -
        CASE window_type
            WHEN '5h'::text THEN '05:00:00'::interval
            WHEN '7d'::text THEN '7 days'::interval
            ELSE '00:00:00'::interval
        END) AS window_start,
    (max(segment_no) OVER (PARTITION BY seg.user_email, window_type, window_end) > 1) AS is_reset_split,
    (peak_pct / (NULLIF((EXTRACT(epoch FROM (peak_ts - first_sample_ts)) / 3600.0), (0)::numeric))::double precision) AS pace_pct_per_hour
   FROM seg
  WITH NO DATA;


--
-- Name: fact_utilization_hourly; Type: MATERIALIZED VIEW; Schema: marts; Owner: -
--

CREATE MATERIALIZED VIEW marts.fact_utilization_hourly AS
 SELECT marts.email_bucket(user_email) AS user_email,
    window_type,
    date_trunc('hour'::text, ts) AS hour,
    avg(util_pct) AS avg_pct,
    max(util_pct) AS max_pct
   FROM staging.stg_utilization_segments
  GROUP BY user_email, window_type, (date_trunc('hour'::text, ts))
  WITH NO DATA;


--
-- Name: mart_refresh_log; Type: TABLE; Schema: marts; Owner: -
--

CREATE TABLE marts.mart_refresh_log (
    id bigint NOT NULL,
    mart text NOT NULL,
    started timestamp with time zone NOT NULL,
    finished timestamp with time zone,
    row_count bigint
);


--
-- Name: mart_refresh_log_id_seq; Type: SEQUENCE; Schema: marts; Owner: -
--

ALTER TABLE marts.mart_refresh_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME marts.mart_refresh_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: column_registry; Type: TABLE; Schema: meta; Owner: -
--

CREATE TABLE meta.column_registry (
    signal text NOT NULL,
    signal_name text NOT NULL,
    attr_path text NOT NULL,
    status text NOT NULL,
    column_name text,
    data_type text,
    description text,
    useful_for text,
    decided_at date,
    notes text,
    CONSTRAINT column_registry_promoted_chk CHECK ((((status = 'promoted'::text) AND (column_name IS NOT NULL) AND (data_type IS NOT NULL)) OR ((status <> 'promoted'::text) AND (column_name IS NULL) AND (data_type IS NULL)))),
    CONSTRAINT column_registry_signal_chk CHECK ((signal = ANY (ARRAY['metrics'::text, 'events'::text, 'resource'::text]))),
    CONSTRAINT column_registry_status_chk CHECK ((status = ANY (ARRAY['promoted'::text, 'kept'::text, 'denied'::text])))
);


--
-- Name: processed_batches; Type: TABLE; Schema: meta; Owner: -
--

CREATE TABLE meta.processed_batches (
    batch_hash text NOT NULL,
    processed_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: roster_drop_drop_id_seq; Type: SEQUENCE; Schema: ref; Owner: -
--

ALTER TABLE ref.roster_drop ALTER COLUMN drop_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME ref.roster_drop_drop_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: stg_telemetry_day; Type: VIEW; Schema: staging; Owner: -
--

CREATE VIEW staging.stg_telemetry_day AS
 SELECT metrics.user_email,
    (metrics.ts)::date AS activity_date
   FROM raw.metrics
  WHERE (metrics.user_email IS NOT NULL)
UNION
 SELECT events.user_email,
    (events.event_time)::date AS activity_date
   FROM raw.events
  WHERE (events.user_email IS NOT NULL);


--
-- Name: stg_seat_uncovered_day; Type: VIEW; Schema: staging; Owner: -
--

CREATE VIEW staging.stg_seat_uncovered_day AS
 SELECT user_email,
    activity_date,
    ( SELECT max(i.valid_to) AS max
           FROM staging.stg_seat_interval i
          WHERE ((i.user_email = t.user_email) AND (i.valid_to <= t.activity_date))) AS closed_on
   FROM staging.stg_telemetry_day t
  WHERE (NOT (EXISTS ( SELECT 1
           FROM staging.stg_seat_interval i
          WHERE ((i.user_email = t.user_email) AND (i.valid_from <= t.activity_date) AND ((i.valid_to IS NULL) OR (i.valid_to > t.activity_date))))));


--
-- Name: dq_finding dq_finding_pkey; Type: CONSTRAINT; Schema: marts; Owner: -
--

ALTER TABLE ONLY marts.dq_finding
    ADD CONSTRAINT dq_finding_pkey PRIMARY KEY (id);


--
-- Name: mart_refresh_log mart_refresh_log_pkey; Type: CONSTRAINT; Schema: marts; Owner: -
--

ALTER TABLE ONLY marts.mart_refresh_log
    ADD CONSTRAINT mart_refresh_log_pkey PRIMARY KEY (id);


--
-- Name: column_registry column_registry_pkey; Type: CONSTRAINT; Schema: meta; Owner: -
--

ALTER TABLE ONLY meta.column_registry
    ADD CONSTRAINT column_registry_pkey PRIMARY KEY (signal, signal_name, attr_path);


--
-- Name: processed_batches processed_batches_pkey; Type: CONSTRAINT; Schema: meta; Owner: -
--

ALTER TABLE ONLY meta.processed_batches
    ADD CONSTRAINT processed_batches_pkey PRIMARY KEY (batch_hash);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: identity_alias identity_alias_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.identity_alias
    ADD CONSTRAINT identity_alias_pkey PRIMARY KEY (personal_email);


--
-- Name: roster_drop roster_drop_file_sha256_key; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.roster_drop
    ADD CONSTRAINT roster_drop_file_sha256_key UNIQUE (file_sha256);


--
-- Name: roster_drop roster_drop_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.roster_drop
    ADD CONSTRAINT roster_drop_pkey PRIMARY KEY (drop_id);


--
-- Name: seat_roster_snapshot seat_roster_snapshot_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.seat_roster_snapshot
    ADD CONSTRAINT seat_roster_snapshot_pkey PRIMARY KEY (drop_id, user_email, subscription_seq);


--
-- Name: stg_identity_alias stg_identity_alias_pkey; Type: CONSTRAINT; Schema: staging; Owner: -
--

ALTER TABLE ONLY staging.stg_identity_alias
    ADD CONSTRAINT stg_identity_alias_pkey PRIMARY KEY (personal_email);


--
-- Name: bridge_session_agent_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX bridge_session_agent_pk ON marts.bridge_session_agent USING btree (session_id, agent_name);


--
-- Name: bridge_session_hook_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX bridge_session_hook_pk ON marts.bridge_session_hook USING btree (session_id, hook_name);


--
-- Name: bridge_session_mcp_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX bridge_session_mcp_pk ON marts.bridge_session_mcp USING btree (session_id, mcp_name);


--
-- Name: bridge_session_plugin_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX bridge_session_plugin_pk ON marts.bridge_session_plugin USING btree (session_id, plugin_name);


--
-- Name: bridge_session_skill_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX bridge_session_skill_pk ON marts.bridge_session_skill USING btree (session_id, skill_name);


--
-- Name: dim_date_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX dim_date_pk ON marts.dim_date USING btree (date_day);


--
-- Name: dim_model_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX dim_model_pk ON marts.dim_model USING btree (model_id);


--
-- Name: dim_seat_current_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX dim_seat_current_pk ON marts.dim_seat_current USING btree (user_email);


--
-- Name: dim_seat_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX dim_seat_pk ON marts.dim_seat USING btree (user_email, valid_from);


--
-- Name: dim_user_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX dim_user_pk ON marts.dim_user USING btree (user_email);


--
-- Name: dq_finding_detected_idx; Type: INDEX; Schema: marts; Owner: -
--

CREATE INDEX dq_finding_detected_idx ON marts.dq_finding USING btree (detected_at DESC);


--
-- Name: fact_api_error_rate_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX fact_api_error_rate_pk ON marts.fact_api_error_rate USING btree (activity_date);


--
-- Name: fact_api_usage_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX fact_api_usage_pk ON marts.fact_api_usage USING btree (session_id, activity_date, model, effort, query_source);


--
-- Name: fact_edit_decision_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX fact_edit_decision_pk ON marts.fact_edit_decision USING btree (session_id, activity_date, tool_name, language, decision, source);


--
-- Name: fact_seat_day_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX fact_seat_day_pk ON marts.fact_seat_day USING btree (date_day, user_email);


--
-- Name: fact_session_daily_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX fact_session_daily_pk ON marts.fact_session_daily USING btree (session_id, activity_date);


--
-- Name: fact_session_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX fact_session_pk ON marts.fact_session USING btree (session_id);


--
-- Name: fact_tool_outcome_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX fact_tool_outcome_pk ON marts.fact_tool_outcome USING btree (session_id, activity_date, tool_name);


--
-- Name: fact_usage_window_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX fact_usage_window_pk ON marts.fact_usage_window USING btree (user_email, window_type, window_end, segment_no);


--
-- Name: fact_utilization_hourly_pk; Type: INDEX; Schema: marts; Owner: -
--

CREATE UNIQUE INDEX fact_utilization_hourly_pk ON marts.fact_utilization_hourly USING btree (user_email, window_type, hour);


--
-- Name: mart_refresh_log_started_idx; Type: INDEX; Schema: marts; Owner: -
--

CREATE INDEX mart_refresh_log_started_idx ON marts.mart_refresh_log USING btree (started DESC);


--
-- Name: events_name_time_idx; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX events_name_time_idx ON raw.events USING btree (event_name, event_time DESC);


--
-- Name: events_session_idx; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX events_session_idx ON raw.events USING btree (session_id);


--
-- Name: events_time_idx; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX events_time_idx ON raw.events USING btree (event_time DESC);


--
-- Name: metrics_name_ts_idx; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX metrics_name_ts_idx ON raw.metrics USING btree (metric_name, ts DESC);


--
-- Name: metrics_ts_idx; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX metrics_ts_idx ON raw.metrics USING btree (ts DESC);


--
-- Name: metrics_user_ts_idx; Type: INDEX; Schema: raw; Owner: -
--

CREATE INDEX metrics_user_ts_idx ON raw.metrics USING btree (user_email, ts DESC);


--
-- Name: roster_drop_as_of_idx; Type: INDEX; Schema: ref; Owner: -
--

CREATE INDEX roster_drop_as_of_idx ON ref.roster_drop USING btree (as_of_date DESC);


--
-- Name: seat_roster_snapshot seat_roster_snapshot_drop_id_fkey; Type: FK CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.seat_roster_snapshot
    ADD CONSTRAINT seat_roster_snapshot_drop_id_fkey FOREIGN KEY (drop_id) REFERENCES ref.roster_drop(drop_id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict dbmate


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('20260713170001'),
    ('20260713170002'),
    ('20260713170003'),
    ('20260713170004'),
    ('20260713170005'),
    ('20260713170006'),
    ('20260713170007'),
    ('20260713170008'),
    ('20260713170009'),
    ('20260713170010'),
    ('20260713170011'),
    ('20260713170012'),
    ('20260713170013'),
    ('20260716153503'),
    ('20260720120000'),
    ('20260722031957'),
    ('20260722120000'),
    ('20260722140000'),
    ('20260723070059'),
    ('20260723074556'),
    ('20260724071943'),
    ('20260724090737'),
    ('20260724090951'),
    ('20260724091019'),
    ('20260724091026'),
    ('20260724091032'),
    ('20260724091038'),
    ('20260724091043'),
    ('20260724091053'),
    ('20260725092718'),
    ('20260725110500'),
    ('20260725110845'),
    ('20260725110850'),
    ('20260725110856'),
    ('20260725110902'),
    ('20260725111500'),
    ('20260726041817'),
    ('20260726041900'),
    ('20260726042056');
