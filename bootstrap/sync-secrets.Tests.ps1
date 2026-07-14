#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in sync-secrets.ps1 (dot-sourced). The effectful
    `gh secret set` shim is exercised by the live interim bring-up, not here.
#>
BeforeAll {
    # Dummy mandatory arg satisfies param binding at load; the dot-source guard
    # inside the script skips the body, so only the functions are defined.
    . (Join-Path $PSScriptRoot 'sync-secrets.ps1') -Environment 'interim'
}

Describe 'ConvertFrom-DotEnv' {
    It 'parses simple key=value pairs' {
        $v = ConvertFrom-DotEnv -Text "A=1`nB=2"
        $v['A'] | Should -Be '1'
        $v['B'] | Should -Be '2'
    }
    It 'strips one layer of surrounding quotes' {
        $v = ConvertFrom-DotEnv -Text ('A="quoted"' + "`n" + "B='single'")
        $v['A'] | Should -Be 'quoted'
        $v['B'] | Should -Be 'single'
    }
    It 'keeps = signs inside the value (splits on first = only)' {
        $v = ConvertFrom-DotEnv -Text 'DATABASE_URL=postgres://u:p@h:5432/db?sslmode=require'
        $v['DATABASE_URL'] | Should -Be 'postgres://u:p@h:5432/db?sslmode=require'
    }
    It 'ignores blank lines and # comments' {
        $v = ConvertFrom-DotEnv -Text "# comment`n`nA=1"
        $v.Keys.Count | Should -Be 1
        $v['A'] | Should -Be '1'
    }
    It 'strips a leading export' {
        $v = ConvertFrom-DotEnv -Text 'export A=1'
        $v['A'] | Should -Be '1'
    }
}

Describe 'Get-SecretPushPlan' {
    BeforeAll {
        $script:full = [ordered]@{
            DATABASE_URL          = 'postgres://x'
            AZURE_SUBSCRIPTION_ID = 'sub-1'
            RESOURCE_GROUP        = 'rg-cc-otel-poc'
            AZURE_CLIENT_ID       = 'client-1'
            AZURE_TENANT_ID       = 'tenant-1'
        }
    }
    It 'prefixes per-environment secrets for interim' {
        $plan = Get-SecretPushPlan -Environment 'interim' -Values $script:full
        ($plan | Where-Object Secret -eq 'INTERIM_DATABASE_URL').Value | Should -Be 'postgres://x'
        ($plan | Where-Object Secret -eq 'INTERIM_RESOURCE_GROUP').Value | Should -Be 'rg-cc-otel-poc'
    }
    It 'prefixes with PROD_ for prod' {
        $plan = Get-SecretPushPlan -Environment 'prod' -Values $script:full
        ($plan | Where-Object Secret -eq 'PROD_AZURE_SUBSCRIPTION_ID').Value | Should -Be 'sub-1'
    }
    It 'leaves the shared OIDC identity unprefixed' {
        $plan = Get-SecretPushPlan -Environment 'interim' -Values $script:full
        ($plan | Where-Object Secret -eq 'AZURE_CLIENT_ID').Value | Should -Be 'client-1'
        ($plan | Where-Object Secret -eq 'AZURE_TENANT_ID').Value | Should -Be 'tenant-1'
    }
    It 'throws when a required key is missing' {
        $partial = [ordered]@{ DATABASE_URL = 'x' }
        { Get-SecretPushPlan -Environment 'interim' -Values $partial } |
            Should -Throw -ExpectedMessage '*AZURE_SUBSCRIPTION_ID*'
    }
    It 'throws when a required key is empty' {
        $empty = [ordered]@{
            DATABASE_URL = 'x'; AZURE_SUBSCRIPTION_ID = ''; RESOURCE_GROUP = 'rg'
            AZURE_CLIENT_ID = 'c'; AZURE_TENANT_ID = 't'
        }
        { Get-SecretPushPlan -Environment 'interim' -Values $empty } | Should -Throw
    }
}
