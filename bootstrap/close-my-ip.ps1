#Requires -Version 5.1
<#
.SYNOPSIS
    Remove the operator's Postgres firewall rule, idempotently.
.DESCRIPTION
    Bootstrap step for issue #52 (friction item #8 on map #48). Companion to
    open-my-ip.ps1: deletes the stable `operator-<initials>` rule so the operator
    IP is not left allow-listed. Detect-first, so a re-run on an already-absent
    rule is a no-op.
.NOTES
    Exit codes: 0 rule absent (removed or never existed) * 1 failure.
    Requires an authenticated `az` session.
#>
param(
    [Parameter(Mandatory)][ValidateSet('interim', 'prod')][string]$Environment
)

. (Join-Path (Join-Path $PSScriptRoot 'lib') 'Get-BootstrapConfig.ps1') -Environment $Environment

# =============================================================================
# Effectful shims - thin wrappers over `az`, kept small on purpose.
# =============================================================================

function Write-BootstrapLog {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    Write-Information "[$Level] $Message" -InformationAction Continue
}

function Test-FirewallRule {
    <# .SYNOPSIS $true when the named rule exists on the server. #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$RuleName
    )
    az postgres flexible-server firewall-rule show --resource-group $ResourceGroup `
        --server-name $ServerName --name $RuleName --output none 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Remove-FirewallRule {
    <# .SYNOPSIS Delete the rule; caller has confirmed it exists. #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$RuleName
    )
    if (-not $PSCmdlet.ShouldProcess("$ServerName/$RuleName", 'delete firewall rule')) { return }
    az postgres flexible-server firewall-rule delete --resource-group $ResourceGroup `
        --server-name $ServerName --name $RuleName --yes --output none
    if ($LASTEXITCODE -ne 0) { throw "Firewall rule delete failed (az exit $LASTEXITCODE)." }
}

# =============================================================================
# Orchestration
# =============================================================================

function Invoke-CloseMyIp {
    param(
        [Parameter(Mandatory)][string]$Environment
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $cfg = Get-BootstrapConfig -Environment $Environment

    if (-not (Test-FirewallRule -ResourceGroup $cfg.ResourceGroup -ServerName $cfg.ServerName -RuleName $cfg.RuleName)) {
        Write-BootstrapLog "Rule '$($cfg.RuleName)' on $($cfg.ServerName) already absent (no-op)."
        return 0
    }

    # Close owns the decision; force so the delete can't be independently declined.
    Remove-FirewallRule -ResourceGroup $cfg.ResourceGroup -ServerName $cfg.ServerName -RuleName $cfg.RuleName -Confirm:$false
    Write-BootstrapLog "Removed '$($cfg.RuleName)' from $($cfg.ServerName)."
    return 0
}

# Run only when executed directly; dot-sourcing (Pester) defines functions without running.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-CloseMyIp -Environment $Environment)
}
