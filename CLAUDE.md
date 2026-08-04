# cc-otel

Captures Claude Code developer-usage telemetry from ITWorx developer machines into Postgres for a daily-refresh Power BI adoption report.

Pipeline: Claude Code OTel exporter → OTel Collector (bearer auth) → FastAPI sink → Azure Postgres (raw → staging → marts) → Power BI; redacted-raw OTLP payloads land in a blob reservoir on the side.

## Design sources

- **`CONTEXT.md`** — the glossary. Use its vocabulary in issues, code, and tests; don't drift to the avoided synonyms.
- **`docs/adr/`** — settled decisions: 0001 no traces, 0002 fresh schema / no backfill, 0003 minimal wrapper contract, 0004 production in Azure, 0005 blob raw reservoir, 0006 interim POC backfill, 0007 cost as API-equivalent value, 0008 canonical mart definitions, 0009 roster drops as immutable dated snapshots, 0010 seat marts under OrgScope RLS, 0011 linked identities scoped not merged, 0012 two-tier text floor + compressed spacing, 0013 semantic text tokens diverge from categorical slots, 0014 PPU workspace + hourly refresh + app-with-audiences distribution, 0015 compacted reservoir (one parquet per signal/day, derived + additive), 0016 POC fallback surrendered early (archive + delete `rg-cc-otel-poc` ahead of the cutover gate; amends 0004), 0017 promoted-column window replayed from the reservoir (interim, 2026-07-17 onward, reservoir-disabled sink; amends 0002), 0018 repo stays public / firewall ranges env-sourced / DB reachability residual accepted (amends 0004), 0019 `dq_finding` is an append-only detection log, read through `marts.dq_finding_current`, 0020 cutover data policy (prod inherits interim telemetry from 2026-07-17, archive-first gated interim decommission; amends 0002), 0021 ingest repoint + terminal sweep (interim's sink retargeted at prod, making interim write-quiet by construction; the seats it cannot reach swept once; amends 0020), 0022 report ownership leaves the repo (host/database as M parameters, `powerbi/` frozen as an archive, two unscoped workspace Admins; amends 0004 + 0014), 0023 environment schema status is a scheduled check (daily `dbmate status` per environment, detection only, red run is the whole alerting surface), 0024 roster revocation events exact-date a Claude closure only when the person is left holding no Claude subscription; truncation guards and closure-by-absence stay, and a person's intervals may now have a gap (amends 0009), 0025 a seat interval records the basis for its close (`valid_to_basis` on `staging.stg_seat_interval` + `marts.dim_seat`: revoke-dated / succession-dated / observation-dated, null while open; `valid_to` derived from the basis so the two cannot disagree; settles the option 0024 deferred, amends 0009). Conflicts get surfaced, never silently overridden.
- **Map issue #1** — the full locked design and decision log. Every implementation issue (#17–#31) traces to a decision bullet there; read the relevant bullet before implementing.

## Way of working

- **Issue-driven.** Planned work starts from a GitHub issue. Frontier = open, unblocked, unassigned, lowest number; respect `ready-for-agent` vs `ready-for-human` labels.
- **Claim first**: `gh issue edit <n> --add-assignee @me` before starting.
- **Search before creating.** Before `gh issue create`, search open AND closed issues for the concern (`gh issue list --search "<keyword>" --state all`). Deferred tickets often carry an explicit "unblock when X" — wire/unblock (`--parent`, `--add-blocked-by`) instead of cutting a dup.
- **One issue → one branch → one PR.** Squash-merge, conventional commit title, `Closes #n` in the body.
- **HITL**: `ready-for-human` issues and anything touching schema, scope, or architecture resolve only through live exchange with Ahmed — never self-answered.
- **Fix first; file only forks.** An adjacent find is not automatically a ticket. Rank it before reaching for `gh issue create`: **(1) mechanical, one obviously-right value** — a wrong number, a stale doc figure, a misaligned coordinate — fix it in the current PR; **(2) two or more defensible answers, or it touches schema, scope, or an ADR** — cut a ticket; **(3) re-litigates a decision locked in the last week** — PR comment, not a ticket; **(4) valid but nobody would ever act on it** — one disposition line in the merge summary, nothing durable. The failure mode is filing at the *observation* level instead of the *decision* level: a review agent's job is to produce findings, so findings are not evidence that tickets are owed. More new tickets than the PR has commits means the reviewer is being obeyed rather than triaged.
- **Deferrals get tickets.** A "defer / revisit later" decision that reaches rung 2 cuts a tracking issue carrying its re-entry condition, wired to its blocker (`--add-blocked-by`) — never a prose-only note. Decision-shaped deferrals get `ready-for-human`.
- **Ad-hoc exemption**: small fixes spotted along the way (typos, one-liners, doc nits, any rung-1 find) ride along in the current PR — named in its body — or get a plain commit; no issue ceremony.

## Branch & worktree discipline

The main checkout is shared — Ahmed runs commands in it concurrently. Rules:

- **Never yank the shared checkout's branch.** If it moves under you mid-session (switched to `main` or another branch), don't `git checkout` it back — spin a dedicated sibling worktree (`git worktree add <path> <branch>`) and do all build/test/PR work isolated. Copy gitignored env files (`.env.interim`) in if the work needs cloud access; they won't be committed.
- **Before any git mutation:** `git branch --show-current && git status --short` first.
- **Stage explicit paths, never `git add -A`.** Operator tools regenerate tracked files (`db/schema.sql` re-dumped by `dbmate up`, lockfiles) — `-A` sweeps a stray `schema.sql` change into the PR and trips the CI schema-drift gate. Stage only what this task changed.
- **"Merge" means land-and-clean, end to end:** copy gitignored env files out of the worktree first → squash-merge, confirm the issue closed → delete the remote branch explicitly (`git push origin --delete <branch>`; `gh --delete-branch` fails its local step while `main` is checked out) → remove the worktree + delete the local branch → `git pull --ff-only` main.

## Commands

```sh
uv sync                      # install workspace deps
uv sync --group analysis     # + marimo/DuckDB notebook lab (analysis/); see analysis/README.md
uv run pytest                # unit (sink/tests) + integration (tests/integration)
uv run pytest -m "not integration"  # unit only — the `python` CI job
uv run pytest -m integration # integration only (needs Docker) — the `integration` CI job
uv run ruff check .          # Python lint (CI runs it via pre-commit)
uv run mypy                  # strict type-check, sink/src only — the `python` CI job
uv run sqlfluff lint db/     # SQL lint (CI runs it via pre-commit)
az bicep build --file iac/main.bicep --stdout >/dev/null  # Bicep lint (the `iac` CI job)
Assert-PSRule -InputPath ./iac/ -Module PSRule.Rules.Azure  # Bicep static analysis (pwsh; see iac/README.md)
uv run pre-commit run -a     # all hooks — the `python` CI job's lint/format gate
dbmate new <name>            # new migration in db/migrations/
scripts/dev-migrate.sh       # apply migrations + regenerate schema.sql on throwaway Docker Postgres (the authoring loop)
scripts/dev-migrate.sh --check  # schema-drift verdict: normalized diff vs HEAD, exit 1 on drift (CI + local gate run this)
uv run python -m tools.spec_sync --check       # gate: column_spec.py <-> migrations converge + mart-literal lint (needs Docker)
uv run python -m tools.spec_sync --name <slug> # author: spec delta -> new migration + schema.sql regen
uv run python -m tools.matview_sync --check    # gate: canonical db/views/marts/ files <-> pg_matviews converge, both ways (needs Docker)
uv run python -m tools.matview_sync --name <slug>  # author: edited mart file -> DROP+CREATE+index+GRANT migration (git-HEAD down body); then dev-migrate.sh regenerates schema.sql
uv run python -m tools.roster_load --file <csv> [--as-of YYYY-MM-DD]  # dry-run an IS seat-roster drop: prints target host/db, then the delta (ADR-0009); as-of comes from a dated filename (claude_users_20260802.csv) unless typed, which overrides it (#420)
uv run python -m tools.roster_load --file <csv> [--as-of YYYY-MM-DD] --execute [--force]  # land the drop in ref, then refresh the seat marts + dim_date (--force overrides the as-of/truncation guards)
uv run python -m tools.compact               # dry-run the reservoir compaction catch-up: frozen partitions with no parquet counterpart (ADR-0015)
uv run python -m tools.compact --execute     # build + upload one parquet per (signal, day); --rebuild re-derives existing counterparts (needed after tools.scrub)
uv run python -m tools.basis_drift [--days 7|--since|--until]  # re-check each kept row's kept_basis against a recent window; exit 1 on basis drift (#366)
uv run python -m tools.cutover_copy          # dry-run the interim->prod raw copy: per-seat flip watermarks, what would move vs stay in interim (ADR-0020); reads INTERIM_DATABASE_URL + PROD_DATABASE_URL
uv run python -m tools.cutover_copy --execute  # copy interim rows below each seat's watermark into prod, verify per-seat counts, refresh prod marts; re-run as seats flip
uv run python -m tools.cutover_copy --execute --sweep  # additionally copy [floor, infinity) for seats production has never seen at all (ADR-0021); refuses unless interim has been write-quiet >= 24h on meta.processed_batches, no --force override
scripts/ship/local-gate.sh   # path-aware local mirror of CI (JSON verdict; the ship skill's phase-5 gate)
psql "$DATABASE_URL"         # ad-hoc DB access (Azure otel real data / cc_otel)
```

- Integration tests use **testcontainers** (throwaway Docker Postgres) — never the shared dev DB.
- No MCP servers for Postgres/Azure/GitHub — use the CLIs (`psql`, `az`/Bicep, `gh`).

## Driving PowerShell — output-capture traps

The shell here is **PowerShell** (pwsh primary, WinPS 5.1 on the fleet). Five traps silently corrupt captured results or CI — each reads like a code bug when it's really PS semantics or the harness lying:

- **Empty `[string[]]` return unrolls to `$null`.** `return [string[]]$x` yields `$null` when `$x` is empty; the caller then fails a `Mandatory` bind or throws on `$null.Count` under `Set-StrictMode`. Use `return , [string[]]$x` (unary comma preserves the array). Tests that pipe the array through `Should` mask it — assert the return **without** piping.
- **Native stdout leaks into the return value.** A function calling `dbmate`/`psql`/any native exe returns `@(<tool output>, $rc)`, not `$rc` — a downstream `if ($rc -ne 0)` then evaluates a truthy array and false-halts a step that succeeded. Pipe native output to `| Out-Host` (shown, not returned).
- **Multi-line stdout captures as a `string[]`, one element per line.** `$body = gh issue view N --json body --jq .body` becomes a line array; `.Replace()` member-enumerates and `Set-Content -NoNewline` concatenates with no separator, wiping newlines. Edit large GH issue/PR bodies in **bash** via `--body-file`, never a PS variable round-trip.
- **`ConvertFrom-Json` hands WinPS 5.1 a JSON array back as one object.** `foreach ($c in @($json | ConvertFrom-Json))` binds the whole array instead of enumerating it, so `$c.name` member-enumerates into one bogus joined key; pwsh 7 enumerates, so the same test passes locally and fails CI (#399). Parse `az` list output as `--output tsv` rows. `scripts/ship/local-gate.sh` runs `bootstrap:pester` under 5.1 via `scripts/ship/winps-pester.ps1` — which imports pwsh's Pester 5 by absolute path when 5.1 has none of its own; with no 5.1-reachable Pester 5 at all the group reports `deferred-to-ci`, never `pass` (#401).
- **`.ps1` files must be pure ASCII.** The `bootstrap` job throws on **any** PSScriptAnalyzer finding, Warnings included; `PSUseBOMForUnicodeEncodedFile` fires on a single non-ASCII byte (one em-dash `-` in a comment) while local `-Severity Error` stays green. Use ASCII; grep the diff with a literal-tab bracket so tab indentation isn't a false positive: `LC_ALL=C grep -n $'[^ -~\t]' file.ps1`.

## Dev database

Migration-authoring loop, the throwaway-container rationale, and the `.env` caveat — it names the **live** interim DB since the POC delete (ADR-0016): `db/CLAUDE.md` (loads when working under `db/`).

## Environments & deploys

- Interim env: VS-benefits subscription (`rg-cc-otel-interim`, swedencentral) — still the live env the report reads. The prod RG is granted and `ccotel-pg-prod` exists (since 2026-07-15); interim retires only at the cutover gate (ADR-0004, #248 Part B). Bicep is dual-target.
- Secrets: ACA secrets + GitHub repo secrets with `INTERIM_`/`PROD_` prefixes — no Key Vault.
- Merge triggers CI only. All **app** deploys are manual `workflow_dispatch` with an environment input; migrations run before image rollout. **Infra** (`iac/`) has no workflow — a Bicep change reaches an environment only through the operator-run `bootstrap/bootstrap.ps1 -Environment <env> -Step deploy` (next bullet).
- **Prod DB access**: no open-internet firewall rule — humans reach the public endpoint over the ITWorx VPN (IS-confirmed egress ranges, kept uncommitted in `.env.<env>` as `PG_FIREWALL_RULES` because this repo is public — ADR-0018) and authenticate with their own Entra ID identity; password auth remains only for the app path (sink `DATABASE_URL`), CI migrations, and the Power BI read login. `AllowAllAzureServices` stays for the ACA path, so the endpoint is reachable from any Azure tenant — accepted residual, ADR-0018. Runbook: `bootstrap/README.md` "Team access".
- **Schema status watch**: `env-schema-status.yml` runs `dbmate status --exit-code` against interim and prod on a daily cron (05:00 UTC) plus `workflow_dispatch`; a pending migration fails the run. Detection only — the fix is a deploy. It exists because a database behind `main` still answers every `SELECT *` partition, so a Power BI refresh reports success while dropping the missing columns from the model (ADR-0023, #414).
- **One-time env bring-up** (identity/RBAC, secret fan-out, first infra deploy, DB logins, gates): `bootstrap/bootstrap.ps1 -Environment <interim|prod>` drives the whole ordered spine (or one `-Step <slug>`), deriving every value from `.env.<env>` via `lib/Get-BootstrapConfig.ps1`; `bootstrap/README.md` is the reference for gate reasoning + the per-step table. `sync-secrets.ps1` treats `.env.<env>` as the single source of truth for the prefixed GitHub secrets.
- Full design: issues #11 (secrets/CI-CD) and #23 (Bicep IaC).

## Layout & standards

| Dir | Concern |
|---|---|
| `db/` | dbmate migrations + `schema.sql` + `views/marts/` canonical mart definitions |
| `bootstrap/` | env bring-up runbook + PowerShell scripts (operator-run) |
| `tools/` | Curation + ops tooling over the blob reservoir (sweep, basis drift, data dictionary, replay, scrub, compact) + reference-data ingest (`roster_load.py`) + the interim->prod cutover copy + terminal sweep (`cutover_copy.py`, ADR-0020/0021) + CI gate-path derivation (`gate_paths.py`) |
| `analysis/` | marimo + DuckDB notebook lab over the blob reservoir (on-demand local EDA, `--group analysis`; #87) |
| `scripts/` | skill-sync + cloud-ship bootstrap + dev-migrate + `ship/` (the ship skill's deterministic mechanics: preflight, isolate, claim, local-gate, ci-wait, merge) + `backfill/` (one-shot POC→interim backfill, ADR-0006) |
| `.claude/skills/` | tracked agent skills (vendored + project-native) |

- **Standards are enforced by config, not prose** — ruff (`pyproject.toml`, line 100), mypy (`--strict`, `sink/src` only), sqlfluff (`db/`), PSScriptAnalyzer (`bootstrap/`, ASCII + zero findings), Bicep/PSRule (`iac/`); Python 3.13. The config *is* the spec; this file never restates a rule the linter already owns. Rule changes land in the config first.
- **Everything is a migration** — views, grants, matviews, column-registry rows all land via dbmate; CI checks schema drift; never edit the schema out-of-band. Mart (matview) bodies are the exception to hand-authoring: edit the canonical `db/views/marts/<slug>.sql` and let `matview_sync --name` generate the migration — never hand-paste a mart DROP+CREATE into a new `dbmate new` migration (#263).
- CI is path-filtered per concern — a new top-level concern needs a workflow filter.
- `powerbi/` is a **frozen archive** — the report is owned and authored in the Power BI Service since 2026-08-03 (ADR-0022); never edit it. Owner runbook: `powerbi/HANDOVER.md`.

## Keep docs in sync with code

Every behavior/command/convention change ships its docs in the **same** PR. Coupled artifacts:

- **This file (`CLAUDE.md`)** — any command, layout, convention, or environment fact stated here.
- **`CONTEXT.md`** — glossary; new domain terms use its vocabulary, never a drifting synonym.
- **`docs/adr/`** — a decision conflicting with a settled ADR is surfaced, never silently overridden; a new settled decision gets a new ADR.
- **Map issue #1** — the locked design/decision log; a scope or design shift updates the relevant bullet.
- **`db/schema.sql`** — never hand-edited; regenerated only via `scripts/dev-migrate.sh` (everything is a migration).
- **CI path filters** — a new top-level concern needs its own workflow filter; validate `.github/workflows/**` edits with **actionlint**, not just a YAML parse (`matrix` context is invalid in a step's `shell:` key and fails at startup with no PR check). `scripts/ship/local-gate.sh` derives its selection from the workflows' `paths:` filters (via `tools/gate_paths.py`) — a new workflow still needs a local gate group or an entry in the script's exclusion list.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five canonical labels, used as-is (no remapping). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

### Shipping

`ship` (issue → merge-ready PR, human merge gate), `powerbi-ship`
(`desktop-bound` Power BI issues — Desktop-verified visuals, no Copilot review,
merge gate opens the report in Desktop), `cloud-ship` (unattended routine
fire), and `pbir-gotchas` (Power BI format traps) are **project-native** skills
in `.claude/skills/` — their source of truth is this repo. Issues labeled
`desktop-bound` route through `powerbi-ship`, never `ship` or a cloud fire.
Every other skill under `.claude/skills/` is **vendored** from the operator's
personal skills by `uv run python scripts/sync-skills.py` (run locally, commit
the result; never edit vendored copies by hand). The scheduled routine that
drives `cloud-ship` over the `ready-for-agent` frontier:
`docs/agents/cloud-ship-routine.md`.

### Power BI authoring

Frozen — the report is authored in the Service by its owner, not here (ADR-0022).
Do not edit `powerbi/**`; `powerbi/HANDOVER.md` holds the owner's runbook and the
escalation split. The archived toolchain, kept for a deliberate un-freeze:
`powerbi/CLAUDE.md` (loads when working under `powerbi/`).
