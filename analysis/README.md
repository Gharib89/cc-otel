# analysis/ — reservoir notebook lab

On-demand [marimo](https://marimo.io) + DuckDB notebooks over the blob reservoir
(ADR-0005), upstream of the Power BI report. Local-only exploration; findings
graduate to the marts + report via the #16 curation flow, never a parallel
dashboard. Decision + charter: #87.

| Notebook | What it explores |
|---|---|
| `overview.py` | Reservoir blob counts per signal + marts / column-registry status + per-column fill of the promoted set over the replayed window ([ADR-0017](../docs/adr/0017-promoted-column-window-replayed-from-the-reservoir.md)) — the EDA seed |
| `promotion_candidates.py` | Kept / unclassified attribute keys ranked by fill rate — promotion candidates for #16 |
| `promotion_profile.py` | The same candidates at **record** grain over a wide window, cross-tabbed against sessions and seats — the evidence a promotion value case argues from (#351; frozen cut: [`docs/research/promotion-candidate-profile.md`](../docs/research/promotion-candidate-profile.md)) |
| `redaction_audit.py` | `denied` keys still present in the redacted reservoir — redaction leaks (#8) |
| `ecosystem.py` | Generic attribute-value explorer — top skills, custom-skill authors (starter) |

## Prerequisites

1. **Install the group** (not part of a plain `uv sync`):

   ```sh
   uv sync --group analysis
   ```

2. **Authenticate to Azure** — the reservoir is read with
   `DefaultAzureCredential`, same path as the curation tools:

   ```sh
   az login
   ```

3. **Environment** — nothing to source: each notebook's setup cell calls
   `analysis._common.load_env()`, which loads the repo-root `.env.interim` into
   the kernel before `cc_otel_sink.config.load_settings` reads it. Point it at
   another file with `CC_OTEL_ENV_FILE` (e.g. `.env.prod`, or an absolute path) —
   not by exporting individual variables, because the file wins: marimo
   auto-loads the repo-root `.env` (the ad-hoc `psql` login — no reservoir settings,
   and its target moves with operator housekeeping) into every kernel, so deferring
   to the inherited environment would silently query the wrong database. A missing file is not an error — the notebook then runs on whatever
   the environment already carries (an unset reservoir surfaces as
   `ReservoirUnconfigured`).

   Required vars: `CC_OTEL_BLOB_ACCOUNT_URL`, `CC_OTEL_BLOB_CONTAINER` (default
   `raw`), and `DATABASE_URL` (the marts join-in). Optional but strongly
   recommended: `CC_OTEL_BLOB_COMPACTED_CONTAINER=compacted` (below) — unset, the
   notebooks read raw blobs and a wide window costs minutes rather than seconds.

## Compaction — read the window in seconds, not minutes

Read cost is driven by **file count, not bytes**: one day's ~860 gzipped blobs take
9.6 s to parse with *zero* network, so ~11 ms of per-file overhead dominates the
2.83 MB of payload (#352). `tools.compact` collapses each partition into one zstd
parquet in the `compacted` container, and `read_payloads` prefers it — taking the
Jul 14 → 28 window from ~6–11 min to ~3.5 min.

```sh
uv run python -m tools.compact             # dry-run: the catch-up plan
uv run python -m tools.compact --execute   # build + upload the missing partitions
```

Three rules worth knowing before you rely on it (full reasoning in
[ADR-0015](../docs/adr/0015-compacted-reservoir.md), operator detail in
[`tools/README.md`](../tools/README.md)):

- **Derived, additive, rebuildable.** `raw` stays the source of truth and the replay
  source; `compacted` is a read cache. Deleting it costs ~21 s per partition to rebuild.
- **On demand, no schedule.** Past partitions are immutable, so compaction is a
  once-per-partition-ever job — there is no drift to correct, only a backlog to catch up,
  and one run catches up whatever is missing no matter when it last ran. **Today's
  partition is never compacted** (it is still growing); the read path falls back to `raw`
  for it, so a notebook window ending today always works.
- **Unset means today's behaviour.** No `CC_OTEL_BLOB_COMPACTED_CONTAINER`, no parquet
  probe — a machine that has never compacted anything still runs every notebook.

## Running

```sh
uv run --group analysis marimo edit analysis/overview.py   # interactive, reactive editor
uv run --group analysis marimo run  analysis/overview.py   # read-only app view
uv run --group analysis marimo export html analysis/overview.py -o overview.html  # headless export
```

## Conventions

- **Notebooks are committed as `.py`** (marimo's pure-Python format) — repo-wide
  ruff (`python.yml`, `**/*.py`) covers them; no dedicated CI workflow. That also
  means no `scripts/ship/local-gate.sh` exclusion entry is needed: the gate keys
  its `EXCLUDED` list on *triggered workflow names*, and `analysis/` triggers the
  existing `python` gate rather than a workflow of its own — so there is no name
  to exclude.
- **Outputs are not committed** — only the `.py` source. Export HTML locally when
  a snapshot needs sharing.
- **No new abstraction** — notebooks reuse the `tools/` reservoir helpers
  (`configure_duckdb`, `partition_glob` / `compacted_url`, `extract_key_paths`,
  `load_registry`) plus `tools/_payload.py` (`read_payloads`, `Profile`), which
  moved out of `analysis/_common.py` when `tools.basis_drift` needed the same
  aggregation (#366) and is unit-tested in `tools/tests/test_payload.py`.
  `analysis/_common.py` re-exports those names, so notebook imports are unchanged;
  what stays its own is `load_env`, the marimo-kernel env loader.
