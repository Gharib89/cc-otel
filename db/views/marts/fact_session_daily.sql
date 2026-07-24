-- Canonical definition for marts.fact_session_daily.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name fact_session_daily
-- Verified against pg_matviews.definition by --check (CI + local gate).
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
     FULL JOIN p ON (((m.session_id = p.session_id) AND (m.activity_date = p.activity_date))));

CREATE UNIQUE INDEX fact_session_daily_pk ON marts.fact_session_daily USING btree (session_id, activity_date);

GRANT SELECT ON marts.fact_session_daily TO cc_otel_read;
