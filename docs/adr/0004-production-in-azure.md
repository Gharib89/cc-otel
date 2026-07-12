# Production runs in Azure, not on-prem

**Status:** accepted

Production runs as a **second Azure environment**, not an on-prem VM. The POC first designed an on-prem topology (Linux telemetry VM exposing 443 + Power BI gateway on an existing IS Windows box) and reversed it before build: Ahmed pitched keeping production in Azure and **Karim Khalifa (Practice Manager, Data & AI) approved**. IS provisions a resource group + a managed Azure Database for PostgreSQL Flexible Server (with `pg_cron` enabled) in an ITWorx subscription and grants Ahmed **Contributor scoped to that RG**; Ahmed deploys the application layer (Azure Container Apps environment + collector/sink Container App + Log Analytics) himself via Bicep and runs the schema-v2 migration over psql. This trades a ~$55–120/mo Azure bill for zero VM ops, no separate Power BI gateway machine (Power BI Service reaches Azure Postgres directly), no IS provisioning of compute, and elastic in-place scaling — reusing the Bicep shape proven in the POC. Sizing/tiers were worked out in the POC's `docs/azure-production-sizing.md` (archived at `D:\projects\archive\cc-otel-azure`).

## Consequences

- **The Bicep splits into two targets.** A full-stack definition for the interim POC environment (VS-benefits subscription, `rg-cc-otel-poc`), and an **app-layer-only** production deploy that references IS-provisioned Postgres via existing-resource parameters instead of creating it. Postgres sizing (B2ms / 128 GB / 7-day PITR / `pg_cron`) moves out of Bicep and into the IS provisioning request.
- **Marts refresh via `pg_cron` inside Postgres** (nightly, before the Power BI pull) — no VM cron host exists. Verified supported on Flexible Server (PG 16, `pg_cron` 1.6); requires `shared_preload_libraries` + `azure.extensions` + `cron.database_name=otel`, set by IS at provision time.
- **Cutover is POC-Azure → prod-Azure, in parallel**: the POC env rehearses the full prod stack, the proven stack is re-deployed to the prod RG, and the POC stays live as fallback until the adoption report refreshes green off production (see parallel cutover in CONTEXT.md). Pilot data is not migrated (ADR-0002).
- **Fallback if IS instead hands over connection strings only** (no RG Contributor): the deploy flow changes to IS running the container from a spec we provide. We plan for the Contributor model as the main line.
