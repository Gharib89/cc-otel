-- migrate:up

-- Two cross-cutting mart rules, previously duplicated as string literals across
-- mart bodies, extracted into shared scalar functions (#264, decided in #254).
-- Declared IMMUTABLE PARALLEL SAFE with single-expression BEGIN ATOMIC bodies so
-- PG16 inlines them into each mart's plan at REFRESH time — refresh cost is
-- identical to the hand-inlined SQL. A future rule change (e.g. also treating
-- '@itworx.co' as internal) is a body-only CREATE OR REPLACE picked up at the
-- next refresh, with no mart DROP+CREATE. Deliberately NOT STRICT: email_bucket
-- must map a NULL argument to '(unknown)', and prefer_itworx must fall through to
-- COALESCE when an argument is NULL.

CREATE OR REPLACE FUNCTION marts.email_bucket(email text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
BEGIN ATOMIC
    SELECT COALESCE(email, '(unknown)'::text);
END;

CREATE OR REPLACE FUNCTION marts.prefer_itworx(a text, b text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
BEGIN ATOMIC
    SELECT CASE
        WHEN a ~~ '%@itworx.com'::text THEN a
        WHEN b ~~ '%@itworx.com'::text THEN b
        ELSE COALESCE(a, b)
    END;
END;

-- migrate:down

DROP FUNCTION IF EXISTS marts.prefer_itworx(text, text);
DROP FUNCTION IF EXISTS marts.email_bucket(text);
