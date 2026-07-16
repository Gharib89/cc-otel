#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in sync-secrets.ps1 (dot-sourced). ConvertFrom-
    DotEnv is now the shared copy from lib/Get-BootstrapConfig.ps1 and is tested
    there. The effectful `gh secret set` shim is exercised by the live interim
    bring-up, not here.
#>
BeforeAll {
    # Dummy mandatory arg satisfies param binding at load; the dot-source guard
    # inside the script skips the body, so only the functions are defined.
    . (Join-Path $PSScriptRoot 'sync-secrets.ps1') -Environment 'interim'
}

Describe 'Get-SecretPushPlan' {
    BeforeAll {
        $script:full = [ordered]@{
            DATABASE_URL          = 'postgres://x'
            AZURE_SUBSCRIPTION_ID = 'sub-1'
            RESOURCE_GROUP        = 'rg-cc-otel-interim'
            AZURE_CLIENT_ID       = 'client-1'
            AZURE_TENANT_ID       = 'tenant-1'
        }
    }
    It 'prefixes per-environment secrets for interim' {
        $plan = Get-SecretPushPlan -Environment 'interim' -Values $script:full
        ($plan | Where-Object Secret -eq 'INTERIM_DATABASE_URL').Value | Should -Be 'postgres://x'
        ($plan | Where-Object Secret -eq 'INTERIM_RESOURCE_GROUP').Value | Should -Be 'rg-cc-otel-interim'
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
