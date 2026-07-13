// Interim target — VS-benefits subscription / rg-cc-otel-poc / Sweden Central.
// Deploy: az deployment group create -g rg-cc-otel-poc -f iac/main.bicep -p iac/params/interim.bicepparam
// Secrets come from the environment (deploy workflow injects the INTERIM_* repo
// secrets); the '' fallbacks let `az bicep`/PSRule compile without them present.
using '../main.bicep'

param environmentName = 'interim'
param location = 'swedencentral'

// Burstable B2s — the cheap interim class (issue #23 scope).
param postgresSkuName = 'Standard_B2s'
param postgresStorageGB = 32
param postgresBackupRetentionDays = 7
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
