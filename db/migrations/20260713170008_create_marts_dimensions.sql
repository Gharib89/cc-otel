-- migrate:up

-- Dimensions (#9): 3 conformed dims. All are materialized views refreshed hourly
-- (marts.refresh_all); each has a unique index so REFRESH ... CONCURRENTLY can run.
-- Org attributes are deliberately absent — they join in from an Azure SQL employee
-- dataset inside the Power BI model, related on normalized email (#9).

-- dim_user: one row per normalized developer identity. Null-email rows collapse to a
-- single '(unknown)' member (an install-health signal, never dropped).
CREATE MATERIALIZED VIEW marts.dim_user AS
WITH seen AS (
    SELECT user_email, user_account_id, organization_id, cc_version, ts AS seen_at
    FROM raw.metrics
    UNION ALL
    SELECT user_email, user_account_id, organization_id, cc_version, event_time
    FROM raw.events
)
SELECT
    COALESCE(user_email, '(unknown)') AS user_email,
    user_email IS NULL AS is_unknown,
    MIN(seen_at) AS first_seen,
    MAX(seen_at) AS last_seen,
    (ARRAY_AGG(user_account_id) FILTER (WHERE user_account_id IS NOT NULL))[1]
        AS user_account_id,
    (ARRAY_AGG(organization_id) FILTER (WHERE organization_id IS NOT NULL))[1]
        AS organization_id,
    (ARRAY_AGG(cc_version ORDER BY seen_at DESC) FILTER (WHERE cc_version IS NOT NULL))[1]
        AS last_cc_version
FROM seen
GROUP BY COALESCE(user_email, '(unknown)'), user_email IS NULL;

CREATE UNIQUE INDEX dim_user_pk ON marts.dim_user (user_email);

-- dim_date: calendar spanning the earliest observed signal → present (#15: no raw
-- trim, so the range only grows). CURRENT_DATE is re-evaluated each refresh.
CREATE MATERIALIZED VIEW marts.dim_date AS
WITH bounds AS (
    SELECT COALESCE(
        LEAST(
            (SELECT MIN(ts)::date FROM raw.metrics),
            (SELECT MIN(event_time)::date FROM raw.events)
        ),
        CURRENT_DATE
    ) AS start_day
)
SELECT
    d::date AS date_day,
    EXTRACT(YEAR FROM d)::int AS year,
    EXTRACT(QUARTER FROM d)::int AS quarter,
    EXTRACT(MONTH FROM d)::int AS month,
    TO_CHAR(d, 'Mon') AS month_name,
    EXTRACT(DAY FROM d)::int AS day_of_month,
    EXTRACT(ISODOW FROM d)::int AS iso_dow,
    TO_CHAR(d, 'Dy') AS day_name,
    EXTRACT(ISODOW FROM d) >= 6 AS is_weekend,
    EXTRACT(WEEK FROM d)::int AS iso_week
FROM bounds, generate_series(bounds.start_day, CURRENT_DATE, INTERVAL '1 day') AS d;

CREATE UNIQUE INDEX dim_date_pk ON marts.dim_date (date_day);

-- dim_model: one row per model id seen, parsed into family / version / long-context.
CREATE MATERIALIZED VIEW marts.dim_model AS
WITH ids AS (
    SELECT model FROM raw.metrics WHERE model IS NOT NULL
    UNION
    SELECT model FROM raw.events WHERE model IS NOT NULL
)
SELECT
    model AS model_id,
    CASE
        WHEN model ILIKE '%opus%' THEN 'opus'
        WHEN model ILIKE '%sonnet%' THEN 'sonnet'
        WHEN model ILIKE '%haiku%' THEN 'haiku'
        WHEN model ILIKE '%fable%' THEN 'fable'
        ELSE 'other'
    END AS family,
    regexp_replace(
        regexp_replace(model, '\[1m\]$', ''),
        '^claude-(opus|sonnet|haiku|fable)-', ''
    ) AS version,
    model LIKE '%[1m]%' AS is_long_context
FROM ids;

CREATE UNIQUE INDEX dim_model_pk ON marts.dim_model (model_id);

-- migrate:down

DROP MATERIALIZED VIEW IF EXISTS marts.dim_model;
DROP MATERIALIZED VIEW IF EXISTS marts.dim_date;
DROP MATERIALIZED VIEW IF EXISTS marts.dim_user;
