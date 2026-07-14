#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Azure CLI 2.88 firewall-rule arguments' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $openScript = Get-Content -Raw (Join-Path $PSScriptRoot 'open-my-ip.ps1')
        $closeScript = Get-Content -Raw (Join-Path $PSScriptRoot 'close-my-ip.ps1')
        $deployWorkflow = Get-Content -Raw (Join-Path $repoRoot '.github/workflows/deploy.yml')
    }

    It 'uses --server-name for servers and --name for rules in every call' {
        $expectedCalls = @(
            @{ Content = $openScript; Pattern = 'firewall-rule show(?s:.*?)--server-name \$ServerName(?s:.*?)--name \$RuleName' }
            @{ Content = $openScript; Pattern = 'firewall-rule create(?s:.*?)--server-name \$ServerName(?s:.*?)--name \$RuleName' }
            @{ Content = $closeScript; Pattern = 'firewall-rule show(?s:.*?)--server-name \$ServerName(?s:.*?)--name \$RuleName' }
            @{ Content = $closeScript; Pattern = 'firewall-rule delete(?s:.*?)--server-name \$ServerName(?s:.*?)--name \$RuleName' }
            @{ Content = $deployWorkflow; Pattern = 'firewall-rule create(?s:.*?)--server-name ccotel-pg-\$\{\{ inputs\.environment \}\}(?s:.*?)--name gha-\$\{\{ github\.run_id \}\}' }
            @{ Content = $deployWorkflow; Pattern = 'firewall-rule delete(?s:.*?)--server-name ccotel-pg-\$\{\{ inputs\.environment \}\}(?s:.*?)--name gha-\$\{\{ github\.run_id \}\}' }
        )

        foreach ($call in $expectedCalls) {
            $call.Content | Should -Match $call.Pattern
        }
    }

    It 'does not use the removed --rule-name argument' {
        $openScript | Should -Not -Match '--rule-name'
        $closeScript | Should -Not -Match '--rule-name'
        $deployWorkflow | Should -Not -Match '--rule-name'
    }
}
