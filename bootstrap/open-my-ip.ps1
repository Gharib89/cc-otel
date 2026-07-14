#Requires -Version 5.1
<#
.SYNOPSIS
    Open a Postgres firewall rule for the operator's current public IP, idempotently.
.DESCRIPTION
    Bootstrap step for issue #52 (friction item #8 on map #48). Local `psql` /
    `dbmate` against the flexible server needs the operator's IP allow-listed.

    Unlike deploy.yml's per-run `gha-<run_id>` rule, this uses a STABLE rule name
    (`operator-<initials>`) so re-runs converge in place rather than accreting one
    rule per run. Pair with close-my-ip.ps1 to remove it afterwards.
.NOTES
    Exit codes: 0 rule present at the right IP * 1 failure.
    Requires an authenticated `az` session.
#>
param(
    [Parameter(Mandatory)][ValidateSet('interim', 'prod')][string]$Environment,
    [Parameter(Mandatory)][string]$ResourceGroup,
    # Operator initials -> stable rule name; keep it the same across runs.
    [Parameter(Mandatory)][string]$Initials,
    # Allow-list a specific address instead of the detected egress IP (e.g. a
    # corporate NAT or jump box); auto-detected when omitted.
    [string]$IpAddress
)

# =============================================================================
# Pure functions (no side effects) - the tested seam.
# =============================================================================

function Get-OperatorRuleName {
    <# .SYNOPSIS Stable operator firewall-rule name from initials. #>
    param([Parameter(Mandatory)][string]$Initials)
    "operator-$($Initials.ToLowerInvariant())"
}

function Get-PostgresServerName {
    <# .SYNOPSIS Flexible-server name for an environment (ccotel-pg-<env>). #>
    param([Parameter(Mandatory)][string]$Environment)
    "ccotel-pg-$Environment"
}

# =============================================================================
# Effectful shims - thin wrappers over `az` and the IP-echo service.
# =============================================================================

function Write-BootstrapLog {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    Write-Information "[$Level] $Message" -InformationAction Continue
}

function Get-MyPublicIp {
    <# .SYNOPSIS Current public IPv4 via api.ipify.org. #>
    [OutputType([string])]
    param()
    $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org' -Method Get).ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($ip)) { throw 'Could not determine public IP.' }
    return $ip
}

function Get-FirewallRuleStartIp {
    <# .SYNOPSIS Start IP of an existing rule, or $null when the rule is absent. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$RuleName
    )
    $ip = az postgres flexible-server firewall-rule show --resource-group $ResourceGroup `
        --server-name $ServerName --name $RuleName --query 'startIpAddress' --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ip)) { return $null }
    return $ip.Trim()
}

function Set-FirewallRule {
    <# .SYNOPSIS Create/update the rule to a single IP (create converges in place). #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][string]$IpAddress
    )
    if (-not $PSCmdlet.ShouldProcess("$ServerName/$RuleName", "allow $IpAddress")) { return }
    az postgres flexible-server firewall-rule create --resource-group $ResourceGroup `
        --server-name $ServerName --name $RuleName `
        --start-ip-address $IpAddress --end-ip-address $IpAddress --output none
    if ($LASTEXITCODE -ne 0) { throw "Firewall rule create failed (az exit $LASTEXITCODE)." }
}

# =============================================================================
# Orchestration
# =============================================================================

function Invoke-OpenMyIp {
    param(
        [Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Initials,
        [string]$IpAddress
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $server = Get-PostgresServerName -Environment $Environment
    $rule = Get-OperatorRuleName -Initials $Initials
    if ([string]::IsNullOrWhiteSpace($IpAddress)) { $IpAddress = Get-MyPublicIp }

    $current = Get-FirewallRuleStartIp -ResourceGroup $ResourceGroup -ServerName $server -RuleName $rule
    if ($current -eq $IpAddress) {
        Write-BootstrapLog "Rule '$rule' on $server already allows $IpAddress (no-op)."
        return 0
    }

    # Open owns the decision; force so the write can't be independently declined.
    Set-FirewallRule -ResourceGroup $ResourceGroup -ServerName $server -RuleName $rule `
        -IpAddress $IpAddress -Confirm:$false
    Write-BootstrapLog "Opened '$rule' on $server for $IpAddress."
    return 0
}

# Run only when executed directly; dot-sourcing (Pester) defines functions without running.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-OpenMyIp -Environment $Environment -ResourceGroup $ResourceGroup `
            -Initials $Initials -IpAddress $IpAddress)
}
