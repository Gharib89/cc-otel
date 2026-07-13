-- migrate:up

-- Power BI reader grants (#19): the semantic model reads the marts schema only (#10).
-- The reader is the existing cc_otel_read group role (created in the schemas/roles
-- migration, whose comment already anticipated "marts SELECT added" here). No dedicated
-- Power-BI-only role is introduced — #9/#10 never name one, and reusing the established
-- read-consumer role keeps grants in one place.
--
-- ALL TABLES IN SCHEMA covers the matviews and the two ops tables; ALTER DEFAULT
-- PRIVILEGES keeps future marts objects readable without another grant migration.
GRANT USAGE ON SCHEMA marts TO cc_otel_read;
GRANT SELECT ON ALL TABLES IN SCHEMA marts TO cc_otel_read;

ALTER DEFAULT PRIVILEGES IN SCHEMA marts GRANT SELECT ON TABLES TO cc_otel_read;

-- migrate:down

ALTER DEFAULT PRIVILEGES IN SCHEMA marts REVOKE SELECT ON TABLES FROM cc_otel_read;
REVOKE SELECT ON ALL TABLES IN SCHEMA marts FROM cc_otel_read;
REVOKE USAGE ON SCHEMA marts FROM cc_otel_read;
