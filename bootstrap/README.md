# Environment bootstrap runbook

Stand up a cc-otel environment (interim now, prod once IS grants the RG) with a
single orchestrator. This replaces the hand-typed interim bring-up that produced
the 10-item friction inventory on [#48](https://github.com/Gharib89/cc-otel/issues/48).

**One command, one input.** `bootstrap.ps1 -Environment interim|prod` drives the
whole ordered spine. Every value it needs is derived from `.env.<env>` (via
`lib/Get-BootstrapConfig.ps1`) — there is no per-command `<PLACEHOLDER>` editing
and no `interim`->`prod` swapping across a dozen commands. Running prod is the
same command with `-Environment prod`.

**Converge, don't fear re-runs.** Every step detects-and-skips or is
idempotent-by-name: a re-run no-ops on already-correct state. Resumption is by
pure idempotency — there is **no state file**. If a bring-up halts (a human gate,
a transient failure), resolve the cause and run it again from the top; the
completed steps no-op and it picks up where it left off.

**Halt-and-instruct at genuine gates.** The orchestrator stops with a clear
message where a human must act (a virgin image registry, an unloaded `pg_cron`,
the Power BI credential step, the final acceptance check) and exits non-zero.
This runbook stays the reference for *why* each gate exists.

**Run from the repo root**, on the operator's Windows machine, locally and
interactively (in **PowerShell**). Bootstrap is deliberately *not* a CI task.

## Quick start

```powershell
.\bootstrap\bootstrap.ps1 -Environment interim              # full ordered spine (resumes via idempotency)
.\bootstrap\bootstrap.ps1 -Environment interim -Step migrate   # run one step standalone
```

A full run stops at the first manual gate (`powerbi`). Configure Power BI, then
finish the tail with `-Step roll-image` and `-Step verify`. On-demand steps
(`close-ip`, `identity`) are never in the default run — invoke them by `-Step`.

## Prerequisites

The `precheck` step validates all of this and reports every gap in one pass, but
have it ready first:

- **Tools:** PowerShell 5.1+, [`az`](https://learn.microsoft.com/cli/azure/) 2.88.0+,
  [`gh`](https://cli.github.com/), `psql`, and
  [`dbmate`](https://github.com/amacneil/dbmate) on `PATH` (plus `docker` for the
  first-time image seed).
- **Sessions:** `az login` (the right tenant — see the prod tenant gate below) and
  `gh auth login` (repo secret write access).
- **`.env.<env>`:** a complete file (keys below) next to the repo root.

## The steps

The default spine runs in this order. `mode` is how the step behaves:
`auto` runs unattended; `gate` asserts a precondition and halts if unmet;
`conditional` runs only when needed; `manual` halts for a human action;
`on-demand` is never in the default run.

| slug | what | mode |
|---|---|---|
| `precheck` | Tools on PATH, `az`/`gh` sessions, tenant+subscription match, all `.env` keys — one consolidated fail-fast report | auto |
| `federated-cred` | Ensure the GitHub-OIDC federated credential on the app | auto |
| `rbac` | Grant the deploy principal Contributor on the RG | auto |
| `seed-images` | Detect the `:latest` images; halt+instruct on a virgin registry (needs Docker) | conditional |
| `sync-secrets` | Fan `.env.<env>` out to the prefixed GitHub secrets | auto |
| `deploy` | Deploy the Bicep template (`CapacityNotAvailable` retry/zone note below) | auto |
| `open-ip` | Open the operator firewall rule; **stays open** (no auto-close) | auto |
| `pg-cron-gate` | Assert `pg_cron` is preloaded and `cron.database_name=cc_otel` is applied (restart if pending) **before** migrating | gate |
| `migrate` | `dbmate up` | auto |
| `db-logins` | Create the ingest + read LOGIN users (passwords from `.env`; was gate G1) | auto |
| `pg-cron-verify` | Assert the 3 cron jobs are present, **active**, and on **cc_otel** | auto |
| `powerbi` | Configure the Power BI Desktop data-source credential | manual |
| `roll-image` | Dispatch `deploy.yml` to roll the SHA-tagged revision | auto |
| `verify` | Run the installer end-to-end acceptance check | manual |
| `close-ip` | Remove the operator firewall rule (deliberate lockdown) | on-demand |
| `identity` | First-time app registration + service principal | on-demand |

The scripts each step delegates to (`assign-rbac.ps1`,
`ensure-federated-credential.ps1`, `sync-secrets.ps1`, `open-my-ip.ps1` /
`close-my-ip.ps1`, `create-db-logins.sql`) are still runnable standalone — every
`.ps1` now takes `-Environment` and derives the rest from `.env.<env>`. Run any
with `Get-Help .\bootstrap\<script>.ps1 -Full`.

## Human gates

The orchestrator **stops** at these — a person decides, no step assumes:

| Gate | When | Handling |
|---|---|---|
| **G1 · DB login users** | interim + prod | **Now automated** by the `db-logins` step: `cc_otel_read`/`cc_otel_ingest` are `NOLOGIN` group roles (migration `...170001`); the LOGIN users + passwords are created from `.env` (no secret home by design — no Key Vault, #11). Covers the sink (ingest) and Power BI (read) logins. |
| **G2 · GHCR classic PAT** | interim + prod | Caught up front by `precheck` (the `GHCR_TOKEN` key). The ACA image-pull credential is a GitHub classic PAT (`read:packages`) created in the GitHub UI — a manual credential action; put it in `.env` before running. |
| **G3 · Prod tenant verification** | prod only | Enforced by `precheck`'s tenant match: the unprefixed-identity design assumes prod lands in tenant `a1a5384f`. A different tenant breaks it (new app + federated credential + prefixed client/tenant). **Verify before prod bootstrap.** |
| **G4 · IS RG grant** | prod only | Prod bootstrap cannot start until IS provisions the empty RG and grants Contributor scoped to it (ADR-0004); `deploy` halts if the RG is absent. Prod RG name is still pending ([#23](https://github.com/Gharib89/cc-otel/issues/23)). |
| **G5 · Fleet cutover + POC decommission** | after prod | Out of scope for the orchestrator. Parallel cutover (ADR-0004): move the fleet and retire the POC only once the new environment is proven. A judgement call — see the end of this file. |

## `.env.<env>` — the one source of truth

`lib/Get-BootstrapConfig.ps1` reads `.env.<env>` (e.g. `.env.interim`, gitignored)
and derives every value the steps use; `sync-secrets.ps1` pushes the
deploy.yml-consumed subset to GitHub. Keys it must carry:

```sh
# --- shared OIDC app identity ---
AZURE_TENANT_ID="a1a5384f-..."         # -> AZURE_TENANT_ID   GitHub secret (shared, unprefixed)
AZURE_SUBSCRIPTION_ID="58b41413-..."   # -> INTERIM_AZURE_SUBSCRIPTION_ID
AZURE_CLIENT_ID="..."                  # -> AZURE_CLIENT_ID    GitHub secret (shared, unprefixed)
AZURE_APP_OBJECT_ID="..."              # app registration object id (federated credential)
AZURE_SP_OBJECT_ID="..."               # service principal object id (RBAC)

# --- target + operator ---
RESOURCE_GROUP="rg-cc-otel-interim"    # -> INTERIM_RESOURCE_GROUP; also derives the RBAC scope
OPERATOR_INITIALS="ag"                 # operator firewall rule name: operator-ag

# --- database ---
DATABASE_URL="postgres://ccotel_admin:<pw>@ccotel-pg-interim.postgres.database.azure.com:5432/cc_otel?sslmode=require"
PG_ADMIN_PASSWORD="..."                # Postgres admin password (Bicep input)
CC_OTEL_INGEST_PASSWORD="..."          # sink login password (db-logins step)
CC_OTEL_READ_PASSWORD="..."            # Power BI login password (db-logins step)

# --- image pull / fleet (Bicep inputs, NOT pushed to GitHub) ---
FLEET_TOKENS='["<bearer-token>"]'
GHCR_USERNAME="<github-username>"
GHCR_TOKEN="<ghcr-classic-pat>"        # from gate G2
```

The loader derives the flexible-server name (`ccotel-pg-<env>`), the secret prefix
(`INTERIM_`/`PROD_`), the RG-scoped role-assignment scope, and the operator rule
name (`operator-<initials>`) — none of these are keys you set.

`DATABASE_URL` is the `ccotel_admin` connection (admin has the DDL rights `dbmate`
needs and works as the sink's runtime login for bring-up). **Interim keeps the
single admin `DATABASE_URL`** (byte-identical across migrate + sink, #4). Splitting
the sink onto the least-privilege `cc_otel_ingest_user` — which trades that
byte-identity for least privilege — is a separate decision to confirm with Ahmed,
not part of the default run.

---

## Interim bring-up

Interim target: subscription = VS-benefits, RG = `rg-cc-otel-interim`, region
`swedencentral`. With a complete `.env.interim` and an `az login` in the interim
tenant:

```powershell
.\bootstrap\bootstrap.ps1 -Environment interim
```

That runs `precheck` through `pg-cron-verify` unattended, then halts at the
`powerbi` manual gate. A few steps warrant notes:

### First-time only — seed the `:latest` images (`seed-images`)

The Bicep deploy creates the Container App from
`ghcr.io/.../{collector,sink}:latest`, and ACA pulls at create time, so those tags
must already exist. A fresh registry has none (`deploy.yml` only builds SHA tags
and *updates* an existing app). The `seed-images` step detects this and halts with
instructions. Seed once:

```powershell
gh workflow run publish-images.yml   # then: gh run watch
```

`workflow_dispatch` only fires for workflows already on the **default branch**, so
on the very first bring-up — before `publish-images.yml` lands on `main` — build
and push the seed locally instead (needs Docker + the `GHCR_*` values):

```powershell
$env:GHCR_TOKEN | docker login ghcr.io -u $env:GHCR_USERNAME --password-stdin
docker build -t ghcr.io/gharib89/cc-otel-collector:latest collector/ ; docker push ghcr.io/gharib89/cc-otel-collector:latest
docker build -t ghcr.io/gharib89/cc-otel-sink:latest      sink/      ; docker push ghcr.io/gharib89/cc-otel-sink:latest
```

**If you seeded locally, grant the repo Actions access to each package** — a
package first pushed by a local PAT is owned by your user and *unlinked* from the
repo, so `deploy.yml`'s built-in `GITHUB_TOKEN` push later fails with `denied:
permission_denied: write_package`. (Packages seeded via `publish-images.yml` link
automatically.) One-time, in the GitHub UI, for **both** `cc-otel-collector` and
`cc-otel-sink`:

> `github.com/users/<owner>/packages/container/<name>/settings` → **Manage Actions
> access** → **Add repository** → `<owner>/cc-otel` → role **Write**.

Then re-run `bootstrap.ps1 -Environment interim`; `seed-images` now passes.

### `deploy` — `CapacityNotAvailable`

`swedencentral` occasionally rejects the Postgres create with `Capacity is not
available in this region/zone. Please retry after some time.` when the
auto-selected availability zone is out of capacity. This is transient infra, not a
config error. Two in-region levers — no region change, so no cost or
SKU-availability trade-off:

1. **Re-run** `bootstrap.ps1 -Environment interim` — a fresh attempt may land on a
   zone that has capacity (completed steps no-op).
2. **Pin a zone** — run `deploy` standalone with a zone param and cycle `1`->`2`->`3`
   (all supported for `Standard_B2s` in swedencentral):
   `az deployment group create ... --parameters postgresAvailabilityZone=<n>`.

### `pg-cron-gate` and `pg-cron-verify`

`pg-cron-gate` runs **before** `migrate` and asserts the two things pg_cron needs
to actually schedule the refresh jobs:

1. `shared_preload_libraries` contains `pg_cron` — the extension is loaded.
   Otherwise migrations `...170004`/`...170012` schedule their jobs under a `RAISE
   WARNING`, are marked applied, and silently skip the jobs forever.
2. `cron.database_name` is `cc_otel` **and not pending a restart.** This parameter
   is restart-only on Azure PG Flexible Server, and Azure does **not** auto-restart
   for it (unlike `shared_preload_libraries`, which it does). Bicep (the `deploy`
   step) sets the value but has no restart primitive, so on a fresh server pg_cron
   still loads against the default `postgres` DB and every `cron.schedule()` in the
   migrations silently no-ops (#65). The gate **restarts the server when the config
   is pending**, then asserts it applied — halting loudly if not, so `dbmate up`
   never runs against a server where the jobs would silently not schedule. (This
   mirrors `deploy.yml`'s pre-migrate gate, #66.)

After `migrate` + `db-logins`, `pg-cron-verify` asserts the three jobs
(`trim-processed-batches`, `refresh-marts`, `trim-mart-refresh-log`) are present,
**active**, and targeting **cc_otel** — catching a job left inactive or scheduled
against the wrong database, not just an absent one. Remediation is instruct-only
(re-apply the owning migration); the schedule stays single-source in the
migrations.

### `powerbi` (manual gate)

Power BI refreshes from Postgres as the **read** login. In Power BI Desktop, open
the `.pbip` and set the PostgreSQL data-source credentials to:

- **Server:** `ccotel-pg-interim.postgres.database.azure.com` **Database:** `cc_otel`
- **User:** `cc_otel_read_user` **Password:** value of `CC_OTEL_READ_PASSWORD`
- SSL required.

Cloud refresh via the Power BI Service is already admitted by the existing
`AllowAllAzureServices` firewall rule, so the operator IP staying open (from
`open-ip`) is only for local work. Refresh to confirm the read login sees data,
then publish (publishing is manual via Desktop — CLAUDE.md).

### Finish the tail

After Power BI is configured:

```powershell
.\bootstrap\bootstrap.ps1 -Environment interim -Step roll-image   # build+roll the SHA revision
.\bootstrap\bootstrap.ps1 -Environment interim -Step verify        # installer end-to-end acceptance
```

`roll-image` dispatches `deploy.yml` (watch with `gh run watch`) to replace the
`:latest` revision Bicep left with a real SHA-tagged image. `verify` prints the
acceptance check: run the installer (`installer/install.ps1`) and confirm the sink
`/healthz` is green, rows land in `raw`, and the Power BI refresh has data — data
flowing end-to-end is the acceptance for interim bring-up.

Then repoint the repo's working `.env` `DATABASE_URL` at interim (was the retired
POC server); interim is now the dev/target DB for ad-hoc `dbmate`/`psql` until POC
decommission. Lock the operator firewall rule back down when done with direct DB
work:

```powershell
.\bootstrap\bootstrap.ps1 -Environment interim -Step close-ip
```

---

## Prod bring-up

Prod is the same command with `-Environment prod` and a `.env.prod` — resolve the
prod-only gates **first**:

- **GATE G3 — verify the tenant.** Confirm prod lands in tenant `a1a5384f`;
  `precheck`'s tenant match enforces it. A different tenant means a new app
  registration, a new federated credential, and *prefixed*
  `AZURE_CLIENT_ID`/`AZURE_TENANT_ID` — a different identity story than the shared
  one this runbook assumes. Do not proceed until verified.
- **GATE G4 — IS RG grant.** Wait for IS to provision the prod RG and grant
  Contributor scoped to it (ADR-0004); `deploy` halts if the RG is absent. The prod
  RG name is pending ([#23](https://github.com/Gharib89/cc-otel/issues/23)).
- Then `.\bootstrap\bootstrap.ps1 -Environment prod`. The shared federated
  credential (`federated-cred`) is already in place from interim and no-ops. The
  deploy uses `iac/params/prod.bicepparam` automatically.

## GATE G5 — fleet cutover + POC decommission

Once prod is proven, cut the fleet over to the prod sink and retire the POC
(parallel cutover, ADR-0004). A judgement call made with Ahmed — not part of any
script or step.

---

## Appendix — first-time identity setup

Only needed once, if the shared app registration does not exist yet. The
`identity` step prints these; run them by hand and record the values in
`.env.<env>`:

```powershell
az ad app create --display-name cc-otel-deploy
$appId = az ad app list --display-name cc-otel-deploy --query "[0].appId" -o tsv
az ad sp create --id $appId
# Record for .env.<env>:
az ad app list --display-name cc-otel-deploy --query "[0].{AZURE_CLIENT_ID:appId, AZURE_APP_OBJECT_ID:id}" -o json
az ad sp show --id $appId --query "{AZURE_SP_OBJECT_ID:id}" -o json
```

Then run `-Step federated-cred` and `-Step rbac` to add the federated credential
and the RG role assignment.
