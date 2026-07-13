// cc-otel production stack — resource-group-scoped (IS grants Contributor on a
// pre-created RG only; ADR-0004). Deploy with:
//   az deployment group create -g <rg> -f iac/main.bicep -p iac/params/<env>.bicepparam
// Dual-target by parameterization (interim vs prod) — no per-environment layers.

targetScope = 'resourceGroup'

@description('Deployment target — drives resource naming and tags.')
@allowed(['interim', 'prod'])
param environmentName string

@description('Azure region. Defaults to the resource group location (both targets are Sweden Central).')
param location string = resourceGroup().location

@description('Short prefix for resource names.')
param namePrefix string = 'ccotel'

// --- Postgres ---
@description('PostgreSQL compute SKU — Standard_B2s (interim) / Standard_B2ms (prod).')
param postgresSkuName string

@description('PostgreSQL storage size in GB.')
param postgresStorageGB int

@description('PostgreSQL PITR backup retention in days.')
param postgresBackupRetentionDays int

@description('PostgreSQL administrator login.')
param postgresAdminUser string

@description('PostgreSQL administrator password.')
@secure()
param postgresAdminPassword string

@description('Application database name; also the pg_cron job database.')
param postgresDatabaseName string = 'cc_otel'

@description('Public-endpoint firewall rules. Include the special 0.0.0.0-0.0.0.0 rule to let the Container App reach the server.')
param postgresFirewallRules array

// --- Container App images & secrets ---
@description('Collector container image (GHCR).')
param collectorImage string

@description('Sink container image (GHCR).')
param sinkImage string

@description('Fleet bearer tokens as a YAML list string, e.g. ["tokenA"].')
@secure()
param fleetTokens string

@description('PostgreSQL connection string for the sink (DATABASE_URL).')
@secure()
param databaseUrl string

@description('GHCR username for the image-pull credential.')
param ghcrUsername string

@description('GHCR classic PAT (read:packages) image-pull credential.')
@secure()
param ghcrPassword string

// --- Monitoring ---
@description('Log Analytics retention in days.')
param logRetentionInDays int = 30

@description('Optional Action Group resource ID for alert notifications.')
param actionGroupId string = ''

@description('Resource tags applied to every resource.')
param tags object = {
  application: 'cc-otel'
  environment: environmentName
}

var storageName = take(toLower('${namePrefix}sa${uniqueString(resourceGroup().id)}'), 24)
var containerAppName = '${namePrefix}-app-${environmentName}'
var blobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    name: storageName
    location: location
    tags: tags
  }
}

module postgres 'modules/postgres.bicep' = {
  name: 'postgres'
  params: {
    name: '${namePrefix}-pg-${environmentName}'
    location: location
    skuName: postgresSkuName
    storageSizeGB: postgresStorageGB
    backupRetentionDays: postgresBackupRetentionDays
    administratorLogin: postgresAdminUser
    administratorLoginPassword: postgresAdminPassword
    databaseName: postgresDatabaseName
    firewallRules: postgresFirewallRules
    tags: tags
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    workspaceName: '${namePrefix}-law-${environmentName}'
    location: location
    retentionInDays: logRetentionInDays
    actionGroupId: actionGroupId
    tags: tags
  }
}

module containerApp 'modules/containerapp.bicep' = {
  name: 'containerApp'
  params: {
    environmentName: '${namePrefix}-env-${environmentName}'
    appName: containerAppName
    location: location
    logAnalyticsWorkspaceName: monitoring.outputs.workspaceName
    collectorImage: collectorImage
    sinkImage: sinkImage
    blobAccountUrl: storage.outputs.blobEndpoint
    fleetTokens: fleetTokens
    databaseUrl: databaseUrl
    registryUsername: ghcrUsername
    registryPassword: ghcrPassword
    tags: tags
  }
}

// Managed-identity blob access (ADR-0005): the app's system-assigned identity gets
// Storage Blob Data Contributor on the reservoir account — no keys, no connection
// strings. Declared here because it needs both the storage scope and the app's
// principal ID.
resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageName
}

resource blobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, containerAppName, blobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributorRoleId)
    principalId: containerApp.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

@description('Public HTTPS ingress FQDN of the collector — the fleet OTLP endpoint.')
output collectorIngressFqdn string = containerApp.outputs.ingressFqdn

@description('PostgreSQL server FQDN.')
output postgresFqdn string = postgres.outputs.fqdn

@description('Blob reservoir endpoint.')
output blobEndpoint string = storage.outputs.blobEndpoint
