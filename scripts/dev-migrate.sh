#!/usr/bin/env bash
# Apply migrations and regenerate db/schema.sql against a throwaway Postgres.
#
# Mirrors the CI schema-drift gate (.github/workflows/integration.yml) byte-for-
# byte: an ephemeral `postgres:16` container, dbmate up, dump via `pg_dump 17`.
# Authoring against a from-zero container — instead of the persistent Azure dev
# DB — means "green locally" equals "green in CI": no drift from accumulated
# state, no Azure firewall dance. Requires dbmate + pg_dump 17 on PATH (already
# needed to produce a CI-matching dump) and a running Docker daemon.
#
# Usage: scripts/dev-migrate.sh   (run from anywhere; cds to repo root)
set -euo pipefail

cd "$(dirname "$0")/.."

NAME=cc-otel-dev-migrate

die() { echo "error: $*" >&2; exit 1; }

command -v dbmate >/dev/null 2>&1 \
  || die "dbmate not found on PATH — see https://github.com/amacneil/dbmate (pin v2.34.1 to match CI)"
command -v pg_dump >/dev/null 2>&1 \
  || die "pg_dump not found on PATH — install PostgreSQL client 17"
pgd_major=$(pg_dump --version | grep -oE '[0-9]+' | head -1)
[ "$pgd_major" = "17" ] \
  || die "pg_dump is version $pgd_major, CI dumps with 17 — a mismatch drifts schema.sql. Put pg_dump 17 first on PATH."
docker info >/dev/null 2>&1 || die "Docker daemon not reachable — start Docker Desktop."

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup  # clear any stale container from a prior interrupted run

# postgres:16 matches the CI service image; host port is auto-assigned to dodge
# clashes with a local Postgres on 5432.
docker run -d --name "$NAME" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=cc_otel \
  -p 127.0.0.1::5432 \
  postgres:16 >/dev/null

port=$(docker port "$NAME" 5432 | head -1 | sed 's/.*://')
[ -n "$port" ] || die "could not resolve the container's mapped port"
export DATABASE_URL="postgres://postgres:postgres@127.0.0.1:${port}/cc_otel?sslmode=disable"

# Poll a real query (not just pg_isready, which flaps during image init).
for _ in $(seq 1 30); do
  if docker exec "$NAME" psql -U postgres -d cc_otel -c 'select 1' >/dev/null 2>&1; then
    ready=1; break
  fi
  sleep 1
done
[ "${ready:-}" = "1" ] || die "Postgres did not become ready within 30s"

# dbmate up applies every migration and regenerates db/schema.sql (defaults:
# db/migrations, db/schema.sql).
dbmate up

echo "db/schema.sql regenerated. Review 'git diff db/schema.sql' and commit it."
