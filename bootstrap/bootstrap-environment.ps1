#Requires -Version 5.1
<#
.SYNOPSIS
    Converge one cc-otel Azure environment from provisioning through rollout.
.DESCRIPTION
    Loads .env.<environment>, validates prerequisites, and reconciles the Azure,
    GitHub, and PostgreSQL state. Re-running derives progress from real state and
    resumes safely; no local checkpoint file is used.
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('interim', 'prod')]
    [string]$Environment
)

function Write-BootstrapLog {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    Write-Information "[$Level] $Message" -InformationAction Continue
}

function ConvertFrom-BootstrapDotEnv {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $values = [ordered]@{}
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        if ($line -match '^export\s+') { $line = $line -replace '^export\s+', '' }
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) { continue }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($value.Length -ge 2 -and
            (($value[0] -eq '"' -and $value[-1] -eq '"') -or
             ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$key] = $value
    }
    return $values
}

function Import-BootstrapEnvironmentFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Environment file '$Path' does not exist. Create it from bootstrap/README.md."
    }
    $values = ConvertFrom-BootstrapDotEnv -Text (Get-Content -Raw -LiteralPath $Path)
    $required = @(
        'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'AZURE_CLIENT_ID',
        'AZURE_APP_OBJECT_ID', 'AZURE_SP_OBJECT_ID', 'RESOURCE_GROUP',
        'OPERATOR_INITIALS', 'PG_ADMIN_PASSWORD', 'MIGRATION_DATABASE_URL',
        'DATABASE_URL', 'CC_OTEL_INGEST_PASSWORD', 'CC_OTEL_READ_PASSWORD',
        'FLEET_TOKENS', 'GHCR_USERNAME', 'GHCR_TOKEN'
    )
    $missing = @($required | Where-Object {
        -not $values.Contains($_) -or [string]::IsNullOrWhiteSpace([string]$values[$_])
    })
    if ($missing.Count -gt 0) {
        throw "Environment file '$Path' is missing required variable(s): $($missing -join ', ')."
    }
    foreach ($entry in $values.GetEnumerator()) {
        Set-Item -LiteralPath "env:$($entry.Key)" -Value ([string]$entry.Value)
    }
    return $values
}
function Get-BootstrapEnvironmentConfig {
    param(
        [Parameter(Mandatory)][ValidateSet('interim', 'prod')][string]$Environment,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
    )
    $sku = if ($Environment -eq 'interim') { 'Standard_B2s' } else { 'Standard_B2ms' }
    [pscustomobject]@{
        Environment = $Environment
        ResourceGroup = [string]$Values['RESOURCE_GROUP']
        ParameterFile = "iac/params/$Environment.bicepparam"
        Location = 'swedencentral'
        PostgresSkuName = $sku
    }
}

function Get-MicrosoftAppRegistrationState {
    param([Parameter(Mandatory)][string]$SubscriptionId)
    $value = az provider show --namespace Microsoft.App --subscription $SubscriptionId `
        --query registrationState --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect Microsoft.App resource-provider registration.'
    }
    return ([string]$value).Trim()
}

function Get-PostgresSkuCapability {
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$SubscriptionId
    )
    $json = az postgres flexible-server list-skus --location $Location `
        --subscription $SubscriptionId --query '[0]' --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query PostgreSQL SKU capabilities in '$Location'."
    }
    return ($json | ConvertFrom-Json)
}

function Get-SupportedPostgresZone {
    param(
        [Parameter(Mandatory)]$Capabilities,
        [Parameter(Mandatory)][string]$SkuName
    )
    $sku = @(
        $Capabilities.supportedServerEditions |
            ForEach-Object { $_.supportedServerSkus } |
            Where-Object { $_.name -eq $SkuName }
    ) | Select-Object -First 1
    if ($null -eq $sku) {
        throw "PostgreSQL SKU '$SkuName' is not available in the configured region."
    }
    $zones = @($sku.supportedZones | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($zones.Count -eq 0) {
        throw "Azure reports no supported availability zones for PostgreSQL SKU '$SkuName'."
    }
    return $zones
}

function Get-ArmErrorCode {
    param($Value)
    if ($null -eq $Value -or $Value -is [string]) { return @() }

    $codes = @()
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains('code')) { $codes += [string]$Value['code'] }
        foreach ($entry in $Value.GetEnumerator()) {
            if ($entry.Key -ne 'code') { $codes += Get-ArmErrorCode -Value $entry.Value }
        }
        return $codes
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { $codes += Get-ArmErrorCode -Value $item }
        return $codes
    }
    $properties = @($Value.PSObject.Properties)
    $codeProperty = $properties | Where-Object Name -eq 'code' | Select-Object -First 1
    if ($null -ne $codeProperty) { $codes += [string]$codeProperty.Value }
    foreach ($property in $properties) {
        if ($property.Name -ne 'code') {
            $codes += Get-ArmErrorCode -Value $property.Value
        }
    }
    return $codes
}

function Invoke-AzureGroupDeployment {
    param(
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ParameterFile,
        [AllowNull()][string]$AvailabilityZone
    )
    $deploymentName = "cc-otel-bootstrap-$Environment"
    $arguments = @(
        'deployment', 'group', 'create',
        '--name', $deploymentName,
        '--resource-group', $ResourceGroup,
        '--template-file', 'iac/main.bicep',
        '--parameters', $ParameterFile
    )
    if ($null -ne $AvailabilityZone) {
        $arguments += "postgresAvailabilityZone=$AvailabilityZone"
    }
    $arguments += @('--output', 'json', '--only-show-errors')

    $output = & az @arguments 2>&1
    if ($LASTEXITCODE -eq 0) {
        return [pscustomobject]@{ Succeeded = $true; Error = $null }
    }

    # ARM persists the structured nested error on the named deployment. Prefer it
    # over Azure CLI's human-formatted stderr so only the exact capacity code retries.
    $errorJson = az deployment group show --name $deploymentName `
        --resource-group $ResourceGroup --query properties.error --output json `
        --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($errorJson -join ''))) {
        try {
            return [pscustomobject]@{
                Succeeded = $false
                Error = (($errorJson -join "`n") | ConvertFrom-Json)
            }
        }
        catch {
            Write-Verbose "Azure deployment error was not valid JSON: $($_.Exception.Message)"
            # Fall through to a non-retryable CLI error when Azure returned malformed JSON.
        }
    }
    return [pscustomobject]@{
        Succeeded = $false
        Error = [pscustomobject]@{ code = 'AzureCliFailure'; message = ($output -join "`n") }
    }
}

function Invoke-BootstrapDeployment {
    param(
        [Parameter(Mandatory)]$EnvironmentConfig,
        [string]$SubscriptionId = $env:AZURE_SUBSCRIPTION_ID
    )
    $providerState = Get-MicrosoftAppRegistrationState -SubscriptionId $SubscriptionId
    if ($providerState -ne 'Registered') {
        throw (
            "Microsoft.App is '$providerState' in subscription '$SubscriptionId'. " +
            'Run: az provider register --namespace Microsoft.App --wait'
        )
    }

    $capabilities = Get-PostgresSkuCapability -Location $EnvironmentConfig.Location `
        -SubscriptionId $SubscriptionId
    $zones = @(Get-SupportedPostgresZone -Capabilities $capabilities `
        -SkuName $EnvironmentConfig.PostgresSkuName)
    $attempts = @($null) + $zones
    $attemptLabels = @()

    foreach ($zone in $attempts) {
        $label = if ($null -eq $zone) { 'automatic' } else { [string]$zone }
        $attemptLabels += $label
        Write-BootstrapLog "Deploying $($EnvironmentConfig.Environment) with PostgreSQL zone $label."
        $result = Invoke-AzureGroupDeployment `
            -Environment $EnvironmentConfig.Environment `
            -ResourceGroup $EnvironmentConfig.ResourceGroup `
            -ParameterFile $EnvironmentConfig.ParameterFile `
            -AvailabilityZone $zone
        if ($result.Succeeded) {
            return [pscustomobject]@{
                SelectedZone = $zone
                Attempts = $attemptLabels
            }
        }

        $codes = @(Get-ArmErrorCode -Value $result.Error)
        if ($codes -notcontains 'CapacityNotAvailable') {
            $displayCodes = if ($codes.Count -gt 0) { $codes -join ', ' } else { 'unknown' }
            throw "Azure deployment failed with non-capacity error code(s): $displayCodes."
        }
    }

    throw "PostgreSQL capacity was unavailable after attempts: $($attemptLabels -join ', ')."
}

function Assert-ExternalCommand {
    param([Parameter(Mandatory)][string]$Name)
    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH. Install it and rerun bootstrap."
    }
}

function Assert-DatabaseUrlContract {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$ExpectedUser,
        [Parameter(Mandatory)][string]$ExpectedHost,
        [Parameter(Mandatory)][string]$VariableName
    )
    try { $uri = [uri]$Url }
    catch { throw "$VariableName is not a valid PostgreSQL URL." }
    $actualUser = [uri]::UnescapeDataString(($uri.UserInfo -split ':', 2)[0])
    if ($actualUser -ne $ExpectedUser) {
        throw "$VariableName must use PostgreSQL user '$ExpectedUser', not '$actualUser'."
    }
    if ($uri.Host -ne $ExpectedHost) {
        throw "$VariableName must target '$ExpectedHost', not '$($uri.Host)'."
    }
    if ($uri.AbsolutePath.Trim('/') -ne 'cc_otel') {
        throw "$VariableName must target database 'cc_otel'."
    }
    if ($uri.Query -notmatch '(?:^|[?&])sslmode=require(?:&|$)') {
        throw "$VariableName must include sslmode=require."
    }
}

function Assert-GhcrPullCredential {
    param(
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Value
    )
    $headers = @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $Value"
        'User-Agent' = 'cc-otel-bootstrap'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    try {
        $response = Invoke-WebRequest -Uri 'https://api.github.com/user' `
            -Headers $headers -Method Get -UseBasicParsing
    }
    catch {
        throw 'GHCR_TOKEN could not authenticate with GitHub. Create a valid classic PAT and rerun.'
    }
    $scopes = @(([string]$response.Headers['X-OAuth-Scopes'] -split ',') |
        ForEach-Object { $_.Trim() })
    if ($scopes -notcontains 'read:packages') {
        throw 'GHCR_TOKEN must be a classic PAT with the read:packages scope.'
    }
    $identity = $response.Content | ConvertFrom-Json
    if ($identity.login -ne $Username) {
        throw "GHCR_USERNAME '$Username' does not match the PAT owner '$($identity.login)'."
    }
}
function Assert-BootstrapPrerequisite {
    param(
        [Parameter(Mandatory)]$EnvironmentConfig,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Values
    )
    foreach ($command in @('az', 'gh', 'git', 'dbmate', 'psql')) {
        Assert-ExternalCommand -Name $command
    }

    $dirty = git status --porcelain --untracked-files=no
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the Git worktree.' }
    if (-not [string]::IsNullOrWhiteSpace(($dirty -join ''))) {
        throw 'Bootstrap requires a clean worktree for tracked files. Commit or stash changes first.'
    }
    $branch = (git branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or $branch -ne 'main') {
        throw "Bootstrap always deploys main; the current branch is '$branch'."
    }
    $localSha = (git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve local main HEAD.' }
    $remoteSha = (gh api repos/Gharib89/cc-otel/commits/main --jq .sha).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'GitHub authentication failed. Run gh auth login and retry.' }
    if ($localSha -ne $remoteSha) {
        throw "Local main ($localSha) does not match GitHub main ($remoteSha). Pull/push before bootstrap."
    }

    $accountJson = az account show --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Azure authentication failed. Run az login and retry.' }
    $account = $accountJson | ConvertFrom-Json
    if ($account.tenantId -ne $Values['AZURE_TENANT_ID']) {
        throw "Azure CLI is signed into tenant '$($account.tenantId)', expected '$($Values['AZURE_TENANT_ID'])'."
    }
    az account set --subscription $Values['AZURE_SUBSCRIPTION_ID'] --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot select Azure subscription '$($Values['AZURE_SUBSCRIPTION_ID'])'."
    }
    az group show --name $EnvironmentConfig.ResourceGroup --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Resource group '$($EnvironmentConfig.ResourceGroup)' is missing or inaccessible. Have IS create/grant it, then retry."
    }
    gh auth status 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'GitHub authentication failed. Run gh auth login and retry.' }    Assert-GhcrPullCredential -Username $Values['GHCR_USERNAME'] -Value $Values['GHCR_TOKEN']


    $server = "ccotel-pg-$($EnvironmentConfig.Environment).postgres.database.azure.com"
    Assert-DatabaseUrlContract -Url $Values['MIGRATION_DATABASE_URL'] `
        -ExpectedUser 'ccotel_admin' -ExpectedHost $server -VariableName 'MIGRATION_DATABASE_URL'
    Assert-DatabaseUrlContract -Url $Values['DATABASE_URL'] `
        -ExpectedUser 'cc_otel_ingest_user' -ExpectedHost $server -VariableName 'DATABASE_URL'
    return $localSha
}


function Test-GhcrLatestTag {
    param([Parameter(Mandatory)][string]$Package)
    $expression = '.[] | select(.metadata.container.tags[]? == "latest") | .id'
    $result = gh api "/users/Gharib89/packages/container/$Package/versions?per_page=100" `
        --jq $expression 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return -not [string]::IsNullOrWhiteSpace(($result -join ''))
}

function Invoke-GitHubWorkflowAndWait {
    param(
        [Parameter(Mandatory)][string]$Workflow,
        [Parameter(Mandatory)][string]$MainSha,
        [string[]]$Fields = @()
    )
    $previousId = gh run list --workflow $Workflow --branch main --commit $MainSha `
        --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId' 2>$null
    $dispatchArgs = @('workflow', 'run', $Workflow, '--ref', 'main') + $Fields
    & gh @dispatchArgs
    if ($LASTEXITCODE -ne 0) { throw "Could not dispatch GitHub workflow '$Workflow'." }

    $runId = $null
    for ($attempt = 0; $attempt -lt 30 -and [string]::IsNullOrWhiteSpace($runId); $attempt++) {
        Start-Sleep -Seconds 2
        $candidate = gh run list --workflow $Workflow --branch main --commit $MainSha `
            --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId'
        if ($LASTEXITCODE -ne 0) { throw "Could not locate the dispatched '$Workflow' run." }
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and $candidate -ne $previousId) {
            $runId = ([string]$candidate).Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($runId)) {
        throw "Timed out locating the dispatched '$Workflow' run. Inspect GitHub Actions."
    }
    gh run watch $runId --exit-status
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub workflow '$Workflow' failed (run $runId)."
    }
}

function Initialize-SeedImage {
    param([Parameter(Mandatory)][string]$MainSha)
    $collector = Test-GhcrLatestTag -Package 'cc-otel-collector'
    $sink = Test-GhcrLatestTag -Package 'cc-otel-sink'
    if ($collector -and $sink) {
        Write-BootstrapLog 'GHCR :latest seed images already exist (no-op).'
        return
    }
    try {
        Invoke-GitHubWorkflowAndWait -Workflow 'publish-images.yml' -MainSha $MainSha
    }
    catch {
        throw (
            "$($_.Exception.Message) If GHCR reports permission_denied, open both package settings, " +
            'Manage Actions access, add Gharib89/cc-otel, and grant Write; then rerun bootstrap.'
        )
    }
}

function Test-AzurePostgresServer {
    param([Parameter(Mandatory)]$EnvironmentConfig)
    az postgres flexible-server show --name "ccotel-pg-$($EnvironmentConfig.Environment)" `
        --resource-group $EnvironmentConfig.ResourceGroup --output none --only-show-errors `
        2>$null
    return $LASTEXITCODE -eq 0
}
function Test-PostgresConnection {
    param([Parameter(Mandatory)][string]$Url)
    psql $Url -v ON_ERROR_STOP=1 -Atqc 'SELECT 1' 1>$null 2>$null
    return $LASTEXITCODE -eq 0
}

function Get-ReadDatabaseUrl {
    param(
        [Parameter(Mandatory)][string]$MigrationUrl,
        [Parameter(Mandatory)][string]$Value
    )
    $separator = $MigrationUrl.IndexOf('@')
    if ($separator -lt 0) { throw 'MIGRATION_DATABASE_URL has no credential separator.' }
    $tail = $MigrationUrl.Substring($separator + 1)
    $encoded = [uri]::EscapeDataString($Value)
    return "postgres://cc_otel_read_user:$encoded@$tail"
}

function Sync-DatabaseLogin {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    $readUrl = Get-ReadDatabaseUrl -MigrationUrl $Values['MIGRATION_DATABASE_URL'] `
        -Value $Values['CC_OTEL_READ_PASSWORD']
    $ingestWorks = Test-PostgresConnection -Url $Values['DATABASE_URL']
    $readWorks = Test-PostgresConnection -Url $readUrl
    if ($ingestWorks -and $readWorks) {
        Write-BootstrapLog 'Database login credentials already match .env (no-op).'
        return
    }
    # The SQL reads both passwords from the inherited environment, keeping them
    # out of the psql argument list and shell history.
    psql $Values['MIGRATION_DATABASE_URL'] -v ON_ERROR_STOP=1 `
        -f bootstrap/create-db-logins.sql
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create or rotate database login credentials.' }
    if (-not (Test-PostgresConnection -Url $Values['DATABASE_URL']) -or
        -not (Test-PostgresConnection -Url $readUrl)) {
        throw 'Database login verification still fails after credential convergence.'
    }
}

function Assert-PgCronJob {
    param([Parameter(Mandatory)][string]$MigrationDatabaseUrl)
    $rows = psql $MigrationDatabaseUrl -v ON_ERROR_STOP=1 -At -F '|' -c (
        "SELECT jobname, schedule FROM cron.job WHERE jobname IN " +
        "('refresh-marts','trim-processed-batches','trim-mart-refresh-log') ORDER BY jobname"
    )
    if ($LASTEXITCODE -ne 0) { throw 'pg_cron is not available or its jobs cannot be inspected.' }
    $actual = @{}
    foreach ($row in $rows) {
        $parts = ([string]$row) -split '\|', 2
        if ($parts.Count -eq 2) { $actual[$parts[0]] = $parts[1] }
    }
    $expected = [ordered]@{
        'refresh-marts' = '0 * * * *'
        'trim-processed-batches' = '17 3 * * *'
        'trim-mart-refresh-log' = '23 3 * * *'
    }
    $errors = @()
    foreach ($job in $expected.GetEnumerator()) {
        if (-not $actual.ContainsKey($job.Key)) { $errors += "$($job.Key) is missing" }
        elseif ($actual[$job.Key] -ne $job.Value) {
            $errors += "$($job.Key) is '$($actual[$job.Key])', expected '$($job.Value)'"
        }
    }
    if ($errors.Count -gt 0) { throw "pg_cron verification failed: $($errors -join '; ')." }
    Write-BootstrapLog 'All required pg_cron jobs and schedules are correct.'
}

function Test-CurrentMainImage {
    param(
        [Parameter(Mandatory)]$EnvironmentConfig,
        [Parameter(Mandatory)][string]$MainSha
    )
    $images = az containerapp show --name "ccotel-app-$($EnvironmentConfig.Environment)" `
        --resource-group $EnvironmentConfig.ResourceGroup `
        --query 'properties.template.containers[].image' --output tsv --only-show-errors
    if ($LASTEXITCODE -ne 0) { return $false }
    $expected = @(
        "ghcr.io/gharib89/cc-otel-collector:$MainSha",
        "ghcr.io/gharib89/cc-otel-sink:$MainSha"
    )
    return @($expected | Where-Object { $images -notcontains $_ }).Count -eq 0
}

function Invoke-BootstrapEnvironment {
    param([Parameter(Mandatory)][ValidateSet('interim', 'prod')][string]$Environment)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $repoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
    if ((Get-Location).Path -ne $repoRoot) {
        throw "Bootstrap must run from repo root '$repoRoot'."
    }
    $values = Import-BootstrapEnvironmentFile -Path ".env.$Environment"
    $config = Get-BootstrapEnvironmentConfig -Environment $Environment -Values $values
    $mainSha = Assert-BootstrapPrerequisite -EnvironmentConfig $config -Values $values

    $providerState = Get-MicrosoftAppRegistrationState `
        -SubscriptionId $values['AZURE_SUBSCRIPTION_ID']
    if ($providerState -ne 'Registered') {
        throw (
            "Microsoft.App is '$providerState'. Run: " +
            'az provider register --namespace Microsoft.App --wait'
        )
    }

    & '.\bootstrap\ensure-federated-credential.ps1' `
        -AppObjectId $values['AZURE_APP_OBJECT_ID']
    if ($LASTEXITCODE -ne 0) { throw 'Federated-credential convergence failed.' }
    $scope = "/subscriptions/$($values['AZURE_SUBSCRIPTION_ID'])/resourceGroups/$($config.ResourceGroup)"
    & '.\bootstrap\assign-rbac.ps1' `
        -PrincipalId $values['AZURE_SP_OBJECT_ID'] `
        -SubscriptionId $values['AZURE_SUBSCRIPTION_ID'] `
        -Scope $scope
    if ($LASTEXITCODE -ne 0) { throw 'RBAC convergence failed.' }
    & '.\bootstrap\sync-secrets.ps1' -Environment $Environment
    if ($LASTEXITCODE -ne 0) { throw 'GitHub secret synchronization failed.' }

    Initialize-SeedImage -MainSha $mainSha

    # A fresh sink cannot start with the ingest URL until migrations create its
    # LOGIN role. On a rerun, probe the real runtime identity first so an already-
    # converged environment never gets temporarily elevated.
    $serverExists = Test-AzurePostgresServer -EnvironmentConfig $config
    if ($serverExists) {
        & '.\bootstrap\open-my-ip.ps1' -Environment $Environment `
            -ResourceGroup $config.ResourceGroup -Initials $values['OPERATOR_INITIALS']
        if ($LASTEXITCODE -ne 0) { throw 'Operator firewall convergence failed.' }
    }
    $runtimeReady = $serverExists -and (Test-PostgresConnection -Url $values['DATABASE_URL'])
    if (-not $runtimeReady) { $env:DATABASE_URL = $values['MIGRATION_DATABASE_URL'] }
    try {
        $deployment = Invoke-BootstrapDeployment -EnvironmentConfig $config `
            -SubscriptionId $values['AZURE_SUBSCRIPTION_ID']
    }
    finally {
        $env:DATABASE_URL = $values['DATABASE_URL']
    }
    Write-BootstrapLog "Infrastructure converged after zone attempts: $($deployment.Attempts -join ', ')."

    if (-not $serverExists) {
        & '.\bootstrap\open-my-ip.ps1' -Environment $Environment `
            -ResourceGroup $config.ResourceGroup -Initials $values['OPERATOR_INITIALS']
        if ($LASTEXITCODE -ne 0) { throw 'Operator firewall convergence failed.' }
    }
    dbmate --url $values['MIGRATION_DATABASE_URL'] up
    if ($LASTEXITCODE -ne 0) { throw 'dbmate migration failed.' }
    Sync-DatabaseLogin -Values $values
    Assert-PgCronJob -MigrationDatabaseUrl $values['MIGRATION_DATABASE_URL']

    if (-not $runtimeReady) {
        $runtimeDeployment = Invoke-BootstrapDeployment -EnvironmentConfig $config `
            -SubscriptionId $values['AZURE_SUBSCRIPTION_ID']
        Write-BootstrapLog (
            'ACA switched to the least-privilege sink URL after zone attempts: ' +
            ($runtimeDeployment.Attempts -join ', ') + '.'
        )
    }

    if (Test-CurrentMainImage -EnvironmentConfig $config -MainSha $mainSha) {
        Write-BootstrapLog "ACA already runs both main images at $mainSha (no-op)."
    }
    else {
        Invoke-GitHubWorkflowAndWait -Workflow 'deploy.yml' -MainSha $mainSha `
            -Fields @('-f', "environment=$Environment")
    }
    if (-not (Test-CurrentMainImage -EnvironmentConfig $config -MainSha $mainSha)) {
        throw "ACA does not run both expected main images at $mainSha."
    }

    Write-BootstrapLog "Bootstrap complete for '$Environment'."
    Write-BootstrapLog 'The operator PostgreSQL firewall rule remains open by design.'
    return 0
}

# Dot-sourcing exposes the public functions to Pester without starting a live bootstrap.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-BootstrapEnvironment -Environment $Environment)
}
