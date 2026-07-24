-- Canonical definition for marts.fact_usage_window.
-- Source of truth for the mart body; edit here, then regenerate the migration:
--   uv run python -m tools.matview_sync --name fact_usage_window
-- Verified against pg_matviews.definition by --check (CI + local gate).
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
   FROM seg;

CREATE UNIQUE INDEX fact_usage_window_pk ON marts.fact_usage_window USING btree (user_email, window_type, window_end, segment_no);

GRANT SELECT ON marts.fact_usage_window TO cc_otel_read;
