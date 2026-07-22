-- migrate:up

-- #172: a wrapper glitch can emit claude_code.usage.reset_in_seconds far beyond
-- the largest window's countdown (7d = 604800s). window_end = ts + reset then
-- lands centuries in the future (observed: reset 8.2e9 -> year 2286), polluting
-- fact_usage_window and wrecking any time axis built over it. Reject samples
-- whose reset is out of range; the daily refresh then drops the stale far-future
-- rows. CREATE OR REPLACE keeps the dependent matviews in place (columns unchanged).
CREATE OR REPLACE VIEW staging.stg_utilization_segments AS
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
        AND r.value BETWEEN 0 AND 604800
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

-- migrate:down

CREATE OR REPLACE VIEW staging.stg_utilization_segments AS
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
