-- migrate:up

-- The utilization pipeline (#9) — the trickiest model. Wrapper gauges
-- claude_code.usage.utilization and claude_code.usage.reset_in_seconds are pushed
-- together (~once per 5 min per machine, ADR-0003), carrying a `window` attribute
-- (usage_window: 5h/7d). A rate-limit window INSTANCE is reconstructed as
-- window_end = ts + reset_in_seconds, bucketed to 5 minutes to absorb sample drift.
--
-- Fleet resets do NOT reset reset_in_seconds, so utilization can crater mid-window;
-- such a window is split into SEGMENTS at each monotonicity break. Break test
-- (tunable constants, kept here in staging): a sample < 80% of the previous AND at
-- least 5 percentage points lower. Reset-split segments are summed downstream in DAX
-- and MAY exceed 100% — reported as-is, never capped.
CREATE VIEW staging.stg_utilization_segments AS
WITH samples AS (
    SELECT
        u.user_email,
        u.usage_window AS window_type,
        u.ts,
        u.value AS util_pct,
        date_bin(
            INTERVAL '5 minutes',
            u.ts + make_interval(secs => r.value),
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        ) AS window_end
    FROM raw.metrics AS u
    INNER JOIN raw.metrics AS r
        ON
            r.metric_name = 'claude_code.usage.reset_in_seconds'
            AND r.user_email IS NOT DISTINCT FROM u.user_email
            AND r.usage_window IS NOT DISTINCT FROM u.usage_window
            AND u.ts = r.ts
    WHERE
        u.metric_name = 'claude_code.usage.utilization'
        AND u.value_kind = 'gauge_last'
),

flagged AS (
    SELECT
        samples.*,
        lag(samples.util_pct) OVER w AS prev_pct
    FROM samples
    WINDOW w AS (PARTITION BY user_email, window_type, window_end ORDER BY ts)
)

SELECT
    user_email,
    window_type,
    window_end,
    ts,
    util_pct,
    1 + sum(
        CASE
            WHEN prev_pct IS NOT NULL AND util_pct < 0.8 * prev_pct AND prev_pct - util_pct >= 5
                THEN 1
            ELSE 0
        END
    ) OVER (PARTITION BY user_email, window_type, window_end ORDER BY ts) AS segment_no
FROM flagged;

-- fact_usage_window: user × window_type × window_end × segment_no. end_pct (utilization at
-- segment close) is the headline measure; peak_pct/pace expose burn behaviour.
CREATE MATERIALIZED VIEW marts.fact_usage_window AS
WITH seg AS (
    SELECT
        user_email,
        window_type,
        window_end,
        segment_no,
        min(ts) AS first_sample_ts,
        max(ts) AS last_sample_ts,
        count(*) AS sample_count,
        (array_agg(util_pct ORDER BY ts DESC))[1] AS end_pct,
        max(util_pct) AS peak_pct,
        (array_agg(ts ORDER BY util_pct DESC, ts ASC))[1] AS peak_ts
    FROM staging.stg_utilization_segments
    GROUP BY user_email, window_type, window_end, segment_no
)

SELECT
    user_email,
    window_type,
    window_end,
    segment_no,
    end_pct,
    peak_pct,
    peak_ts,
    first_sample_ts,
    last_sample_ts,
    sample_count,
    window_end - CASE window_type
        WHEN '5h' THEN INTERVAL '5 hours'
        WHEN '7d' THEN INTERVAL '7 days'
        ELSE INTERVAL '0'
    END AS window_start,
    max(segment_no) OVER (PARTITION BY user_email, window_type, window_end) > 1
        AS is_reset_split,
    peak_pct / nullif(extract(EPOCH FROM (peak_ts - first_sample_ts)) / 3600.0, 0)
        AS pace_pct_per_hour
FROM seg;

CREATE UNIQUE INDEX fact_usage_window_pk ON marts.fact_usage_window
(user_email, window_type, window_end, segment_no);

-- fact_utilization_hourly: user × window × hour, avg/max utilization — the time-of-day
-- burn heatmap. reset_in_seconds is otherwise dropped from marts (a countdown, meaningless
-- once aggregated).
CREATE MATERIALIZED VIEW marts.fact_utilization_hourly AS
SELECT
    user_email,
    window_type,
    date_trunc('hour', ts) AS hour,
    avg(util_pct) AS avg_pct,
    max(util_pct) AS max_pct
FROM staging.stg_utilization_segments
GROUP BY user_email, window_type, date_trunc('hour', ts);

CREATE UNIQUE INDEX fact_utilization_hourly_pk ON marts.fact_utilization_hourly
(user_email, window_type, hour);

-- migrate:down

DROP MATERIALIZED VIEW IF EXISTS marts.fact_utilization_hourly;
DROP MATERIALIZED VIEW IF EXISTS marts.fact_usage_window;
DROP VIEW IF EXISTS staging.stg_utilization_segments;
