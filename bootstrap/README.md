# Environment bootstrap

`bootstrap-environment.ps1` is the primary bring-up and convergence path for both
cc-otel Azure environments. It loads `.env.<env>`, validates all prerequisites,
and continues from real Azure, GitHub, and PostgreSQL state. There is no checkpoint
file: fix any reported gate and run the same command again.

```powershell
.\bootstrap\bootstrap-environment.ps1 -Environment interim
.\bootstrap\bootstrap-environment.ps1 -Environment prod
```

Run it from a clean, pushed `main` checkout at the repo root. Bootstrap always
migrates and deploys the exact GitHub `main` commit; it rejects another branch, a
dirty tracked worktree, or a local `main` that differs from GitHub.

## Scope

The script owns the mechanical path end to end:

1. Load and validate `.env.<env>`; its values overwrite stale process variables.
2. Validate tools, Azure/GitHub sessions, tenant/subscription, RG access, URLs,
   identity object IDs, GHCR PAT, and `Microsoft.App` registration.
3. Reconcile the GitHub OIDC federated credential, RG Contributor assignment, and
   GitHub Actions secrets.
4. Ensure the two GHCR `:latest` seed images exist, dispatching and waiting for
   `publish-images.yml` only when needed.
5. Deploy Bicep, including automatic PostgreSQL availability-zone fallback.
6. Open/update the stable operator-IP PostgreSQL firewall rule.
7. Apply dbmate migrations with the admin connection.
8. Create or rotate the ingest/read login passwords only when authentication does
   not already match `.env.<env>`.
9. Verify the required `pg_cron` jobs and schedules.
10. Dispatch and wait for `deploy.yml` only when ACA is not already running both
    images for the current `main` SHA, then verify the final images.

Power BI configuration/publishing and fleet cutover/POC decommission are outside
this script. They remain operator decisions after the environment is healthy.

## Prerequisites

- PowerShell 5.1+.
- `az` 2.88.0+, `gh`, `git`, `psql`, and dbmate 2.34.1 on `PATH`.
- `az login` in the configured tenant and `gh auth login` with repo secret access.
- A pre-created target RG. For prod, IS creates the RG and grants Ahmed the agreed
  access (ADR-0004); bootstrap does not create or guess it.
- The shared Entra app registration/service principal and their IDs in the env
  file. See *First-time identity setup* below if they do not exist.
- A classic GitHub PAT with `read:packages` in `GHCR_TOKEN`, used by ACA to pull
  private images. PAT creation is a manual GitHub action.

The script is intentionally non-interactive. Missing or empty prerequisites are
reported together where possible, with a command or action to take before rerun.

## `.env.<env>` contract

`.env.interim` and `.env.prod` are gitignored and are the source of truth. Both
must contain every key below:

```dotenv
# Shared OIDC identity
AZURE_TENANT_ID="a1a5384f-..."
AZURE_SUBSCRIPTION_ID="..."
AZURE_CLIENT_ID="..."
AZURE_APP_OBJECT_ID="..."
AZURE_SP_OBJECT_ID="..."

# Target and operator
RESOURCE_GROUP="rg-cc-otel-interim"
OPERATOR_INITIALS="ag"

# PostgreSQL provisioning and identities
PG_ADMIN_PASSWORD="..."
MIGRATION_DATABASE_URL="postgres://ccotel_admin:<admin-password>@ccotel-pg-interim.postgres.database.azure.com:5432/cc_otel?sslmode=require"
DATABASE_URL="postgres://cc_otel_ingest_user:<ingest-password>@ccotel-pg-interim.postgres.database.azure.com:5432/cc_otel?sslmode=require"
CC_OTEL_INGEST_PASSWORD="..."
CC_OTEL_READ_PASSWORD="..."

# Collector and private GHCR pull
FLEET_TOKENS='["<bearer-token>"]'
GHCR_USERNAME="<github-username>"
GHCR_TOKEN="<classic-PAT-with-read:packages>"
```

`MIGRATION_DATABASE_URL` is the privileged admin connection used locally by
bootstrap and pushed to the existing `<ENV>_DATABASE_URL` GitHub secret consumed
by `deploy.yml`. `DATABASE_URL` is the least-privilege sink runtime connection;
Bicep reads it from the process environment and stores it as the ACA sink secret.
See ADR-0006.

The script validates the expected user, `ccotel-pg-<env>` host, `cc_otel` database,
and `sslmode=require` for both URLs. It never prints their values.

On a fresh or partially provisioned environment, the first Bicep pass gives ACA the
admin URL so the sink can start before its LOGIN role exists. Bootstrap immediately
migrates and creates/verifies the login, then performs a second convergent Bicep pass
with the ingest URL. Once ingest authentication works, reruns use only the runtime URL.

## Manual stop-and-resume gates

Bootstrap stops instead of guessing at these boundaries:

- **Missing GHCR PAT:** create a classic PAT with `read:packages`, set
  `GHCR_USERNAME`/`GHCR_TOKEN`, and rerun.
- **`Microsoft.App` unregistered:** run the reported command:

  ```powershell
  az provider register --namespace Microsoft.App --wait
  ```

  Registration is checked before deployment and is never treated as a PostgreSQL
  capacity failure.
- **GitHub Actions package access:** if a package was originally pushed locally,
  grant the repo write access for both packages, then rerun:

  `github.com/users/Gharib89/packages/container/cc-otel-collector/settings`

  `github.com/users/Gharib89/packages/container/cc-otel-sink/settings`

  In each: **Manage Actions access -> Add repository -> Gharib89/cc-otel -> Write**.
- **Prod RG/permission:** have IS create the agreed RG and grant access, update
  `.env.prod`, and rerun.

## PostgreSQL availability-zone fallback

For the environment's tracked SKU (`Standard_B2s` interim, `Standard_B2ms` prod)
and region, bootstrap queries
`az postgres flexible-server list-skus` and uses the returned `supportedZones`.
It never assumes the two SKUs have identical zone support.

Deployment tries Azure automatic zone selection first, then each advertised zone.
A retry occurs only when the structured nested ARM error contains PostgreSQL
`CapacityNotAvailable`. Any unrelated ARM code fails immediately. Zone attempts
are command-line overrides of `postgresAvailabilityZone`; the tracked
`.bicepparam` files are never rewritten. ARM deployments remain incremental, so
resources created by an earlier attempt converge on rerun.

## `pg_cron`

Bicep configures the Azure PostgreSQL server with:

- `azure.extensions = PG_CRON`
- `shared_preload_libraries = pg_cron`
- `cron.database_name = cc_otel`

Dbmate then creates/updates these named jobs, and bootstrap treats a missing or
incorrect schedule as a hard failure:

| Job | UTC schedule | Retention/action |
|---|---|---|
| `refresh-marts` | `0 * * * *` | Refresh all marts hourly |
| `trim-processed-batches` | `17 3 * * *` | Delete ledger rows older than 7 days |
| `trim-mart-refresh-log` | `23 3 * * *` | Delete refresh logs older than 1 year |

The daily cleanup cadence keeps deletes small and retention near its stated
boundary. A corrective migration repairs environments where older migrations
warned and continued before `pg_cron` was ready.

## Persistent operator database access

Bootstrap creates or updates the stable `operator-<initials>` rule to the
operator's current public IP and deliberately leaves it open. Ahmed uses this
access for Power BI configuration, PostgreSQL management, and data analysis. A
later run updates the same rule if the public IP changes; it does not accumulate
rules.

`close-my-ip.ps1` remains available for an explicit future decision to remove
operator access, but it is not part of successful bootstrap.

## Helper scripts

The orchestrator reuses the tested, single-purpose helpers:

| Script | Convergent responsibility |
|---|---|
| `ensure-federated-credential.ps1` | Branch-based GitHub OIDC credential |
| `assign-rbac.ps1` | Deterministic RG role assignment via ARM PUT |
| `sync-secrets.ps1` | Upsert workflow secrets from `.env.<env>` |
| `open-my-ip.ps1` | Stable operator firewall rule |
| `create-db-logins.sql` | Create/rotate login roles and grant group roles |

Run `Get-Help .\bootstrap\<script>.ps1 -Full` for a helper's contract. Helpers are
troubleshooting surfaces; normal bring-up uses `bootstrap-environment.ps1`.

## First-time identity setup

Only do this once if the shared Entra identity does not exist:

```powershell
az ad app create --display-name cc-otel-deploy
$appId = az ad app list --display-name cc-otel-deploy --query "[0].appId" -o tsv
az ad sp create --id $appId
az ad app list --display-name cc-otel-deploy `
  --query "[0].{AZURE_CLIENT_ID:appId,AZURE_APP_OBJECT_ID:id}" -o json
az ad sp show --id $appId --query "{AZURE_SP_OBJECT_ID:id}" -o json
```

Copy the returned values to both env files. Bootstrap then owns the federated
credential and RG assignment.
