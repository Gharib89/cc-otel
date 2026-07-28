// Storage account for the redacted-raw OTLP blob reservoir (ADR-0005).
// All-Hot, LRS, keep-forever: no lifecycle tiering and no auto-delete (#15).
// Access is managed-identity only (no keys/connection strings) — the caller wires
// the Storage Blob Data Contributor role assignment for the Container App identity.

@description('Storage account name (globally unique, 3–24 lowercase alphanumerics).')
@minLength(3)
@maxLength(24)
param name string

@description('Location for the account.')
param location string

@description('Blob container for the raw reservoir.')
param containerName string = 'raw'

@description('Blob container for the compacted reservoir (ADR-0015) — derived, operator-written.')
param compactedContainerName string = 'compacted'

@description('Blob container for decommission archives (ADR-0016) — unredacted, operator-written.')
param archiveContainerName string = 'archive'

@description('Resource tags.')
param tags object = {}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    // Soft delete guards against accidental deletion; the reservoir itself is
    // keep-forever, so no lifecycle-management (tiering/expiry) policy exists (#15).
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

// Derived read cache, one parquet per (signal, day) — additive to raw and never the replay
// source (ADR-0015). Written by the operator running `tools.compact`, not by the sink, which
// only ever addresses containerName. Same keep-forever posture as raw (no lifecycle policy),
// but for the opposite reason: a partition is ~2 MB/day and rebuildable in ~21 s.
resource compactedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: compactedContainerName
  properties: {
    publicAccess: 'None'
  }
}

// Decommission archives: a pg_dump of a database whose server is being deleted (ADR-0016).
// Its own container, NOT a prefix inside containerName: a dump is unredacted (raw user_email,
// every promoted column), whereas every blob in the raw reservoir is redacted at the sink
// (ADR-0005) and tools.scrub treats that container as its scrubbable surface. Written by the
// operator, never by the sink. Empty in any environment that has not retired a database yet.
resource archiveContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: archiveContainerName
  properties: {
    publicAccess: 'None'
  }
}

@description('Storage account resource ID (for the role assignment).')
output id string = storage.id

@description('Blob service endpoint — the sink CC_OTEL_BLOB_ACCOUNT_URL.')
output blobEndpoint string = storage.properties.primaryEndpoints.blob

@description('Storage account name.')
output name string = storage.name
