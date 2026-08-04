-- Canonical definition for staging.stg_utilization_segments.
-- Source of truth for the view body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name stg_utilization_segments
-- Verified against pg_views.definition by --check (CI + local gate).
CREATE OR REPLACE VIEW staging.stg_utilization_segments AS
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
