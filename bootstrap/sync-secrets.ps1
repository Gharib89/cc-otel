#Requires -Version 5.1
<#
.SYNOPSIS
    Fan out secrets from a single-source .env.<env> file to the GitHub repo secrets.
.DESCRIPTION
    Bootstrap step for issue #52 (friction item #4 on map #48). The one source of
    truth is `.env.<env>` (e.g. .env.interim); this script upserts the values
    deploy.yml consumes into GitHub Actions secrets with `gh secret set`, so
    DATABASE_URL is byte-identical across the Bicep input, the sink runtime secret,
    and the CI migration target.

    Per-environment values are pushed prefixed (INTERIM_/PROD_); the shared OIDC
    app identity (AZURE_CLIENT_ID/AZURE_TENANT_ID) is pushed unprefixed. The set of
    keys mirrors deploy.yml's required secrets exactly - nothing else is fanned out
    (Bicep-only inputs like PG_ADMIN_PASSWORD stay in .env for the local deploy).

    `gh secret set` is an upsert, so re-running converges.
.NOTES
    Exit codes: 0 all secrets synced * 1 failure (missing key or gh error).
    Requires an authenticated `gh` session with repo secret write access.
#>
param(
    [Parameter(Mandatory)][ValidateSet('interim', 'prod')][string]$Environment,
    # Defaults to .env.<environment> next to the repo root.
    [string]$EnvFile,
    [string]$Repository = 'Gharib89/cc-otel'
)

. (Join-Path (Join-Path $PSScriptRoot 'lib') 'Get-BootstrapConfig.ps1') -Environment $Environment
. (Join-Path (Join-Path $PSScriptRoot 'lib') 'Common.ps1')

# =============================================================================
# Pure functions (no side effects) - the tested seam.
# =============================================================================

function Get-SecretPushPlan {
    <#
    .SYNOPSIS Resolve which GitHub secret names + values to push for an environment.
    .DESCRIPTION The mapping mirrors deploy.yml's required secrets: DATABASE_URL,
    AZURE_SUBSCRIPTION_ID and RESOURCE_GROUP are environment-prefixed
    (INTERIM_/PROD_, from the config's SecretPrefix); AZURE_CLIENT_ID and
    AZURE_TENANT_ID are shared and unprefixed. The config is already validated by
    Get-BootstrapConfig (the one .env gate), so no per-key check is repeated here.
    .OUTPUTS Array of [pscustomobject]@{ Secret; Value }.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject]$Config
    )
    $prefix = $Config.SecretPrefix
    $mapping = @(
        [pscustomobject]@{ Value = $Config.DatabaseUrl;    Secret = "${prefix}_DATABASE_URL" }
        [pscustomobject]@{ Value = $Config.SubscriptionId; Secret = "${prefix}_AZURE_SUBSCRIPTION_ID" }
        [pscustomobject]@{ Value = $Config.ResourceGroup;  Secret = "${prefix}_RESOURCE_GROUP" }
        [pscustomobject]@{ Value = $Config.ClientId;       Secret = 'AZURE_CLIENT_ID' }
        [pscustomobject]@{ Value = $Config.TenantId;       Secret = 'AZURE_TENANT_ID' }
    )
    $plan = foreach ($m in $mapping) {
        [pscustomobject]@{ Secret = $m.Secret; Value = [string]$m.Value }
    }
    return @($plan)
}

# =============================================================================
# Effectful shims - thin wrappers over the filesystem and `gh`.
# =============================================================================

function Set-GitHubSecret {
    <# .SYNOPSIS Upsert one repo secret via `gh secret set` (value on stdin). #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Repository
    )
    if (-not $PSCmdlet.ShouldProcess($Name, 'gh secret set')) { return }
    # gh reads the value from stdin only when --body is omitted; `--body -` would
    # store the literal string "-". Feed the value on stdin so it never lands in
    # the process arg list / shell history, and write the exact bytes (a piped
    # PowerShell string would append a trailing CRLF that gh stores verbatim).
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'gh'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    foreach ($a in @('secret', 'set', $Name, '--repo', $Repository)) {
        $psi.ArgumentList.Add($a)
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($Value)
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "gh secret set '$Name' failed (exit $($proc.ExitCode))." }
}

# =============================================================================
# Orchestration
# =============================================================================

function Invoke-SecretSync {
    param(
        [Parameter(Mandatory)][ValidateSet('interim', 'prod')][string]$Environment,
        [string]$EnvFile,
        [string]$Repository = 'Gharib89/cc-otel'
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $cfg = Get-BootstrapConfig -Environment $Environment -EnvFile $EnvFile
    $plan = Get-SecretPushPlan -Config $cfg

    foreach ($p in $plan) {
        Set-GitHubSecret -Name $p.Secret -Value $p.Value -Repository $Repository -Confirm:$false
        Write-BootstrapLog "Synced secret $($p.Secret)."
    }
    Write-BootstrapLog "Synced $($plan.Count) secrets to $Repository from .env.$Environment."
    return 0
}

# Run only when executed directly; dot-sourcing (Pester) defines functions without running.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-SecretSync -Environment $Environment -EnvFile $EnvFile -Repository $Repository)
}
