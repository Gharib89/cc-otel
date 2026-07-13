# cc-otel — Claude Code telemetry

Captures Claude Code developer-usage telemetry from ITWorx developer machines
into Postgres for a daily-refresh Power BI **adoption report**.

```
Claude Code OTel exporter ─▶ OTel Collector (bearer auth) ─▶ FastAPI sink ─▶ Azure Postgres ─▶ Power BI
                                                                  │           (raw → staging → marts)
                                                                  └─▶ redacted-raw OTLP payloads ─▶ blob raw reservoir
```

Two signal sources feed the pipeline: **official telemetry** — Claude Code's
built-in OTel exporter (tokens, LOC, commits, PRs, active time, model/effort,
skills, MCPs, subagents) — and **wrapper telemetry** — a statusline wrapper
adding what official telemetry cannot provide: rate-limit utilization and reset
countdown per window. No traces in production (ADR-0001). The blob **raw
reservoir** keeps redacted-raw payloads on the side for drift discovery and
future-parser replay (ADR-0005); the report reads only the Postgres marts.

## Layout

| Dir | Concern |
|---|---|
| `collector/` | OTel Collector config — the only authenticated ingest boundary |
| `sink/` | FastAPI OTLP sink (uv workspace member) |
| `db/` | dbmate migrations + generated `schema.sql` |
| `iac/` | Bicep for the Azure stack |
| `installer/` | `install.ps1` fleet setup |
| `powerbi/` | `.pbip` report + branding (publishing is manual via Desktop) |
| `tools/` | DuckDB curation queries over the raw reservoir |
| `tests/integration/` | end-to-end suite (testcontainers) |
| `docs/adr/` | architecture decision records |

## Getting started

```sh
uv sync                      # install workspace deps
uv run pytest                # unit (sink/tests) + integration (tests/integration; needs Docker)
uv run pre-commit run -a     # all hooks (ruff, sqlfluff, hygiene)
```

Database work goes through dbmate (`dbmate new <name>`, `dbmate up` — reads
`DATABASE_URL` from a gitignored `.env`). **Everything is a migration** — views,
grants, matviews, registry rows all land via `db/migrations/`; CI fails on
schema drift. Integration tests spin a throwaway Docker Postgres via
testcontainers — never a shared database.

## Design sources

- **`CONTEXT.md`** — the glossary; its vocabulary is binding in issues, code, and tests.
- **`docs/adr/`** — settled decisions (no traces, fresh schema, wrapper contract, Azure production, blob reservoir).
- **Map issue #1** — the full locked design and decision log.

## Environments

Production is an Azure stack — Container Apps running collector + sink, a
Postgres Flexible Server, and the reservoir storage account — deployed via
Bicep (`iac/`). Dual-target for the parallel cutover (ADR-0004): an interim
VS-benefits resource group until IS grants the production one. Merges trigger
CI only; deploys are manual `workflow_dispatch` with migrations before image
rollout.

## Contributing

Issue-driven: one issue → one branch → one PR, squash-merged with a
Conventional-Commit title. `CLAUDE.md` holds the working agreement;
`.github/PULL_REQUEST_TEMPLATE.md` is the merge-gate checklist.
