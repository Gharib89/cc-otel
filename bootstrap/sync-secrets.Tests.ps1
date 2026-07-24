#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in sync-secrets.ps1 (dot-sourced). Get-SecretPushPlan
    now consumes the typed config from Get-BootstrapConfig; the .env parsing and the
    required-key validation live in lib/Get-BootstrapConfig.ps1 and are tested there,
    so the plan builder is exercised on an already-validated config object. The
    effectful `gh secret set` shim is exercised by the live interim bring-up, not here.
#>
BeforeAll {
    # Dummy mandatory arg satisfies param binding at load; the dot-source guard
    # inside the script skips the body, so only the functions are defined.
    . (Join-Path $PSScriptRoot 'sync-secrets.ps1') -Environment 'interim'
}

Describe 'Get-SecretPushPlan' {
    BeforeAll {
        $script:interim = [pscustomobject]@{
            SecretPrefix   = 'INTERIM'
            DatabaseUrl    = 'postgres://x'
            SubscriptionId = 'sub-1'
            ResourceGroup  = 'rg-cc-otel-interim'
            ClientId       = 'client-1'
            TenantId       = 'tenant-1'
        }
    }
    It 'prefixes per-environment secrets for interim' {
        $plan = Get-SecretPushPlan -Config $script:interim
        ($plan | Where-Object Secret -eq 'INTERIM_DATABASE_URL').Value | Should -Be 'postgres://x'
        ($plan | Where-Object Secret -eq 'INTERIM_RESOURCE_GROUP').Value | Should -Be 'rg-cc-otel-interim'
    }
    It 'prefixes with PROD_ for prod' {
        $prod = [pscustomobject]@{
            SecretPrefix   = 'PROD'
            DatabaseUrl    = 'postgres://x'
            SubscriptionId = 'sub-1'
            ResourceGroup  = 'rg-cc-otel-prod'
            ClientId       = 'client-1'
            TenantId       = 'tenant-1'
        }
        $plan = Get-SecretPushPlan -Config $prod
        ($plan | Where-Object Secret -eq 'PROD_AZURE_SUBSCRIPTION_ID').Value | Should -Be 'sub-1'
    }
    It 'leaves the shared OIDC identity unprefixed' {
        $plan = Get-SecretPushPlan -Config $script:interim
        ($plan | Where-Object Secret -eq 'AZURE_CLIENT_ID').Value | Should -Be 'client-1'
        ($plan | Where-Object Secret -eq 'AZURE_TENANT_ID').Value | Should -Be 'tenant-1'
    }
}
