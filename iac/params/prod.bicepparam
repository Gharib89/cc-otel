// Production target — Data & Analytics subscription
// (d01c33ab-2bae-4797-ae80-2fc802a26d3d) / Sweden Central.
// The production RG name is still pending IS (tracked in the IS-asks issue); set it
// on the deploy command once granted:
//   az deployment group create -g <PROD_RG> -f iac/main.bicep -p iac/params/prod.bicepparam
// Secrets come from the environment (deploy workflow injects the PROD_* repo secrets).
using '../main.bicep'

param environmentName = 'prod'

// Burstable B2ms / 128 GB / 7-day PITR (ADR-0004).
param postgresSkuName = 'Standard_B2ms'
param postgresStorageGB = 128
param postgresBackupRetentionDays = 7
param postgresAdminUser = 'ccotel_admin'
param postgresAdminPassword = readEnvironmentVariable('PG_ADMIN_PASSWORD', '')
param postgresDatabaseName = 'cc_otel'
param postgresFirewallRules = [
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
