#Requires -Version 5.1
<#
.SYNOPSIS
    Shared effectful shims dot-sourced by the bootstrap scripts.
.DESCRIPTION
    The first effectful shared module beside the deliberately pure
    Get-BootstrapConfig.ps1. Holds only what was duplicated verbatim across the
    bootstrap scripts: the logger, and the temp-file lifecycle of the az
    body-file idiom. Single-site helpers stay where they are used.

    Dot-source (no params); the guard convention that keeps a script's body from
    running on dot-source lives in the callers, not here - this file defines
    functions only and has no body to guard.
#>

function Write-BootstrapLog {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    Write-Information "[$Level] $Message" -InformationAction Continue
}

function Invoke-WithBodyFile {
    <#
    .SYNOPSIS
        Run $Action with the path to a temp file holding $Body; clean up guaranteed.
    .DESCRIPTION
        Owns only the temp-file lifecycle of the az body-file idiom. Inline JSON
        passed to az is mangled by PowerShell/az quote-stripping on Windows: the
        value quotes are dropped, so the server reads a leading "/s" in a value as
        a comment and rejects the request. Writing the JSON to a file and passing
        the path sidesteps it. The helper does not own the az call itself, because
        the call sites place the path differently (--body "@$path" vs
        --parameters $path); $Action receives the path and does the call.
    #>
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][scriptblock]$Action  # receives the temp file path
    )
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.json')
    try {
        [System.IO.File]::WriteAllText($tmp, $Body)
        & $Action $tmp
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
