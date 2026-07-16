#Requires -Version 5.1
<#
.SYNOPSIS
    Single resumable orchestrator for a cc-otel environment bring-up.
.DESCRIPTION
    Bootstrap step for issue #64. Drives the automatable spine of the bring-up
    runbook (bootstrap/README.md) from one input, -Environment, deriving every
    value from .env.<env> via lib/Get-BootstrapConfig.ps1 - no per-command copy-
    paste-and-swap. It halts with a clean message at the genuine human gates
    (a virgin image registry, an unloaded pg_cron, the Power BI credential step,
    the final acceptance check) and is resumable by pure idempotency: every step
    detects-and-skips already-correct state, so re-running from the top no-ops up
    to wherever it last halted. No state file.

    Run the whole spine, or one named step standalone:
        bootstrap.ps1 -Environment prod
        bootstrap.ps1 -Environment prod -Step migrate

    The step bodies delegate to the same tested scripts the README documents
    (assign-rbac, ensure-federated-credential, sync-secrets, open/close-my-ip)
    and to inline az / dbmate / psql / gh commands for the rest.
.NOTES
    Exit codes: 0 all selected steps completed * non-zero halted at a gate or a
    manual step (resolve it, then re-run or run the remaining steps by -Step).
    Requires authenticated az + gh sessions; run locally, not in CI.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('interim', 'prod')][string]$Environment,
    # Run a single step by slug instead of the full default spine. On-demand
    # steps (close-ip, identity) are reachable only this way.
    [string]$Step
)

. (Join-Path (Join-Path $PSScriptRoot 'lib') 'Get-BootstrapConfig.ps1') -Environment $Environment

# =============================================================================
# Pure functions (no side effects) - the tested seam.
# =============================================================================

# The three pg_cron jobs the migrations schedule (...170004, ...170012), and the
# database they must target (cron.database_name = cc_otel, set at provision).
$script:ExpectedCronJob = @('trim-processed-batches', 'refresh-marts', 'trim-mart-refresh-log')
$script:CronDatabase = 'cc_otel'

function Get-BootstrapStepList {
    <# .SYNOPSIS The ordered bring-up spine: slug, description, mode, default-run flag. #>
    [OutputType([object[]])]
    param()
    $steps = @(
        @{ Slug = 'precheck';       Mode = 'auto';        Desc = 'Tools, sessions, tenant/subscription match, and .env keys - one fail-fast report' }
        @{ Slug = 'federated-cred'; Mode = 'auto';        Desc = 'Ensure the GitHub-OIDC federated credential on the app' }
        @{ Slug = 'rbac';           Mode = 'auto';        Desc = 'Grant the deploy principal Contributor on the RG' }
        @{ Slug = 'seed-images';    Mode = 'conditional'; Desc = 'Detect the :latest images; halt to seed a virgin registry' }
        @{ Slug = 'sync-secrets';   Mode = 'auto';        Desc = 'Fan .env.<env> out to the prefixed GitHub secrets' }
        @{ Slug = 'deploy';         Mode = 'auto';        Desc = 'Deploy the Bicep template' }
        @{ Slug = 'open-ip';        Mode = 'auto';        Desc = 'Open the operator firewall rule (stays open)' }
        @{ Slug = 'pg-cron-gate';   Mode = 'gate';        Desc = 'Assert pg_cron is preloaded before migrating' }
        @{ Slug = 'migrate';        Mode = 'auto';        Desc = 'Apply the dbmate migrations' }
        @{ Slug = 'db-logins';      Mode = 'auto';        Desc = 'Create the ingest + read LOGIN users (passwords from .env)' }
        @{ Slug = 'pg-cron-verify'; Mode = 'auto';        Desc = 'Assert the 3 cron jobs are active on cc_otel' }
        @{ Slug = 'powerbi';        Mode = 'manual';      Desc = 'Configure the Power BI Desktop data-source credential' }
        @{ Slug = 'roll-image';     Mode = 'auto';        Desc = 'Dispatch deploy.yml to roll the SHA-tagged revision' }
        @{ Slug = 'verify';         Mode = 'manual';      Desc = 'Run the installer end-to-end acceptance check' }
        @{ Slug = 'close-ip';       Mode = 'on-demand';   Desc = 'Remove the operator firewall rule (deliberate lockdown)' }
        @{ Slug = 'identity';       Mode = 'on-demand';   Desc = 'First-time app registration + service principal' }
    )
    foreach ($s in $steps) {
        [pscustomobject]@{
            Slug         = $s.Slug
            Description  = $s.Desc
            Mode         = $s.Mode
            InDefaultRun = ($s.Mode -ne 'on-demand')
        }
    }
}

function Select-BootstrapStep {
    <# .SYNOPSIS The single named step, or the default-run spine when none is named. #>
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][object[]]$All,
        [string]$Step
    )
    if (-not [string]::IsNullOrWhiteSpace($Step)) {
        $match = $All | Where-Object { $_.Slug -eq $Step }
        if (-not $match) {
            $valid = ($All.Slug) -join ', '
            throw "Unknown step '$Step'. Valid steps: $valid."
        }
        return $match
    }
    return $All | Where-Object { $_.InDefaultRun }
}

function Get-PrecheckReport {
    <#
    .SYNOPSIS
        Consolidated fail-fast report: every unmet prerequisite in one list.
    .OUTPUTS
        One string per failure; an empty result means the precheck passed.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Tool,
        [Parameter(Mandatory)][hashtable]$Session,
        [Parameter(Mandatory)][bool]$TenantMatch,
        [Parameter(Mandatory)][bool]$SubMatch,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$MissingEnvKey
    )
    $fail = [System.Collections.Generic.List[string]]::new()
    foreach ($name in ($Tool.Keys | Sort-Object)) {
        if (-not $Tool[$name]) { $fail.Add("Tool not found on PATH: $name") }
    }
    foreach ($name in ($Session.Keys | Sort-Object)) {
        if (-not $Session[$name]) { $fail.Add("Not signed in to '$name' (run its login).") }
    }
    if (-not $TenantMatch) { $fail.Add('Active az tenant does not match .env AZURE_TENANT_ID (prod gate G3).') }
    if (-not $SubMatch) { $fail.Add('Active az subscription does not match .env AZURE_SUBSCRIPTION_ID.') }
    if ($MissingEnvKey.Count -gt 0) { $fail.Add("Missing/empty .env keys: $($MissingEnvKey -join ', ').") }
    return [string[]]$fail
}

function Test-PgCronPreloaded {
    <# .SYNOPSIS True when pg_cron is an entry in a shared_preload_libraries value. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PreloadValue)
    $entries = $PreloadValue -split ',' | ForEach-Object { $_.Trim() }
    return ($entries -contains 'pg_cron')
}

function Get-PgCronJobReport {
    <#
    .SYNOPSIS
        Problems with the scheduled cron jobs: missing, inactive, or wrong DB.
    .DESCRIPTION
        Checks each expected job is present, active, and targets the expected
        database - not merely present (issue #64 owner refinement). An empty
        result means all jobs are healthy.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Job,
        [Parameter(Mandatory)][string[]]$ExpectedName,
        [Parameter(Mandatory)][string]$Database
    )
    $problem = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $ExpectedName) {
        $row = $Job | Where-Object { $_.JobName -eq $name } | Select-Object -First 1
        if (-not $row) {
            $problem.Add("cron job missing: $name")
            continue
        }
        if (-not $row.Active) { $problem.Add("cron job inactive: $name") }
        if ($row.Database -ne $Database) {
            $problem.Add("cron job '$name' targets database '$($row.Database)' (expected $Database)")
        }
    }
    return [string[]]$problem
}

function Get-SeedImagesDecision {
    <# .SYNOPSIS Whether to halt for image seeding, and the operator instruction. #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][bool]$CollectorPresent,
        [Parameter(Mandatory)][bool]$SinkPresent
    )
    if ($CollectorPresent -and $SinkPresent) {
        return [pscustomobject]@{ Halt = $false; Message = 'Both :latest images present.' }
    }
    $missing = @()
    if (-not $CollectorPresent) { $missing += 'collector' }
    if (-not $SinkPresent) { $missing += 'sink' }
    $msg = "Missing :latest image(s): $($missing -join ', '). A fresh registry has none; " +
    'seed them once (see README step 6 - `gh workflow run publish-images.yml`, or a ' +
    'local docker build+push before the workflow is on main), then re-run.'
    return [pscustomobject]@{ Halt = $true; Message = $msg }
}

# =============================================================================
# Effectful shims - thin wrappers over PATH probes, az, dbmate, psql, gh, docker.
# =============================================================================

function Write-BootstrapLog {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    Write-Information "[$Level] $Message" -InformationAction Continue
}

function Test-CommandPresent {
    <# .SYNOPSIS True when a command is resolvable on PATH. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-AzAccountInfo {
    <# .SYNOPSIS The active az account (tenantId + id), or $null when signed out. #>
    [OutputType([pscustomobject])]
    param()
    $json = az account show --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $null }
    return $json | ConvertFrom-Json
}

function Test-GhAuth {
    <# .SYNOPSIS True when a gh session is authenticated. #>
    [OutputType([bool])]
    param()
    gh auth status 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-PgCronPreload {
    <# .SYNOPSIS The server's shared_preload_libraries value. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$DatabaseUrl)
    $val = psql $DatabaseUrl -t -A -c 'SHOW shared_preload_libraries' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not read shared_preload_libraries (is the server reachable / IP opened?).' }
    return ([string]$val).Trim()
}

function Get-PgCronJob {
    <# .SYNOPSIS The cron.job rows as {JobName, Active, Database} objects. #>
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$DatabaseUrl)
    $lines = psql $DatabaseUrl -t -A -F '|' -c 'SELECT jobname, active, database FROM cron.job' 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not query cron.job (is pg_cron installed and the server reachable?).' }
    $rows = foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $f = $line -split '\|'
        [pscustomobject]@{ JobName = $f[0]; Active = ($f[1] -eq 't'); Database = $f[2] }
    }
    return [object[]]$rows
}

function Test-ContainerImage {
    <# .SYNOPSIS True when a container image reference exists in its registry. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Reference)
    docker manifest inspect $Reference 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# =============================================================================
# Step bodies - each returns 0 to continue, non-zero to halt the run.
# =============================================================================

function Invoke-StepScript {
    <# .SYNOPSIS Run a co-located bootstrap script with -Environment; return its exit code. #>
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Environment)
    $path = Join-Path $PSScriptRoot $Name
    & $path -Environment $Environment
    return $LASTEXITCODE
}

function Invoke-Precheck {
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Environment)
    $tools = @{}
    foreach ($t in @('az', 'gh', 'psql', 'dbmate')) { $tools[$t] = Test-CommandPresent -Name $t }

    $repoRoot = Split-Path -Parent $PSScriptRoot
    $envFile = Join-Path $repoRoot ".env.$Environment"
    $missing = @()
    $tenantMatch = $true
    $subMatch = $true
    if (-not (Test-Path -LiteralPath $envFile)) {
        $missing = @(".env.$Environment (file not found)")
    }
    else {
        $raw = ConvertFrom-DotEnv -Line (Get-Content -LiteralPath $envFile)
        $missing = Get-MissingConfigKey -Raw $raw -Required (Get-BootstrapRequiredKey)
        $acct = Get-AzAccountInfo
        if ($acct) {
            $tenantMatch = ($acct.tenantId -eq $raw['AZURE_TENANT_ID'])
            $subMatch = ($acct.id -eq $raw['AZURE_SUBSCRIPTION_ID'])
        }
    }
    $sessions = @{ az = ($null -ne (Get-AzAccountInfo)); gh = (Test-GhAuth) }

    $report = Get-PrecheckReport -Tool $tools -Session $sessions -TenantMatch $tenantMatch `
        -SubMatch $subMatch -MissingEnvKey $missing
    if ($report.Count -gt 0) {
        Write-BootstrapLog 'Precheck found unmet prerequisites:' 'FAIL'
        foreach ($r in $report) { Write-BootstrapLog "  - $r" 'FAIL' }
        return 1
    }
    Write-BootstrapLog 'Precheck passed.'
    return 0
}

function Invoke-StepSeedImage {
    [OutputType([int])]
    param()
    if (-not (Test-CommandPresent -Name 'docker')) {
        Write-BootstrapLog 'docker not on PATH; cannot check the :latest images. Install Docker or seed manually (README step 6), then re-run.' 'HALT'
        return 1
    }
    $collector = Test-ContainerImage -Reference 'ghcr.io/gharib89/cc-otel-collector:latest'
    $sink = Test-ContainerImage -Reference 'ghcr.io/gharib89/cc-otel-sink:latest'
    $decision = Get-SeedImagesDecision -CollectorPresent $collector -SinkPresent $sink
    if ($decision.Halt) {
        Write-BootstrapLog $decision.Message 'HALT'
        return 1
    }
    Write-BootstrapLog $decision.Message
    return 0
}

function Invoke-StepDeploy {
    [OutputType([int])]
    param([Parameter(Mandatory)]$Config)
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $template = Join-Path $repoRoot (Join-Path 'iac' 'main.bicep')
    $params = Join-Path $repoRoot (Join-Path 'iac' (Join-Path 'params' "$($Config.Environment).bicepparam"))
    $state = az deployment group create --resource-group $Config.ResourceGroup `
        --template-file $template --parameters $params `
        --query 'properties.provisioningState' -o tsv
    if ($LASTEXITCODE -ne 0) {
        Write-BootstrapLog 'Bicep deploy failed. On `CapacityNotAvailable` in swedencentral, re-run (fresh zone) or pin postgresAvailabilityZone=1|2|3 (README step 6).' 'FAIL'
        return 1
    }
    Write-BootstrapLog "Deploy provisioningState: $state"
    return 0
}

function Invoke-StepPgCronGate {
    [OutputType([int])]
    param([Parameter(Mandatory)]$Config)
    $preload = Get-PgCronPreload -DatabaseUrl $Config.DatabaseUrl
    if (-not (Test-PgCronPreloaded -PreloadValue $preload)) {
        Write-BootstrapLog "pg_cron is not in shared_preload_libraries ('$preload'). Migrating now would schedule-and-skip the cron jobs and mark the migration applied. Set azure.extensions + shared_preload_libraries to include pg_cron on the server, then re-run." 'HALT'
        return 1
    }
    Write-BootstrapLog "pg_cron is preloaded ('$preload')."
    return 0
}

function Invoke-StepMigrate {
    [OutputType([int])]
    param([Parameter(Mandatory)]$Config)
    dbmate --url $Config.DatabaseUrl up
    if ($LASTEXITCODE -ne 0) { Write-BootstrapLog 'dbmate up failed.' 'FAIL'; return 1 }
    return 0
}

function Invoke-StepDbLogin {
    [OutputType([int])]
    param([Parameter(Mandatory)]$Config)
    $sql = Join-Path $PSScriptRoot 'create-db-logins.sql'
    psql $Config.DatabaseUrl -v ON_ERROR_STOP=1 `
        -v ingest_pw="$($Config.IngestPassword)" -v read_pw="$($Config.ReadPassword)" -f $sql
    if ($LASTEXITCODE -ne 0) { Write-BootstrapLog 'create-db-logins.sql failed.' 'FAIL'; return 1 }
    Write-BootstrapLog 'DB logins created/converged.'
    return 0
}

function Invoke-StepPgCronVerify {
    [OutputType([int])]
    param([Parameter(Mandatory)]$Config)
    $jobs = Get-PgCronJob -DatabaseUrl $Config.DatabaseUrl
    $problems = Get-PgCronJobReport -Job $jobs -ExpectedName $script:ExpectedCronJob -Database $script:CronDatabase
    if ($problems.Count -gt 0) {
        Write-BootstrapLog 'pg_cron verification failed:' 'FAIL'
        foreach ($p in $problems) { Write-BootstrapLog "  - $p" 'FAIL' }
        Write-BootstrapLog 'Remediation: confirm pg_cron is preloaded and cron.database_name = cc_otel, then re-apply the owning migration (...170004 / ...170012).' 'FAIL'
        return 1
    }
    Write-BootstrapLog "All $($script:ExpectedCronJob.Count) cron jobs are active on $($script:CronDatabase)."
    return 0
}

function Invoke-StepRollImage {
    [OutputType([int])]
    param([Parameter(Mandatory)]$Config)
    gh workflow run deploy.yml -f environment=$($Config.Environment)
    if ($LASTEXITCODE -ne 0) { Write-BootstrapLog 'deploy.yml dispatch failed.' 'FAIL'; return 1 }
    Write-BootstrapLog 'Dispatched deploy.yml; watch it with `gh run watch`.'
    return 0
}

function Show-ManualStep {
    <# .SYNOPSIS Print a manual-gate instruction and halt (returns non-zero). #>
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Message)
    Write-BootstrapLog $Message 'MANUAL'
    return 1
}

# =============================================================================
# Orchestration
# =============================================================================

function Invoke-BootstrapStep {
    <# .SYNOPSIS Dispatch one step by slug; return 0 to continue or non-zero to halt. #>
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Environment
    )
    switch ($Slug) {
        'precheck' { return (Invoke-Precheck -Environment $Environment) }
        'federated-cred' { return (Invoke-StepScript -Name 'ensure-federated-credential.ps1' -Environment $Environment) }
        'rbac' { return (Invoke-StepScript -Name 'assign-rbac.ps1' -Environment $Environment) }
        'seed-images' { return (Invoke-StepSeedImage) }
        'sync-secrets' { return (Invoke-StepScript -Name 'sync-secrets.ps1' -Environment $Environment) }
        'deploy' { return (Invoke-StepDeploy -Config (Get-BootstrapConfig -Environment $Environment)) }
        'open-ip' { return (Invoke-StepScript -Name 'open-my-ip.ps1' -Environment $Environment) }
        'pg-cron-gate' { return (Invoke-StepPgCronGate -Config (Get-BootstrapConfig -Environment $Environment)) }
        'migrate' { return (Invoke-StepMigrate -Config (Get-BootstrapConfig -Environment $Environment)) }
        'db-logins' { return (Invoke-StepDbLogin -Config (Get-BootstrapConfig -Environment $Environment)) }
        'pg-cron-verify' { return (Invoke-StepPgCronVerify -Config (Get-BootstrapConfig -Environment $Environment)) }
        'powerbi' {
            return (Show-ManualStep -Message ('Configure the Power BI Desktop data source as the read login: ' +
                    "server ccotel-pg-$Environment.postgres.database.azure.com, database cc_otel, user cc_otel_read_user, " +
                    'password CC_OTEL_READ_PASSWORD, SSL required. Refresh to confirm, then publish (README step 9). ' +
                    'Then run the remaining steps (e.g. -Step roll-image).'))
        }
        'roll-image' { return (Invoke-StepRollImage -Config (Get-BootstrapConfig -Environment $Environment)) }
        'verify' {
            return (Show-ManualStep -Message ('Run the installer end-to-end acceptance (README step 13): install on a ' +
                    'machine and confirm the sink /healthz is green, rows land in raw, and the Power BI refresh has data.'))
        }
        'close-ip' { return (Invoke-StepScript -Name 'close-my-ip.ps1' -Environment $Environment) }
        'identity' {
            return (Show-ManualStep -Message ('First-time identity setup is a deliberate one-off (README appendix): ' +
                    'az ad app create / sp create, then record the AZURE_*_OBJECT_ID / AZURE_CLIENT_ID keys in .env.<env>.'))
        }
        default { throw "No dispatch for step '$Slug'." }
    }
}

function Invoke-Bootstrap {
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Environment,
        [string]$Step
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $selected = Select-BootstrapStep -All (Get-BootstrapStepList) -Step $Step
    foreach ($s in $selected) {
        Write-BootstrapLog "=== $($s.Slug): $($s.Description) ==="
        $rc = Invoke-BootstrapStep -Slug $s.Slug -Environment $Environment
        if ($rc -ne 0) {
            Write-BootstrapLog "Halted at '$($s.Slug)'. Resolve the above, then re-run (completed steps no-op) or run the rest by -Step." 'HALT'
            return $rc
        }
    }
    Write-BootstrapLog "Completed: $(($selected.Slug) -join ', ')."
    return 0
}

# Run only when executed directly; dot-sourcing (tests) defines functions without running.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-Bootstrap -Environment $Environment -Step $Step)
}
