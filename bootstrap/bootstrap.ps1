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
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'Common.ps1')

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
    # Unary comma preserves the array; a bare empty [string[]] unrolls to $null
    # on return, and $null.Count throws under Set-StrictMode -Version Latest.
    return , [string[]]$fail
}

function Test-PgCronPreloaded {
    <# .SYNOPSIS True when pg_cron is an entry in a shared_preload_libraries value. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PreloadValue)
    $entries = $PreloadValue -split ',' | ForEach-Object { $_.Trim() }
    return ($entries -contains 'pg_cron')
}

function Test-PgCronDatabaseApplied {
    <#
    .SYNOPSIS
        True when cron.database_name equals the expected DB and is not pending a
        restart.
    .DESCRIPTION
        cron.database_name is restart-only on Azure PG Flexible Server and Azure
        does not auto-restart for it, so a set-but-pending value means pg_cron is
        still bound to the default database and cron.schedule() silently no-ops
        (#65/#66). Both conditions must hold before migrating.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Pending,
        [Parameter(Mandatory)][string]$Expected
    )
    $isPending = ($Pending.Trim().ToLowerInvariant() -eq 'true')
    return (($Value.Trim() -eq $Expected) -and -not $isPending)
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
    # Unary comma preserves the array across the return boundary; see
    # Get-PrecheckReport for why a bare empty [string[]] would crash the caller.
    return , [string[]]$problem
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
    'seed them once (see the README seed-images notes - `gh workflow run publish-images.yml`, or a ' +
    'local docker build+push before the workflow is on main), then re-run.'
    return [pscustomobject]@{ Halt = $true; Message = $msg }
}

function Get-DeployImagePin {
    <#
    .SYNOPSIS
        Whether the deploy step can re-pin the live Container App's images (#390).
    .DESCRIPTION
        An RG deploy is incremental per resource but authoritative for the resources
        it declares, so deploying the template with the bicepparams' `:latest`
        fallback replaces whatever SHA-tagged revision deploy.yml last rolled out
        with a stale one - silent ingest failure until someone re-runs deploy.yml.
        Reading the live images back and passing them as params keeps the revision
        where it is. Both containers are declared together (iac/modules/containerapp.bicep),
        so a blank read means there is no app yet (virgin bring-up) and the `:latest`
        fallback is correct; a half-read is treated the same, because pinning one and
        defaulting the other would deploy an empty image reference.
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$ImageMap)
    $CollectorImage = [string]$ImageMap['collector']
    $SinkImage = [string]$ImageMap['sink']
    $pinned = -not ([string]::IsNullOrWhiteSpace($CollectorImage) -or
        [string]::IsNullOrWhiteSpace($SinkImage))
    $msg = if ($pinned) { "Pinning the live images: $CollectorImage, $SinkImage." }
    else { 'No live Container App images to read; deploying the bicepparams'' :latest fallback (virgin bring-up).' }
    return [pscustomobject]@{
        Pinned         = $pinned
        CollectorImage = $CollectorImage
        SinkImage      = $SinkImage
        Message        = $msg
    }
}

# =============================================================================
# Effectful shims - thin wrappers over PATH probes, az, dbmate, psql, gh, docker.
# =============================================================================

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
    # Force array semantics so a single returned row is one line, not iterated.
    $rows = foreach ($line in @($lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $f = $line -split '\|'
        [pscustomobject]@{ JobName = $f[0]; Active = ($f[1] -eq 't'); Database = $f[2] }
    }
    return [object[]]$rows
}

function Get-PgParameter {
    <# .SYNOPSIS A server parameter field (value / isConfigPendingRestart) via az. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Query
    )
    $val = az postgres flexible-server parameter show --subscription $SubscriptionId `
        --resource-group $ResourceGroup `
        --server-name $ServerName --name $Name --query $Query --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not read server parameter '$Name' (is the server reachable?)." }
    return ([string]$val).Trim()
}

function Invoke-PostgresRestart {
    <# .SYNOPSIS Restart the flexible server (applies restart-only config). #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ServerName
    )
    if (-not $PSCmdlet.ShouldProcess($ServerName, 'restart')) { return }
    az postgres flexible-server restart --subscription $SubscriptionId `
        --resource-group $ResourceGroup --name $ServerName --output none
    if ($LASTEXITCODE -ne 0) { throw "Server restart failed (az exit $LASTEXITCODE)." }
}

function Test-ContainerImage {
    <# .SYNOPSIS True when a container image reference exists in its registry. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Reference)
    docker manifest inspect $Reference 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-ContainerAppImageMap {
    <#
    .SYNOPSIS
        The live Container App's container-name -> image map; empty when absent.
    .DESCRIPTION
        Empty is the virgin-registry answer: az exits non-zero when the app does not
        exist yet. deploy.yml sets these with `az containerapp update
        --container-name <c> --image <sha>`, so the live template's container images
        are the SHA tags to re-pin.

        Deliberately `az resource show` (core CLI) and not `az containerapp show`:
        the containerapp extension is not a bootstrap prerequisite, and a
        missing-extension failure is indistinguishable here from "no app yet" - it
        would fall back to :latest and silently reintroduce the very bug this reads
        the images to prevent.
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$AppName
    )
    $json = az resource show --subscription $SubscriptionId --resource-group $ResourceGroup `
        --name $AppName --resource-type 'Microsoft.App/containerApps' `
        --query 'properties.template.containers[].{name:name,image:image}' --output json 2>$null
    if ($LASTEXITCODE -ne 0) { return @{} }
    # az stdout captures as a string[] (one element per line); WinPS 5.1's
    # ConvertFrom-Json rejects an array, so rejoin before parsing.
    $map = @{}
    foreach ($c in @(($json -join "`n") | ConvertFrom-Json)) {
        if ($c.name) { $map[[string]$c.name] = [string]$c.image }
    }
    return $map
}

# =============================================================================
# Step bodies - each returns 0 to continue, non-zero to halt the run.
# =============================================================================

function Invoke-NativeStep {
    <#
    .SYNOPSIS
        Run a native command for effect; show its output, return the exit code only.
    .DESCRIPTION
        The single owner of the native-call contract. Routing stdout+stderr to the
        host (2>&1 | Out-Host) keeps it off the pipeline, so the return is a lone
        [int] and never @(<tool output>, 0) - the shape a caller's `$rc -ne 0`
        reads as a truthy array and false-halts on (the #143 leak class).
    #>
    [OutputType([int])]
    param([Parameter(Mandatory)][scriptblock]$Command)
    & $Command 2>&1 | Out-Host
    return $LASTEXITCODE
}

function Invoke-StepScript {
    <# .SYNOPSIS Run a co-located bootstrap script with -Environment; return its exit code. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Environment',
        Justification = 'Consumed inside the scriptblock passed to Invoke-NativeStep; PSSA does not track scriptblock variable capture.')]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Environment)
    $path = Join-Path $PSScriptRoot $Name
    return (Invoke-NativeStep -Command { & $path -Environment $Environment })
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

    # Probe the az/gh sessions only when the binary is actually on PATH; calling
    # them when absent would throw command-not-found and abort precheck before it
    # can build the one consolidated report of every missing tool/session/key.
    $acct = if ($tools['az']) { Get-AzAccountInfo } else { $null }
    $ghAuthed = if ($tools['gh']) { Test-GhAuth } else { $false }

    if (-not (Test-Path -LiteralPath $envFile)) {
        $missing = @(".env.$Environment (file not found)")
    }
    else {
        $raw = ConvertFrom-DotEnv -Line (Get-Content -LiteralPath $envFile)
        $missing = Get-MissingConfigKey -Raw $raw -Required (Get-BootstrapRequiredKey)
        if ($acct) {
            $tenantMatch = ($acct.tenantId -eq $raw['AZURE_TENANT_ID'])
            $subMatch = ($acct.id -eq $raw['AZURE_SUBSCRIPTION_ID'])
        }
    }
    $sessions = @{ az = ($null -ne $acct); gh = $ghAuthed }

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
        # Docker is only needed to seed a virgin registry. Without it we can't
        # verify the tags, but a Docker-less operator can't seed anyway - so
        # proceed rather than block; a genuinely missing image surfaces as a
        # clear ACA pull failure at the deploy step.
        Write-BootstrapLog 'docker not on PATH; skipping the :latest image check. If deploy fails to pull, seed the images (README seed-images notes) on a machine with Docker.' 'WARN'
        return 0
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
    # The .bicepparam files resolve the ACA secret params via
    # readEnvironmentVariable(...) - Bicep reads them from this process's
    # environment, not from $Config. Set them from the validated .env only for
    # the span of the az call, then restore the prior values in finally. Leaving
    # them exported would leak into every later step's native children (psql, az,
    # gh); notably DATABASE_URL is dbmate's default config var, so a later dbmate
    # call omitting --url would silently target this deploy-step export.
    # Omitting them makes Bicep fall back to '' and Azure rejects the empty ACA
    # secrets (ContainerAppSecretInvalid).
    # PG_FIREWALL_RULES is not a secret, but it rides the same mechanism: the VPN
    # ranges are uncommitted (ADR-0018), so Bicep only sees them if they are in
    # this process. Omitting it deploys an empty rule array - and because
    # resource-group deploys are incremental, the live rules would survive while
    # silently leaving the template.
    $secretEnv = [ordered]@{
        FLEET_TOKENS      = $Config.FleetTokens
        DATABASE_URL      = $Config.DatabaseUrl
        GHCR_USERNAME     = $Config.GhcrUsername
        GHCR_TOKEN        = $Config.GhcrToken
        PG_ADMIN_PASSWORD = $Config.PgAdminPassword
        PG_FIREWALL_RULES = $Config.PgFirewallRules
    }
    # Same mechanism, one step further (#390): the container images are read off the
    # live app and passed back in, so this deploy cannot roll the SHA-tagged revision
    # deploy.yml last shipped back to the stale :latest. Set only when both resolved -
    # an empty-but-set variable defeats readEnvironmentVariable's default and would
    # deploy an empty image reference instead of the intended :latest fallback.
    $pin = Get-DeployImagePin -ImageMap (Get-ContainerAppImageMap `
            -SubscriptionId $Config.SubscriptionId -ResourceGroup $Config.ResourceGroup `
            -AppName $Config.AppName)
    Write-BootstrapLog $pin.Message
    if ($pin.Pinned) {
        $secretEnv['COLLECTOR_IMAGE'] = $pin.CollectorImage
        $secretEnv['SINK_IMAGE'] = $pin.SinkImage
    }
    $prior = [ordered]@{}
    foreach ($name in $secretEnv.Keys) { $prior[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        foreach ($name in $secretEnv.Keys) { Set-Item -LiteralPath "env:$name" -Value $secretEnv[$name] }
        $state = az deployment group create --subscription $Config.SubscriptionId `
            --resource-group $Config.ResourceGroup `
            --template-file $template --parameters $params `
            --query 'properties.provisioningState' -o tsv
        if ($LASTEXITCODE -ne 0) {
            Write-BootstrapLog 'Bicep deploy failed. On `CapacityNotAvailable` in swedencentral, re-run (fresh zone) or pin postgresAvailabilityZone=1|2|3 (README deploy / CapacityNotAvailable note).' 'FAIL'
            return 1
        }
        Write-BootstrapLog "Deploy provisioningState: $state"
        return 0
    }
    finally {
        foreach ($name in $secretEnv.Keys) {
            if ($null -eq $prior[$name]) { Remove-Item -LiteralPath "env:$name" -ErrorAction SilentlyContinue }
            else { Set-Item -LiteralPath "env:$name" -Value $prior[$name] }
        }
    }
}

function Invoke-StepPgCronGate {
    [OutputType([int])]
    param([Parameter(Mandatory)]$Config)
    # 1. shared_preload_libraries must have pg_cron loaded.
    $preload = Get-PgCronPreload -DatabaseUrl $Config.DatabaseUrl
    if (-not (Test-PgCronPreloaded -PreloadValue $preload)) {
        Write-BootstrapLog "pg_cron is not in shared_preload_libraries ('$preload'). Migrating now would schedule-and-skip the cron jobs and mark the migration applied. Set azure.extensions + shared_preload_libraries to include pg_cron on the server, then re-run." 'HALT'
        return 1
    }
    Write-BootstrapLog "pg_cron is preloaded ('$preload')."

    # 2. cron.database_name must be cc_otel AND applied (not pending a restart).
    # It is restart-only on Azure PG Flexible Server and Azure does not auto-restart
    # for it (unlike shared_preload_libraries), so Bicep sets it but pg_cron still
    # binds to the default DB until a restart - every cron.schedule() silently
    # no-ops (#65/#66). Restart when pending, then assert it applied.
    $pending = Get-PgParameter -SubscriptionId $Config.SubscriptionId -ResourceGroup $Config.ResourceGroup `
        -ServerName $Config.ServerName -Name 'cron.database_name' -Query 'isConfigPendingRestart'
    if ($pending.Trim().ToLowerInvariant() -eq 'true') {
        Write-BootstrapLog "cron.database_name restart pending; restarting $($Config.ServerName) (one restart applies all pending config)."
        Invoke-PostgresRestart -SubscriptionId $Config.SubscriptionId -ResourceGroup $Config.ResourceGroup `
            -ServerName $Config.ServerName -Confirm:$false
        $pending = Get-PgParameter -SubscriptionId $Config.SubscriptionId -ResourceGroup $Config.ResourceGroup `
            -ServerName $Config.ServerName -Name 'cron.database_name' -Query 'isConfigPendingRestart'
    }
    $value = Get-PgParameter -SubscriptionId $Config.SubscriptionId -ResourceGroup $Config.ResourceGroup `
        -ServerName $Config.ServerName -Name 'cron.database_name' -Query 'value'
    if (-not (Test-PgCronDatabaseApplied -Value $value -Pending $pending -Expected $script:CronDatabase)) {
        Write-BootstrapLog "cron.database_name is '$value' (pendingRestart=$pending); expected '$($script:CronDatabase)' applied. pg_cron jobs will not schedule - do NOT migrate." 'HALT'
        return 1
    }
    Write-BootstrapLog "cron.database_name applied ('$value')."
    return 0
}

function Invoke-StepMigrate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Config',
        Justification = 'Consumed inside the scriptblock passed to Invoke-NativeStep; PSSA does not track scriptblock variable capture.')]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Config)
    # --no-dump-schema: a bring-up applies migrations against the live target
    # (prod/interim); it must NOT re-author db/schema.sql, which is dumped from
    # the canonical CI image by scripts/dev-migrate.sh. Dumping against Azure PG
    # instead injects environment-specific noise (server-version string, pg_cron
    # placement) that dirties the tree and fails the CI schema-drift gate.
    $rc = Invoke-NativeStep -Command { dbmate --url $Config.DatabaseUrl --no-dump-schema up }
    if ($rc -ne 0) { Write-BootstrapLog 'dbmate up failed.' 'FAIL'; return 1 }
    return 0
}

function Invoke-StepDbLogin {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Config',
        Justification = 'Consumed inside the scriptblock passed to Invoke-NativeStep; PSSA does not track scriptblock variable capture.')]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Config)
    $sql = Join-Path $PSScriptRoot 'create-db-logins.sql'
    $rc = Invoke-NativeStep -Command {
        psql $Config.DatabaseUrl -v ON_ERROR_STOP=1 `
            -v ingest_pw="$($Config.IngestPassword)" -v read_pw="$($Config.ReadPassword)" -f $sql
    }
    if ($rc -ne 0) { Write-BootstrapLog 'create-db-logins.sql failed.' 'FAIL'; return 1 }
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Config',
        Justification = 'Consumed inside the scriptblock passed to Invoke-NativeStep; PSSA does not track scriptblock variable capture.')]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Config)
    $rc = Invoke-NativeStep -Command { gh workflow run deploy.yml -f environment=$($Config.Environment) }
    if ($rc -ne 0) { Write-BootstrapLog 'deploy.yml dispatch failed.' 'FAIL'; return 1 }
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
                    'password CC_OTEL_READ_PASSWORD, SSL required. Refresh to confirm, then publish (README powerbi step). ' +
                    'Then run the remaining steps (e.g. -Step roll-image).'))
        }
        'roll-image' { return (Invoke-StepRollImage -Config (Get-BootstrapConfig -Environment $Environment)) }
        'verify' {
            return (Show-ManualStep -Message ('Run the installer end-to-end acceptance (README verify step): install on a ' +
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
        Write-BootstrapLog "=== $($s.Slug) [$($s.Mode)]: $($s.Description) ==="
        try {
            $rc = Invoke-BootstrapStep -Slug $s.Slug -Environment $Environment
        }
        catch {
            # An unexpected throw (e.g. a bad/partial .env on a standalone -Step,
            # or an unreachable server) becomes a clean non-zero halt rather than
            # a raw stack trace, keeping the orchestrator's halt UX consistent.
            Write-BootstrapLog "Halted at '$($s.Slug)': $($_.Exception.Message)" 'HALT'
            return 1
        }
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
