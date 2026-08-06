# Curation & ops tooling — operator runbook

Ten command-line tools for curating and operating the redacted-blob reservoir (the
`raw` container), the column registry, the seat-roster reference data, the interim -> prod
cutover copy (both halves — Postgres rows and reservoir blobs), and the **front-door silence**
measurement that gates retiring an environment (ADR-0027). They are
**manual / on-demand** — never wired into CI or the sink. This is the human operator guide;
the agent-facing curation workflow lives in
[`docs/agents/column-curation.md`](../docs/agents/column-curation.md).

| tool | what it does | destructive? |
|---|---|---|
| `tools.sweep` | list blob attribute key paths not yet in the column registry (+ redaction leaks) | no |
| `tools.basis_drift` | re-check every `kept` classification's **kept basis** against a recent window | no |
| `tools.gen_data_dictionary` | regenerate `docs/data-dictionary.md` from Postgres + the registry | no |
| `tools.scrub` | re-redact a window of blobs **in place** after a new `denied` classification | **yes** (overwrites blobs) |
| `tools.replay` | rebuild a window of raw → staging → marts by re-POSTing blobs through the sink | **yes** (deletes raw rows, re-POSTs) |
| `tools.compact` | collapse each frozen reservoir partition into one parquet in the `compacted` container | no (writes only the derived container) |
| `tools.roster_load` | land an IS seat-roster drop as an immutable dated snapshot in `ref` | **yes** (writes HR data) |
| `tools.cutover_copy` | copy interim's pre-flip `raw` telemetry into production, bounded per seat by the flip watermark | **yes** (writes production telemetry; never deletes) |
| `tools.reservoir_copy` | copy interim's reservoir blobs from the cutover floor up into production's `raw` container, same paths | **yes** (writes production blobs; never deletes) |
| `tools.front_door` | count requests per UTC day at an environment's **front door**, split by status code — the **front-door silence** measurement | no (reads one Azure metric) |

## Prerequisites

1. **`uv sync`** — installs the workspace so `uv run python -m tools.<name>` resolves.
2. **`az login`** — the blob tools authenticate off your `az` session via
   `DefaultAzureCredential`: `scrub` / `replay` use it directly; `sweep` and `basis_drift`
   fetch one token from it and hand that to DuckDB's Azure extension (`access_token`
   provider); `compact`
   does both (DuckDB reads raw, the SDK writes the parquet). Log in as an identity that holds
   the RBAC below on the storage account.
3. **Environment** — the tools read the same settings the sink uses. Export or put in `.env`:

   | var | needed by | value |
   |---|---|---|
   | `DATABASE_URL` | sweep, basis_drift, gen_data_dictionary, replay, roster_load | Postgres connection string |
   | `INTERIM_DATABASE_URL` / `PROD_DATABASE_URL` | cutover_copy | the two environments' `cc_otel` connection strings — it needs both at once, so it reads its own pair rather than the ambient `DATABASE_URL` |
   | `INTERIM_BLOB_ACCOUNT_URL` / `PROD_BLOB_ACCOUNT_URL` | reservoir_copy | the two environments' storage-account URLs, same reason — copy `CC_OTEL_BLOB_ACCOUNT_URL` out of `.env.interim` and `.env.prod` |
   | `AZURE_SUBSCRIPTION_ID` / `RESOURCE_GROUP` | front_door | the target environment's own pair — `set -a; . ./.env.interim; set +a`. Neither has a default: interim lives in the **VS Enterprise** subscription, not your `az` default, so a guess would measure the wrong front door and report silence |
   | `CC_OTEL_BLOB_ACCOUNT_URL` | sweep, basis_drift, scrub, replay, compact | `https://<account>.blob.core.windows.net` |
   | `CC_OTEL_BLOB_CONTAINER` | sweep, basis_drift, scrub, replay, compact | container name (default `raw`) |
   | `CC_OTEL_BLOB_COMPACTED_CONTAINER` | compact, basis_drift | the derived container, `compacted` (ADR-0015); unset ⇒ `compact` refuses to run, and `basis_drift` reads raw throughout (~30x slower) |

   `.env.interim` already carries `CC_OTEL_BLOB_ACCOUNT_URL`, `CC_OTEL_BLOB_CONTAINER` and
   `CC_OTEL_BLOB_COMPACTED_CONTAINER`.
   A `CC_OTEL_BLOB_CONNECTION_STRING` may be set instead of the account URL to bypass
   `az login` (key-based auth); the account URL + `az login` path is preferred.

### Blob RBAC per tool

Grant the role on the storage account (or the named container) to the identity you logged in as with `az login`:

| tool | blob role | why |
|---|---|---|
| `tools.sweep` | **Storage Blob Data Reader** | reads blobs via DuckDB |
| `tools.basis_drift` | **Storage Blob Data Reader** on `raw` + `compacted` | reads both via DuckDB (prefers the parquet) |
| `tools.gen_data_dictionary` | *(none — Postgres only)* | never touches blobs |
| `tools.replay` | **Storage Blob Data Reader** | downloads blobs to re-POST; never rewrites them |
| `tools.scrub` | **Storage Blob Data Contributor** | overwrites blobs in place |
| `tools.compact` | **Storage Blob Data Reader** on `raw` + **Storage Blob Data Contributor** on `compacted` | reads raw via DuckDB, writes only the derived container |
| `tools.roster_load` | *(none — Postgres only)* | never touches blobs (ADR-0009 keeps no file copy) |
| `tools.cutover_copy` | *(none — Postgres only)* | the reservoir half of the cutover is `tools.reservoir_copy` (#246) |
| `tools.reservoir_copy` | **Storage Blob Data Reader** on interim `raw` + **Storage Blob Data Contributor** on production `raw` | downloads interim's blobs and uploads them to production under the same names; interim is only ever read |
| `tools.front_door` | *(none — no blob or Postgres access)* | needs **Monitoring Reader** on the resource group instead; it shells out to `az monitor metrics list` and reads nothing else |

> Progress: sweep / basis_drift / scrub / replay / compact / reservoir_copy print a throttled `label: n[/total]` line to **stderr**
> every ~2s over long windows so a big run is visibly alive. stdout stays pipe-clean.

## `tools.sweep` — find unclassified keys & redaction leaks

Reads a recent blob window, extracts every attribute key path, and diffs against
`meta.column_registry`.

```sh
uv run python -m tools.sweep --days 7
uv run python -m tools.sweep --since 2026-07-01 --until 2026-07-07 --signal logs
```

**Reading the report** (stdout):

- **Unclassified keys** — key paths with no registry row. Each must be classified
  `promoted` / `kept` / `denied` in a migration (see the curation workflow doc).
- **Redaction leaks** — keys classified `denied` yet still present in a redacted blob. A
  non-empty list means the sink's redaction missed one — investigate (#8), then `scrub`.

Both empty = the window is fully curated and clean.

`sweep` only sees **unclassified** keys — a `kept` key never resurfaces there however far its
distribution drifts. That is what `basis_drift` is for.

## `tools.basis_drift` — re-check the `kept` classifications

Every `kept` registry row carries a **kept basis** (`meta.column_registry.kept_basis`): why the
key is kept rather than promoted. Two of the five carry no machine predicate; the other three are claims
about observed data that a fleet change can invalidate, and this re-derives them from a recent
window. Nothing is stored as a baseline — a number recorded today is the exact staleness this
tool exists to catch.

```sh
uv run python -m tools.basis_drift --days 7
uv run python -m tools.basis_drift --since 2026-07-18 --until 2026-07-28
```

| basis | predicate | drift means |
|---|---|---|
| `nature` | *(never evaluated)* | identity or unbounded cardinality — cannot drift |
| `constant` | cardinality of **present** values `== 1` | a second distinct value appeared |
| `collinear` | `basis_partner` → key functional dependency, **counting absence as a value** | some partner-value group holds ≥ 2 distinct values |
| `thin` | seats carrying the key `< 50%` of the window's reporting seats | the key reaches half the fleet |
| `redundant` | *(never evaluated)* | the claim is cross-grain, so no single record answers it — the argument lives in `notes` |

`constant` ignoring absence while `collinear` counts it is **deliberate**, not an oversight: it
is what lets one `collinear` rule cover both a value dependency (`os.type='windows'` →
`os.version='10.0.26200'`) and a presence dependency (`wsl.version` present iff
`os.type='linux'`).

**Exit code is the report**: `0` clean, `1` any drift — the repo's `--check` idiom, so a
scheduled routine can act on it without a rewrite. Drift is not a status change: if a key really
has drifted, that is a new ticket for the promotion flow, never an edit to its `kept` row in the
same PR.

> `thin` is **not evaluated** when the window has fewer than 10 reporting seats, and the run says
> so, naming the observed population. Both sides of the seat share shrink with the window, so 2
> seats of 4 reads 50% for a key that reaches one seat in twenty. `constant` and `collinear` need
> no such guard — they require a single counterexample, so a short window can miss drift but
> never invent it.

Not in CI, and deliberately not folded into `spec_sync --check`: it needs blob credentials and a
multi-minute window read, while `spec_sync --check` is definitional and needs no reservoir. What
*is* enforced everywhere is the registry CHECK — a new `kept` row without a basis fails its
migration.

## `tools.gen_data_dictionary` — regenerate the data dictionary

Reads Postgres (`raw.metrics` / `raw.events` + `meta.column_registry`) — no blob access.

```sh
uv run python -m tools.gen_data_dictionary          # -> writes docs/data-dictionary.md
uv run python -m tools.gen_data_dictionary --out -  # -> stdout (preview / diff)
```

Regenerate and commit as part of a promotion PR so the committed dictionary never drifts.

## `tools.scrub` — re-redact blobs after a new deny (destructive)

When a key is newly classified `denied`, blobs written before that decision still hold it.
`scrub` rewrites each blob in the window through the sink's own `redact`.

**Safety flow — dry-run first, always:**

```sh
uv run python -m tools.scrub --days 30                                  # dry-run: counts only
uv run python -m tools.scrub --since 2026-06-01 --until 2026-06-30 --execute
```

Without `--execute` it only reports how many blobs it *would* rewrite (and any
defense-in-depth leaks seen). Confirm the count looks right, then re-run with `--execute`.

## `tools.compact` — collapse each frozen partition into one parquet

Reservoir reads cost ~22–31 s per full-day partition, and the driver is **file count, not
bytes** (#352): one partition's ~860 gzipped blobs read in 9.6 s with *zero* network. `compact`
writes one zstd parquet per `(signal, day)` — a single `json VARCHAR` payload column — into the
`compacted` container, and the analysis notebooks prefer it (ADR-0015). Measured: 1.63 MB and
~21 s to build a logs partition; fetch drops from 10–15 s to ~1 s.

**On demand, no schedule.** Past partitions are immutable — `blob.py` names each blob from
ingest wall-clock UTC, so nothing ever arrives late into a past `dt=` — which makes compaction a
once-per-partition-ever job with no drift to correct, only a backlog to catch up. The default
target is therefore *every* partition with `dt < today` and no counterpart, so one run catches
up whatever is missing no matter when it last ran. Today's partition is never compacted (it is
still growing); the read path falls back to `raw` for it.

```sh
uv run python -m tools.compact                     # dry-run: lists the catch-up plan
uv run python -m tools.compact --execute           # build + upload the missing partitions
uv run python -m tools.compact --signal logs --since 2026-07-20 --until 2026-07-22 --execute
```

Without `--execute` it prints only which partitions it *would* build, reading blob listings and
no blob content — building is the expensive half, so the dry run costs a couple of seconds.
`--since` / `--until` bound the discovered set; `--signal` restricts to one.

**`--rebuild` after a scrub.** `tools.scrub` rewrites raw blobs in place, so a compacted
partition built before a new `denied` classification still carries the denied key. Re-derive the
scrubbed window:

```sh
uv run python -m tools.compact --since <scrubbed-start> --until <scrubbed-end> --rebuild --execute
```

The container is declared in `iac/modules/storage.bicep` and never created by the tool, so a
fresh environment needs an infra deploy first — `bootstrap/bootstrap.ps1 -Environment <env> -Step
deploy`, the operator-run Bicep apply (`workflow_dispatch` covers the app/migration deploys, not
`iac/`) — and until then `compact` exits 2 naming that step. Deleting the whole container is safe — it is derived and rebuildable at ~21 s
per partition.

## `tools.replay` — rebuild a window through the sink (destructive)

Re-drives a window of blobs back through a **running sink** so `raw → staging → marts`
rebuild from the reservoir. Needs the sink reachable at `--sink-url`.

**Safety flow — dry-run first, always:**

```sh
uv run python -m tools.replay --since 2026-07-10 --until 2026-07-11               # dry-run
uv run python -m tools.replay --since 2026-07-10 --until 2026-07-11 \
    --execute --sink-url http://127.0.0.1:8080
```

Without `--execute` it reports the blob / hash / raw-row counts in the window and stops.
`--execute` deletes the window's raw rows + batch hashes, then re-POSTs every blob. Pick
the time window generously — raw rows are keyed by event time, so ingest-vs-event skew at
the edges is expected.

**Run the target sink with the reservoir unconfigured.** Unset `CC_OTEL_BLOB_ACCOUNT_URL` /
`CC_OTEL_BLOB_CONNECTION_STRING` on the *sink* process (the replay itself still needs them,
to read). A sink with blob settings writes a **new** blob per re-POST under *today's* `dt=`,
so a 18k-blob replay near-doubles the reservoir and poisons the compacted parquet
(ADR-0015). Nothing in the tool prevents this.

**A transient sink 5xx is retried, four times with backoff** (1/2/4/8 s). The sink answers 503
when its pool hands out a connection Postgres has already closed (`SSL error: unexpected eof
while reading`), and the next request opens a fresh one. Aborting there is the expensive
failure: the delete has already run, so a run that stops halfway leaves a bigger hole than it
came to close — three such aborts emptied event-day Jul 30 during #388. A 4xx still fails the
run immediately. If the retries are exhausted, re-run the whole pass; it deletes and re-POSTs
the window from scratch, so nothing depends on where the previous run stopped.

**One pass for the whole window, not a pass per day.** A day pass deletes event-day D but
re-POSTs partition `dt=D`, whose midnight-straddle records carry event-day **D-1** — rows the
delete never touched, so the pass duplicates them, and the neighbouring day's pass later
deletes them without restoring them (they live in a partition it does not read). Day passes
compose only in strictly ascending order, which serialises the slowest phase of the job; one
whole-range delete followed by every blob has no boundary to get wrong. ADR-0017 records the
~150 rows this cost when it was learned the other way round.

The whole-range delete is what races live ingest: a batch landing between the blob listing and
the delete loses its rows while its blob sits outside the re-POST set, and its ledger hash
survives, so a bare re-POST no-ops. Finish with a pass over the live day alone — first confirming
that partition carries no straddle from the previous day, or the repair reintroduces the boundary
bug. Repeating it converges to a floor, not to zero: each pass restores its predecessor's losses
and incurs its own, so the residual settles at about one pass-duration of ingest (69 metrics / 39
events in #379). Replaying the day once frozen is what closes the gap exactly.

**Measure before mutating** — the event-time delete and the `dt`-partition re-POST only line
up if the data says they do. ADR-0017 records the three checks a replay rests on (skew at the
window's outer edge *and* at each interior day boundary, blob-vs-raw row reconciliation per
day, and `sha256(gunzip(blob))` equal to the hash the sink re-claims) and what each rules out.

On Windows the sink cannot run natively — uvicorn's `ProactorEventLoop` is incompatible with
psycopg's async pool. Run the deployed image instead:
`docker run -d -p 8080:8080 -e CC_OTEL_SINK_HOST=0.0.0.0 -e DATABASE_URL=... ghcr.io/gharib89/cc-otel-sink:<sha>`,
and confirm `docker ps` shows `0.0.0.0:8080->8080/tcp` — an unpublished port plus a stray
local listener answers `/healthz` from the wrong process.

## `tools.roster_load` — land an IS seat-roster drop (destructive)

IS emails a roster CSV roughly every two weeks. Each file lands as one **roster drop**: a
registry row plus one immutable `ref.seat_roster_snapshot` observation per person per
subscription. Seat history is derived from all drops (ADR-0009), so drops arriving out of
order need no repair — and no copy of the file is kept, so keep the source emails.

Since the 2026-08-02 drop the file also carries `revoked_subscription_N` / `revoke_date_N`,
unpivoted into `revoked_subscription_raw` + `revoke_date` per sequence. They are
per-subscription **revocation events**, not a person-level status, so the truncation guards
below and closure-by-absence are unchanged; the revoke date only exact-dates a Claude seat's
close when the person is left holding no Claude subscription (ADR-0024).

**Safety flow — dry-run first, always:**

```sh
uv run python -m tools.roster_load --file ~/Downloads/claude_users_20260802.csv
uv run python -m tools.roster_load --file ~/Downloads/claude_users_20260802.csv \
    --execute --notes "IS email 2 Aug"
```

The first line of output is the resolved **target host and database** — check it before
anything else: the ambient `DATABASE_URL` names a live database — interim since the POC
delete (ADR-0016) — so the most natural invocation writes HR data into whichever
environment that variable happens to point at. Pass `--database-url` to override.

The as-of date is read from a `YYYYMMDD` run in the filename when there is one — the form IS's
export timestamp arrived in (#420) — and announced on its own line before anything consumes it;
`--as-of` is required otherwise, since the file carries no in-file timestamp and a filesystem
timestamp resets on copy. An explicit `--as-of` overrides the filename, and a name carrying two
different dates is treated as carrying none. However the date is resolved, it faces the same
refusals below.

The dry run then prints the delta against the newest existing drop — new seats, tier
changes, **closures**, unchanged. Closures are seats absent from this file; IS sends no status
column, so absence is revocation. Read that number before writing.

Refusals no flag overrides: byte-identical content already ingested, and an as-of earlier than
the newest assignment date in the file. Refusals `--force` overrides: an as-of duplicating or
preceding the newest drop, and the three truncation guards — row count down >10%, an
organization gone, a tier gone. Only force when you have confirmed the file is genuinely
smaller. If a bad drop does land, delete it (`DELETE FROM ref.roster_drop WHERE drop_id = …`,
snapshots cascade) and re-derive; history heals.

A successful write then refreshes `marts.dim_seat`, `marts.dim_seat_current`,
`marts.fact_seat_day` and `marts.dim_date`, so Power BI is current without waiting for the
hourly cycle; every other telemetry mart is left to `marts.refresh_all()`. `dim_date` is in the
list because its floor considers the earliest assignment date (#293), which this write can
move — a `fact_seat_day` row with no matching date row vanishes from every date-filtered
measure. A refresh failure is reported and does not fail the load: the drop is already
committed, and the hourly `marts.refresh_all()` reconciles.

## `tools.cutover_copy` — copy interim's pre-flip telemetry into production (destructive)

The raw half of the cutover data policy (#245, ADR-0020). Interim and production run the same
schema behind the same sink image, so this is an **identity copy** — no mapping layer, which is
why ADR-0002's ban on translated history does not apply. The reservoir half is
`tools.reservoir_copy` (#246, below).

A seat's **flip watermark** is `MIN(<event time>)` over that seat's *production* rows — the moment
its machine started emitting to prod. The copy moves interim rows in `[2026-07-17, watermark)` and
nothing else, **per table**, because the two tables name that column differently
(`raw.metrics.ts`, `raw.events.event_time`) and a seat can be flipped for one and not the other.

**Safety flow — dry-run first, always:**

```sh
export INTERIM_DATABASE_URL='postgres://.../cc_otel?sslmode=require'
export PROD_DATABASE_URL='postgres://.../cc_otel?sslmode=require'
uv run python -m tools.cutover_copy            # read-only: watermarks + what would move
uv run python -m tools.cutover_copy --execute
```

The first two lines name the resolved **source and target** host and database. Check them: the two
URLs differ by one word, and a swapped pair would copy production's telemetry back into interim.
A source and target resolving to the same host, port and database is refused outright, as is a
table whose column list differs between the environments — the copy names its columns explicitly,
so an interim-only column would otherwise be dropped silently.

**One `--execute` at a time.** It takes a session-level advisory lock on production for the length
of the run and refuses if another holds it. Two concurrent runs would both read the pre-copy
watermark and both copy the same rows, and those duplicates could not be removed afterwards —
`raw.*` has no primary key and this tool has no delete. A dry-run never takes the lock, so it stays
available while a copy is in flight.

**Re-run it as seats flip.** The flip is staggered (#244 closed at 4 of 18 seats), so a seat with
no production row yet has no watermark and is skipped; a later run picks it up. There is **no
delete step**: the one ADR-0020 first described is empty on every run by the definition of `MIN`
— no production row sits below that seat's own minimum — and idempotency comes from the watermark
itself, since a copied row *becomes* production's new minimum and collapses the next run's window
to `[floor, floor)`. That matters because `raw.*` has no primary key, so `ON CONFLICT` was never
available (ADR-0017).

Interim is never written to. It stays the fallback until #248 Part B's gate opens.

Each run reports what **stays** in interim per table: rows belonging to unflipped seats, rows at or
above a watermark (post-flip interim traffic from a Claude Code process that had not restarted
yet), and rows with no `user_email` to derive a seat from. #248 Part B's row-count-verified `pg_dump`
is the backstop for whatever never flips.

The at-or-above count is **not** a progress measure and does not fall to zero — nothing is deleted
from interim, so a copied row lands in that bucket forever once its seat's watermark collapses onto
it. Read the **cutover shortfall** below for that. (#245's original closure condition said the
opposite; corrected in #415.)

A seat whose watermark lands **at or below the floor** is named and dropped from the run: one
production row predating 2026-07-17 makes `[floor, watermark)` empty, so nothing is copyable and
leaving it in would let verification report the seat as matched on 0 == 0 while its interim rows sat
there. It needs a human look, not a re-run. A run also names any session that emitted to **both**
environments at once — ADR-0020 assumes one baked endpoint per machine and assigns detecting the
exception here. A session merely straddling the flip is not one of those, and is not reported.

**Accepted residual:** a batch arriving in interim *below* a seat's watermark after that seat was
copied is stranded — watermark collapse empties the re-run window, and ADR-0020 fixes the watermark
as derived, never recorded, so nothing can distinguish it. The exposure is **not** one flush
interval: the collector's sending queue is file-backed and survives restarts, so a replayed batch can
carry an event time hours old — one seat's arrived ~17 hours late after the ingest repoint and
collapsed its window to nothing (ADR-0021, amended by #415). What that costs is evidence rather than
rows, which is what the shortfall report restores.

**Every run reports the cutover shortfall per seat.** Per table, how many of interim's rows above the
floor production demonstrably lacks — `sum(max(interim - production, 0))` grouped by
`(user_email, UTC day)` — naming each seat and flagging the ones with no production row at all as
`--sweep` targets (#409):

```
raw.metrics not in production: 30640 row(s) above the floor across 15 seat(s)
  eman.abdelghany@itworx.com: 7165 of 7165 row(s) missing — no production rows at all (#409 --sweep target)
  hadeel.sharaf@itworx.com: 654 of 47600 row(s) missing
  (no user_email): 6 of 6 row(s) missing — never swept, no user_email to derive a seat from (ADR-0021)
```

Read this, not the held-in-interim buckets, to answer "what does the cutover still owe?". The
at-or-above count conflates rows already copied, rows a returning seat's collector replayed straight
into production, and rows genuinely missing; all three read the same. On 2026-08-04 that bucket read
303,283 metrics against an actual shortfall of 30,640.

The day grain is load-bearing: an active seat holds thousands *more* rows in production than in
interim (`ahmed.gharib`, 14,141 more), and a flat count would let that surplus absorb pre-flip rows
the copy missed. Grouping by day confines the overlap to the seat's flip day, making the figure a
lower bound. Counts, not row identities — `raw.*` has no primary key, so it says how many rows are
missing, never which. A detector, not a recovery cursor: a non-zero shortfall never fails a run,
because the residuals ADR-0021 accepts are permanently non-zero. A dry run describes the state as it
stands; `--execute` prints it after the commit, so it names what is still missing rather than rows
the run just delivered, and a rolled-back run prints no verdict at all.

Verification **gates the commit** rather than following it, against the watermarks captured before
the copy (by then production's own minimum has collapsed, so re-deriving them would compare empty
windows and pass vacuously): per-seat interim-vs-production counts over each seat's
`[floor, watermark)` window must match. A whole-window count comparison would not do — production
also holds its own #244 validation rows and post-flip rows inside the same window. On a mismatch
the whole run rolls back, nothing is refreshed, and it exits 1: a short copy that had been
committed would be permanent, because the copied rows collapse each seat's watermark and the
missing ones then fall outside every future run's window. Only a clean verification commits;
production's marts are refreshed after that, and a refresh failure is reported without failing the
copy, since the rows are in and the hourly `marts.refresh_all()` reconciles.

### `--sweep` — the terminal sweep for seats production has never seen (#409, ADR-0021)

Additive to the normal run, not a separate mode: pass `--sweep` alongside `--execute` (or on a
dry-run) and both ride in the same pass — every already-flipped seat's normal watermark-bounded
window copies exactly as above, and seats production has never recorded at all get one on top.

**The target set** is a seat interim holds rows for above the floor (`user_email IS NOT NULL`,
`ts`/`event_time` `>= 2026-07-17`) that is **absent from `watermarks()` entirely** — computed
before the below-floor filter drops anyone, because a below-floor seat *has* a production row and
so is already present in `watermarks()`; it can never be a sweep target, and the run's existing
"watermark at or below the floor" message gains a clause saying so. A seat with no `user_email` is
never swept, whatever the count — it has no seat identity to derive a target or a watermark
collapse from, so a re-run would copy it again into a table with no primary key (ADR-0017).

**The mechanism** is `timestamptz 'infinity'`, seeded into the same watermark scratch table
alongside the normal finite marks. Infinity compares greater than every finite timestamp, so the
census, the copy, per-seat verification, the rollback-on-mismatch path and the dual-send probe are
all correct with no second code path. Idempotent the same way the normal copy is: once swept, the
seat has a production row, so it is no longer absent from `watermarks()` and its next window is
`[floor, floor)`.

**Write-quiet gate, no override.** `--sweep` refuses (exit 1, nothing written, dry-run and
`--execute` alike) unless interim has gone `>= 24h` with no new batch, measured as
`now() - MAX(meta.processed_batches.processed_at)` on the **interim** connection — that column is
claimed by every batch that writes rows, so it is an exact "did interim just gain rows" clock,
unlike a client-side event-time column that a skewed clock or a long-buffered flush can't be
trusted to reflect. The measured age is printed either way. If no batch has ever been recorded the
age is unmeasurable and the sweep refuses too (conservative). There is deliberately **no `--force`**:
sweeping early is a decision about permanent data placement whose failure mode is silent.

**Pre-copy watermark evidence.** A `--sweep` run prints every seeded seat's pre-copy watermark per
table — a swept seat's as `infinity`, an already-flipped seat's as its real timestamp — so the
run's output records which window it moved. This is run evidence, explicitly **not** a recovery
cursor: no state is persisted from it.

## `tools.reservoir_copy` — copy interim's reservoir blobs into production (destructive)

The reservoir half of the same cutover data policy (#246, ADR-0020), twin of `cutover_copy`: same
window, same floor (`2026-07-17`), same direction. Blob paths are **identical** on both ends —
`signal=<metrics|logs>/dt=<YYYY-MM-DD>/<HHMMSS>-<uuid4>.json.gz` — so production's reservoir
becomes replay- and curation-capable back to the floor (ADR-0017), addressed exactly as interim's
was. Pre-floor blobs are deliberately left behind: they die with the interim RG, and #248 Part B's
archive dump is their only surviving record.

**Safety flow — dry-run first, always:**

```sh
export INTERIM_BLOB_ACCOUNT_URL='https://<interim-account>.blob.core.windows.net'
export PROD_BLOB_ACCOUNT_URL='https://<prod-account>.blob.core.windows.net'
uv run python -m tools.reservoir_copy            # read-only: per-partition counts both ends
uv run python -m tools.reservoir_copy --execute  # copy the missing blobs, then verify
```

The first two lines name the resolved **source and target** account and container. Check them: a
swapped pair would copy production's live blobs back into interim, which is due to be deleted. A
source and target resolving to the same container is refused outright. Both ends are addressed by
**account URL under `az login`** — a connection string names one account and this tool needs two,
so an ambient `CC_OTEL_BLOB_CONNECTION_STRING` never decides either end.

**What a run moves** is, per `(signal, day)` partition from the floor up, the source blob names
production does not already hold. Set difference on **names**, not a count comparison: a name
carries a `uuid4()` and so identifies one blob globally, which is also why the two sinks writing
into the same post-repoint partition (ADR-0021) cannot collide. Production's own blobs in those
partitions are its live post-flip traffic and are never copy targets — a partition line reading
`0 missing of 343 interim blob(s); production holds 688` is the normal overlap on a flip day.

**Idempotent by construction, and the repair for a short run is a re-run.** A name already in
production is never a target again. Blob writes have no transaction, so verification *follows* the
copy rather than gating it: it re-lists both containers and fails the run (exit 1) if any source
name is still absent, leaving what did land in place. Nothing is ever deleted from either end.

**Write-quiet gate, no override.** `--execute` refuses (exit 1, nothing written) unless interim's
newest in-window blob is `>= 24h` old — the same window `cutover_copy --sweep` waits on (ADR-0021),
for the same reason: until the ingest repoint has stopped interim gaining blobs, its right edge is
still moving and a partition listing cannot settle. The age is read off the blob **name**, which
`blob.py` stamps from the sink's UTC clock at write, so no `last_modified` round trip is needed;
an unreadable name is named on stderr and never counted as "quiet". A dry-run prints the age and is
never refused. There is deliberately **no `--force`** — same reasoning as `--sweep`.

**Then compact production.** The compacted container is derived and additive (ADR-0015), so the
days this copy lands blobs into need their parquet counterpart built:

```sh
uv run python -m tools.compact --execute   # add --rebuild for a day production had already compacted
```

A successful `--execute` prints this as its closing line.

## `tools.front_door` — is anything still posting to this environment's front door?

Read-only. Answers the one question every other quiet-check in this repo cannot: **is a machine
still reaching this endpoint.** `tools.cutover_copy --sweep` and `tools.reservoir_copy` both measure
a *store* — `meta.processed_batches`, the newest blob name — and after the **ingest repoint** those
stores answer about production. Interim's stores read quiet *because* its sink writes elsewhere,
while its collector endpoint stays live and in use (ADR-0027, #431).

```sh
set -a; . ./.env.interim; set +a          # AZURE_SUBSCRIPTION_ID + RESOURCE_GROUP
uv run python -m tools.front_door                          # last 14 days
uv run python -m tools.front_door --since 2026-07-30       # a named window
uv run python -m tools.front_door --env prod --days 30
```

It prints the resolved app, subscription and resource group first — check them, because a
subscription and an environment that disagree would measure a different front door and report
silence. Then one line per UTC day, counts per status code, then the verdict:

```
  2026-08-04  200   1367  401   1348  404      3
  2026-08-05  200    374  401      0  404      0
  2026-08-06  200    267  401      0  404      0  (partial day)
STILL RECEIVING: 0 consecutive complete day(s) with zero 200s, of the 7 ADR-0027 requires ...
```

**Exit code is the verdict**: `0` = `SILENT` (the run has reached ADR-0027's seven days), `1` =
`STILL RECEIVING`, `2` = it could not measure — a missing subscription/resource group, a window
outside retention, or an `az` that would not answer. The `2` cases matter: an unreadable metric must
never be mistaken for a door with no traffic, so the tool says so and refuses rather than printing a
verdict.

**Read the rejected columns as loss, not noise.** A `401` or `404` payload is dropped at the
collector — never queued, never retried into existence — so `401 1348` on 2026-08-04 is 1,348 posts
that exist nowhere. Accepted posts (`200`) are the only ones the silence run counts.

**Today is reported but never counted, and the run is anchored at yesterday.** The current UTC day
is still accruing, so a quiet morning is not a quiet day. And a window that stops short of
yesterday scores zero however quiet it was — `--until 2026-07-01` cannot report a seven-day run
that ended weeks ago, because a day the window does not cover is unknown, and unknown is not
silence. Both rules run the same way: the gate must not open early.

**A window older than 93 days is refused.** That is Azure's platform-metric retention, and outside
it the API returns an *empty series* rather than an error — unretained days would read as silence,
the one direction this measurement must not fail in. Inside it the metric answers retrospectively,
so nothing had to be collecting before the question was asked.

There is deliberately no `--force` and no threshold flag: seven days is a constant, for the same
reason `--sweep` has no override — the decision it feeds is `az group delete`.
