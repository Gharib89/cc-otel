#!/usr/bin/env bash
# One-shot backfill of mapped POC pilot history into interim raw.* (#131, ADR-0006).
#
# Streams the POC otel metrics/events, mapped to schema-v2, straight into interim over a
# client-side pipe -- no temp files, no PII on disk, no server-side extensions. The load
# is scope-filtered (Claude Code only), deduped against live interim sessions, idempotent
# (a meta.processed_batches sentinel), and reversible (see README.md for the rollback).
#
# Run from an operator box that can reach BOTH databases. Requires:
#   POC_DATABASE_URL      -- POC otel (schema-v1 source; the sibling `otel` db)
#   INTERIM_DATABASE_URL  -- interim cc_otel (schema-v2 target)
# Usage: POC_DATABASE_URL=... INTERIM_DATABASE_URL=... scripts/backfill/backfill.sh
set -euo pipefail

: "${POC_DATABASE_URL:?set POC_DATABASE_URL to the POC otel connection string}"
: "${INTERIM_DATABASE_URL:?set INTERIM_DATABASE_URL to the interim cc_otel connection string}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sql="$here/sql"

echo "==> creating runtime staging (backfill_stg) on interim"
psql "$INTERIM_DATABASE_URL" -v ON_ERROR_STOP=1 -q \
    -c "DROP SCHEMA IF EXISTS backfill_stg CASCADE" \
    -f "$sql/00_staging.sql"

echo "==> streaming mapped metrics POC -> interim.backfill_stg.metrics"
psql "$POC_DATABASE_URL" -v ON_ERROR_STOP=1 -q \
    -c "COPY ($(cat "$sql/map_metrics.sql")) TO STDOUT" \
    | psql "$INTERIM_DATABASE_URL" -v ON_ERROR_STOP=1 -q \
        -c "\copy backfill_stg.metrics FROM STDIN"

echo "==> streaming mapped events POC -> interim.backfill_stg.events"
psql "$POC_DATABASE_URL" -v ON_ERROR_STOP=1 -q \
    -c "COPY ($(cat "$sql/map_events.sql")) TO STDOUT" \
    | psql "$INTERIM_DATABASE_URL" -v ON_ERROR_STOP=1 -q \
        -c "\copy backfill_stg.events FROM STDIN"

echo "==> filtered, deduped, idempotent load into interim raw.*"
psql "$INTERIM_DATABASE_URL" -v ON_ERROR_STOP=1 -f "$sql/load.sql"

echo "==> dropping runtime staging"
psql "$INTERIM_DATABASE_URL" -v ON_ERROR_STOP=1 -q \
    -c "DROP SCHEMA IF EXISTS backfill_stg CASCADE"

echo "==> done. Now run SELECT marts.refresh_all() on interim, then the README verification gate."
