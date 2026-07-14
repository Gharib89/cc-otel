#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in assign-rbac.ps1 (dot-sourced so its functions
    are defined without running the script). The effectful `az` shims are exercised
    by the live interim bring-up (issue #52 runbook), not here.
#>
BeforeAll {
    # Dummy mandatory args satisfy param binding at load; the dot-source guard
    # inside the script skips the body, so only the functions are defined.
    . (Join-Path $PSScriptRoot 'assign-rbac.ps1') -PrincipalId 'x' -SubscriptionId 'x'
}

Describe 'Get-DeterministicGuid' {
    It 'matches the RFC 4122 v5 (SHA-1) test vector' {
        # DNS namespace + "www.example.com" is the canonical published v5 vector.
        # Cross-checked against Python uuid.uuid5(NAMESPACE_DNS, 'python.org').
        $ns = [guid]'6ba7b810-9dad-11d1-80b4-00c04fd430c8'
        Get-DeterministicGuid -Namespace $ns -Name 'python.org' |
            Should -Be '886313e1-3b8a-5372-9b90-0c9aee199e5d'
    }
    It 'is deterministic - same inputs, same GUID' {
        $ns = [guid]'6f3b2c8a-1d4e-5a7b-9c2d-0e1f2a3b4c5d'
        $a = Get-DeterministicGuid -Namespace $ns -Name 'scope|principal|role'
        $b = Get-DeterministicGuid -Namespace $ns -Name 'scope|principal|role'
        $a | Should -Be $b
    }
    It 'differs when the name differs' {
        $ns = [guid]'6f3b2c8a-1d4e-5a7b-9c2d-0e1f2a3b4c5d'
        (Get-DeterministicGuid -Namespace $ns -Name 'a') |
            Should -Not -Be (Get-DeterministicGuid -Namespace $ns -Name 'b')
    }
}

Describe 'Get-RoleAssignmentName' {
    It 'is stable for the same scope/principal/role' {
        $p = @{ Scope = '/subscriptions/s1'; PrincipalId = 'p1'; RoleDefinitionId = 'r1' }
        (Get-RoleAssignmentName @p) | Should -Be (Get-RoleAssignmentName @p)
    }
    It 'returns a well-formed GUID' {
        $n = Get-RoleAssignmentName -Scope '/subscriptions/s1' -PrincipalId 'p1' -RoleDefinitionId 'r1'
        [guid]::Parse($n) | Should -BeOfType [guid]
    }
}

Describe 'Get-RoleAssignmentUri' {
    It 'builds the ARM URI with the 2022-04-01 api-version' {
        $u = Get-RoleAssignmentUri -Scope '/subscriptions/s1' -AssignmentName 'aaaa'
        $u | Should -Be 'https://management.azure.com/subscriptions/s1/providers/Microsoft.Authorization/roleAssignments/aaaa?api-version=2022-04-01'
    }
}

Describe 'Get-RoleAssignmentBody' {
    It 'emits roleDefinitionId, principalId and principalType' {
        $json = Get-RoleAssignmentBody -Scope '/subscriptions/s1' -RoleDefinitionId 'rd1' `
            -PrincipalId 'p1' -PrincipalType 'ServicePrincipal'
        $o = $json | ConvertFrom-Json
        $o.properties.principalId | Should -Be 'p1'
        $o.properties.principalType | Should -Be 'ServicePrincipal'
        $o.properties.roleDefinitionId |
            Should -Be '/subscriptions/s1/providers/Microsoft.Authorization/roleDefinitions/rd1'
    }
}
