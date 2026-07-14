#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in close-my-ip.ps1 (dot-sourced). close and open
    each carry their own copy of the name-derivation functions (self-contained,
    copy-runnable scripts); these tests assert close's copies independently, so a
    unilateral edit that drifts them from open's is caught here. The `az` argument
    contract is mocked below; live Azure behavior stays in interim bring-up.
#>
BeforeAll {
    # Dummy mandatory args satisfy param binding at load; the dot-source guard
    # inside the script skips the body, so only the functions are defined.
    . (Join-Path $PSScriptRoot 'close-my-ip.ps1') -Environment 'interim' -ResourceGroup 'x' -Initials 'x'
}

Describe 'Get-OperatorRuleName' {
    It 'is a stable operator-<initials> name' {
        Get-OperatorRuleName -Initials 'ag' | Should -Be 'operator-ag'
    }
    It 'lowercases the initials so it matches open-my-ip' {
        Get-OperatorRuleName -Initials 'AG' | Should -Be 'operator-ag'
    }
}

Describe 'Get-PostgresServerName' {
    It 'derives ccotel-pg-<env>' {
        Get-PostgresServerName -Environment 'interim' | Should -Be 'ccotel-pg-interim'
        Get-PostgresServerName -Environment 'prod' | Should -Be 'ccotel-pg-prod'
    }
}

Describe 'Azure CLI firewall-rule shims' {
    BeforeEach {
        $script:AzArguments = @()
        Mock az {
            $script:AzArguments = @($args)
            $global:LASTEXITCODE = 0
        }
    }

    It 'checks the rule with the Azure CLI 2.88 arguments' {
        Test-FirewallRule -ResourceGroup 'rg' -ServerName 'server' -RuleName 'rule' |
            Should -BeTrue
        $script:AzArguments -join ' ' | Should -Be (
            'postgres flexible-server firewall-rule show --resource-group rg ' +
            '--server-name server --name rule --output none'
        )
    }

    It 'removes the rule with the Azure CLI 2.88 arguments' {
        Remove-FirewallRule -ResourceGroup 'rg' -ServerName 'server' -RuleName 'rule' `
            -Confirm:$false
        $script:AzArguments -join ' ' | Should -Be (
            'postgres flexible-server firewall-rule delete --resource-group rg ' +
            '--server-name server --name rule --yes --output none'
        )
    }
}
