# Environment bootstrap runbook

Stand up a cc-otel environment (interim now, prod once IS grants the RG) in a few
repeatable steps. This replaces the hand-typed interim bring-up that produced the
10-item friction inventory on [#48](https://github.com/Gharib89/cc-otel/issues/48).

**Shape (hybrid, thick spine).** This runbook owns the *ordering* and the *human
gates*. The deterministic, error-prone clusters are PowerShell scripts in this
directory (same tested-shim shape as `installer/`). Everything else is an inline,
copy-pasteable command.

**Converge, don't fear re-runs.** Every script and every `az`/`dbmate`/`gh`
command here is detect-and-skip or idempotent-by-name: a re-run no-ops on
already-correct state. If a bring-up half-fails, fix the cause and run it again
from the top — it picks up where it left off. This is how the chicken-and-egg
ordering below is resolved: you deploy with a placeholder `DATABASE_URL`, create
the DB login at its gate, then re-run the secret/deploy steps to converge on the
final value.

## Prerequisites

- **Tools:** PowerShell 5.1+, [`az`](https://learn.microsoft.com/cli/azure/),
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
| `ensure-federated-credential.ps1` | Creates the GitHub-OIDC federated credential on the app | Detect-by-name, create-if-absent |
| `sync-secrets.ps1` | Fans `.env.<env>` out to the `INTERIM_`/`PROD_` GitHub secrets deploy.yml consumes | `gh secret set` upsert |
| `open-my-ip.ps1` / `close-my-ip.ps1` | Opens/removes a Postgres firewall rule for the operator IP | Stable rule name `operator-<initials>` |

Every script detects current state first and prints what it changed (or that it
no-op'd). Run any with `Get-Help .\<script>.ps1 -Full` for parameters.

## Human gates

The runbook **stops** at these — a person decides, no script assumes:

| Gate | When | Why it is gated |
|---|---|---|
| **G1 · DB login users + passwords** | interim + prod | `cc_otel_read`/`cc_otel_ingest` are `NOLOGIN` group roles (migration `…170001`). The LOGIN users + passwords are created by hand and `GRANT`-joined; there is no secret home by design (no Key Vault, #11). |
| **G2 · GHCR classic PAT** | interim + prod | The ACA image-pull credential is a GitHub classic PAT (`read:packages`) created in the GitHub UI — a manual credential action. |
| **G3 · Prod tenant verification** | prod only | The unprefixed-identity design assumes prod lands in tenant `a1a5384f`. A different tenant breaks it (new app + federated credential + prefixed client/tenant). **Verify before prod bootstrap — do not assume.** |
| **G4 · IS RG grant** | prod only | Prod bootstrap cannot start until IS provisions the empty RG and grants Contributor scoped to it (ADR-0004). Prod RG name is still pending ([#23](https://github.com/Gharib89/cc-otel/issues/23)). |
| **G5 · Fleet cutover + POC decommission** | after prod | Parallel cutover (ADR-0004): move the fleet to the new sink and retire the POC only once the new environment is proven. A judgement call, not a script. |

For **interim** bring-up (the common case), gates **G1** and **G2** fire; **G3**
and **G4** are prod-only; **G5** is the very end of the whole migration. That is
the "four gates" the interim walkthrough calls out (G1, G2, and — at the prod
boundary — G3 and G4).

## `.env.<env>` — the one source of truth

`sync-secrets.ps1` reads `.env.<env>` (e.g. `.env.interim`, gitignored) and pushes
the deploy.yml-consumed values to GitHub. The same file's `DATABASE_URL` also
feeds the Bicep deploy below, so the value is byte-identical across the Bicep
input, the sink runtime secret, and the CI migration target. Keys it must carry:

```sh
# --- fanned out to GitHub secrets by sync-secrets.ps1 ---
DATABASE_URL="postgres://<login>:<pw>@ccotel-pg-interim.postgres.database.azure.com:5432/cc_otel?sslmode=require"
AZURE_SUBSCRIPTION_ID="..."      # -> INTERIM_AZURE_SUBSCRIPTION_ID
RESOURCE_GROUP="rg-cc-otel-interim"  # -> INTERIM_RESOURCE_GROUP
AZURE_CLIENT_ID="..."            # -> AZURE_CLIENT_ID   (shared, unprefixed)
AZURE_TENANT_ID="a1a5384f-..."   # -> AZURE_TENANT_ID   (shared, unprefixed)

# --- consumed locally by the Bicep deploy (NOT pushed to GitHub) ---
PG_ADMIN_PASSWORD="..."
FLEET_TOKENS='["<bearer-token>"]'
GHCR_USERNAME="<github-username>"
GHCR_TOKEN="<ghcr-classic-pat>"  # from gate G2
```

`DATABASE_URL` is finalised at gate **G1** (its login/password do not exist until
then). Populate the rest first; re-run `sync-secrets.ps1` after G1 to converge.

---

## Interim bring-up

Interim target: subscription = VS-benefits, RG = `rg-cc-otel-interim`, region
`swedencentral`. Run the steps in order; re-run any step freely.

### 1. Sign in and select the subscription

```sh
az login
az account set --subscription "<INTERIM_SUBSCRIPTION_ID>"
gh auth status
```

### 2. Locate (or create) the OIDC app registration

One app registration is shared across interim and prod. If it already exists, just
grab its ids:

```sh
az ad app list --display-name cc-otel-deploy --query "[0].{appId:appId,objectId:id}" -o table
az ad sp show --id <APP_ID> --query id -o tsv   # the service principal object id
```

If it does not exist yet, create it once:

```sh
az ad app create --display-name cc-otel-deploy
az ad sp create --id <APP_ID>
```

Record the **app object id**, **app (client) id**, and **SP object id** for the
next steps and for `.env.interim` (`AZURE_CLIENT_ID` = the app/client id).

### 3. Federated credential (OIDC login)

```powershell
.\ensure-federated-credential.ps1 -AppObjectId <APP_OBJECT_ID>
```

Subject is `repo:Gharib89/cc-otel:ref:refs/heads/main` — one branch-based
credential, shared by both environments.

### 4. Grant the deploy principal Contributor

```powershell
.\assign-rbac.ps1 -PrincipalId <SP_OBJECT_ID> -SubscriptionId <INTERIM_SUBSCRIPTION_ID>
```

### 5. GATE G2 — create the GHCR pull PAT

In the GitHub UI, create a **classic** PAT with `read:packages`. Put it in
`.env.interim` as `GHCR_TOKEN` (and set `GHCR_USERNAME`). This is the ACA
image-pull credential; the deploy sets it as an ACA secret.

### 6. Sync secrets to GitHub

Populate `.env.interim` (all keys above except the final `DATABASE_URL`, which
comes at G1), then:

```powershell
.\sync-secrets.ps1 -Environment interim
```

### 7. Deploy infrastructure (Bicep first)

Bicep creates the Postgres server and the Container App with a `:latest`
placeholder image. Secrets come from `.env.interim` as environment variables:

```sh
set -a; . ./.env.interim; set +a     # export the .env.interim keys
az deployment group create -g rg-cc-otel-interim \
  -f iac/main.bicep -p iac/params/interim.bicepparam
```

(In PowerShell, load `.env.interim` into the process env before the `az` call;
the plain values above are what `iac/params/interim.bicepparam` reads.)

### 8. Open the operator IP, then migrate

```powershell
.\open-my-ip.ps1 -Environment interim -ResourceGroup rg-cc-otel-interim -Initials <yours>
```

```sh
dbmate up     # DATABASE_URL from .env — use the admin connection for DDL
```

Migrations create the schemas and the `cc_otel_read`/`cc_otel_ingest` **NOLOGIN
group roles** (migration `…170001`). They do **not** create logins.

### 9. GATE G1 — DB login users + passwords

Connect as admin and create the LOGIN user(s) by hand, then join to the group
role. There is no secret home by design — you hold the password:

```sql
CREATE ROLE cc_otel_ingest_user LOGIN PASSWORD '<choose-a-strong-password>';
GRANT cc_otel_ingest TO cc_otel_ingest_user;
-- optionally a read-only login joined to cc_otel_read
```

Now build the real `DATABASE_URL` from this login and write it into
`.env.interim`.

### 10. Converge the final DATABASE_URL

Re-run the secret fan-out and re-apply the deploy so the sink secret and the CI
migration target match the finalised `DATABASE_URL` (both upsert / converge):

```powershell
.\sync-secrets.ps1 -Environment interim
```
```sh
set -a; . ./.env.interim; set +a
az deployment group create -g rg-cc-otel-interim \
  -f iac/main.bicep -p iac/params/interim.bicepparam
```

Close the operator firewall rule when you are done with direct DB work:

```powershell
.\close-my-ip.ps1 -Environment interim -ResourceGroup rg-cc-otel-interim -Initials <yours>
```

### 11. Push a real image and roll the revision

Bicep left ACA on `:latest`; dispatch `deploy.yml` once to build a SHA-tagged
image and roll the revision (closes the image chicken-and-egg):

```sh
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
- Then run the interim steps with `-Environment prod`, `-ResourceGroup <PROD_RG>`,
  `.env.prod`, and `iac/params/prod.bicepparam`. The shared federated credential
  (step 3) is already in place from interim — `ensure-federated-credential.ps1`
  no-ops.

## GATE G5 — fleet cutover + POC decommission

Once prod is proven, cut the fleet over to the prod sink and retire the POC
(parallel cutover, ADR-0004). A judgement call made with Ahmed — not part of any
script.
