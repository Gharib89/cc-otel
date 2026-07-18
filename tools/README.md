# Curation & ops tooling — operator runbook

Four command-line tools for curating and operating the redacted-blob reservoir (the
`raw` container) and the column registry. They are **manual / on-demand** — never wired
into CI or the sink. This is the human operator guide; the agent-facing curation workflow
lives in [`docs/agents/column-curation.md`](../docs/agents/column-curation.md).

| tool | what it does | destructive? |
|---|---|---|
| `tools.sweep` | list blob attribute key paths not yet in the column registry (+ redaction leaks) | no |
| `tools.gen_data_dictionary` | regenerate `docs/data-dictionary.md` from Postgres + the registry | no |
| `tools.scrub` | re-redact a window of blobs **in place** after a new `denied` classification | **yes** (overwrites blobs) |
| `tools.replay` | rebuild a window of raw → staging → marts by re-POSTing blobs through the sink | **yes** (deletes raw rows, re-POSTs) |

## Prerequisites

1. **`uv sync`** — installs the workspace so `uv run python -m tools.<name>` resolves.
2. **`az login`** — the blob tools authenticate off your `az` session: `scrub` / `replay`
   via `DefaultAzureCredential`, `sweep` via DuckDB's Azure extension using its own
   `credential_chain` provider. Log in as an identity that holds the RBAC below on the
   storage account. (If `sweep` fails to read a partition with `Failed to get token from
   ChainedTokenCredential`, that's the DuckDB path — see #99.)
3. **Environment** — the tools read the same settings the sink uses. Export or put in `.env`:

   | var | needed by | value |
   |---|---|---|
   | `DATABASE_URL` | sweep, gen_data_dictionary, replay | Postgres connection string |
   | `CC_OTEL_BLOB_ACCOUNT_URL` | sweep, scrub, replay | `https://<account>.blob.core.windows.net` |
   | `CC_OTEL_BLOB_CONTAINER` | sweep, scrub, replay | container name (default `raw`) |

   `.env.interim` already carries `CC_OTEL_BLOB_ACCOUNT_URL` + `CC_OTEL_BLOB_CONTAINER`.
   A `CC_OTEL_BLOB_CONNECTION_STRING` may be set instead of the account URL to bypass
   `az login` (key-based auth); the account URL + `az login` path is preferred.

### Blob RBAC per tool

Grant the role on the storage account (or `raw` container) to the identity you logged in as with `az login`:

| tool | blob role | why |
|---|---|---|
| `tools.sweep` | **Storage Blob Data Reader** | reads blobs via DuckDB |
| `tools.gen_data_dictionary` | *(none — Postgres only)* | never touches blobs |
| `tools.replay` | **Storage Blob Data Reader** | downloads blobs to re-POST; never rewrites them |
| `tools.scrub` | **Storage Blob Data Contributor** | overwrites blobs in place |

> Progress: sweep / scrub / replay print a throttled `label: n[/total]` line to **stderr**
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
