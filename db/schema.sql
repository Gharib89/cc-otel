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
-- Name: staging; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA staging;


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
           FROM raw.events)), CURRENT_DATE))::timestamp with time zone, (CURRENT_DATE)::timestamp with time zone, '1 day'::interval) d(d)
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
        )
 SELECT COALESCE(user_email, '(unknown)'::text) AS user_email,
    (user_email IS NULL) AS is_unknown,
    min(seen_at) AS first_seen,
    max(seen_at) AS last_seen,
    (array_agg(user_account_id) FILTER (WHERE (user_account_id IS NOT NULL)))[1] AS user_account_id,
    (array_agg(organization_id) FILTER (WHERE (organization_id IS NOT NULL)))[1] AS organization_id,
    (array_agg(cc_version ORDER BY seen_at DESC) FILTER (WHERE (cc_version IS NOT NULL)))[1] AS last_cc_version
   FROM seen
  GROUP BY COALESCE(user_email, '(unknown)'::text), (user_email IS NULL)
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
    COALESCE((array_agg(user_email) FILTER (WHERE (user_email IS NOT NULL)))[1], '(unknown)'::text) AS user_email,
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
    COALESCE((array_agg(user_email) FILTER (WHERE (user_email IS NOT NULL)))[1], '(unknown)'::text) AS user_email,
    sum(value) AS decision_count
   FROM staging.stg_counter_delta
  WHERE ((metric_name = 'claude_code.code_edit_tool.decision'::text) AND (session_id IS NOT NULL))
  GROUP BY session_id, ((ts)::date), tool_name, language, decision, source
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
    COALESCE((array_agg(sig.user_email ORDER BY sig.t) FILTER (WHERE (sig.user_email IS NOT NULL)))[1], '(unknown)'::text) AS user_email,
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
    COALESCE(
        CASE
            WHEN (m.user_email ~~ '%@itworx.com'::text) THEN m.user_email
            WHEN (p.user_email ~~ '%@itworx.com'::text) THEN p.user_email
            ELSE COALESCE(m.user_email, p.user_email)
        END, '(unknown)'::text) AS user_email,
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
 SELECT COALESCE(user_email, '(unknown)'::text) AS user_email,
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
 SELECT COALESCE(user_email, '(unknown)'::text) AS user_email,
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
    ('20260724071943');
