#!/usr/bin/env bash
# Apply migrations and regenerate db/schema.sql against a throwaway Postgres.
#
# Owns the schema-drift verdict (#225): with --check, after regeneration it
# normalizes the `-- Dumped ...` version-comment lines on both the committed
# (HEAD) and regenerated dump, diffs, and exits nonzero on drift — the CI
# schema-drift job and local-gate.sh both run this same call. An ephemeral
# `postgres:16` container, dbmate up, dump via `pg_dump 17`. Authoring against
# a from-zero container — instead of the persistent Azure dev DB — means
# "green locally" equals "green in CI": no drift from accumulated state, no
# Azure firewall dance. Requires dbmate + pg_dump 17 on PATH (already needed
# to produce a CI-matching dump) and a running Docker daemon.
#
# Usage: scripts/dev-migrate.sh [--check]   (run from anywhere; cds to repo root)
#
#   --check  diff the regenerated dump against HEAD (pg_dump version comments
#            normalized); exit 1 on drift, leaving the regenerated dump in the
#            tree — that IS the fix: commit it.
set -euo pipefail

cd "$(dirname "$0")/.."

NAME=cc-otel-dev-migrate

die() { echo "error: $*" >&2; exit 1; }

CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  "") ;;
  *) die "unknown argument: $1 (usage: scripts/dev-migrate.sh [--check])" ;;
esac
[ $# -le 1 ] || die "unexpected extra arguments: ${*:2} (usage: scripts/dev-migrate.sh [--check])"

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

if [ "$CHECK" = 1 ]; then
  # The two `-- Dumped ...` lines vary by toolchain minor and are normalized
  # before the structural diff (mirrored from the retired CI norm() step).
  norm() { sed -E 's/^-- Dumped (from database version|by pg_dump version).*/-- Dumped <normalized>/'; }
  if ! diff -u <(git show HEAD:db/schema.sql | norm) <(norm < db/schema.sql); then
    die "db/schema.sql is out of date — the regenerated dump is left in the tree; commit it."
  fi
  echo "db/schema.sql matches the migrations (version comments normalized)."
else
  echo "db/schema.sql regenerated. Review 'git diff db/schema.sql' and commit it."
fi
