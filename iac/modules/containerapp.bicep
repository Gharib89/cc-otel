// Container Apps environment + the single collector+sink app.
// External HTTPS ingress terminates at the COLLECTOR only (:4318); the sink binds
// loopback inside the same app and never gets its own ingress (#6). The collector's
// persistent sending queue lives on an emptyDir volume; minReplicas:1 kills the
// cold-start loss that plagued the POC (#7).

@description('Container Apps managed environment name.')
param environmentName string

@description('Container App name.')
param appName string

@description('Location for the environment and app.')
param location string

@description('Name of the Log Analytics workspace backing the environment logs.')
param logAnalyticsWorkspaceName string

@description('Collector container image (GHCR).')
param collectorImage string

@description('Sink container image (GHCR).')
param sinkImage string

@description('Blob service endpoint the sink writes the reservoir to (managed-identity auth).')
param blobAccountUrl string

@description('Fleet bearer tokens as a YAML list string, e.g. ["tokenA","tokenB"] — the collector parses FLEET_TOKENS as YAML (#6).')
@secure()
param fleetTokens string

@description('PostgreSQL connection string for the sink (DATABASE_URL).')
@secure()
param databaseUrl string

@description('GHCR registry server, e.g. ghcr.io.')
param registryServer string = 'ghcr.io'

@description('GHCR username for the pull credential.')
param registryUsername string

@description('GHCR classic PAT (read:packages) used as the image-pull credential.')
@secure()
param registryPassword string

@description('Resource tags.')
param tags object = {}

// listKeys stays inside this module so the workspace shared key never surfaces as
// a parameter or output.
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: environment.id
    configuration: {
      // Ingress fronts the collector only; the sink is unreachable from outside.
      ingress: {
        external: true
        targetPort: 4318
        transport: 'auto'
        allowInsecure: false
      }
      secrets: [
        { name: 'fleet-tokens', value: fleetTokens }
        { name: 'database-url', value: databaseUrl }
        { name: 'ghcr-pull-token', value: registryPassword }
      ]
      registries: [
        {
          server: registryServer
          username: registryUsername
          passwordSecretRef: 'ghcr-pull-token'
        }
      ]
    }
    template: {
      volumes: [
        {
          name: 'collector-queue'
          storageType: 'EmptyDir'
        }
      ]
      containers: [
        {
          name: 'collector'
          image: collectorImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'FLEET_TOKENS'
              secretRef: 'fleet-tokens'
            }
          ]
          volumeMounts: [
            {
              volumeName: 'collector-queue'
              mountPath: '/var/lib/otelcol/sending-queue'
            }
          ]
        }
        {
          name: 'sink'
          image: sinkImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'DATABASE_URL'
              secretRef: 'database-url'
            }
            {
              name: 'CC_OTEL_BLOB_ACCOUNT_URL'
              value: blobAccountUrl
            }
          ]
        }
      ]
      scale: {
        // Single always-on replica: the collector's file-backed queue is per-replica
        // emptyDir, and the loopback collector→sink hop assumes co-location.
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

@description('Container App system-assigned identity principal ID (for role assignments).')
output principalId string = app.identity.principalId

@description('External ingress FQDN of the collector.')
output ingressFqdn string = app.properties.configuration.ingress.fqdn

@description('Container App name.')
output appName string = app.name
