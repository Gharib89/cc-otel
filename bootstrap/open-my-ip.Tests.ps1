#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in open-my-ip.ps1 (dot-sourced). close-my-ip.ps1
    carries its own copy of the same derivation and is tested separately in
    close-my-ip.Tests.ps1, so a drift between the two is caught. The `az` argument
    contract is mocked below; live Azure and IP-echo behavior stay in interim bring-up.
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

Describe 'Azure CLI firewall-rule shims' {
    BeforeEach {
        $script:AzArguments = @()
        Mock az {
            $script:AzArguments = @($args)
            $global:LASTEXITCODE = 0
            if ($args -contains 'show') { '203.0.113.10' }
        }
    }

    It 'gets the rule IP with the Azure CLI 2.88 arguments' {
        Get-FirewallRuleStartIp -ResourceGroup 'rg' -ServerName 'server' -RuleName 'rule' |
            Should -Be '203.0.113.10'
        $script:AzArguments -join ' ' | Should -Be (
            'postgres flexible-server firewall-rule show --resource-group rg ' +
            '--server-name server --name rule --query startIpAddress --output tsv'
        )
    }

    It 'sets the rule with the Azure CLI 2.88 arguments' {
        Set-FirewallRule -ResourceGroup 'rg' -ServerName 'server' -RuleName 'rule' `
            -IpAddress '203.0.113.10' -Confirm:$false
        $script:AzArguments -join ' ' | Should -Be (
            'postgres flexible-server firewall-rule create --resource-group rg ' +
            '--server-name server --name rule --start-ip-address 203.0.113.10 ' +
            '--end-ip-address 203.0.113.10 --output none'
        )
    }
}
