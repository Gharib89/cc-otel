// Azure Database for PostgreSQL Flexible Server.
// Public endpoint + firewall (deliberate — keeps Power BI gateway-less, ADR-0004);
// Burstable class; pg_cron enabled for the DB-side mart-refresh / trim jobs.

@description('PostgreSQL Flexible Server name (globally unique within the region).')
param name string

@description('Location for the server.')
param location string

@description('Availability zone ("1"/"2"/"3", or "" to let Azure pick). Pin or cycle this to dodge a zone-level CapacityNotAvailable without leaving the region (which would change cost/SKU availability).')
param availabilityZone string = ''

@description('Compute SKU name, e.g. Standard_B2s (interim) or Standard_B2ms (prod).')
param skuName string

@description('Storage size in GB.')
param storageSizeGB int

@description('Point-in-time-restore backup retention, in days (7–35).')
@minValue(7)
@maxValue(35)
param backupRetentionDays int

@description('Major PostgreSQL version.')
param version string = '16'

@description('Administrator login name.')
param administratorLogin string

@description('Administrator password.')
@secure()
param administratorLoginPassword string

@description('Application database name; also the pg_cron job database.')
param databaseName string

@description('Firewall rules opening the public endpoint to specific ranges. The special rule 0.0.0.0-0.0.0.0 (name "AllowAllAzureServices") lets Azure-hosted services (the Container App) reach the server.')
param firewallRules array

@description('Object ID of the Microsoft Entra user set as the server\'s Entra administrator — the identity that mints per-person team principals (issue #93).')
param entraAdminObjectId string

@description('Sign-in name (UPN) of the Entra administrator.')
param entraAdminLogin string

@description('Resource tags.')
param tags object = {}

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: 'Burstable' // Both targets are Burstable (ADR-0004).
  }
  properties: {
    version: version
    // Omit entirely when unset so Azure picks a zone (empty string is the "no
    // preference" sentinel; sending nothing is the unambiguous form).
    availabilityZone: empty(availabilityZone) ? null : availabilityZone
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      // Password auth stays on: the app path (sink DATABASE_URL), CI migrations, and
      // the Power BI read login all authenticate with passwords. Entra is for humans.
      passwordAuth: 'Enabled'
      tenantId: tenant().tenantId
    }
    storage: {
      storageSizeGB: storageSizeGB
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// pg_cron requires the extension on the allowlist AND preloaded; cron jobs run in
// the application database. shared_preload_libraries forces a server restart, so
// it is applied before the dependent config values.
resource extensionsAllowlist 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: server
  name: 'azure.extensions'
  properties: {
    value: 'PG_CRON'
    source: 'user-override'
  }
}

resource sharedPreload 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: server
  name: 'shared_preload_libraries'
  properties: {
    value: 'pg_cron'
    source: 'user-override'
  }
  dependsOn: [extensionsAllowlist]
}

// Restart-only, and — unlike shared_preload_libraries — Azure does NOT auto-restart
// for it. Bicep has no restart primitive, so setting this value here only marks it
// pending; the deploy/bootstrap flow issues the required restart before migrating
// (#65). Without that restart pg_cron loads against the default DB and every job
// silently no-ops.
resource cronDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: server
  name: 'cron.database_name'
  properties: {
    value: databaseName
    source: 'user-override'
  }
  dependsOn: [sharedPreload]
}

// shared_preload_libraries restarts the server; Azure PG Flexible Server rejects
// concurrent operations mid-restart, so the database and firewall rules are gated
// behind the full configuration chain rather than racing it.
resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [cronDatabase]
}

// The Entra administrator — required for any Entra principal to connect; per-person
// team principals are minted from this login (bootstrap/README.md "Team access").
// Serialized after the database resource: administrator writes are server-level
// operations and Azure PG rejects concurrent operations (same reasoning as the
// configuration chain above).
resource entraAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: server
  name: entraAdminObjectId
  properties: {
    principalType: 'User'
    principalName: entraAdminLogin
    tenantId: tenant().tenantId
  }
  dependsOn: [database]
}

resource firewall 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = [
  for rule in firewallRules: {
    parent: server
    name: rule.name
    properties: {
      startIpAddress: rule.startIpAddress
      endIpAddress: rule.endIpAddress
    }
    // Gated behind entraAdmin (itself behind the configuration chain) so the rule
    // writes never race the server-level administrators operation.
    dependsOn: [entraAdmin]
  }
]

@description('Fully qualified domain name of the server.')
output fqdn string = server.properties.fullyQualifiedDomainName

@description('Server resource name.')
output serverName string = server.name
