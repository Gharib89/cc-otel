#Requires -Version 5.1
<#
.SYNOPSIS
    Run a Pester 5 suite in the *host* PowerShell, resolving Pester 5 for
    Windows PowerShell 5.1 where Install-Module is unavailable.
.DESCRIPTION
    scripts/ship/local-gate.sh invokes this with powershell.exe so the
    bootstrap:pester gate matches bootstrap.yml's CI job, which runs
    `shell: powershell` (Windows PowerShell 5.1) deliberately - the operator runs
    bootstrap.ps1 under 5.1. pwsh 7 and 5.1 disagree on pipeline enumeration
    (ConvertFrom-Json hands 5.1 a JSON array back as one object), so a pwsh-only
    local run can be green on code CI fails (#401).

    Pester 5 is often not installed for 5.1 on a stock box - Install-Module can
    itself be unavailable - so resolution falls back to pwsh's per-user copy,
    imported by absolute path. Exit 3 means no Pester 5 is reachable at all;
    local-gate.sh then reports the gate deferred-to-ci rather than pass.

    Deliberately sets neither Set-StrictMode nor $ErrorActionPreference: both
    leak into the suite's script blocks and would fail tests CI passes, which is
    the exact divergence this wrapper exists to close.
.PARAMETER Path
    The suite directory to run (Pester's Run.Path).
.NOTES
    Exit codes: 0 suite passed - 1 suite failed - 3 Pester 5 unresolvable.
    The failed-test count is deliberately NOT the exit code (Pester's Run.Exit
    behaviour) - a 3-failure run would then be indistinguishable from the
    unresolvable sentinel.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path
)

function Resolve-Pester5Manifest {
    <#
    .SYNOPSIS
        Absolute path to a Pester 5 module manifest, or $null if none is reachable.
    #>
    [OutputType([string])]
    param()

    # 1. Already on this shell's module path (a box where 5.1 has its own copy).
    $onPath = Get-Module -ListAvailable -Name Pester |
        Where-Object { $_.Version.Major -ge 5 } |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($onPath) { return $onPath.Path }

    # 2. pwsh's per-user module dir. Documents can be OneDrive-redirected, so ask
    #    the shell for its real location rather than assuming $HOME\Documents.
    $root = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\Pester'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    # `-as [version]` so a non-version directory name sorts out as $null rather
    # than throwing on the cast.
    $dir = Get-ChildItem -LiteralPath $root -Directory |
        Where-Object { ($_.Name -as [version]) -and ([version]$_.Name).Major -ge 5 } |
        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $dir) { return $null }
    $manifest = Join-Path $dir.FullName 'Pester.psd1'
    if (Test-Path -LiteralPath $manifest) { return $manifest }
    return $null
}

$manifest = Resolve-Pester5Manifest
if (-not $manifest) {
    Write-Host "No Pester 5 reachable from PowerShell $($PSVersionTable.PSVersion)."
    exit 3
}

Write-Host "PowerShell $($PSVersionTable.PSVersion) - Pester from $manifest"
Import-Module -Name $manifest -ErrorAction Stop

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config
if ($result.Result -ne 'Passed') { exit 1 }
exit 0
