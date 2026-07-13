#Requires -Version 5.1
<#
.SYNOPSIS
    Bake the collector endpoint + fleet token + wrapper into a single self-contained
    install.ps1 that IS distributes to the fleet.

.DESCRIPTION
    Reuses the pure builders in install.ps1 (dot-sourced) so the baked managed
    settings and the runtime materialization share one definition. Generates
    managed-settings.json (endpoint + token + gates) and reads the statusline
    wrapper, base64-substitutes both into install.ps1's payload placeholders, and
    writes the result to dist/install.ps1 - the ONLY file handed to IS.

    Emits the artifact stamp on stdout - SHA256(wrapper + managed-settings + schema
    version) - so a rotated-token rebuild produces a different stamp and forces every
    machine to overwrite (issue #26 acceptance).

    The committed install.ps1 / build-installer.ps1 carry no secret: the token is
    read from $env:FLEET_TOKEN and lands only in the gitignored dist/install.ps1.

.EXAMPLE
    $env:FLEET_TOKEN = '<token>'
    ./build-installer.ps1 -Endpoint https://collector.example.com
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

# Base64 so arbitrary token/JSON/JS bytes can't break the PowerShell string literal.
$managedB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($managedJson))
$wrapperB64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($wrapperContent))

$source = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install.ps1'))
$baked  = $source.Replace('__CC_OTEL_MANAGED_B64__', $managedB64).Replace('__CC_OTEL_WRAPPER_B64__', $wrapperB64)
if ($baked -eq $source) { throw 'Payload placeholders not found in install.ps1 - cannot bake a self-contained artifact.' }

if ($PSCmdlet.ShouldProcess($OutputPath, 'Stage self-contained install.ps1')) {
    # Outer ShouldProcess is authoritative; force the nested write.
    if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Recurse -Force -Confirm:$false }
    [System.IO.Directory]::CreateDirectory($OutputPath) | Out-Null
    Write-TextFile -Path (Join-Path $OutputPath 'install.ps1') -Content $baked -Confirm:$false
    Write-Information "[INFO] Self-contained install.ps1 staged at $OutputPath (schema v$script:InstallerSchemaVersion)." -InformationAction Continue
}

# Stamp on stdout so callers/CI can diff builds.
Write-Output $stamp
