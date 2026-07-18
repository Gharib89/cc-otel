#Requires -Version 5.1
<#
.SYNOPSIS
    Bake the collector endpoint + fleet token + wrapper into a single self-contained
    install.ps1 that IS distributes to the fleet.

.DESCRIPTION
    Bootstrap-style: the only input is -Environment. Every value is derived from
    .env.<env> via bootstrap/lib/Get-BootstrapConfig.ps1 (the same loader bootstrap.ps1
    uses) - no per-command copy-paste of endpoint or token. The fleet token is the
    first entry of the FLEET_TOKENS list; the collector endpoint is the container
    app's public ingress FQDN, resolved live via `az`.

    Reuses the pure builders in install.ps1 (dot-sourced) so the baked managed
    settings and the runtime materialization share one definition. Generates
    managed-settings.json (endpoint + token + gates) and reads the statusline
    wrapper, base64-substitutes both into install.ps1's payload placeholders, and
    writes the result to dist/install.ps1 - the ONLY file handed to IS.

    Emits the artifact stamp on stdout - SHA256(wrapper + managed-settings + schema
    version) - so a rotated-token rebuild produces a different stamp and forces every
    machine to overwrite (issue #26 acceptance).

    The committed install.ps1 / build-installer.ps1 carry no secret: the token is
    read from .env.<env> (gitignored) and lands only in the gitignored dist/install.ps1.

.EXAMPLE
    ./build-installer.ps1 -Environment interim
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Target environment; selects .env.<env> and the ccotel-app-<env> container app.
    [Parameter(Mandatory)][ValidateSet('interim', 'prod')][string]$Environment,

    # Statusline wrapper source (ADR-0003) bundled into the artifact and hashed
    # into the stamp. A required build input.
    [string]$WrapperPath = (Join-Path $PSScriptRoot 'cc-otel-wrapper.mjs'),

    # Fleet install root the wrapper materializes to. A literal default (not host
    # env-derived) so the baked managed-settings statusLine points at the fleet
    # path even when the build runs on Linux CI.
    [string]$InstallRoot = 'C:\Program Files\ClaudeCode',

    # Where the staged artifact is written.
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'

# Reuse install.ps1's builders; its dot-source guard keeps Main from running.
. (Join-Path $PSScriptRoot 'install.ps1')
# The shared .env.<env> loader (bootstrap/lib) - its guard defines functions only.
$bootstrapLib = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap') 'lib'
. (Join-Path $bootstrapLib 'Get-BootstrapConfig.ps1') -Environment $Environment

# =============================================================================
# Pure functions (no side effects) - the tested seam.
# =============================================================================

function Select-FleetToken {
    <#
    .SYNOPSIS
        The single fleet bearer token to bake, chosen from the FLEET_TOKENS list.
    .DESCRIPTION
        FLEET_TOKENS is a JSON array string - the collector accepts every token in
        it. The installer bakes exactly one; by defined selection that is the FIRST
        token in the list.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$FleetTokens)
    # Assign then index rather than piping: under Windows PowerShell 5.1
    # ConvertFrom-Json does not unroll a top-level JSON array into the pipeline
    # (it emits the array as one object), so `| Select-Object -First 1` grabs the
    # whole array, which stringifies to "first second". Binding the result and
    # guarding on [array] picks the first element consistently on 5.1 and pwsh 7.
    $parsed = ConvertFrom-Json -InputObject $FleetTokens
    $first  = if ($parsed -is [array]) { $parsed[0] } else { $parsed }
    if ([string]::IsNullOrWhiteSpace([string]$first)) {
        throw 'FLEET_TOKENS is empty - no token to bake. Set FLEET_TOKENS in .env.<env> to a JSON array, e.g. ["<bearer-token>"].'
    }
    return [string]$first
}

function ConvertTo-CollectorEndpoint {
    <# .SYNOPSIS The https:// OTLP endpoint URL for a bare collector ingress FQDN. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Fqdn)
    if ([string]::IsNullOrWhiteSpace($Fqdn)) { throw 'Collector FQDN is empty - cannot build the OTLP endpoint URL.' }
    return "https://$($Fqdn.Trim())"
}

# =============================================================================
# Effectful shim - thin wrapper over `az`.
# =============================================================================

function Get-CollectorFqdn {
    <# .SYNOPSIS Public ingress FQDN of the collector container app (via az). #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$AppName
    )
    $fqdn = az containerapp show --resource-group $ResourceGroup --name $AppName `
        --query 'properties.configuration.ingress.fqdn' --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fqdn)) {
        throw "Could not resolve the collector ingress FQDN for '$AppName' in '$ResourceGroup' (az exit $LASTEXITCODE). Deploy the app first and ensure you have an authenticated az session."
    }
    return $fqdn.Trim()
}

# =============================================================================
# Orchestration
# =============================================================================

function Invoke-BuildInstaller {
    <# .SYNOPSIS Resolve inputs from .env.<env> + az, bake, and stage dist/install.ps1; emit the stamp. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$OutputPath
    )
    if (-not (Test-Path -LiteralPath $WrapperPath)) {
        throw "Wrapper not found at '$WrapperPath'. Build the wrapper (cc-otel-wrapper.mjs, ADR-0003) or pass -WrapperPath."
    }

    $cfg      = Get-BootstrapConfig -Environment $Environment
    $token    = Select-FleetToken -FleetTokens $cfg.FleetTokens
    $endpoint = ConvertTo-CollectorEndpoint -Fqdn (Get-CollectorFqdn -ResourceGroup $cfg.ResourceGroup -AppName $cfg.AppName)

    $wrapperContent     = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $WrapperPath))
    $wrapperInstallPath = Join-Path $InstallRoot 'cc-otel-wrapper.mjs'
    $telemetryEnv       = Get-DesiredTelemetryEnv -Endpoint $endpoint -Token $token
    $managedJson        = ConvertTo-ManagedSettingsJson -TelemetryEnv $telemetryEnv -WrapperPath $wrapperInstallPath
    $stamp              = Get-InstallerStamp -WrapperContent $wrapperContent -ManagedSettingsJson $managedJson -SchemaVersion $script:InstallerSchemaVersion

    # Base64 so arbitrary token/JSON/JS bytes can't break the PowerShell string literal.
    $managedB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($managedJson))
    $wrapperB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($wrapperContent))

    $source = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install.ps1'))
    $baked  = $source.Replace('__CC_OTEL_MANAGED_B64__', $managedB64).Replace('__CC_OTEL_WRAPPER_B64__', $wrapperB64)
    if ($baked -eq $source) { throw 'Payload placeholders not found in install.ps1 - cannot bake a self-contained artifact.' }

    if ($PSCmdlet.ShouldProcess($OutputPath, 'Stage self-contained install.ps1')) {
        # This ShouldProcess is authoritative; force the nested writes.
        if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Recurse -Force -Confirm:$false }
        [System.IO.Directory]::CreateDirectory($OutputPath) | Out-Null
        Write-TextFile -Path (Join-Path $OutputPath 'install.ps1') -Content $baked -Confirm:$false
        Write-Information "[INFO] Self-contained install.ps1 for '$Environment' staged at $OutputPath (schema v$script:InstallerSchemaVersion)." -InformationAction Continue
    }

    # Stamp on stdout so callers/CI can diff builds.
    Write-Output $stamp
}

# Run only when executed directly; dot-sourcing (Pester) defines functions without building.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-BuildInstaller -Environment $Environment -WrapperPath $WrapperPath -InstallRoot $InstallRoot -OutputPath $OutputPath
}
