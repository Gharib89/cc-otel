# Column curation + ops runbook

Manual, on-demand operator procedures over the blob reservoir (#16, #7, #8, #29). The
tools live in `tools/` and run as modules from the repo root:

```sh
uv run python -m tools.sweep --days 7
uv run python -m tools.gen_data_dictionary
uv run python -m tools.scrub  --since <d> --until <d> [--execute]
uv run python -m tools.replay --since <d> --until <d> [--execute]
```

All read the sink's own config: `DATABASE_URL` plus `CC_OTEL_BLOB_CONNECTION_STRING` or
`CC_OTEL_BLOB_ACCOUNT_URL` (+ `CC_OTEL_BLOB_CONTAINER`, default `raw`). Point them at an
environment by exporting that environment's values (interim/prod secrets live in ACA /
GitHub, not in a committed env file). `sweep` reads blobs with DuckDB's Azure extension;
`scrub`/`replay` use the blob SDK; `replay` re-POSTs to a reachable sink URL.

The reservoir is Hive-partitioned `signal=<metrics|logs>/dt=<YYYY-MM-DD>/…json.gz` — the
partition uses the OTLP **route** names `metrics`/`logs`, while the registry's signal
dimension is `metrics`/`events`/`resource`; the sweep maps between them.

## 1. Sweep — find unclassified keys

`tools.sweep` reads a recent window, extracts every attribute key path
`(signal, signal_name, attr_path)`, and diffs against `meta.column_registry`. It reports:

- **Unclassified** — keys with no registry row under their signal. Every one is an
  obligation (below).
- **Redaction leaks** — keys classified `denied` yet present in a (redacted) blob. A leak
  means the sink's redaction (`sink/src/cc_otel_sink/redaction.py`) missed a path — fix the
  redaction, then `scrub` the exposed window.

Matching is wildcard-aware: a key recorded at `signal_name = '*'` is known under every
name; a key recorded only under specific names is surfaced again when it appears under a
new one (its meaning may differ there).

## 2. Classification obligation

Every value-bearing key that reaches the pipeline must have exactly one
`meta.column_registry` row, `status` one of:

- **`promoted`** — worth a typed column in `raw.metrics`/`raw.events`; carries
  `column_name` + `data_type`. Feeds staging/marts.
- **`kept`** — retained in the blob reservoir only, no Postgres column. The default for
  low-value or high-cardinality keys.
- **`denied`** — stripped by the sink wherever seen; never at rest. For secret-bearing or
  PII keys (#8).

A sweep finding is not resolved until its key is classified in a migration. Do not leave a
key unclassified "for later" — an unclassified promoted-worthy key is silently dropped
(schema-v2 has no JSONB catch-all).

## 3. Promotion-PR bundle

Promoting a key (or adding any registry row) ships as **one PR** carrying, together:

1. **Migration** (`dbmate new …`) — the `raw.*` DDL change (for `promoted`) **and** the
   `meta.column_registry` row(s). Registry rows are migration data; they must not drift
   from the DDL (that is why they live in the same `db/` migration stream).
2. **Parser** — map the OTLP key to the new column in `sink/src/cc_otel_sink/parser.py`.
3. **Tests** — sink unit tests covering the new column; integration coverage if it feeds a
   mart.
4. **Schema regen** — `scripts/dev-migrate.sh` to apply the migration and regenerate
   `db/schema.sql` (CI's schema-drift gate fails otherwise).
5. **Dictionary regen** — `uv run python -m tools.gen_data_dictionary`, commit
   `docs/data-dictionary.md`.

`kept`/`denied` decisions ship the same way minus the DDL/parser/dictionary-stat changes
(they have no column) — still a migration row + schema regen + dictionary regen (the
kept/denied section lists them).

## 4. Data dictionary

`tools.gen_data_dictionary` regenerates `docs/data-dictionary.md`: registry descriptions
as the backbone, live profiling stats (non-null %, unique %, distinct) for promoted
columns from `raw.*`, and a kept/denied section (metadata only — those keys have no
column, so use `sweep` to see their live blob presence). Pure-Postgres; needs no blob
access. Commit the regenerated file as step 5 of the promotion PR.

## 5. Backfill decision

Default is **forward-only**: a newly promoted column is populated for new ingests only;
historical rows keep NULL. This matches ADR-0002 (fresh schema, no pilot backfill) and is
almost always correct for an adoption report.

Opt in to a **targeted backfill** only when a specific analysis needs history and the key
was already being `kept` in blobs for the period. Extract it from the reservoir with a
DuckDB query over the window and `UPDATE` the promoted column — a bespoke, reviewed
one-off, not a standing tool. Record the backfill window in the registry row's `notes`.

## 6. Deny flow (scrub)

When a key becomes `denied`:

1. Add the deny to the sink redaction denylist and ship the `denied` registry row
   (promotion-PR bundle, minus DDL).
2. Blobs written before the deploy still hold the key. Rewrite the exposed window in place
   with `tools.scrub` (dry-run first, then `--execute`). Scrub runs each blob back through
   the sink's `redact` and overwrites it; it is idempotent on already-clean blobs and
   deliberately does **not** touch `processed_batches` (the payload bytes change, so the
   hash would too — replaying is the wrong tool for a deny).
3. Postgres needs no change if the key was never a promoted column; if it was, drop/clear
   the column in the same migration.

## 7. Replay (incident recovery)

`tools.replay` rebuilds a time window from the reservoir after a sink/DB incident: it
clears the window's raw rows and batch hashes, then re-POSTs each blob so the pipeline
re-derives raw → staging → marts. Because raw rows are keyed by event time (not blob
path), the window is a time range — pick it generously; ingest-time vs event-time skew at
the edges is expected. Dry-run first to see blob/row counts, then `--execute` with a
`--sink-url` that reaches the target sink (the sink has no external ingress, so run against
a local sink or a port-forward). Never use replay for a deny — that is `scrub`.
