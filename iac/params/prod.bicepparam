// Production target — Data & Analytics subscription / Sweden Central.
// The subscription id lives in .env.prod (AZURE_SUBSCRIPTION_ID, uncommitted).
// The production RG name lives in .env.prod (RESOURCE_GROUP, uncommitted); pass it
// on the deploy command:
//   az deployment group create -g "$RESOURCE_GROUP" -f iac/main.bicep -p iac/params/prod.bicepparam
// Secrets come from the environment (deploy workflow injects the PROD_* repo secrets).
using '../main.bicep'

param environmentName = 'prod'
param location = 'swedencentral'

// Burstable B2ms / 128 GB / 7-day PITR (ADR-0004).
param postgresSkuName = 'Standard_B2ms'
param postgresStorageGB = 128
param postgresBackupRetentionDays = 7
// "" lets Azure pick the zone; cycle "1"/"2"/"3" to work around a zone-level
// CapacityNotAvailable without leaving the region.
param postgresAvailabilityZone = ''
param postgresAdminUser = 'ccotel_admin'
param postgresAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD', '')
// The ITWorx VPN egress ranges live in .env.prod (PG_FIREWALL_RULES, uncommitted) —
// a JSON array of {name,startIpAddress,endIpAddress} objects. This repo is public and
// the ranges map the employer's network perimeter, so they are never committed
// (ADR-0018). Unset compiles to the Azure-services rule alone, which is what lets
// `az bicep build-params` run in CI; bootstrap treats the key as required so a real
// deploy cannot silently drop the rules from IaC.
param postgresFirewallRules = concat([
  {
    name: 'AllowAllAzureServices'
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
], json(readEnvironmentVariable('PG_FIREWALL_RULES', '[]')))

// Postgres Entra administrator (issue #93) — Ahmed's identity; per-person team
// access is minted from this login (bootstrap/README.md "Team access"). Committed
// as literals deliberately: directory pointers, not secrets, same person + tenant
// on both targets.
param postgresEntraAdminObjectId = '72599483-8910-479f-a2b3-47b22f225a44'
param postgresEntraAdminLogin = 'Ahmed.Gharib@itworx.com'

// bootstrap's deploy step reads the live Container App's images back and exports
// these (#390) — an RG deploy is authoritative for the resources it declares, so a
// literal :latest here replaced whatever SHA-tagged revision deploy.yml last rolled
// out, silently. The fallback is the first bring-up, before any app exists to read.
param collectorImage = readEnvironmentVariable('COLLECTOR_IMAGE', 'ghcr.io/gharib89/cc-otel-collector:latest')
param sinkImage = readEnvironmentVariable('SINK_IMAGE', 'ghcr.io/gharib89/cc-otel-sink:latest')

param fleetTokens = readEnvironmentVariable('FLEET_TOKENS', '')
param databaseUrl = readEnvironmentVariable('DATABASE_URL', '')
param ghcrUsername = readEnvironmentVariable('GHCR_USERNAME', '')
param ghcrPassword = readEnvironmentVariable('GHCR_TOKEN', '')

// Cost budget — 150 USD/mo hard cap (ADR-0004). Add more recipients as needed.
param budgetAmount = 150
param budgetContactEmails = ['Ahmed.Gharib@itworx.com']
param budgetStartDate = '2026-07-01'
