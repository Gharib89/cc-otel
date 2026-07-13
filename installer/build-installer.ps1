#Requires -Version 5.1
<#
.SYNOPSIS
    Assemble the cc-otel installer artifact: bake the collector endpoint + fleet
    token into managed-settings.json, stamp it, and stage it for IS to push.

.DESCRIPTION
    Reuses the pure builders in install.ps1 (dot-sourced) so the baked managed
    settings and the runtime drift check share one definition. Emits the artifact
    stamp on stdout - SHA256(wrapper + managed-settings + schema version) - so a
    rotated-token rebuild produces a different stamp and forces every machine to
    overwrite (issue #26 acceptance).

    The repo commits build-installer.ps1 with a token PLACEHOLDER default; the real
    fleet token is passed via -Token only when building the artifact handed to IS,
    and never committed.

.EXAMPLE
    ./build-installer.ps1 -Endpoint https://collector.example.com -Token $env:FLEET_TOKEN
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Public HTTPS ingress FQDN of the collector - the fleet OTLP endpoint (iac/main.bicep).
    [Parameter(Mandatory)][string]$Endpoint,

    # Fleet bearer token (issue #6). Sourced from $env:FLEET_TOKEN by default
    # (a GitHub/ACA secret in CI, or a locally-exported .env value) so the committed
    # script carries no secret and the token only ever lives in the environment and
    # the gitignored dist/ artifact - never in the repo. Override with -Token.
    [string]$Token = $env:FLEET_TOKEN,

    # Statusline wrapper source (ADR-0003) bundled into the artifact and hashed
    # into the stamp. A required build input.
    [string]$WrapperPath = (Join-Path $PSScriptRoot 'cc-otel-wrapper.mjs'),

    # Where the staged artifact is written.
    [string]$OutputPath = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'

# Reuse install.ps1's builders; its dot-source guard keeps Main from running.
. (Join-Path $PSScriptRoot 'install.ps1')

if (-not (Test-Path -LiteralPath $WrapperPath)) {
    throw "Wrapper not found at '$WrapperPath'. Build the wrapper (cc-otel-wrapper.mjs, ADR-0003) or pass -WrapperPath."
}
if ([string]::IsNullOrWhiteSpace($Token)) {
    Write-Warning 'No fleet token in $env:FLEET_TOKEN (and none passed via -Token) - this artifact will NOT authenticate. Set FLEET_TOKEN or pass -Token for a real build.'
    $Token = '__FLEET_TOKEN_PLACEHOLDER__'
}

$wrapperContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $WrapperPath))
$telemetryEnv   = Get-DesiredTelemetryEnv -Endpoint $Endpoint -Token $Token
$managedJson    = ConvertTo-ManagedSettingsJson -TelemetryEnv $telemetryEnv
$stamp          = Get-InstallerStamp -WrapperContent $wrapperContent -ManagedSettingsJson $managedJson -SchemaVersion $script:InstallerSchemaVersion

if ($PSCmdlet.ShouldProcess($OutputPath, 'Stage installer artifact')) {
    # Outer ShouldProcess is authoritative; force nested writes so they can't be
    # independently declined, leaving a half-staged artifact reported as staged.
    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Recurse -Force -Confirm:$false }
    [System.IO.Directory]::CreateDirectory($OutputPath) | Out-Null

    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'install.ps1') -Destination (Join-Path $OutputPath 'install.ps1') -Force -Confirm:$false
    Copy-Item -LiteralPath $WrapperPath -Destination (Join-Path $OutputPath 'cc-otel-wrapper.mjs') -Force -Confirm:$false
    Write-TextFile -Path (Join-Path $OutputPath 'managed-settings.json') -Content $managedJson -Confirm:$false
    Write-TextFile -Path (Join-Path $OutputPath '.install-stamp') -Content $stamp -Confirm:$false

    Write-Information "[INFO] Artifact staged at $OutputPath (schema v$script:InstallerSchemaVersion)." -InformationAction Continue
}

# Stamp on stdout so callers/CI can diff builds.
Write-Output $stamp
