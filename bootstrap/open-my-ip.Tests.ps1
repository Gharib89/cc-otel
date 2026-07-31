#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in open-my-ip.ps1 (dot-sourced). The name
    derivations (server name, rule name) now live in lib/Get-BootstrapConfig.ps1
    and are tested there. The `az` argument contract is mocked below; live Azure
    and IP-echo behavior stay in interim bring-up.
#>
BeforeAll {
    # Dummy mandatory arg satisfies param binding at load; the dot-source guard
    # inside the script skips the body, so only the functions are defined.
    . (Join-Path $PSScriptRoot 'open-my-ip.ps1') -Environment 'interim'
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
        Get-FirewallRuleStartIp -SubscriptionId 'sub' -ResourceGroup 'rg' -ServerName 'server' -RuleName 'rule' |
            Should -Be '203.0.113.10'
        $script:AzArguments -join ' ' | Should -Be (
            'postgres flexible-server firewall-rule show --subscription sub --resource-group rg ' +
            '--server-name server --name rule --query startIpAddress --output tsv'
        )
    }

    It 'sets the rule with the Azure CLI 2.88 arguments' {
        Set-FirewallRule -SubscriptionId 'sub' -ResourceGroup 'rg' -ServerName 'server' -RuleName 'rule' `
            -IpAddress '203.0.113.10' -Confirm:$false
        $script:AzArguments -join ' ' | Should -Be (
            'postgres flexible-server firewall-rule create --subscription sub --resource-group rg ' +
            '--server-name server --name rule --start-ip-address 203.0.113.10 ' +
            '--end-ip-address 203.0.113.10 --output none'
        )
    }
}

Describe 'Invoke-OpenMyIp (orchestration)' {
    # Mock the config source and the effectful shims (IP echo + az) so the
    # detect-then-write decision runs with no .env / az / network dependency.
    BeforeEach {
        Mock Get-BootstrapConfig {
            [pscustomobject]@{ SubscriptionId = 'sub-123'; ResourceGroup = 'rg'; ServerName = 'server'; RuleName = 'operator-ag' }
        }
        Mock Write-BootstrapLog {}
    }

    It 'detects the public IP and opens the rule when it differs, rc 0' {
        Mock Get-MyPublicIp { '203.0.113.10' }
        Mock Get-FirewallRuleStartIp { $null }
        Mock Set-FirewallRule {}

        Invoke-OpenMyIp -Environment 'interim' | Should -Be 0

        Should -Invoke Get-MyPublicIp -Times 1 -Exactly
        Should -Invoke Set-FirewallRule -Times 1 -Exactly -ParameterFilter {
            $IpAddress -eq '203.0.113.10' -and $RuleName -eq 'operator-ag' -and
            $SubscriptionId -eq 'sub-123'
        }
    }

    It 'short-circuits without a write when the rule already allows the IP, rc 0' {
        Mock Get-MyPublicIp {}
        Mock Get-FirewallRuleStartIp { '203.0.113.10' }
        Mock Set-FirewallRule {}

        Invoke-OpenMyIp -Environment 'interim' -IpAddress '203.0.113.10' | Should -Be 0
        Should -Invoke Set-FirewallRule -Times 0 -Exactly
        Should -Invoke Get-MyPublicIp -Times 0 -Exactly
    }

    It 'uses an explicit IP without auto-detecting' {
        Mock Get-MyPublicIp { throw 'auto-detect must not run when -IpAddress is supplied' }
        Mock Get-FirewallRuleStartIp { $null }
        Mock Set-FirewallRule {}

        Invoke-OpenMyIp -Environment 'interim' -IpAddress '198.51.100.5' | Should -Be 0
        Should -Invoke Get-MyPublicIp -Times 0 -Exactly
        Should -Invoke Set-FirewallRule -Times 1 -Exactly -ParameterFilter { $IpAddress -eq '198.51.100.5' }
    }

    It 'surfaces a throw when the firewall write fails' {
        Mock Get-FirewallRuleStartIp { $null }
        Mock Set-FirewallRule { throw 'Firewall rule create failed (az exit 1).' }

        { Invoke-OpenMyIp -Environment 'interim' -IpAddress '198.51.100.5' } | Should -Throw
    }
}
