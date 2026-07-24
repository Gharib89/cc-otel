#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in ensure-federated-credential.ps1 (dot-sourced).
    The effectful `az` shims are exercised by the live interim bring-up, not here.
#>
BeforeAll {
    # Dummy mandatory arg satisfies param binding at load; the dot-source guard
    # inside the script skips the body, so only the functions are defined.
    . (Join-Path $PSScriptRoot 'ensure-federated-credential.ps1') -Environment 'interim'
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

Describe 'Invoke-EnsureFederatedCredential (orchestration)' {
    # Mock the config source and the effectful az shims so the orchestration runs
    # with no .env / az dependency; the pure Get-Federated* builders stay real.
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock Get-BootstrapConfig { [pscustomobject]@{ AppObjectId = 'app-1' } }
        Mock Write-BootstrapLog {}
    }

    It 'lists then creates (in order) when the subject is absent, rc 0' {
        # A non-empty existing set whose subject differs: the honest "subject absent,
        # create it" case (the app already carries an unrelated credential).
        Mock Get-ExistingCredential {
            $script:calls.Add('list')
            @([pscustomobject]@{ name = 'other'; subject = 'repo:Gharib89/cc-otel:ref:refs/heads/dev' })
        }
        Mock New-FederatedCredential { $script:calls.Add('create') }

        Invoke-EnsureFederatedCredential -Environment 'interim' | Should -Be 0

        $script:calls.ToArray() | Should -Be @('list', 'create')
        Should -Invoke New-FederatedCredential -Times 1 -Exactly -ParameterFilter {
            $AppObjectId -eq 'app-1' -and $Body -like '*refs/heads/main*'
        }
    }

    It 'short-circuits without a create when the subject is already present, rc 0' {
        Mock Get-ExistingCredential {
            @([pscustomobject]@{ name = 'gha-main'; subject = 'repo:Gharib89/cc-otel:ref:refs/heads/main' })
        }
        Mock New-FederatedCredential {}

        Invoke-EnsureFederatedCredential -Environment 'interim' | Should -Be 0
        Should -Invoke New-FederatedCredential -Times 0 -Exactly
    }

    It 'surfaces a throw when the create shim fails' {
        Mock Get-ExistingCredential { @() }
        Mock New-FederatedCredential { throw 'Federated credential create failed (az exit 1).' }

        { Invoke-EnsureFederatedCredential -Environment 'interim' } | Should -Throw
    }

    It 'throws before any create when listing credentials fails' {
        Mock Get-ExistingCredential { throw 'Could not list federated credentials for app app-1.' }
        Mock New-FederatedCredential {}

        { Invoke-EnsureFederatedCredential -Environment 'interim' } | Should -Throw
        Should -Invoke New-FederatedCredential -Times 0 -Exactly
    }
}
