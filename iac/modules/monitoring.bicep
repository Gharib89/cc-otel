// Log Analytics workspace (the Container App's log sink) plus scheduled-query log
// alerts over the collector's ingest-reliability signals (#7) and the sink's
// defense-in-depth strip-fire warning (#8).

@description('Log Analytics workspace name.')
param workspaceName string

@description('Location for the workspace and alert rules.')
param location string

@description('Workspace data retention, in days.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 30

@description('Resource tags.')
param tags object = {}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// ContainerAppConsoleLogs_CL is the table the ACA environment streams stdout into;
// Log_s is the log line, ContainerName_s the emitting container. `contains` (not the
// token-based `has`) is used deliberately: it substring-matches, so "queue is full"
// catches both the "sending queue is full" and "sending_queue is full" phrasings the
// collector may emit across versions, and no exact wording has to be pinned.
var alertRules = [
  {
    name: 'ccotel-collector-ingest-failure'
    description: 'Collector export failed or the persistent sending queue is full (#7) — points at a downstream outage or sustained backpressure.'
    severity: 1
    query: 'ContainerAppConsoleLogs_CL | where ContainerName_s == "collector" | where Log_s contains "Exporting failed" or Log_s contains "queue is full"'
  }
  {
    name: 'ccotel-sink-strip-fire'
    description: 'Sink redaction stripped a non-empty defense-in-depth field (#8) — a client-side content gate has leaked and needs investigation.'
    severity: 2
    query: 'ContainerAppConsoleLogs_CL | where ContainerName_s == "sink" | where Log_s contains "a client content gate has leaked"'
  }
]

resource alerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [
  for rule in alertRules: {
    name: rule.name
    location: location
    tags: tags
    properties: {
      displayName: rule.name
      description: rule.description
      severity: rule.severity
      enabled: true
      scopes: [workspace.id]
      evaluationFrequency: 'PT15M'
      windowSize: 'PT15M'
      criteria: {
        allOf: [
          {
            query: rule.query
            timeAggregation: 'Count'
            operator: 'GreaterThan'
            threshold: 0
            failingPeriods: {
              numberOfEvaluationPeriods: 1
              minFailingPeriodsToAlert: 1
            }
          }
        ]
      }
      autoMitigate: true
    }
  }
]

@description('Log Analytics workspace resource ID.')
output workspaceId string = workspace.id

@description('Log Analytics customer/workspace ID (GUID) for the Container App env.')
output workspaceCustomerId string = workspace.properties.customerId

@description('Workspace name.')
output workspaceName string = workspace.name
