# Curation & ops tooling — operator runbook

Six command-line tools for curating and operating the redacted-blob reservoir (the
`raw` container), the column registry, and the seat-roster reference data. They are
**manual / on-demand** — never wired into CI or the sink. This is the human operator guide;
the agent-facing curation workflow lives in
[`docs/agents/column-curation.md`](../docs/agents/column-curation.md).

| tool | what it does | destructive? |
|---|---|---|
| `tools.sweep` | list blob attribute key paths not yet in the column registry (+ redaction leaks) | no |
| `tools.gen_data_dictionary` | regenerate `docs/data-dictionary.md` from Postgres + the registry | no |
| `tools.scrub` | re-redact a window of blobs **in place** after a new `denied` classification | **yes** (overwrites blobs) |
| `tools.replay` | rebuild a window of raw → staging → marts by re-POSTing blobs through the sink | **yes** (deletes raw rows, re-POSTs) |
| `tools.compact` | collapse each frozen reservoir partition into one parquet in the `compacted` container | no (writes only the derived container) |
| `tools.roster_load` | land an IS seat-roster drop as an immutable dated snapshot in `ref` | **yes** (writes HR data) |

## Prerequisites

1. **`uv sync`** — installs the workspace so `uv run python -m tools.<name>` resolves.
2. **`az login`** — the blob tools authenticate off your `az` session via
   `DefaultAzureCredential`: `scrub` / `replay` use it directly; `sweep` fetches one token
   from it and hands that to DuckDB's Azure extension (`access_token` provider); `compact`
   does both (DuckDB reads raw, the SDK writes the parquet). Log in as an identity that holds
   the RBAC below on the storage account.
3. **Environment** — the tools read the same settings the sink uses. Export or put in `.env`:

   | var | needed by | value |
   |---|---|---|
   | `DATABASE_URL` | sweep, gen_data_dictionary, replay, roster_load | Postgres connection string |
   | `CC_OTEL_BLOB_ACCOUNT_URL` | sweep, scrub, replay, compact | `https://<account>.blob.core.windows.net` |
   | `CC_OTEL_BLOB_CONTAINER` | sweep, scrub, replay, compact | container name (default `raw`) |
   | `CC_OTEL_BLOB_COMPACTED_CONTAINER` | compact | the derived container, `compacted` (ADR-0015); unset ⇒ `compact` refuses to run |

   `.env.interim` already carries `CC_OTEL_BLOB_ACCOUNT_URL`, `CC_OTEL_BLOB_CONTAINER` and
   `CC_OTEL_BLOB_COMPACTED_CONTAINER`.
   A `CC_OTEL_BLOB_CONNECTION_STRING` may be set instead of the account URL to bypass
   `az login` (key-based auth); the account URL + `az login` path is preferred.

### Blob RBAC per tool

Grant the role on the storage account (or the named container) to the identity you logged in as with `az login`:

| tool | blob role | why |
|---|---|---|
| `tools.sweep` | **Storage Blob Data Reader** | reads blobs via DuckDB |
| `tools.gen_data_dictionary` | *(none — Postgres only)* | never touches blobs |
| `tools.replay` | **Storage Blob Data Reader** | downloads blobs to re-POST; never rewrites them |
| `tools.scrub` | **Storage Blob Data Contributor** | overwrites blobs in place |
| `tools.compact` | **Storage Blob Data Reader** on `raw` + **Storage Blob Data Contributor** on `compacted` | reads raw via DuckDB, writes only the derived container |
| `tools.roster_load` | *(none — Postgres only)* | never touches blobs (ADR-0009 keeps no file copy) |

> Progress: sweep / scrub / replay / compact print a throttled `label: n[/total]` line to **stderr**
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
fresh environment needs a manual `workflow_dispatch` deploy first; until then `compact` exits 2
naming that step. Deleting the whole container is safe — it is derived and rebuildable at ~21 s
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

## `tools.roster_load` — land an IS seat-roster drop (destructive)

IS emails a roster CSV roughly every two weeks. Each file lands as one **roster drop**: a
registry row plus one immutable `ref.seat_roster_snapshot` observation per person per
subscription. Seat history is derived from all drops (ADR-0009), so drops arriving out of
order need no repair — and no copy of the file is kept, so keep the source emails.

**Safety flow — dry-run first, always:**

```sh
uv run python -m tools.roster_load --file ~/Downloads/claude_users.csv --as-of 2026-07-24
uv run python -m tools.roster_load --file ~/Downloads/claude_users.csv --as-of 2026-07-24 \
    --execute --notes "IS email 24 Jul"
```

The first line of output is the resolved **target host and database** — check it before
anything else: the ambient `DATABASE_URL` points at the retired POC server, so the most
natural invocation would otherwise write HR data into a decommissioned database and report
success. Pass `--database-url` to override.

`--as-of` is required: the file carries no export timestamp and a filesystem timestamp resets
on copy. The dry run then prints the delta against the newest existing drop — new seats, tier
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
