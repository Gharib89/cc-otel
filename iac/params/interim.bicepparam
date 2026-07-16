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
param postgresFirewallRules = [
  // Lets the Container App (Azure-hosted) reach the public endpoint. This is all the
  // ingest pipeline needs; append operator/office IP ranges here for ad-hoc psql.
  {
    name: 'AllowAllAzureServices'
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
]

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
