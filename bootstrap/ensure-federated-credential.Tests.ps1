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

Describe 'Test-SubjectPresent' {
    BeforeAll { $script:sub = 'repo:Gharib89/cc-otel:ref:refs/heads/main' }
    It 'is true when the subject exists under any name (e.g. gha-main)' {
        # Real interim env: the credential is named gha-main, not the script default.
        $existing = @(
            [pscustomobject]@{ name = 'other'; subject = 'repo:x:ref:refs/heads/dev' },
            [pscustomobject]@{ name = 'gha-main'; subject = $script:sub }
        )
        Test-SubjectPresent -Existing $existing -Subject $script:sub | Should -BeTrue
    }
    It 'is false when the subject is absent' {
        $existing = @([pscustomobject]@{ name = 'other'; subject = 'repo:x:ref:refs/heads/dev' })
        Test-SubjectPresent -Existing $existing -Subject $script:sub | Should -BeFalse
    }
    It 'is false for an empty set' {
        Test-SubjectPresent -Existing @() -Subject $script:sub | Should -BeFalse
    }
}
