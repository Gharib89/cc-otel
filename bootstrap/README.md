# Environment bootstrap runbook

Stand up a cc-otel environment (interim now, prod once IS grants the RG) in a few
repeatable steps. This replaces the hand-typed interim bring-up that produced the
10-item friction inventory on [#48](https://github.com/Gharib89/cc-otel/issues/48).

**Shape (hybrid, thick spine).** This runbook owns the *ordering* and the *human
gates*. The deterministic, error-prone clusters are PowerShell scripts in this
directory (same tested-shim shape as `installer/`). Everything else is an inline,
copy-pasteable command.

**Copy-paste, no substitution.** Every value a command needs lives in `.env.<env>`.
Step 0 loads that file into the process environment; from then on the commands
reference `$env:...` and you paste them verbatim — no `<PLACEHOLDER>` editing.

**Converge, don't fear re-runs.** Every script and every `az`/`dbmate`/`gh`
command here is detect-and-skip or idempotent-by-name: a re-run no-ops on
already-correct state. If a bring-up half-fails, fix the cause and run it again
from the top — it picks up where it left off. This is how the chicken-and-egg
ordering below is resolved: you deploy first, create the DB logins at gate G1,
then re-run the secret/deploy steps to converge on the final `DATABASE_URL`.

**Run from the repo root.** All commands below assume the current directory is the
repo root (so `iac\`, `db\`, `bootstrap\`, and `.env.interim` are all relative),
in **PowerShell**.

## Prerequisites

- **Tools:** PowerShell 5.1+, [`az`](https://learn.microsoft.com/cli/azure/) 2.88.0+,
  [`gh`](https://cli.github.com/), `psql`, and
  [`dbmate`](https://github.com/amacneil/dbmate) on `PATH`.
- **Sessions:** `az login` (the right tenant — see the prod tenant gate below) and
  `gh auth login` (repo secret write access).
- **Run from:** a clone of this repo on the operator's Windows machine, locally and
  interactively. Bootstrap is deliberately *not* a CI task.

## The scripts

| Script | Does | Idempotency |
|---|---|---|
| `assign-rbac.ps1` | Grants a principal a role via ARM REST PUT (bypasses the broken `az role assignment create`; looks the role-def up per-sub) | Deterministic GUID assignment name |
| `ensure-federated-credential.ps1` | Creates the GitHub-OIDC federated credential on the app | Detect-by-subject, create-if-absent |
| `sync-secrets.ps1` | Fans `.env.<env>` out to the `INTERIM_`/`PROD_` GitHub secrets deploy.yml consumes | `gh secret set` upsert |
| `open-my-ip.ps1` / `close-my-ip.ps1` | Opens/removes a Postgres firewall rule for the operator IP | Stable rule name `operator-<initials>` |
| `create-db-logins.sql` | Creates the ingest + read LOGIN users and joins them to the group roles (gate G1) | Create-if-absent + idempotent `GRANT` |

Every script detects current state first and prints what it changed (or that it
no-op'd). Run any with `Get-Help .\bootstrap\<script>.ps1 -Full` for parameters.

## Human gates

The runbook **stops** at these — a person decides, no script assumes:

| Gate | When | Why it is gated |
|---|---|---|
| **G1 · DB login users + passwords** | interim + prod | `cc_otel_read`/`cc_otel_ingest` are `NOLOGIN` group roles (migration `…170001`). The LOGIN users + passwords are created by hand and `GRANT`-joined; there is no secret home by design (no Key Vault, #11). Covers both the sink (ingest) and Power BI (read) logins. |
| **G2 · GHCR classic PAT** | interim + prod | The ACA image-pull credential is a GitHub classic PAT (`read:packages`) created in the GitHub UI — a manual credential action. |
| **G3 · Prod tenant verification** | prod only | The unprefixed-identity design assumes prod lands in tenant `a1a5384f`. A different tenant breaks it (new app + federated credential + prefixed client/tenant). **Verify before prod bootstrap — do not assume.** |
| **G4 · IS RG grant** | prod only | Prod bootstrap cannot start until IS provisions the empty RG and grants Contributor scoped to it (ADR-0004). Prod RG name is still pending ([#23](https://github.com/Gharib89/cc-otel/issues/23)). |
| **G5 · Fleet cutover + POC decommission** | after prod | Parallel cutover (ADR-0004): move the fleet to the new sink and retire the POC only once the new environment is proven. A judgement call, not a script. |

For **interim** bring-up (the common case), gates **G1** and **G2** fire; **G3**
and **G4** are prod-only; **G5** is the very end of the whole migration.

## `.env.<env>` — the one source of truth

`sync-secrets.ps1` reads `.env.<env>` (e.g. `.env.interim`, gitignored) and pushes
the deploy.yml-consumed values to GitHub. The same file also feeds the Bicep
deploy and every command below (via step 0). Keys it must carry:

```sh
# --- shared OIDC app identity ---
AZURE_TENANT_ID="a1a5384f-..."         # -> AZURE_TENANT_ID   GitHub secret (shared, unprefixed)
AZURE_SUBSCRIPTION_ID="58b41413-..."   # -> INTERIM_AZURE_SUBSCRIPTION_ID
AZURE_CLIENT_ID="..."                  # -> AZURE_CLIENT_ID    GitHub secret (shared, unprefixed)
AZURE_APP_OBJECT_ID="..."              # app registration object id (federated credential)
AZURE_SP_OBJECT_ID="..."               # service principal object id (RBAC)

# --- target + operator ---
RESOURCE_GROUP="rg-cc-otel-interim"    # -> INTERIM_RESOURCE_GROUP
OPERATOR_INITIALS="ag"                 # operator firewall rule name: operator-ag

# --- database ---
DATABASE_URL="postgres://ccotel_admin:<pw>@ccotel-pg-interim.postgres.database.azure.com:5432/cc_otel?sslmode=require"
PG_ADMIN_PASSWORD="..."                # Postgres admin password (Bicep input)
CC_OTEL_INGEST_PASSWORD="..."          # sink login password (gate G1)
CC_OTEL_READ_PASSWORD="..."            # Power BI login password (gate G1)

# --- image pull / fleet (Bicep inputs, NOT pushed to GitHub) ---
FLEET_TOKENS='["<bearer-token>"]'
GHCR_USERNAME="<github-username>"
GHCR_TOKEN="<ghcr-classic-pat>"        # from gate G2
```

`DATABASE_URL` starts as the `ccotel_admin` connection (admin has the DDL rights
`dbmate` needs and works as the sink's runtime login for bring-up). Splitting the
sink onto the least-privilege `cc_otel_ingest_user` is a decision at gate G1 (see
there) — it trades the single byte-identical `DATABASE_URL` (#4) for least
privilege, so confirm with Ahmed before adopting it.

---

## Interim bring-up

Interim target: subscription = VS-benefits, RG = `rg-cc-otel-interim`, region
`swedencentral`. Run the steps in order; re-run any step freely.

### 0. Load `.env.interim` into the process environment

Everything below reads `$env:...`. Re-run this whenever you open a new shell or
edit `.env.interim`:

```powershell
Get-Content .\.env.interim | Where-Object { $_ -match '^\s*[^#].+=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2
    Set-Item "env:$($k.Trim())" ($v.Trim().Trim('"').Trim("'"))
}
```

### 1. Sign in and select the subscription

```powershell
az login --tenant $env:AZURE_TENANT_ID
az account set --subscription $env:AZURE_SUBSCRIPTION_ID
gh auth status
```

> The app registration, its service principal, and (for interim) the Contributor
> role assignment are one-time identity setup. If they do not exist yet, see
> *Appendix — first-time identity setup* at the bottom, then fill the
> `AZURE_*_OBJECT_ID` / `AZURE_CLIENT_ID` keys before continuing.

### 2. Federated credential (OIDC login)

```powershell
.\bootstrap\ensure-federated-credential.ps1 -AppObjectId $env:AZURE_APP_OBJECT_ID
```

One branch-based credential (subject `repo:Gharib89/cc-otel:ref:refs/heads/main`),
shared by both environments. No-ops if already present.

### 3. Grant the deploy principal Contributor on the RG

```powershell
.\bootstrap\assign-rbac.ps1 -PrincipalId $env:AZURE_SP_OBJECT_ID `
  -SubscriptionId $env:AZURE_SUBSCRIPTION_ID `
  -Scope "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$($env:RESOURCE_GROUP)"
```

### 4. GATE G2 — GHCR pull PAT

Create a **classic** PAT with `read:packages` in the GitHub UI and set it in
`.env.interim` as `GHCR_TOKEN` (with `GHCR_USERNAME`), then re-run step 0. This is
the ACA image-pull credential; the deploy sets it as an ACA secret.

### 5. Sync secrets to GitHub

```powershell
.\bootstrap\sync-secrets.ps1 -Environment interim
```

### 6. Deploy infrastructure (Bicep first)

**First-time only — seed the `:latest` images.** The Bicep deploy creates the
Container App from `ghcr.io/.../{collector,sink}:latest`, and ACA pulls the image
at create time, so those tags must already exist. A fresh environment has none
(`deploy.yml` only builds SHA tags and *updates* an existing app). Seed them once,
no app needed:

```powershell
gh workflow run publish-images.yml   # then: gh run watch
```

`workflow_dispatch` only fires for workflows already on the **default branch**, so
on the very first bring-up — before `publish-images.yml` lands on `main` — build and
push the seed locally instead (needs Docker + the `GHCR_*` values from step 0):

```powershell
$env:GHCR_TOKEN | docker login ghcr.io -u $env:GHCR_USERNAME --password-stdin
docker build -t ghcr.io/gharib89/cc-otel-collector:latest collector/ ; docker push ghcr.io/gharib89/cc-otel-collector:latest
docker build -t ghcr.io/gharib89/cc-otel-sink:latest      sink/      ; docker push ghcr.io/gharib89/cc-otel-sink:latest
```

**If you seeded locally, grant the repo Actions access to each package** — a
package first pushed by a local PAT is owned by your user and *unlinked* from the
repo, so `deploy.yml`'s built-in `GITHUB_TOKEN` push later fails with `denied:
permission_denied: write_package`. (Packages seeded via `publish-images.yml` link
automatically and need no action.) One-time, in the GitHub UI, for **both**
`cc-otel-collector` and `cc-otel-sink`:

> `github.com/users/<owner>/packages/container/<name>/settings` → **Manage Actions
> access** → **Add repository** → `<owner>/cc-otel` → role **Write**.

Then deploy. Bicep creates the Postgres server and the Container App on those
`:latest` images; `deploy.yml` rolls the real SHA-tagged revision later (step 11).
Secret params come from the env loaded in step 0:

```powershell
az deployment group create `
  --resource-group $env:RESOURCE_GROUP `
  --template-file iac\main.bicep `
  --parameters iac\params\interim.bicepparam `
  --query "properties.provisioningState" -o tsv
```

Expect `Succeeded` (~5–10 min; the Postgres flexible server is the slow part).

> **`CapacityNotAvailable` on the Postgres server?** `swedencentral` occasionally
> rejects the create with `Capacity is not available in this region/zone. Please retry
> after some time.` when the auto-selected availability zone is out of capacity. This
> is transient infra, not a config error. Two in-region levers — no region change, so
> no cost or SKU-availability trade-off:
> 1. **Re-run the step** — a fresh attempt may land on a zone that has capacity.
> 2. **Pin a different zone** — append `--parameters postgresAvailabilityZone=<n>` to
>    the command above and cycle `1` → `2` → `3` (all supported for `Standard_B2s` in
>    swedencentral) until one provisions.

### 7. Open the operator IP, then migrate

```powershell
.\bootstrap\open-my-ip.ps1 -Environment interim -ResourceGroup $env:RESOURCE_GROUP -Initials $env:OPERATOR_INITIALS
dbmate --url $env:DATABASE_URL up
```

Migrations create the schemas and the `cc_otel_read`/`cc_otel_ingest` **NOLOGIN
group roles** (migration `…170001`). They do **not** create logins.

### 8. GATE G1 — DB login users + passwords

Create the sink (ingest) and Power BI (read) LOGIN users and join them to the
group roles. Idempotent; passwords come from `.env.interim`:

```powershell
psql $env:DATABASE_URL -v ON_ERROR_STOP=1 `
  -v ingest_pw="$env:CC_OTEL_INGEST_PASSWORD" `
  -v read_pw="$env:CC_OTEL_READ_PASSWORD" `
  -f bootstrap\create-db-logins.sql
```

**Sink `DATABASE_URL` decision (confirm with Ahmed):** keep the single
`ccotel_admin` `DATABASE_URL` (byte-identical across migrate + sink, #4, but the
sink is over-privileged), **or** repoint the sink to `cc_otel_ingest_user` for
least privilege (then migrate keeps using an admin URL and the single-URL
byte-identity no longer holds — #4 to be revisited). Interim bring-up keeps the
admin URL unless decided otherwise.

### 9. Configure the Power BI data source (read login)

Power BI refreshes from Postgres as the **read** login. In Power BI Desktop, open
the `.pbip` and set the PostgreSQL data-source credentials to:

- **Server:** `ccotel-pg-interim.postgres.database.azure.com` **Database:** `cc_otel`
- **User:** `cc_otel_read_user` **Password:** value of `CC_OTEL_READ_PASSWORD`
- SSL required.

Refresh to confirm the read login sees data, then publish (publishing is manual
via Desktop — CLAUDE.md).

### 10. Converge (only if you changed `DATABASE_URL` at G1)

If you repointed the sink `DATABASE_URL`, re-apply so the GitHub secret and the ACA
sink secret match (both upsert / converge):

```powershell
.\bootstrap\sync-secrets.ps1 -Environment interim
az deployment group create `
  --resource-group $env:RESOURCE_GROUP `
  --template-file iac\main.bicep `
  --parameters iac\params\interim.bicepparam `
  --query "properties.provisioningState" -o tsv
```

Close the operator firewall rule when done with direct DB work:

```powershell
.\bootstrap\close-my-ip.ps1 -Environment interim -ResourceGroup $env:RESOURCE_GROUP -Initials $env:OPERATOR_INITIALS
```

### 11. Push a real image and roll the revision

Bicep left ACA on `:latest`; dispatch `deploy.yml` once to build a SHA-tagged
image and roll the revision (closes the image chicken-and-egg):

```powershell
gh workflow run deploy.yml -f environment=interim
gh run watch
```

### 12. Repoint local dev `.env`

Point the repo's working `.env` `DATABASE_URL` at interim (was the retired POC
server). Interim is now the dev/target DB for `dbmate` and ad-hoc `psql` until POC
decommission.

### 13. Verify

Run the installer (`installer/install.ps1`) on a machine and confirm telemetry
lands: the sink `/healthz` is green, rows appear in `raw`, and the Power BI
refresh has data. Data flowing end-to-end is the acceptance for interim bring-up.

---

## Prod bring-up

Prod repeats the interim spine with three differences — resolve the prod-only
gates **first**:

- **GATE G3 — verify the tenant.** Confirm prod lands in tenant `a1a5384f`. A
  different tenant means a new app registration, a new federated credential, and
  *prefixed* `AZURE_CLIENT_ID`/`AZURE_TENANT_ID` — a different identity story than
  the shared one this runbook assumes. Do not proceed until verified.
- **GATE G4 — IS RG grant.** Wait for IS to provision the prod RG and grant
  Contributor scoped to it (ADR-0004). The prod RG name is pending ([#23](https://github.com/Gharib89/cc-otel/issues/23)).
- Then make a `.env.prod` with the prod values and run the interim steps with
  `-Environment prod`, `iac/params/prod.bicepparam`, and the prod `RESOURCE_GROUP`.
  The shared federated credential (step 2) is already in place from interim —
  `ensure-federated-credential.ps1` no-ops.

## GATE G5 — fleet cutover + POC decommission

Once prod is proven, cut the fleet over to the prod sink and retire the POC
(parallel cutover, ADR-0004). A judgement call made with Ahmed — not part of any
script.

---

## Appendix — first-time identity setup

Only needed once, if the shared app registration does not exist yet:

```powershell
az ad app create --display-name cc-otel-deploy
$appId = az ad app list --display-name cc-otel-deploy --query "[0].appId" -o tsv
az ad sp create --id $appId
# Record for .env.interim:
az ad app list --display-name cc-otel-deploy --query "[0].{AZURE_CLIENT_ID:appId, AZURE_APP_OBJECT_ID:id}" -o json
az ad sp show --id $appId --query "{AZURE_SP_OBJECT_ID:id}" -o json
```

Then run steps 2–3 to add the federated credential and the RG role assignment.
