#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in ensure-federated-credential.ps1 (dot-sourced).
    The effectful `az` shims are exercised by the live interim bring-up, not here.
#>
BeforeAll {
    # Dummy mandatory arg satisfies param binding at load; the dot-source guard
    # inside the script skips the body, so only the functions are defined.
    . (Join-Path $PSScriptRoot 'ensure-federated-credential.ps1') -AppObjectId 'x'
}

Describe 'Get-FederatedSubject' {
    It 'builds the branch-based GitHub OIDC subject' {
        Get-FederatedSubject -Repository 'Gharib89/cc-otel' -Ref 'refs/heads/main' |
            Should -Be 'repo:Gharib89/cc-otel:ref:refs/heads/main'
    }
}

Describe 'Get-FederatedCredentialBody' {
    It 'sets the GitHub issuer and the token-exchange audience' {
        $o = (Get-FederatedCredentialBody -Name 'github-main' `
                -Subject 'repo:Gharib89/cc-otel:ref:refs/heads/main') | ConvertFrom-Json
        $o.name | Should -Be 'github-main'
        $o.issuer | Should -Be 'https://token.actions.githubusercontent.com'
        $o.subject | Should -Be 'repo:Gharib89/cc-otel:ref:refs/heads/main'
        $o.audiences | Should -Be 'api://AzureADTokenExchange'
    }
}

Describe 'Test-CredentialPresent' {
    It 'is true when a credential with the name exists' {
        $existing = @([pscustomobject]@{ name = 'other' }, [pscustomobject]@{ name = 'github-main' })
        Test-CredentialPresent -Existing $existing -Name 'github-main' | Should -BeTrue
    }
    It 'is false when the name is absent' {
        $existing = @([pscustomobject]@{ name = 'other' })
        Test-CredentialPresent -Existing $existing -Name 'github-main' | Should -BeFalse
    }
    It 'is false for an empty set' {
        Test-CredentialPresent -Existing @() -Name 'github-main' | Should -BeFalse
    }
}
