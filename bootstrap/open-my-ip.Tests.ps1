#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in open-my-ip.ps1 (dot-sourced). close-my-ip.ps1
    carries its own copy of the same derivation and is tested separately in
    close-my-ip.Tests.ps1, so a drift between the two is caught. The effectful `az`
    / IP-echo shims are exercised by the live interim bring-up, not here.
#>
BeforeAll {
    # Dummy mandatory args satisfy param binding at load; the dot-source guard
    # inside the script skips the body, so only the functions are defined.
    . (Join-Path $PSScriptRoot 'open-my-ip.ps1') -Environment 'interim' -ResourceGroup 'x' -Initials 'x'
}

Describe 'Get-OperatorRuleName' {
    It 'is a stable operator-<initials> name' {
        Get-OperatorRuleName -Initials 'ag' | Should -Be 'operator-ag'
    }
    It 'lowercases the initials so re-runs converge' {
        Get-OperatorRuleName -Initials 'AG' | Should -Be 'operator-ag'
    }
}

Describe 'Get-PostgresServerName' {
    It 'derives ccotel-pg-<env>' {
        Get-PostgresServerName -Environment 'interim' | Should -Be 'ccotel-pg-interim'
        Get-PostgresServerName -Environment 'prod' | Should -Be 'ccotel-pg-prod'
    }
}
