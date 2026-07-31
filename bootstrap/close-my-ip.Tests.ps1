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
        Test-FirewallRule -SubscriptionId 'sub' -ResourceGroup 'rg' -ServerName 'server' -RuleName 'rule' |
            Should -BeTrue
        $script:AzArguments -join ' ' | Should -Be (
            'postgres flexible-server firewall-rule show --subscription sub --resource-group rg ' +
            '--server-name server --name rule --output none'
        )
    }

    It 'removes the rule with the Azure CLI 2.88 arguments' {
        Remove-FirewallRule -SubscriptionId 'sub' -ResourceGroup 'rg' -ServerName 'server' -RuleName 'rule' `
            -Confirm:$false
        $script:AzArguments -join ' ' | Should -Be (
            'postgres flexible-server firewall-rule delete --subscription sub --resource-group rg ' +
            '--server-name server --name rule --yes --output none'
        )
    }
}

Describe 'Invoke-CloseMyIp (orchestration)' {
    # Mock the config source and the effectful az shims so the detect-then-delete
    # decision runs with no .env / az dependency.
    BeforeEach {
        Mock Get-BootstrapConfig {
            [pscustomobject]@{ SubscriptionId = 'sub-123'; ResourceGroup = 'rg'; ServerName = 'server'; RuleName = 'operator-ag' }
        }
        Mock Write-BootstrapLog {}
    }

    It 'deletes the rule when it is present, rc 0' {
        Mock Test-FirewallRule { $true }
        Mock Remove-FirewallRule {}

        Invoke-CloseMyIp -Environment 'interim' | Should -Be 0
        Should -Invoke Remove-FirewallRule -Times 1 -Exactly `
            -ParameterFilter { $RuleName -eq 'operator-ag' -and $SubscriptionId -eq 'sub-123' }
    }

    It 'short-circuits without a delete when the rule is already absent, rc 0' {
        Mock Test-FirewallRule { $false }
        Mock Remove-FirewallRule {}

        Invoke-CloseMyIp -Environment 'interim' | Should -Be 0
        Should -Invoke Remove-FirewallRule -Times 0 -Exactly
    }

    It 'surfaces a throw when the delete shim fails' {
        Mock Test-FirewallRule { $true }
        Mock Remove-FirewallRule { throw 'Firewall rule delete failed (az exit 1).' }

        { Invoke-CloseMyIp -Environment 'interim' } | Should -Throw
    }
}
