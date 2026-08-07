# Column curation + ops runbook

Manual, on-demand operator procedures over the blob reservoir (#16, #7, #8, #29). The
tools live in `tools/` and run as modules from the repo root:

```sh
uv run python -m tools.sweep --days 7
uv run python -m tools.basis_drift --days 7        # re-check the kept classifications
uv run python -m tools.spec_sync --check           # gate: spec <-> migrations converge
uv run python -m tools.spec_sync --name <slug>     # author: spec delta -> new migration
uv run python -m tools.gen_data_dictionary
uv run python -m tools.scrub  --since <d> --until <d> [--execute]
uv run python -m tools.replay --since <d> --until <d> [--execute]
uv run python -m tools.compact [--since <d> --until <d>] [--rebuild] [--execute]
```

The attr-to-column-to-status catalogue is `sink/src/cc_otel_sink/column_spec.py` (**Column
spec** in CONTEXT.md) — the parser maps, store column tuples, and redaction denylist all
derive from it at import. `meta.column_registry` + the `raw.*` DDL are its deployed
projection; `tools.spec_sync` proves the two converge (CI `integration` job +
`local-gate.sh`). Curation edits start at the spec row, never at the migration.

All read the sink's own config: `DATABASE_URL` plus `CC_OTEL_BLOB_CONNECTION_STRING` or
`CC_OTEL_BLOB_ACCOUNT_URL` (+ `CC_OTEL_BLOB_CONTAINER`, default `raw`). Point them at an
environment by exporting that environment's values (interim/prod secrets live in ACA /
GitHub, not in a committed env file). `sweep` and `basis_drift` read blobs with DuckDB's Azure
extension; `scrub`/`replay` use the blob SDK; `compact` uses both; `replay` re-POSTs to a
reachable sink URL.

The reservoir is Hive-partitioned `signal=<metrics|logs>/dt=<YYYY-MM-DD>/…json.gz` — the
partition uses the OTLP **route** names `metrics`/`logs`, while the registry's signal
dimension is `metrics`/`events`/`resource`; the sweep maps between them.

Beside it sits the **compacted reservoir** (`CC_OTEL_BLOB_COMPACTED_CONTAINER`, ADR-0015): one
parquet per `(signal, day)` at the same Hive path, written on demand by `tools.compact` and
preferred by the `analysis/` notebooks and by `tools.basis_drift`. It is **derived, additive and
rebuildable** — `sweep`, `scrub` and `replay` address `raw` only, which stays the source of
truth. It touches curation in two places: the deny flow in step 6, and `basis_drift`'s window
read (which falls back to `raw` per partition, so a pending compaction catch-up only costs it
time).

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

It also falls back across the **signal** dimension, one-directionally: a key with no row
under its own signal resolves to the `resource`/`*` row for the same path. The sink merges
the resource block into each signal's flat namespace (`attrs = {**res_attrs, **flatten(rec_attrs)}`,
and `attr_columns` drops `signal_name`), so a resource attribute seen at
`events/api_request/os.type` is the same byte the parser already reads — not a second fact
needing a second verdict. The fallback does **not** run the other way: a genuinely new key
at the resource path still surfaces. Register a resource attribute once, as `resource`/`*`.

## 1b. Basis drift — re-check the keys already classified

`sweep` concerns **unclassified** keys only. A key classified `kept` never resurfaces there
however far its live distribution drifts from the evidence the classification rested on — the
sweep's extraction returns key paths with no values, so it cannot see cardinality at all. That
gap is **basis drift** (CONTEXT.md), and `tools.basis_drift` closes it: it re-derives each
`kept` row's basis from a recent window and exits 1 on any contradiction. Details and the
per-basis predicates: [`tools/README.md`](../../tools/README.md).

Two rules when it fires:

- **Drift is a promotion-flow ticket, not an edit.** If a `constant` key now takes two values,
  the key may deserve a column — that is a new issue for step 3, never a status change smuggled
  into the same PR.
- **`thin` is skipped below 10 reporting seats** and the run says so. A skip is not a pass;
  widen the window.

## 2. Classification obligation

Every value-bearing key that reaches the pipeline must have exactly one
`meta.column_registry` row, `status` one of:

- **`promoted`** — worth a typed column in `raw.metrics`/`raw.events`; carries
  `column_name` + `data_type`. Feeds staging/marts.
- **`kept`** — retained in the blob reservoir only, no Postgres column. The default for
  low-value or high-cardinality keys. A `kept` row must also declare a **kept basis**
  (`kept_basis`, and `basis_partner` when it is `collinear`) — *why* it is kept: `nature`,
  `constant`, `collinear`, `thin`, or `redundant` (**Kept basis** in CONTEXT.md). The registry
  CHECK enforces it, so a `kept` row without one fails its migration. Only `nature` and
  `redundant` carry no machine predicate; step 1b re-checks the rest. That is not the same as
  unfalsifiable: `nature` cannot drift, but `redundant` is a cross-grain claim no single record
  answers, so it is re-checked by hand when the schema that carries the information moves.
- **`denied`** — stripped by the sink wherever seen; never at rest. For secret-bearing or
  PII keys (#8).

A sweep finding is not resolved until its key is classified in a migration. Do not leave a
key unclassified "for later" — an unclassified promoted-worthy key is silently dropped
(schema-v2 has no JSONB catch-all).

## 3. Promotion-PR bundle

Promoting a key (or adding any registry row) ships as **one PR** carrying, together:

1. **Spec row** — add the `ColumnSpec(...)` to `sink/src/cc_otel_sink/column_spec.py`. A
   plain attribute promotion is `kind="attr"` (the flat `attr_columns` map picks it up with
   no parser edit); an ordered coalesce over several attr paths is `kind="derived"`, also
   parser-free (`derived_coalesce` is generic). Only `kind="structural"` — a value read from
   OTLP structure rather than the attribute map — needs matching parser code. The
   import-time invariants reject a malformed row immediately; three are easy to trip:
   a `kind="attr"` column takes **exactly one attr path per signal** (invariant 8 — where
   the fleet emits one path across several event families the column is polysemous and the
   `signal_name` rows document it; where the paths differ they get their own columns), a
   `kept`/`denied` row must not contradict a `promoted` one for the same path (invariant 7),
   and a `kept` row — and only a `kept` row — carries a `kept_basis`, with a `basis_partner`
   iff that basis is `collinear` (invariants 10/11). Promoting a key therefore *drops* its
   basis; leaving one behind fails the import.
   A **resource** attribute is registered once as `resource`/`*` and its promoted column
   lands on **both** raw tables — the sink merges the resource block into each signal's flat
   namespace, so a resource-only promotion is `kind="derived"` with a single source (#357).
2. **Generate the migration** — `uv run python -m tools.spec_sync --name <slug>` diffs the
   spec against a from-zero DB, writes the `raw.*` DDL + `meta.column_registry` migration
   closing the delta, applies it, and regenerates `db/schema.sql`. (**Needs Docker** — in an
   unattended run, do this before hand-off. On Windows the migration lands but the
   `schema.sql` step throws — Python cannot exec a `.sh`; finish it with
   `bash scripts/dev-migrate.sh` under git-bash.) Renames, type changes, and **in-place `status`
   edits** are refused: the registry diff is a set diff over the whole row, so editing a
   `kept` row to `promoted` reads as a missing row *plus* an orphan row, and the generator
   refuses orphans. Hand-author those as an `UPDATE` with a matching down body, then let
   `--check` prove convergence.
3. **Parser** (`kind="structural"` only) — add the extraction code in
   `sink/src/cc_otel_sink/parser.py`; a fixture test proves every promoted column is
   populated.
4. **Tests** — sink unit tests covering the new column; integration coverage if it feeds a
   mart.
5. **Dictionary regen** — `uv run python -m tools.gen_data_dictionary`, commit
   `docs/data-dictionary.md`.

`kept`/`denied` decisions ship the same way minus the DDL/parser/dictionary-stat changes
(they have no column) — still a spec row + `spec_sync --name` (registry-only migration) +
dictionary regen (the kept/denied section lists them).

## 4. Data dictionary

`tools.gen_data_dictionary` regenerates `docs/data-dictionary.md`: registry descriptions
as the backbone, live profiling stats (non-null %, unique %, distinct) for promoted
columns from `raw.*`, and a kept/denied section (metadata only — those keys have no
column, so use `sweep` to see their live blob presence). Pure-Postgres; needs no blob
access. Commit the regenerated file as step 5 of the promotion PR.

The stats are **live**, so the regen needs a database that already carries the columns it is
documenting. A promotion PR authored *before* its deploy therefore cannot regenerate honestly —
against a throwaway container every other column's stats would read zero — so the regen moves to the
first curation pass after the deploy, and the PR says so in its body (#432, ADR-0028). Silent lag
between the dictionary and the registry is the drift this step exists to prevent; an announced lag
with a named trigger is not.

Point `DATABASE_URL` at the environment the migration and the sink image actually reached. Since the
ingest repoint that is **prod**: interim's stores are write-quiet (ADR-0021), so even a migrated
interim would profile every newly promoted column as 100% NULL. Every environment names its database
`cc_otel`, so the generated header also records the **host** — that line is the document's only
statement of which environment it profiled (#436).

A column promoted under several registry rows can carry a different meaning per row
(`duration_ms` is six event families' duration). Where the descriptions genuinely differ
the cell names each one, prefixed by the narrowest registry label that tells them apart —
signal name, else attr path, else signal, else the whole grain (#368). One wording across
every row renders bare, so a qualified cell that reads as the same meaning twice is wording
drift between registry rows, not polysemy: harmonize the rows and the cell collapses.

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

1. Add a `denied` spec row with the right `deny_mode` (`strip` / `defense_in_depth`) —
   `redaction.py`'s `DENYLIST` / `DEFENSE_IN_DEPTH` derive from it, so there is no separate
   denylist to edit — then `spec_sync --name <slug>` ships the registry row (promotion-PR
   bundle, minus DDL). A key moving `kept` -> `denied` is an in-place `status` edit, which
   the generator refuses (step 3): hand-author that `UPDATE` in its own earlier migration.
   Deny the **whole attribute**, never a leaf inside it: the emitted
   shape of a structured value is the client's choice, and a mode that descends one shape
   strips nothing when the fleet sends another (#369).
2. Blobs written before the deploy still hold the key. Rewrite the exposed window in place
   with `tools.scrub` (dry-run first, then `--execute`). Scrub runs each blob back through
   the sink's `redact` and overwrites it; it is idempotent on already-clean blobs and
   deliberately does **not** touch `processed_batches` (the payload bytes change, so the
   hash would too — replaying is the wrong tool for a deny).
3. **Re-compact the scrubbed window.** A compacted partition (ADR-0015) built before the deny
   still carries the denied key — scrub rewrites `raw` in place and never touches the derived
   container, so the deny is not complete until the parquet is re-derived from the scrubbed
   blobs:

   ```sh
   uv run python -m tools.compact --since <scrubbed-start> --until <scrubbed-end> --rebuild --execute
   ```

   Skipping this leaves the key readable through the notebooks' preferred read path. Nothing to
   do if the window was never compacted.
4. Postgres needs no change if the key was never a promoted column; if it was, drop/clear
   the column in the same migration.

## 7. Replay (incident recovery)

`tools.replay` rebuilds a time window from the reservoir after a sink/DB incident: it
clears the window's raw rows and batch hashes, then re-POSTs each blob so the pipeline
re-derives raw → staging → marts. Because raw rows are keyed by event time (not blob
path), the window is a time range — pick it generously; ingest-time vs event-time skew at
the edges is expected. Dry-run first to see blob/row counts, then `--execute` with a
`--sink-url` that reaches the target sink (the sink has no external ingress, so run against
a local sink or a port-forward). Never use replay for a deny — that is `scrub`.
