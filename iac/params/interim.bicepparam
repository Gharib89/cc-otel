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
