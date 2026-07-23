# analysis/ — reservoir notebook lab

On-demand [marimo](https://marimo.io) + DuckDB notebooks over the blob reservoir
(ADR-0005), upstream of the Power BI report. Local-only exploration; findings
graduate to the marts + report via the #16 curation flow, never a parallel
dashboard. Decision + charter: #87.

| Notebook | What it explores |
|---|---|
| `overview.py` | Reservoir blob counts per signal + marts / column-registry status (EDA seed) |
| `promotion_candidates.py` | Kept / unclassified attribute keys ranked by fill rate — promotion candidates for #16 |
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

3. **Load the environment** so the notebooks see the reservoir and marts. Source
   the interim (or prod) env file — it carries the blob and DB settings the
   notebooks read via `cc_otel_sink.config.load_settings`:

   ```sh
   set -a; . ./.env.interim; set +a
   ```

   Required vars: `CC_OTEL_BLOB_ACCOUNT_URL`, `CC_OTEL_BLOB_CONTAINER` (default
   `raw`), and `DATABASE_URL` (the marts join-in).

## Running

```sh
uv run --group analysis marimo edit analysis/overview.py   # interactive, reactive editor
uv run --group analysis marimo run  analysis/overview.py   # read-only app view
uv run --group analysis marimo export html analysis/overview.py -o overview.html  # headless export
```

## Conventions

- **Notebooks are committed as `.py`** (marimo's pure-Python format) — repo-wide
  ruff (`python.yml`, `**/*.py`) covers them; no dedicated CI workflow.
- **Outputs are not committed** — only the `.py` source. Export HTML locally when
  a snapshot needs sharing.
- **No new abstraction** — notebooks reuse the `tools/` reservoir helpers
  (`configure_duckdb`, `globs`, `extract_key_paths`, `load_registry`); the only
  shared code is `analysis/_common.py` (`read_payloads`), unit-tested in
  `analysis/tests/`.
