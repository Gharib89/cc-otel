#Requires -Version 5.1
<#
.SYNOPSIS
    Ensure the GitHub-OIDC federated identity credential exists on the app, idempotently.
.DESCRIPTION
    Bootstrap step for issue #52 (friction item #3 on map #48). Without this
    credential the OIDC login in deploy.yml fails silently, so it is created
    detect-first.

    One credential is shared across interim and prod: the subject is branch-based
    (`repo:Gharib89/cc-otel:ref:refs/heads/main`), not environment-based, because
    the free GitHub plan has no Environments. Detection is by SUBJECT, not name:
    Entra enforces (issuer, subject) uniqueness on the app, so a credential with
    the target subject under any name blocks creation. The script lists the app's
    credentials and no-ops if the subject is already present (re-creating would
    error), regardless of what that credential happens to be named.
.NOTES
    Exit codes: 0 created or already present * 1 failure.
    Requires an authenticated `az` session with rights on the app registration.
#>
param(
    # Object id of the app registration (not the client/application id).
    [Parameter(Mandatory)][string]$AppObjectId,
    [string]$Name = 'gha-main',
    [string]$Repository = 'Gharib89/cc-otel',
    [string]$Ref = 'refs/heads/main'
)

# =============================================================================
# Pure functions (no side effects) - the tested seam.
# =============================================================================

function Get-FederatedSubject {
    <# .SYNOPSIS GitHub-OIDC subject claim for a repo + git ref. #>
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Ref)
    "repo:${Repository}:ref:$Ref"
}

function Get-FederatedCredentialBody {
    <# .SYNOPSIS JSON parameters for `az ad app federated-credential create`. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Subject
    )
    $obj = [ordered]@{
        name      = $Name
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = $Subject
        audiences = @('api://AzureADTokenExchange')
    }
    ($obj | ConvertTo-Json -Compress -Depth 5)
}

function Test-SubjectPresent {
    <#
    .SYNOPSIS $true when a credential with $Subject is in the listed set.
    .DESCRIPTION Matches on subject, not name: Entra keys uniqueness on
    (issuer, subject), so an existing credential with this subject blocks a create
    no matter what it is named.
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Existing,
        [Parameter(Mandatory)][string]$Subject
    )
    foreach ($c in $Existing) {
        if ($c -and $c.subject -eq $Subject) { return $true }
    }
    return $false
}

# =============================================================================
# Effectful shims - thin wrappers over `az`, kept small on purpose.
# =============================================================================

function Write-BootstrapLog {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    Write-Information "[$Level] $Message" -InformationAction Continue
}

function Get-ExistingCredential {
    <# .SYNOPSIS Federated credentials currently on the app, as objects. #>
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$AppObjectId)
    $json = az ad app federated-credential list --id $AppObjectId --output json
    if ($LASTEXITCODE -ne 0) { throw "Could not list federated credentials for app $AppObjectId." }
    if ([string]::IsNullOrWhiteSpace($json)) { return @() }
    return @($json | ConvertFrom-Json)
}

function New-FederatedCredential {
    <# .SYNOPSIS Create the credential from a JSON parameter blob; caller confirmed absent. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$AppObjectId, [Parameter(Mandatory)][string]$Body)
    if (-not $PSCmdlet.ShouldProcess($AppObjectId, 'Create federated credential')) { return }
    # Via a temp file: az's inline --parameters JSON is mangled by PowerShell/az
    # quote-stripping on Windows; a file path sidesteps it.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fic-" + [guid]::NewGuid().ToString() + ".json")
    try {
        [System.IO.File]::WriteAllText($tmp, $Body)
        az ad app federated-credential create --id $AppObjectId --parameters $tmp --output none
        if ($LASTEXITCODE -ne 0) { throw "Federated credential create failed (az exit $LASTEXITCODE)." }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# Orchestration
# =============================================================================

function Invoke-EnsureFederatedCredential {
    param(
        [Parameter(Mandatory)][string]$AppObjectId,
        [string]$Name = 'github-main',
        [string]$Repository = 'Gharib89/cc-otel',
        [string]$Ref = 'refs/heads/main'
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $subject = Get-FederatedSubject -Repository $Repository -Ref $Ref
    $existing = Get-ExistingCredential -AppObjectId $AppObjectId
    if (Test-SubjectPresent -Existing $existing -Subject $subject) {
        Write-BootstrapLog "Federated credential for subject '$subject' already present on app $AppObjectId (no-op)."
        return 0
    }

    $body = Get-FederatedCredentialBody -Name $Name -Subject $subject
    New-FederatedCredential -AppObjectId $AppObjectId -Body $body -Confirm:$false
    Write-BootstrapLog "Created federated credential '$Name' (subject $subject)."
    return 0
}

# Run only when executed directly; dot-sourcing (Pester) defines functions without running.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-EnsureFederatedCredential -AppObjectId $AppObjectId -Name $Name `
            -Repository $Repository -Ref $Ref)
}
