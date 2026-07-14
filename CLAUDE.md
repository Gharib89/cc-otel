# cc-otel

Captures Claude Code developer-usage telemetry from ITWorx developer machines into Postgres for a daily-refresh Power BI adoption report.

Pipeline: Claude Code OTel exporter → OTel Collector (bearer auth) → FastAPI sink → Azure Postgres (raw → staging → marts) → Power BI; redacted-raw OTLP payloads land in a blob reservoir on the side.

## Design sources

- **`CONTEXT.md`** — the glossary. Use its vocabulary in issues, code, and tests; don't drift to the avoided synonyms.
- **`docs/adr/`** — settled decisions: 0001 no traces, 0002 fresh schema / no backfill, 0003 minimal wrapper contract, 0004 production in Azure, 0005 blob raw reservoir. Conflicts get surfaced, never silently overridden.
- **Map issue #1** — the full locked design and decision log. Every implementation issue (#17–#31) traces to a decision bullet there; read the relevant bullet before implementing.

## Way of working

- **Issue-driven.** Planned work starts from a GitHub issue. Frontier = open, unblocked, unassigned, lowest number; respect `ready-for-agent` vs `ready-for-human` labels.
- **Claim first**: `gh issue edit <n> --add-assignee @me` before starting.
- **One issue → one branch → one PR.** Squash-merge, conventional commit title, `Closes #n` in the body.
- **HITL**: `ready-for-human` issues and anything touching schema, scope, or architecture resolve only through live exchange with Ahmed — never self-answered.
- **Ad-hoc exemption**: small fixes spotted along the way (typos, one-liners, doc nits) ride along in the current PR or get a plain commit — no issue ceremony.

## Commands

```sh
uv sync                      # install workspace deps
uv run pytest                # unit (sink/tests) + integration (tests/integration)
uv run pytest -m "not integration"  # unit only — the `python` CI job
uv run pytest -m integration # integration only (needs Docker) — the `integration` CI job
uv run ruff check .          # Python lint — the `python` CI job
uv run sqlfluff lint db/     # SQL lint — the `python` CI job
az bicep build --file iac/main.bicep --stdout >/dev/null  # Bicep lint (the `iac` CI job)
Assert-PSRule -InputPath ./iac/ -Module PSRule.Rules.Azure  # Bicep static analysis (pwsh; see iac/README.md)
uv run pre-commit run -a     # all hooks
dbmate new <name>            # new migration in db/migrations/
scripts/dev-migrate.sh       # apply migrations + regenerate schema.sql on throwaway Docker Postgres (the authoring loop)
psql "$DATABASE_URL"         # ad-hoc DB access (Azure otel real data / cc_otel)
```

- Integration tests use **testcontainers** (throwaway Docker Postgres) — never the shared dev DB.
- No MCP servers for Postgres/Azure/GitHub — use the CLIs (`psql`, `az`/Bicep, `gh`).

## Dev database

**Authoring migrations:** run `scripts/dev-migrate.sh` — it spins a throwaway `postgres:16` container (matching the CI service image), applies migrations, and regenerates `db/schema.sql` via `pg_dump 17`, mirroring the CI schema-drift gate byte-for-byte. Authoring from-zero avoids drift that a persistent DB accumulates when a migration is edited after being applied. Requires `dbmate` (pin v2.34.1) + `pg_dump 17` on PATH and a running Docker daemon.

_Until POC decommission (parallel cutover, ADR-0004):_ the gitignored `.env` holds `DATABASE_URL` pointing at the retired POC's Azure Postgres Flexible Server (a dedicated `cc_otel` database for this repo; real POC telemetry lives in the sibling `otel` database). Migrations no longer target it — `.env` `DATABASE_URL` is for ad-hoc `psql` only. `.env` also carries the Azure identity vars (`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`, …) used by deploy tooling.

## Environments & deploys

- Interim env: VS-benefits subscription (`rg-cc-otel-interim`, swedencentral) until IS grants the production RG; Bicep is dual-target.
- Secrets: ACA secrets + GitHub repo secrets with `INTERIM_`/`PROD_` prefixes — no Key Vault.
- Merge triggers CI only. All deploys are manual `workflow_dispatch` with an environment input; migrations run before image rollout.
- **One-time env bring-up** (identity/RBAC, secret fan-out, first infra deploy, DB logins, gates): `bootstrap/README.md` runbook + its detect-and-skip PowerShell scripts. `sync-secrets.ps1` treats `.env.<env>` as the single source of truth for the prefixed GitHub secrets.
- Full design: issues #11 (secrets/CI-CD) and #23 (Bicep IaC).

## Layout & standards

| Dir | Concern |
|---|---|
| `iac/` | Bicep only |
| `sink/` | FastAPI OTLP sink (uv workspace member) |
| `collector/` | OTel Collector config |
| `db/` | dbmate migrations + `schema.sql` |
| `installer/` | `install.ps1` fleet setup |
| `bootstrap/` | env bring-up runbook + PowerShell scripts (operator-run) |
| `powerbi/` | `.pbip` report + branding |
| `tools/` | DuckDB curation queries over the blob reservoir |
| `tests/integration/` | end-to-end suite |
| `scripts/` | skill-sync + cloud-ship bootstrap + dev-migrate |
| `.claude/skills/` | tracked agent skills (vendored + project-native) |

- Python 3.13; ruff (line 100); sqlfluff for SQL; PSScriptAnalyzer for PowerShell.
- **Everything is a migration** — views, grants, matviews, column-registry rows all land via dbmate; CI checks schema drift; never edit the schema out-of-band.
- CI is path-filtered per concern — a new top-level concern needs a workflow filter.
- `.pbip` is the Power BI source of truth; publishing is manual via Desktop.

## Maintenance

If your PR changes a command, convention, or environment fact stated in this file, update this file in the same PR.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five canonical labels, used as-is (no remapping). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Shipping

`ship` (issue → merge-ready PR, human merge gate) and `cloud-ship` (unattended
routine fire) are **project-native** skills in `.claude/skills/` — their source
of truth is this repo. Everything else under `.claude/skills/` is **vendored**
from the operator's personal skills by `uv run python scripts/sync-skills.py`
(run locally, commit the result; never edit vendored copies by hand). The
scheduled routine that drives `cloud-ship` over the `ready-for-agent` frontier:
`docs/agents/cloud-ship-routine.md`.
