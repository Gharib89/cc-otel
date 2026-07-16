#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in close-my-ip.ps1 (dot-sourced). The name
    derivations (server name, rule name) now live in lib/Get-BootstrapConfig.ps1
    and are tested there. The `az` argument contract is mocked below; live Azure
    behavior stays in interim bring-up.
#>
BeforeAll {
    # Dummy mandatory arg satisfies param binding at load; the dot-source guard
    # inside the script skips the body, so only the functions are defined.
    . (Join-Path $PSScriptRoot 'close-my-ip.ps1') -Environment 'interim'
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
