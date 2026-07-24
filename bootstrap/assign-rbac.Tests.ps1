#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in assign-rbac.ps1 (dot-sourced so its functions
    are defined without running the script). The effectful `az` shims are exercised
    by the live interim bring-up (issue #52 runbook), not here.
#>
BeforeAll {
    # Dummy mandatory arg satisfies param binding at load; the dot-source guard
    # inside the script skips the body, so only the functions are defined.
    . (Join-Path $PSScriptRoot 'assign-rbac.ps1') -Environment 'interim'
}

Describe 'Get-DeterministicGuid' {
    It 'matches the RFC 4122 v5 (SHA-1) test vector' {
        # Canonical v5 vector: Python uuid.uuid5(NAMESPACE_DNS, 'python.org').
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
    It 'emits principalId, principalType and the role-def id verbatim' {
        # The id is used as-is (subscription-rooted), not rebuilt from the scope,
        # so a resource-group-narrower assignment still points at a valid role def.
        $fullId = '/subscriptions/s1/providers/Microsoft.Authorization/roleDefinitions/rd1'
        $json = Get-RoleAssignmentBody -RoleDefinitionId $fullId `
            -PrincipalId 'p1' -PrincipalType 'ServicePrincipal'
        $o = $json | ConvertFrom-Json
        $o.properties.principalId | Should -Be 'p1'
        $o.properties.principalType | Should -Be 'ServicePrincipal'
        $o.properties.roleDefinitionId | Should -Be $fullId
    }
}

Describe 'Invoke-AssignRbac (orchestration)' {
    # Mock the config source and the effectful az shims so the orchestration is
    # exercised with no .env / az / network dependency - the pure Get-RoleAssignment*
    # builders stay real. Same shim-mocking pattern bootstrap.Tests.ps1 uses.
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock Get-BootstrapConfig { [pscustomobject]@{ SpObjectId = 'sp-1'; Scope = '/subscriptions/s1' } }
        Mock Get-RoleDefinition {
            $script:calls.Add('def')
            [pscustomobject]@{
                name = 'rd-guid'
                id   = '/subscriptions/s1/providers/Microsoft.Authorization/roleDefinitions/rd1'
            }
        }
        Mock Write-BootstrapLog {}
    }

    It 'looks up, checks, then PUTs the assignment (in order) when absent, rc 0' {
        Mock Test-RoleAssignment { $script:calls.Add('test'); $false }
        Mock New-RoleAssignment { $script:calls.Add('put') }

        Invoke-AssignRbac -Environment 'interim' | Should -Be 0

        $script:calls.ToArray() | Should -Be @('def', 'test', 'put')
        Should -Invoke New-RoleAssignment -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*subscriptions/s1*roleAssignments/*' -and $Body -like '*sp-1*'
        }
    }

    It 'short-circuits without a PUT when the assignment already exists, rc 0' {
        Mock Test-RoleAssignment { $true }
        Mock New-RoleAssignment {}

        Invoke-AssignRbac -Environment 'interim' | Should -Be 0
        Should -Invoke New-RoleAssignment -Times 0 -Exactly
    }

    It 'surfaces a throw when the PUT shim fails' {
        Mock Test-RoleAssignment { $false }
        Mock New-RoleAssignment { throw 'Role assignment PUT failed (az exit 1).' }

        { Invoke-AssignRbac -Environment 'interim' } | Should -Throw
    }

    It 'throws before any PUT when the role definition cannot be resolved' {
        Mock Get-RoleDefinition { throw "Could not resolve role definition 'Contributor'." }
        Mock Test-RoleAssignment { $false }
        Mock New-RoleAssignment {}

        { Invoke-AssignRbac -Environment 'interim' } | Should -Throw
        Should -Invoke New-RoleAssignment -Times 0 -Exactly
    }
}
