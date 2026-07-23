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

@description('PostgreSQL availability zone ("1"/"2"/"3", or "" to let Azure pick). Cycle this to work around a zone-level CapacityNotAvailable without changing region.')
param postgresAvailabilityZone string = ''

@description('PostgreSQL administrator login.')
param postgresAdminUser string

@description('PostgreSQL administrator password.')
@secure()
param postgresAdminPassword string

@description('Application database name; also the pg_cron job database.')
param postgresDatabaseName string = 'cc_otel'

@description('Public-endpoint firewall rules. Include the special 0.0.0.0-0.0.0.0 rule to let the Container App reach the server.')
param postgresFirewallRules array

@description('Object ID of the Microsoft Entra user set as the Postgres Entra administrator.')
param postgresEntraAdminObjectId string

@description('Sign-in name (UPN) of the Postgres Entra administrator.')
param postgresEntraAdminLogin string

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

// --- Cost budget ---
@description('Monthly cost cap in USD (150 prod / interim credit slice).')
param budgetAmount int

@description('Email addresses that receive budget threshold notifications.')
param budgetContactEmails array

@description('Budget anchor date — first of a month, fixed so redeploys never shift it.')
param budgetStartDate string

@description('Resource tags applied to every resource.')
param tags object = {
  application: 'cc-otel'
  environment: environmentName
}

// Storage account names allow only lowercase alphanumerics, so strip the separators
// that are legal in the other (hyphenated) resource names derived from namePrefix.
var storageName = take(toLower(replace(replace('${namePrefix}sa${uniqueString(resourceGroup().id)}', '-', ''), '_', '')), 24)
var containerAppName = '${namePrefix}-app-${environmentName}'
var blobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    // storageName is always ≥ 15 chars (uniqueString() alone is 13); take() only caps
    // the upper bound, so it can never fall below the account name's 3-char minimum.
    #disable-next-line BCP334
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
    availabilityZone: postgresAvailabilityZone
    administratorLogin: postgresAdminUser
    administratorLoginPassword: postgresAdminPassword
    databaseName: postgresDatabaseName
    firewallRules: postgresFirewallRules
    entraAdminObjectId: postgresEntraAdminObjectId
    entraAdminLogin: postgresEntraAdminLogin
    tags: tags
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    workspaceName: '${namePrefix}-law-${environmentName}'
    location: location
    retentionInDays: logRetentionInDays
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

module budget 'modules/budget.bicep' = {
  name: 'budget'
  params: {
    name: '${namePrefix}-budget-${environmentName}'
    amount: budgetAmount
    contactEmails: budgetContactEmails
    startDate: budgetStartDate
  }
}

// Managed-identity blob access (ADR-0005): the app's system-assigned identity gets
// Storage Blob Data Contributor on the reservoir account — no keys, no connection
// strings. Declared here because it needs both the storage scope and the app's
// principal ID.
resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  // Same guaranteed-length name as the storage module above (BCP334 is a false positive).
  #disable-next-line BCP334
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
  // storageAccount is an `existing` ref (no implicit dependency), but this assignment
  // is already ordered after the storage module transitively: principalId pulls in the
  // containerApp module, which itself consumes storage.outputs.blobEndpoint. So an
  // explicit dependsOn: [storage] would be redundant (no-unnecessary-dependson).
}

@description('Public HTTPS ingress FQDN of the collector — the fleet OTLP endpoint.')
output collectorIngressFqdn string = containerApp.outputs.ingressFqdn

@description('PostgreSQL server FQDN.')
output postgresFqdn string = postgres.outputs.fqdn

@description('Blob reservoir endpoint.')
output blobEndpoint string = storage.outputs.blobEndpoint
