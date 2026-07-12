# Dev Tooling Stack: Skills, Plugins, MCP Servers, and CLI Tools

**Date:** 2026-07-12

**Research question:** Which skills, plugins, MCP servers, and CLI tools should cc-otel adopt for development, beyond the already-adopted Microsoft Learn MCP and Context7 — across Postgres tooling, Bicep/azd, Power BI/PBIR validation, pytest/uv helpers, gh automation, and Claude Code plugins?

**Method:** Every claim traces to a primary source — official GitHub repos (README, releases, commit activity), Microsoft Learn, docs.astral.sh, PyPI, docs.github.com. Versions and dates were cross-checked against GitHub API / PyPI absolute timestamps (release *pages* render relative dates that mislead). The retired POC at `D:\projects\archive\cc-otel-azure` was inspected directly to ground what "the POC used": plain numbered SQL migrations (`iac/migrations/0001..0010`), a PowerShell validation orchestrator (`tools/validate-all.ps1` → custom ajv PBIR schema validator + fab-inspector rules + Tabular Editor 2 BPA), vendored `PBIRInspectorCLI.exe`/`PBIXInspectorCLI.exe`, a uv + pytest sink (`asyncio_mode = "auto"`), hand-rolled Bicep modules, and **no** CI workflows (all validation ran locally).

Anything not confirmed against a primary source is flagged **UNVERIFIED**.

---

## TL;DR — verdicts

| Tool | Category | Verdict | Why (one line) |
|---|---|---|---|
| psql (direct, via shell) | Postgres | **Adopt** | Agent already has a shell; psql beats any MCP wrapper for zero context cost |
| dbmate v2.34.1 | Postgres | **Adopt** | Single binary, plain-SQL migrations — formalizes the POC's numbered-file style |
| sqlfluff v4.2.2 | Postgres | **Adopt** | Actively maintained SQL linter with first-class `postgres` dialect; lints migrations/views in CI |
| Bicep CLI linter + `bicepconfig.json` | Bicep | **Adopt** | Built into `az bicep`; Error-level rules fail the build — free CI gate |
| Azure Verified Modules (AVM) | Bicep | **Adopt** | Published, versioned modules exist for all four resources this project deploys |
| PSRule for Azure v1.47.0 | Bicep | **Adopt** (via module, not the stale action) | 500+ WAF-aligned checks over expanded Bicep; useful evidence for the IS production handover |
| fab-inspector v3.4.0 | Power BI | **Adopt** | It *is* PBI Inspector V2 renamed — one actively-maintained PBIR rules engine replaces two POC tools |
| Custom ajv PBIR schema validator (keep) | Power BI | **Adopt** | Microsoft's PBIR schemas are live and versioned; no off-the-shelf substitute exists |
| Tabular Editor 2 (`-A` BPA) v2.28.0 | Power BI | **Adopt** | Free, license-free in CI, runs on `windows-latest`; only viable local semantic-model BPA |
| uv (run/lock/dependency-groups/uvx) | pytest/uv | **Adopt** | Already in use; PEP 735 dependency groups replace requirements.txt sprawl |
| ruff (lint + format) v0.15.x | pytest/uv | **Adopt** | One tool replaces flake8 + isort + black; same vendor as uv |
| pytest-asyncio v1.4.0 | pytest/uv | **Adopt** | POC already configured `asyncio_mode = "auto"`; actively maintained |
| pytest-cov v7.1.0 | pytest/uv | **Adopt** | Standard coverage gate, nothing else needed |
| testcontainers-python v4.14.2 | pytest/uv | **Adopt** | Self-provisions the exact Azure-matching Postgres in Docker, local and CI alike |
| gh CLI ≥ v2.94.0 native sub-issues | gh | **Adopt** | Sub-issues/dependencies are native since June 2026 — retire the `gh api` GraphQL workaround |
| GitHub Actions CI (setup-uv v8, azure/login v3, azure/bicep-deploy v2) | gh | **Adopt** | POC had zero CI; these are the current official actions for every pipeline leg |
| Branch protection via `gh api` rulesets | gh | **Adopt** | Plain REST; rulesets are GitHub's forward-looking mechanism |
| Postgres MCP servers (all) | Postgres | Skip | Reference server archived; alternatives stale or overkill vs psql-in-shell |
| pgTAP | Postgres | Skip | Not in Azure flexible server's allowed-extensions list |
| sqitch, alembic | Postgres | Skip | More machinery / wrong paradigm for plain-SQL analytics migrations |
| azd | Bicep | Skip | Dual-scope (subscription POC vs RG-only prod) fights azd's one-template model |
| Azure MCP Server / Azure Skills plugin | Bicep | Skip (revisit) | 276–422 tool schemas of context cost to wrap what `az` already does in the shell |
| pbi-tools | Power BI | Skip | Legacy PBIX-era; no PBIR support; no release in ~18 months |
| Fabric CLI `fab`, fabric-cicd | Power BI | Skip (for now) | Deploy tools, not validators; revisit if automated publish is added |
| pytest-postgresql, respx | pytest/uv | Skip | Needs local pg binaries / no outbound httpx to mock in the sink |
| GitHub MCP server | gh | Skip | ~10–32× token overhead vs `gh` for an agent that already has a shell |
| gh-dash | gh | Skip (agents) | Interactive TUI — fine for humans, unusable non-interactively |
| anthropics/skills entries | Claude Code | Skip | Nothing Azure/Postgres/Power BI-specific exists there |

---

## 1. Postgres MCP / tooling

### Anthropic reference Postgres MCP server — dead, confirmed

`@modelcontextprotocol/server-postgres` was moved to [modelcontextprotocol/servers-archived](https://github.com/modelcontextprotocol/servers-archived), archived (read-only) **2025-05-29**. The README states the servers "are no longer maintained" and "NO SECURITY GUARANTEES ARE PROVIDED"; the active [modelcontextprotocol/servers](https://github.com/modelcontextprotocol/servers) repo no longer carries a Postgres reference server. **Skip.**

### Postgres MCP Pro (crystaldba/postgres-mcp) — real but slowing. Skip

[crystaldba/postgres-mcp](https://github.com/crystaldba/postgres-mcp) (MIT, ~3k stars) offers read-only access modes, index tuning, EXPLAIN with hypothetical-index simulation, and health checks. But the latest release is **v0.3.0 (2025-05-16)** — no release in ~14 months, last push 2026-01-22, 66 open issues. The genuinely maintained alternative is Google's [MCP Toolbox for Databases](https://github.com/googleapis/genai-toolbox) (**v1.6.0, 2026-07-01**, ~16k stars), which supports a generic PostgreSQL source and therefore works against plain Azure Database for PostgreSQL — but it solves a problem this project doesn't have. Claude Code already runs `psql` in the shell with zero tool-schema overhead; an MCP layer adds context cost without adding capability. **Skip both; psql-in-shell is the workflow.** Revisit genai-toolbox only if a no-shell agent surface (e.g., claude.ai) needs DB access.

### dbmate — adopt as the migration runner

The POC managed schema with hand-numbered SQL files and no applied-migrations tracking. [dbmate](https://github.com/amacneil/dbmate) (**v2.34.1, 2026-07-09** — released three days before this research; very healthy) is a single Go binary using plain-SQL migration files with `-- migrate:up` / `-- migrate:down` markers plus a `schema_migrations` table and `schema.sql` dump. It maps directly onto the existing style while adding tracked application, rollback, and `dbmate status`. sqitch ([sqitchers/sqitch](https://github.com/sqitchers/sqitch), v1.6.1, 2026-01-06) is maintained but is a Perl app with a heavier deploy/revert/verify script model; alembic is SQLAlchemy/ORM-autogenerate-oriented — wrong paradigm for an analytics-first plain-SQL schema (alembic current version **UNVERIFIED**, not pursued). **Adopt dbmate; skip sqitch and alembic.**

### sqlfluff — adopt for SQL linting

[sqlfluff](https://github.com/sqlfluff/sqlfluff) **v4.2.2 (2026-06-04**, monthly release cadence per [PyPI](https://pypi.org/project/sqlfluff/)) has a first-class [`postgres` dialect](https://docs.sqlfluff.com/en/stable/reference/dialects.html) with ongoing parser fixes. The repo's SQL surface (migrations, views, marts) is exactly what it lints; it installs cleanly as a uv dev-dependency group entry and runs in CI. **Adopt.**

### pgTAP — skip

[theory/pgtap](https://github.com/theory/pgtap) is current (**v1.3.4, 2025-10-04**, PG17 support) but is a server-side extension, and **pgtap does not appear** in the [Azure Database for PostgreSQL flexible server allowed-extensions list](https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions-versions). It could only run against local containers — where pytest + testcontainers (section 4) already covers view/schema assertions in the language the project tests in. **Skip.**

## 2. Bicep / azd tooling

### Bicep CLI + linter — adopt with a committed `bicepconfig.json`

Bicep **v0.45.6 (2026-07-10)** ([Azure/bicep releases](https://github.com/Azure/bicep/releases/latest)); az CLI self-manages the install via `az bicep install/upgrade` (stored under `%USERPROFILE%\.Azure\bin`, [installation notes](https://learn.microsoft.com/azure/azure-resource-manager/bicep/installation-troubleshoot)). The [linter](https://learn.microsoft.com/azure/azure-resource-manager/bicep/linter) runs automatically on `bicep lint` / `bicep build`; rules are configured per-directory in [`bicepconfig.json`](https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-config-linter) with `Error` level failing the build. There is **no official GitHub Action for Bicep lint** — the documented CI pattern is simply an `az bicep build`/`bicep lint` step. The `use-recent-module-versions` rule (off by default) pairs well with AVM pins. **Adopt: commit a `bicepconfig.json`, run lint in CI.**

### Azure Verified Modules (AVM) — adopt for the module layer

AVM is Microsoft's official module strategy; the [Bicep resource-module index](https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/) lists ~171 published modules, including everything this project deploys: `avm/res/app/container-app` (v0.23.0), `avm/res/app/managed-environment` (v0.13.3), `avm/res/db-for-postgre-sql/flexible-server` (v0.15.4), plus `avm/res/operational-insights/workspace` and `avm/res/storage/storage-account` (confirmed in [Azure/bicep-registry-modules](https://github.com/Azure/bicep-registry-modules/tree/main/avm/res)). Consumed unauthenticated via `br/public:avm/res/...:<version>`. The POC hand-rolled five modules; AVM replaces them with WAF-aligned, versioned, tested equivalents and works at both subscription and RG scope. **Adopt** (pragmatically — where an AVM module fights the dual-target parameterization, a thin local wrapper over AVM is fine).

### azd — skip

azd **v1.27.1 (2026-07-09)** ([Azure/azure-dev](https://github.com/Azure/azure-dev/releases/latest)) adds environment management, `azure.yaml` service mapping, and `azd up/deploy` convenience. It *can* deploy into a pre-provisioned RG via the beta [resource-group-scoped deployments](https://learn.microsoft.com/azure/developer/azure-developer-cli/resource-group-scoped-deployments) feature (`targetScope = 'resourceGroup'` + `AZURE_RESOURCE_GROUP`), but that requires the template itself to be RG-scoped — azd doesn't switch between a subscription-scoped full-stack template and an RG-scoped app-layer template within one project, which is exactly this repo's dual-target shape. Plain `az deployment sub create` / `az deployment group create` + `az containerapp update` stays simpler and fully scriptable in CI. **Skip.**

### PSRule for Azure — adopt (module, not the action)

[Azure/PSRule.Rules.Azure](https://github.com/Azure/PSRule.Rules.Azure) is **active, not deprecated** — v1.47.0 (2026-01-08), 392 releases, 500+ WAF-aligned rules, maintainer active; no maintenance-mode announcement exists on the repo (the deprecation rumor is **UNVERIFIED / not confirmed at the source**). It analyzes Bicep via ARM expansion (`AZURE_BICEP_FILE_EXPANSION`). Caveat: the official GitHub Action [microsoft/ps-rule](https://github.com/microsoft/ps-rule/releases/latest) is stale (v2.9.0, 2023-06-18, pinned to PSRule v2.x) — invoke the PowerShell module directly (`Assert-PSRule`) in a script step instead. Value here: WAF/security evidence for the production RG handover to IS, beyond what the Bicep linter checks. **Adopt.**

### Azure MCP Server — skip for now

The repo moved: [Azure/azure-mcp was archived 2025-08-25](https://github.com/Azure/azure-mcp); development is at [microsoft/mcp → servers/Azure.Mcp.Server](https://github.com/microsoft/mcp/blob/main/servers/Azure.Mcp.Server/README.md). Very active (stable 2.0.5, 2026-07-10; 3.0.0-beta.25, 2026-07-11 with 422 tools and explicit Claude Code instructions). It covers 44+ services including PostgreSQL, Container Apps, Monitor, Bicep schemas/AVM lookup, and NL→az-command generation; installable via `npx @azure/mcp`, dotnet tool, or Docker. But it largely wraps operations the agent already performs through `az`/`azd` in the shell, at a context cost of hundreds of tool schemas. Its genuinely distinctive pieces (Bicep schema/AVM lookup, Monitor queries) are also reachable via Microsoft Learn MCP + `az monitor`. The official [Azure Skills plugin for Claude Code](https://learn.microsoft.com/azure/developer/azure-skills/install) (`/plugin marketplace add microsoft/azure-skills`) is real and configures Azure MCP + a skills layer — same trade-off. **Skip both; revisit if az-in-shell friction (auth, output parsing) becomes a recurring tax.** az CLI itself: **2.88.0 (2026-07-07)** ([Azure/azure-cli](https://github.com/Azure/azure-cli/releases/latest)) — already de facto adopted.

## 3. Power BI / PBIR validation

### Key finding: the POC's two inspectors are one tool

[NatVanG/PBI-Inspector](https://github.com/NatVanG/PBI-Inspector) (v1, `PBIXInspectorCLI`, PBIX-only, last release v1.9.4 Nov 2023 — dormant) explicitly does not support PBIR. PBI Inspector **V2** (`PBIRInspectorCLI`, PBIR-only) was **renamed to [fab-inspector](https://github.com/NatVanG/fab-inspector)** — the author's docs state "The latest PBI Inspector V2 release is now also known as Fab Inspector," and github.com/NatVanG/PBI-InspectorV2 now serves the fab-inspector content. So the POC's "pbi-inspector + fab-inspector" pair collapses to a single successor.

### fab-inspector — adopt as the PBIR rules engine

[NatVanG/fab-inspector](https://github.com/NatVanG/fab-inspector): declarative JSON rules over Fabric item definitions; PBIR explicitly supported ("PBIX files are not currently supported"); since v2.3 it tests any Fabric item's JSON. Actively maintained — **v3.4.0, 2026-06-29**, 29 releases — with CLI + Docker distribution and native `-formats ADO|GitHub` CI output, plus a [VS Code extension](https://github.com/NatVanG/fab-inspector-vscode-ext). The POC's `cc-otel-rules.json` carries forward. **Adopt** (pin the CLI in CI rather than vendoring the binary in-repo as the POC did).

### Custom ajv PBIR schema validator — keep

Microsoft's PBIR schemas live in [microsoft/json-schemas](https://github.com/microsoft/json-schemas) under `fabric/item/report/definition` and are actively versioned (report.json 3.3.0 May 2026; visualContainer.json 2.9.0 May 2026; page.json 2.1.0 Mar 2026), resolvable at the `https://developer.microsoft.com/json-schemas/...` URLs that PBIR files' `$schema` fields point at. No off-the-shelf CI validator over these schemas exists, so the POC's `tools/pbir-validator/validate-pbir.mjs` (ajv 8 + schema cache + fallback map for Desktop-emitted versions Microsoft hasn't published yet) remains the right tool — note the May 2026 schema publications likely shrink the POC's `SCHEMA_FALLBACK` map (e.g. visualContainer 2.9.0 is now published). **Adopt (port forward and re-check the fallback map).** PBIR itself is **still preview** as of July 2026 — Microsoft Learn says "PBIR is currently in preview" and that at GA it becomes the only supported format ([projects-report](https://learn.microsoft.com/power-bi/developer/projects/projects-report#pbir-format)); the service already creates new reports in PBIR by default.

### Tabular Editor 2 BPA — adopt, with one caveat

[TabularEditor/TabularEditor](https://github.com/TabularEditor/TabularEditor) (TE2) is free/open-source; latest **v2.28.0, 2025-03-02** (slow but alive; updated AMO/TOM to 19.112.0). BPA from the CLI is the **`-A`** switch (`TabularEditor.exe <model> -A <rulesfile>`; `-AX` excludes model-annotation rules) per the [command-line docs](https://docs.tabulareditor.com/te2/Command-line-Options.html), which also confirm CI use requires no TE3 license. Default rules: [microsoft/Analysis-Services BestPracticeRules](https://github.com/microsoft/Analysis-Services/tree/master/BestPracticeRules) (last updated v1.2.6, June 2023) — the POC's `BPARules.json` derives from these. Caveat (**PARTIALLY UNVERIFIED**): the CLI docs list Model.bim / database.json folders as inputs; loading a PBIP TMDL `definition\` folder via CLI is common practice but not explicitly documented — verify against this repo's PBIP before wiring CI. TE2 is Windows-only, so BPA runs on a `windows-latest` runner; no cross-platform official alternative exists ([microsoft/fabric-cicd](https://github.com/microsoft/fabric-cicd) is deploy-only; [semantic-link-labs](https://github.com/microsoft/semantic-link-labs) `run_model_bpa` runs in Fabric notebooks against *published* models; an official "semantic-model-audit" CLI is **UNVERIFIED/likely nonexistent**). **Adopt.**

### Minimal CI validation set for a .pbip/PBIR Import-mode report

1. **ajv schema validation** of every PBIR JSON against Microsoft's published schemas (ubuntu runner, Node).
2. **fab-inspector** with the project rules file, `-formats GitHub` (ubuntu runner via CLI/Docker).
3. **TE2 `-A` BPA** over the semantic model (windows-latest runner).

That is exactly the POC's `validate-all.ps1` triad, modernized: one inspector instead of two, CI-hosted binaries instead of vendored ones.

### Skips in this category

- **pbi-tools** ([pbi-tools/pbi-tools](https://github.com/pbi-tools/pbi-tools)): last release 1.2.0, 2025-01-06, nothing since (~18 months); PBIX extract/compile focus with no PBIP/PBIR claims — the native PBIP/PBIR/TMDL formats solve the problem it was built for. **Skip.**
- **Fabric CLI `fab`** ([docs](https://learn.microsoft.com/rest/api/fabric/articles/fabric-command-line-interface), [microsoft/fabric-cli](https://github.com/microsoft/fabric-cli), `pip install ms-fabric-cli`, GA May 2025, v1.6.1 Apr 2026): deploy/automation over Fabric APIs, no validation capability; whether it publishes to a Pro-only (non-Fabric-capacity) workspace is **UNVERIFIED** in primary docs. **Skip for validation; revisit for publish automation.**
- **fabric-cicd** (v1.2.0, 2026-06-30, actively maintained): "full deployment every time," 31 item types incl. Report/SemanticModel — deploy-only, no validation. **Skip for now.**
- **TMDL tooling**: TMDL view in Desktop is GA, but PBIP-with-TMDL-folder is itself **still preview** ([projects-dataset](https://learn.microsoft.com/power-bi/developer/projects/projects-dataset#tmdl-format)). No standalone TMDL linter exists; practical validation = TE2 load or Desktop open. Microsoft's [TMDL VS Code extension](https://marketplace.visualstudio.com/items?itemName=analysis-services.TMDL) is a worthwhile human editor aid, not CI tooling.

## 4. pytest / uv workflow helpers

The POC sink already ran uv (pyproject + uv.lock) and pytest with `asyncio_mode = "auto"`. Keep the footprint minimal:

- **uv** — current **0.11.28 (2026-07-07)**, near-daily releases ([releases](https://github.com/astral-sh/uv/releases)). Confirmed features: [`uv run` / `uv lock`](https://docs.astral.sh/uv/getting-started/features/), `uvx` / `uv tool run`, and PEP 735 [`[dependency-groups]`](https://docs.astral.sh/uv/concepts/projects/dependencies/) (`--dev` = `--group dev`). Put pytest/ruff/sqlfluff in dependency groups; run one-off tools (e.g. sqlfluff ad hoc) via `uvx`. **Adopt.**
- **ruff** — **0.15.21 (2026-07-09)** ([releases](https://github.com/astral-sh/ruff/releases)); the [docs](https://docs.astral.sh/ruff/) confirm it replaces flake8 (+plugins), black, isort, pyupgrade et al., with `ruff format` as the formatter. One tool, one config block. **Adopt.**
- **pytest-asyncio** — **v1.4.0 (2026-05-26)**, Production/Stable ([PyPI](https://pypi.org/project/pytest-asyncio/), [config reference](https://pytest-asyncio.readthedocs.io/en/latest/reference/configuration.html)). Note: [FastAPI's own async-tests docs](https://fastapi.tiangolo.com/advanced/async-tests/) use **anyio** + httpx `ASGITransport` instead; both work, and the POC precedent (`asyncio_mode = "auto"`) makes pytest-asyncio the no-migration choice. **Adopt (keep).**
- **pytest-cov** — **v7.1.0 (2026-03-21)** ([PyPI](https://pypi.org/project/pytest-cov/)). **Adopt.**
- **testcontainers-python** — **v4.14.2 (2026-03-18)** ([PyPI](https://pypi.org/project/testcontainers/), [repo](https://github.com/testcontainers/testcontainers-python)); `postgres` module; requires Docker. It self-provisions the exact Postgres version matching the Azure flexible server, identically on a dev machine and a GitHub ubuntu runner — the right home for integration tests of the sink's writes, schema, and analytics views (and where pgTAP-style assertions land instead, in Python). **Adopt.**
- **pytest-postgresql** — now under [dbfixtures](https://github.com/dbfixtures/pytest-postgresql), **v8.1.0 (2026-05-15)**, maintained; but its default fixtures need local Postgres binaries (`pg_config`/`initdb`), and its `postgresql_noproc` mode just shifts provisioning to CI config. Testcontainers covers the need with less machinery. **Skip.**
- **respx** — alive again (**v0.23.1, 2026-04-08**, [lundberg/respx](https://github.com/lundberg/respx)) but the sink has no outbound httpx traffic to mock (it ingests OTLP and writes Postgres/Blob); if a rare need appears, httpx's built-in `MockTransport` is zero-dep. **Skip.**

## 5. gh automation

- **gh CLI native sub-issues — adopt (and upgrade).** Current **v2.96.0 (2026-07-02)**, which includes a security fix for `gh codespace jupyter` ([cli/cli releases](https://github.com/cli/cli/releases/latest)). Since **v2.94.0 (June 2026)**, `gh issue` natively manages parent/sub-issue relationships, issue types, and dependencies (`--parent`, `--set-parent`, `--remove-parent`) — [GitHub changelog](https://github.blog/changelog/2026-06-10-manage-sub-issues-types-and-dependencies-from-github-cli/), [tracking issue](https://github.com/cli/cli/issues/10298). This obsoletes the `gh api` GraphQL sub-issue recipes in `docs/agents/issue-tracker.md` — simplify them.
- **GitHub Actions CI — adopt.** The POC had no CI at all; the pipeline legs and their current official actions:
  - Python: [astral-sh/setup-uv](https://github.com/astral-sh/setup-uv) **v8 (v8.3.2, 2026-07-08)** — caching `auto`-on for hosted runners, installs Python itself, so `actions/setup-python` is unnecessary. Then `uv run pytest` (+cov), `uv run ruff check` / `ruff format --check`, `uv run sqlfluff lint`.
  - Bicep: `az bicep build` / `bicep lint` step (no dedicated official action exists; [linter docs](https://learn.microsoft.com/azure/azure-resource-manager/bicep/linter)); PSRule via `Assert-PSRule` in a PowerShell step (the [microsoft/ps-rule action](https://github.com/microsoft/ps-rule/releases/latest) is stale at v2.9.0/2023).
  - Deploy: [azure/login](https://github.com/Azure/login) **v3.0.0 (2026-03-17)** + [azure/bicep-deploy](https://github.com/Azure/bicep-deploy) **v2.3.0 (2026-04-15)** (Microsoft-maintained, supports deployments and deployment stacks) — or plain `az deployment` steps, equally supported.
  - PBIR validation: the section-3 triad (two ubuntu jobs + one windows-latest job for TE2).
- **Branch protection — adopt via rulesets.** `gh api` fully manages both [classic branch protection](https://docs.github.com/en/rest/branches/branch-protection) and the newer [repository rulesets](https://docs.github.com/en/rest/repos/rules) (`POST /repos/{owner}/{repo}/rulesets`, with an `evaluate` dry-run mode). Rulesets are the forward-looking choice; a one-time `gh api ... --input ruleset.json` script suffices.
- **GitHub MCP server — skip.** [github/github-mcp-server](https://github.com/github/github-mcp-server) is healthy (**v1.5.0, 2026-06-27**; remote hosted at `api.githubcopilot.com/mcp/`, local Docker, 24 toolsets). No official GitHub statement on the MCP-vs-CLI trade-off exists (**UNVERIFIED as an official position**); third-party measurements put MCP tool-schema overhead at ~10–32× tokens vs `gh` invocations ([Zechner](https://mariozechner.at/posts/2025-08-15-mcp-vs-cli/), [Scalekit](https://www.scalekit.com/blog/mcp-vs-cli-use)). Its real value (OAuth-scoped auth, no-shell hosts) doesn't apply to a shell-equipped Claude Code agent already using `gh`.
- **gh-dash — skip for agents.** [dlvhdr/gh-dash](https://github.com/dlvhdr/gh-dash) (**v4.25.2, 2026-07-10**) is an actively maintained interactive TUI dashboard — human-only by nature; agents should keep using `gh ... --json`.

## 6. Claude Code skills / plugins

- **[anthropics/skills](https://github.com/anthropics/skills)** contains algorithmic-art, docx/pptx/pdf/xlsx, mcp-builder, skill-creator, frontend/canvas design, webapp-testing, etc. — nothing Azure-, Postgres-, SQL-, or Power BI-specific. **Skip** (xlsx and mcp-builder are the only tangentially relevant entries, and both are already available in this environment).
- **Verifiably real official Microsoft entries** (all on Microsoft Learn):
  1. [Azure Skills plugin](https://learn.microsoft.com/azure/developer/azure-skills/install) — `/plugin marketplace add microsoft/azure-skills` → installs a skills layer + Azure MCP Server. **Skip** per the section-2 Azure MCP verdict.
  2. [Azure MCP Server for Claude Code](https://learn.microsoft.com/azure/developer/azure-mcp-server/overview) (`npx -y @azure/mcp@latest server start`) — same verdict.
  3. [Microsoft Learn docs plugin](https://learn.microsoft.com/training/support/mcp-get-started) (`/plugin marketplace add microsoftdocs/mcp`) — **already adopted** in this project as the Microsoft Learn MCP.
- No official Power BI/Fabric-specific Claude Code skill or plugin exists that could be verified. Anything else circulating in community lists was not verifiable to a primary source and is omitted rather than guessed.

---

## Skip list (consolidated, with reasons)

| Tool | Reason |
|---|---|
| `@modelcontextprotocol/server-postgres` | Archived 2025-05-29 with an explicit no-maintenance/no-security notice ([servers-archived](https://github.com/modelcontextprotocol/servers-archived)) |
| crystaldba/postgres-mcp | No release since v0.3.0 (2025-05-16); psql-in-shell already covers the workflow |
| googleapis/genai-toolbox | Healthy (v1.6.0, 2026-07-01) and Azure-Postgres-compatible, but duplicates psql at MCP context cost; fallback only for no-shell surfaces |
| pgTAP | Absent from [Azure flexible server allowed extensions](https://learn.microsoft.com/en-us/azure/postgresql/extensions/concepts-extensions-versions); pytest + testcontainers covers the same assertions |
| sqitch | Maintained, but Perl + deploy/revert/verify machinery exceeds what numbered plain-SQL migrations need |
| alembic | ORM-autogenerate paradigm; wrong fit for a plain-SQL analytics schema |
| azd | Dual-target scopes (subscription full-stack vs RG app-layer) fight its one-template convention; RG-scoped deploys are beta ([docs](https://learn.microsoft.com/azure/developer/azure-developer-cli/resource-group-scoped-deployments)) |
| Azure MCP Server / Azure Skills plugin | Hundreds of tool schemas to wrap what `az` does in the shell; revisit on demonstrated friction |
| microsoft/ps-rule GitHub Action | Stale (v2.9.0, 2023-06-18), pinned to PSRule v2 — use the PowerShell module directly instead |
| pbi-tools | PBIX-era, no PBIR support, no release in ~18 months |
| Fabric CLI `fab` / fabric-cicd | Deploy tools, not validators; Pro-workspace publish support UNVERIFIED — revisit if automated publish is added |
| PBI Inspector v1 (`PBIXInspectorCLI`) | PBIX-only, dormant since Nov 2023; superseded by fab-inspector |
| pytest-postgresql | Default fixtures need local pg binaries; testcontainers is the lighter total setup here |
| respx | No outbound httpx in the sink; httpx `MockTransport` suffices if that changes |
| GitHub MCP server | ~10–32× token overhead vs `gh` for a shell-equipped agent; benefits target no-shell hosts |
| gh-dash | Interactive TUI, human-only; agents use `gh --json` |
| anthropics/skills entries | Nothing stack-specific exists there |

## Uncertainties / UNVERIFIED

- **TE2 CLI loading a PBIP TMDL folder** — commonly done, not explicitly documented in the [TE2 CLI docs](https://docs.tabulareditor.com/te2/Command-line-Options.html); verify locally before wiring the CI job.
- **Fabric CLI publishing to a Pro-only workspace** — plausible but not confirmed in primary docs.
- **PSRule deprecation rumor** — no evidence on the repo; treated as false, but noted since the survey premise raised it.
- **Official GitHub position on MCP-vs-CLI** — none found; token-overhead figures are third-party measurements.
- **alembic current version** — not pursued (skipped on paradigm fit, not on maintenance).
- httpx `MockTransport` docs URL not spot-checked this pass (the feature is standard httpx API).
