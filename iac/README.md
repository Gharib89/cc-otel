# `iac/` — Bicep infrastructure

Resource-group-scoped Bicep for the cc-otel production stack (ADR-0004). IS grants
Contributor on a **pre-created** resource group only, so `main.bicep` targets an
existing RG and never creates one. Dual-target by parameterization — one template,
two `.bicepparam` files — not per-environment layers.

## What it deploys

`main.bicep` orchestrates four modules into one RG:

| Module | Resource |
|---|---|
| `modules/containerapp.bicep` | Container Apps env + one app: `collector` (external HTTPS ingress `:4318`) and `sink` (loopback `:8080`, no ingress — #6). System-assigned identity; collector queue on an emptyDir volume; `minReplicas: 1` (#7). |
| `modules/postgres.bicep` | PostgreSQL Flexible Server — Burstable, **public** endpoint + firewall rules, `pg_cron` enabled, `cc_otel` database. |
| `modules/storage.bicep` | Storage account for the redacted-raw blob reservoir (ADR-0005) — StorageV2 / LRS / Hot, container `raw`, **no** lifecycle policy (#15). |
| `modules/monitoring.bicep` | Log Analytics workspace + scheduled-query alerts: collector queue-full / export-failure (#7) and sink strip-fire (#8). |
| `modules/budget.bicep` | RG-scoped monthly cost budget (150 USD) with Actual 50/75/90/100% + Forecasted 100% email alerts. |

`main.bicep` also grants the app identity **Storage Blob Data Contributor** on the
reservoir account (managed-identity blob auth — no keys, ADR-0005).

## Targets

| | Subscription | Resource group | Postgres |
|---|---|---|---|
| **interim** | VS-benefits | `rg-cc-otel-interim` | `Standard_B2s`, 32 GB, 7-day PITR |
| **prod** | `d01c33ab-2bae-4797-ae80-2fc802a26d3d` (Data & Analytics) | _pending IS_ | `Standard_B2ms`, 128 GB, 7-day PITR (ADR-0004) |

Both regions are Sweden Central. The production RG name is still pending IS — pass
it on the deploy command once granted.

## Deploy (manual, per issue #11)

Secrets come from the environment (the deploy workflow injects the `INTERIM_*` /
`PROD_*` repo secrets; `az`/PSRule compile without them via `''` fallbacks):

```sh
export PG_ADMIN_PASSWORD=... FLEET_TOKENS='["token"]' DATABASE_URL=... \
       GHCR_USERNAME=... GHCR_TOKEN=...

# interim
az deployment group create -g rg-cc-otel-interim \
  -f iac/main.bicep -p iac/params/interim.bicepparam

# prod (once IS grants the RG)
az deployment group create -g <PROD_RG> \
  -f iac/main.bicep -p iac/params/prod.bicepparam
```

## Validate locally (mirrors the `iac` CI job)

```sh
az bicep build --file iac/main.bicep --stdout > /dev/null            # lint
az bicep build-params --file iac/params/interim.bicepparam --stdout > /dev/null
# PSRule finds the Bicep CLI on PATH (as CI does). If yours is only under az
# (e.g. ~/.azure/bin), set PSRULE_AZURE_BICEP_PATH to it first.
pwsh -c 'Assert-PSRule -InputPath ./iac/ -Module PSRule.Rules.Azure -Outcome Fail,Error -As Summary'
```

PSRule suppressions live in the repo-root `ps-rule.yaml`; each excluded rule is a
documented POC-scale resiliency/cost trade-off or an architecture requirement.
