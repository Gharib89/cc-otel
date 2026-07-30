// Interim target — VS-benefits subscription / rg-cc-otel-interim / Sweden Central.
// Deploy: az deployment group create -g rg-cc-otel-interim -f iac/main.bicep -p iac/params/interim.bicepparam
// Secrets come from the environment (deploy workflow injects the INTERIM_* repo
// secrets); the '' fallbacks let `az bicep`/PSRule compile without them present.
using '../main.bicep'

param environmentName = 'interim'
param location = 'swedencentral'

// Burstable B2s — the cheap interim class (issue #23 scope).
param postgresSkuName = 'Standard_B2s'
param postgresStorageGB = 32
param postgresBackupRetentionDays = 7
// "" lets Azure pick the zone. If a deploy hits CapacityNotAvailable, cycle this
// through "1"/"2"/"3" (all supported for B2s in swedencentral) to stay in-region.
param postgresAvailabilityZone = ''
param postgresAdminUser = 'ccotel_admin'
param postgresAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD', '')
// The ITWorx VPN egress ranges live in .env.interim (PG_FIREWALL_RULES, uncommitted)
// — a JSON array of {name,startIpAddress,endIpAddress} objects. This repo is public
// and the ranges map the employer's network perimeter, so they are never committed
// (ADR-0018). Unset compiles to the Azure-services rule alone, which is what lets
// `az bicep build-params` run in CI; bootstrap treats the key as required so a real
// deploy cannot silently drop the rules from IaC.
param postgresFirewallRules = concat([
  // Lets the Container App (Azure-hosted) reach the public endpoint. This is all the
  // ingest pipeline needs; the env-sourced ranges add operator access for ad-hoc psql.
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

param collectorImage = 'ghcr.io/gharib89/cc-otel-collector:latest'
param sinkImage = 'ghcr.io/gharib89/cc-otel-sink:latest'

param fleetTokens = readEnvironmentVariable('FLEET_TOKENS', '')
param databaseUrl = readEnvironmentVariable('DATABASE_URL', '')
param ghcrUsername = readEnvironmentVariable('GHCR_USERNAME', '')
param ghcrPassword = readEnvironmentVariable('GHCR_TOKEN', '')

// Cost budget — fence cc-otel's slice of the shared VS-benefits subscription at 75
// USD/mo (other resources share the credit) so it can't be drained early. RG scope
// means this counts only cc-otel spend. Add more recipients to the array as needed.
param budgetAmount = 75
param budgetContactEmails = ['Ahmed.Gharib@itworx.com']
param budgetStartDate = '2026-07-01'
