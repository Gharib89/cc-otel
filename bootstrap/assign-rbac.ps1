#Requires -Version 5.1
<#
.SYNOPSIS
    Assign an Azure role to a principal, idempotently, via the ARM REST PUT.
.DESCRIPTION
    Bootstrap step for issue #52 (grounded in docs/research/bootstrap-redesign.md).
    Grants a role (default Contributor) to a service principal at a subscription
    (or narrower) scope, converging on re-run.

    Two sharp edges are encoded here so the next bring-up does not re-learn them
    (friction inventory #1, #2 on map #48):

      * `az role assignment create` throws `MissingSubscription` on this surface,
        so the assignment is created with `az rest --method PUT` to the ARM
        `roleAssignments/{guid}` endpoint (api-version 2022-04-01, the first
        stable version; `principalType` is sent so a freshly created SP is not
        rejected by replication delay).
      * The built-in role definition id is never hardcoded; it is looked up
        per-subscription with `az role definition list`.

    The assignment name is a deterministic RFC 4122 v5 GUID over
    (scope, principalId, roleDefinitionId), so a re-run PUTs the same name and
    converges instead of accreting duplicates.
.NOTES
    Exit codes: 0 assigned or already present * 1 failure.
    Requires an authenticated `az` session with rights to assign roles at the scope.
#>
param(
    # Object id of the principal to grant (the OIDC app's service principal).
    [Parameter(Mandatory)][string]$PrincipalId,
    # Target subscription id; also the default assignment scope.
    [Parameter(Mandatory)][string]$SubscriptionId,
    # Built-in role to grant; looked up per-subscription, never hardcoded.
    [string]$RoleName = 'Contributor',
    # Assignment scope; defaults to the whole subscription.
    [string]$Scope,
    [ValidateSet('ServicePrincipal', 'User', 'Group')][string]$PrincipalType = 'ServicePrincipal'
)

# =============================================================================
# Pure functions (no side effects) - the tested seam.
# =============================================================================

function Get-DeterministicGuid {
    <#
    .SYNOPSIS Name-based RFC 4122 v5 (SHA-1) GUID over a fixed namespace.
    .DESCRIPTION Deterministic: the same namespace + name always yields the same
    GUID, which is what makes the role-assignment PUT converge on re-run.
    .OUTPUTS [string] canonical lowercase GUID.
    #>
    param(
        [Parameter(Mandatory)][guid]$Namespace,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name
    )
    $nsBytes = $Namespace.ToByteArray()
    # .NET lays the first three fields little-endian; RFC hashing needs big-endian.
    [Array]::Reverse($nsBytes, 0, 4)
    [Array]::Reverse($nsBytes, 4, 2)
    [Array]::Reverse($nsBytes, 6, 2)
    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($Name)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($nsBytes + $nameBytes)
    }
    finally {
        $sha1.Dispose()
    }

    $bytes = $hash[0..15]
    $bytes[6] = ($bytes[6] -band 0x0F) -bor 0x50  # version 5
    $bytes[8] = ($bytes[8] -band 0x3F) -bor 0x80  # RFC 4122 variant

    # Bytes are already big-endian per the RFC, so format the hex directly rather
    # than round-tripping through [guid] (which would re-swap the first fields).
    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4),
        $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
}

function Get-RoleAssignmentName {
    <# .SYNOPSIS Deterministic assignment GUID for (scope, principal, roleDef). #>
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$RoleDefinitionId
    )
    # Fixed namespace for cc-otel bootstrap role assignments (arbitrary but stable).
    $namespace = [guid]'6f3b2c8a-1d4e-5a7b-9c2d-0e1f2a3b4c5d'
    Get-DeterministicGuid -Namespace $namespace -Name "$Scope|$PrincipalId|$RoleDefinitionId"
}

function Get-RoleAssignmentUri {
    <# .SYNOPSIS ARM URI for the role-assignment PUT/GET. #>
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$AssignmentName
    )
    $trimmed = $Scope.TrimStart('/')
    "https://management.azure.com/$trimmed/providers/Microsoft.Authorization/roleAssignments/$AssignmentName`?api-version=2022-04-01"
}

function Get-RoleAssignmentBody {
    <#
    .SYNOPSIS JSON body for the ARM role-assignment PUT.
    .DESCRIPTION RoleDefinitionId is the full ARM path as returned by
    `az role definition list` (`.id`) - role definitions are rooted at the
    subscription (or management group), not at the assignment scope, so it is used
    verbatim rather than rebuilt from the scope (which would be wrong for a
    resource-group-narrower assignment).
    #>
    param(
        [Parameter(Mandatory)][string]$RoleDefinitionId,
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$PrincipalType
    )
    $props = [ordered]@{
        roleDefinitionId = $RoleDefinitionId
        principalId      = $PrincipalId
        principalType    = $PrincipalType
    }
    ([ordered]@{ properties = $props } | ConvertTo-Json -Compress -Depth 5)
}

# =============================================================================
# Effectful shims - thin wrappers over `az`, kept small on purpose.
# =============================================================================

function Write-BootstrapLog {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    Write-Information "[$Level] $Message" -InformationAction Continue
}

function Get-RoleDefinition {
    <#
    .SYNOPSIS Look up a built-in role definition for this scope (never hardcoded).
    .OUTPUTS [pscustomobject] with .name (the GUID) and .id (the full ARM path).
    #>
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RoleName, [Parameter(Mandatory)][string]$Scope)
    $json = az role definition list --name $RoleName --scope $Scope `
        --query "[0].{name:name,id:id}" --output json
    if ($LASTEXITCODE -ne 0) { throw "Could not resolve role definition '$RoleName' at scope '$Scope'." }
    $def = $json | ConvertFrom-Json
    if (-not $def -or [string]::IsNullOrWhiteSpace($def.name) -or [string]::IsNullOrWhiteSpace($def.id)) {
        throw "Could not resolve role definition '$RoleName' at scope '$Scope'."
    }
    return $def
}

function Test-RoleAssignment {
    <# .SYNOPSIS $true when the assignment GUID already exists at the scope. #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Uri)
    az rest --method GET --uri $Uri --output none 2>$null
    return ($LASTEXITCODE -eq 0)
}

function New-RoleAssignment {
    <# .SYNOPSIS PUT the role assignment; caller has confirmed it is absent. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Body)
    if (-not $PSCmdlet.ShouldProcess($Uri, 'PUT role assignment')) { return }
    az rest --method PUT --uri $Uri --body $Body --headers 'Content-Type=application/json' --output none
    if ($LASTEXITCODE -ne 0) { throw "Role assignment PUT failed (az exit $LASTEXITCODE)." }
}

# =============================================================================
# Orchestration
# =============================================================================

function Invoke-AssignRbac {
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [string]$RoleName = 'Contributor',
        [string]$Scope,
        [string]$PrincipalType = 'ServicePrincipal'
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($Scope)) { $Scope = "/subscriptions/$SubscriptionId" }

    $def = Get-RoleDefinition -RoleName $RoleName -Scope $Scope
    # Name uses the role-def GUID (.name); the body uses the full ARM path (.id).
    $name = Get-RoleAssignmentName -Scope $Scope -PrincipalId $PrincipalId -RoleDefinitionId $def.name
    $uri = Get-RoleAssignmentUri -Scope $Scope -AssignmentName $name

    if (Test-RoleAssignment -Uri $uri) {
        Write-BootstrapLog "Role '$RoleName' already assigned to $PrincipalId at $Scope (no-op)."
        return 0
    }

    $body = Get-RoleAssignmentBody -RoleDefinitionId $def.id `
        -PrincipalId $PrincipalId -PrincipalType $PrincipalType
    # Assign owns the decision; force so the write can't be independently declined.
    New-RoleAssignment -Uri $uri -Body $body -Confirm:$false
    Write-BootstrapLog "Assigned '$RoleName' to $PrincipalId at $Scope."
    return 0
}

# Run only when executed directly; dot-sourcing (Pester) defines functions without running.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-AssignRbac -PrincipalId $PrincipalId -SubscriptionId $SubscriptionId `
            -RoleName $RoleName -Scope $Scope -PrincipalType $PrincipalType)
}
