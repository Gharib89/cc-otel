# POC -> interim backfill (#131, ADR-0006)

One-shot, operator-run backfill of the POC's ~6 weeks of Claude Code telemetry
into the **interim** `raw.metrics` / `raw.events`, mapped into schema-v2 exactly as the
current sink would have written it. Interim-only; production still starts fresh
(ADR-0002, superseded here for interim only by [ADR-0006](../../docs/adr/0006-interim-poc-backfill.md)).

**Already run, and no longer runnable as written**: its source server was archived and
deleted on 2026-07-28 (ADR-0016). Kept as the record of how interim's pilot history got
there; a re-run would first restore the dump from the prod `archive` container.

This is **not** part of CI or any deploy — it is a manual operation with a verification
gate. The mapping SQL is unit-tested (`tests/integration/test_backfill.py`); the transport,
staging lifecycle, and `refresh_all()` are covered by the gate below.

## What it does

- **Window:** `2026-05-24` (first clean all-`sum_delta` day) .. `2026-07-16` (POC last day), inclusive.
- **Scope filter:** drops `github.copilot` metrics and `com.anthropic.claude_code.tracing`
  events (ADR-0001); keeps `com.anthropic.claude_code*`, `cc-otel.statusline`, and null-scope rows.
- **Domain filter (#162):** drops rows whose `user_email` has a non-itworx domain (matched
  case-/whitespace-insensitively via `lower(trim(user_email))`); keeps itworx and
  null-`user_email` rows. So a rerun cannot reintroduce the non-itworx rows the one-shot purge
  below removed.
- **Mapping:** POC schema-v1 -> schema-v2 — same-named columns 1:1, `token_type`->`type_label`,
  `usage_window`/`source` and the event agent/plugin/marketplace/mcp/decision columns lifted
  out of `attrs`; `attrs`/`resource` JSONB dropped. See `sql/map_metrics.sql`, `sql/map_events.sql`.
- **Dedup:** any POC row whose `session_id` already exists in interim `raw` (metrics ∪ events,
  snapshotted before the load) is dropped — drops exactly the cutover sessions that dual-sent.
  Null-`session_id` rows are kept.
- **Idempotent:** claims `poc-backfill:interim:v1` in `meta.processed_batches`; a second run no-ops.
- **No PII on disk:** a client-side `COPY ... TO STDOUT` | `\copy ... FROM STDIN` pipe.

## Run

```sh
export POC_DATABASE_URL='postgres://.../otel?sslmode=require'       # POC schema-v1 source
export INTERIM_DATABASE_URL='postgres://.../cc_otel?sslmode=require' # interim schema-v2 target
scripts/backfill/backfill.sh
psql "$INTERIM_DATABASE_URL" -c 'SELECT marts.refresh_all()'
```

The load prints the inserted row counts and the overlap-complement session list
(`>= 2026-07-14`) — **record that list**; it is part of the rollback predicate below.

## One-shot purge of non-itworx emails (#162)

The initial backfill (before the domain filter above) carried non-itworx-domain emails into
interim. `sql/purge_non_itworx.sql` deletes those rows from `raw.metrics` / `raw.events` in one
transaction (NULL emails kept -- covered by the `unknown_email` DQ finding) and logs a
`non_itworx_email_purge` `marts.dq_finding` row with the total row count and the distinct domains
purged (domains, not full emails). Both purge records land as `kind = 'gauge'` (#396): a completed
purge is a historical record that never drains, so the DQ card must not carry it as a defect it can
never work off. It is scoped to the **backfill window** (`ts` / `event_time`
`< 2026-07-14`, the same backfill-vs-live cutoff as the Rollback section below), so live
non-itworx rows are left untouched, and the itworx domain is matched case-/whitespace-insensitively
(`lower(trim(user_email))`) so a mixed-case ITWORX address is never wrongly deleted. Run once
against interim, locally, then refresh so the staging views + marts matviews (all rebuilt from raw)
drop the derived rows too:

```sh
psql "$INTERIM_DATABASE_URL" -f scripts/backfill/sql/purge_non_itworx.sql   # prints deleted counts
psql "$INTERIM_DATABASE_URL" -c 'SELECT marts.refresh_all()'
```

Verify (backfill window only): both of
`SELECT count(*) FROM raw.metrics WHERE lower(trim(user_email)) NOT LIKE '%@itworx.com' AND ts < DATE '2026-07-14'`
and the `raw.events` / `event_time` equivalent return 0, and the `non_itworx_email_purge` DQ
finding row is present.

## One-shot purge of empty (NULL) user_email rows (#216)

Follow-up to #214, and the complement of the non-itworx purge above (which kept NULL emails). The
backfill carried POC rows that never resolved an email; #214 buckets them into dim_user's visible
`'(unknown)'` member so the volume can be judged first. Once that volume is confirmed stale POC
backfill (**#216 re-entry: Ahmed has reviewed the `'(unknown)'` bucket in the report**),
`sql/purge_empty_user.sql` deletes the `user_email IS NULL` rows from `raw.metrics` / `raw.events`
in one transaction and logs an `empty_user_purge` `marts.dq_finding`. Scoped to the same
**backfill window** (`ts` / `event_time` `< 2026-07-14`), so live NULL-email rows are left
untouched. Run once against interim, locally, then refresh:

```sh
psql "$INTERIM_DATABASE_URL" -f scripts/backfill/sql/purge_empty_user.sql   # prints deleted counts
psql "$INTERIM_DATABASE_URL" -c 'SELECT marts.refresh_all()'
```

Verify (backfill window only): both of
`SELECT count(*) FROM raw.metrics WHERE user_email IS NULL AND ts < DATE '2026-07-14'`
and the `raw.events` / `event_time` equivalent return 0, and the `empty_user_purge` DQ finding row
is present.

## Verification gate (run after load + refresh_all)

1. `raw.metrics` / `raw.events` grew by the printed filtered POC counts (expected vs actual).
2. The cutover sessions appear once (not doubled).
3. Coverage spans `2026-05-24` -> today (the `2026-05-26..05-31` gap is expected — nobody emitted).
4. `fact_usage_window` / `fact_utilization_hourly` now hold historical rows.
5. `refresh_all()` logged the `cumulative_value_kind` DQ count with no unexpected
   `multi_email` / `unknown_email` spike.
6. Spot-check one POC user (e.g. riham): a day's commits/LOC/tokens match POC source vs interim mart.

## Rollback (disposable interim; no `raw` schema change)

Backfilled rows are everything before the overlap plus the printed overlap sessions.

> **Assumption:** interim's own live telemetry starts `2026-07-14` (the staggered-rollout
> start), so the `< 2026-07-14` predicate deletes only backfilled rows. If live interim data
> ever predates that date, raise the cutoff to interim's true first-live day before running
> the `DELETE` — otherwise it would remove legitimate live rows.

```sql
DELETE FROM raw.metrics
 WHERE ts < DATE '2026-07-14' OR session_id = ANY('{<printed session list>}'::uuid[]);
DELETE FROM raw.events
 WHERE event_time < DATE '2026-07-14' OR session_id = ANY('{<printed session list>}'::uuid[]);
DELETE FROM meta.processed_batches WHERE batch_hash = 'poc-backfill:interim:v1';
SELECT marts.refresh_all();
```
