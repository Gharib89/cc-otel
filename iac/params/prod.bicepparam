// Production target — Data & Analytics subscription
// (d01c33ab-2bae-4797-ae80-2fc802a26d3d) / Sweden Central.
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
param postgresFirewallRules = [
  {
    name: 'AllowAllAzureServices'
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
  // ITWorx corporate network / VPN egress ranges — operator access for ad-hoc psql
  // and Power BI Desktop publishing over the public endpoint.
  { name: 'ITWorxVpn1', startIpAddress: '196.201.3.16', endIpAddress: '196.201.3.22' }
  { name: 'ITWorxVpn2', startIpAddress: '196.219.42.14', endIpAddress: '196.219.42.14' }
  { name: 'ITWorxVpn3', startIpAddress: '196.22.7.16', endIpAddress: '196.22.7.22' }
  { name: 'ITWorxVpn4', startIpAddress: '217.52.206.214', endIpAddress: '217.52.206.214' }
  { name: 'ITWorxVpn5', startIpAddress: '41.33.165.114', endIpAddress: '41.33.165.118' }
  { name: 'ITWorxVpn6', startIpAddress: '82.129.128.226', endIpAddress: '82.129.128.227' }
  { name: 'ITWorxVpn7', startIpAddress: '82.129.128.230', endIpAddress: '82.129.128.230' }
  { name: 'ITWorxVpn8', startIpAddress: '82.129.222.35', endIpAddress: '82.129.222.36' }
]

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

// Cost budget — 150 USD/mo hard cap (ADR-0004). Add more recipients as needed.
param budgetAmount = 150
param budgetContactEmails = ['Ahmed.Gharib@itworx.com']
param budgetStartDate = '2026-07-01'
