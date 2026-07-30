#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the shared config loader. It is the single place `.env.<env>`
    becomes the derived values every bootstrap script and the orchestrator use, so
    the name-derivation that used to be copy-pasted across open/close-my-ip lives
    here now and is tested here.
#>
BeforeAll {
    # Dummy mandatory arg satisfies param binding at load; the dot-source guard
    # inside the script skips the body, so only the functions are defined.
    . (Join-Path $PSScriptRoot 'Get-BootstrapConfig.ps1') -Environment 'interim'

    $script:FullEnv = @'
# shared identity
AZURE_TENANT_ID="a1a5384f-tenant"
AZURE_SUBSCRIPTION_ID='58b41413-sub'
AZURE_CLIENT_ID=client-id
AZURE_APP_OBJECT_ID=app-obj
AZURE_SP_OBJECT_ID=sp-obj
RESOURCE_GROUP="rg-cc-otel-interim"
OPERATOR_INITIALS=AG
DATABASE_URL="postgres://admin:pw@host:5432/cc_otel?sslmode=require"
PG_ADMIN_PASSWORD=pgpw
CC_OTEL_INGEST_PASSWORD=ingestpw
CC_OTEL_READ_PASSWORD=readpw
FLEET_TOKENS=["tok"]
GHCR_USERNAME=ghuser
GHCR_TOKEN=ghtok
PG_FIREWALL_RULES=[{"name":"Vpn1","startIpAddress":"10.0.0.1","endIpAddress":"10.0.0.2"}]
'@
}

Describe 'ConvertFrom-DotEnv' {
    It 'parses key=value, stripping quotes and inline layout' {
        $h = ConvertFrom-DotEnv -Line @('FOO=bar', 'BAZ="quoted"', "QUX='single'")
        $h['FOO'] | Should -Be 'bar'
        $h['BAZ'] | Should -Be 'quoted'
        $h['QUX'] | Should -Be 'single'
    }
    It 'skips comments and blank lines' {
        $h = ConvertFrom-DotEnv -Line @('# comment', '', '   ', 'A=1')
        $h.Keys | Should -Be @('A')
    }
    It 'keeps = inside the value (e.g. connection strings)' {
        $h = ConvertFrom-DotEnv -Line @('DATABASE_URL=postgres://u:p@h/db?sslmode=require')
        $h['DATABASE_URL'] | Should -Be 'postgres://u:p@h/db?sslmode=require'
    }
    It 'strips a leading export prefix (shell-style env files)' {
        $h = ConvertFrom-DotEnv -Line @('export FOO=bar')
        $h['FOO'] | Should -Be 'bar'
    }
}

Describe 'Get-BootstrapRequiredKey' {
    It 'lists the full core key set a bring-up needs' {
        $keys = Get-BootstrapRequiredKey
        $keys | Should -Contain 'AZURE_SUBSCRIPTION_ID'
        $keys | Should -Contain 'GHCR_TOKEN'
        $keys | Should -Contain 'DATABASE_URL'
    }
    It 'requires PG_FIREWALL_RULES so a deploy cannot silently drop the VPN rules' {
        # The ranges are uncommitted (ADR-0018); the bicepparam default is an empty
        # array, so an unset key deploys IaC that no longer describes the live
        # firewall. Required here is the only thing that catches it.
        Get-BootstrapRequiredKey | Should -Contain 'PG_FIREWALL_RULES'
    }
}

Describe 'Get-BootstrapConfig - derived values' {
    BeforeEach {
        $envFile = Join-Path $TestDrive '.env.interim'
        Set-Content -Path $envFile -Value $script:FullEnv
        $script:cfg = Get-BootstrapConfig -Environment 'interim' -EnvFile $envFile
    }
    It 'surfaces raw keys as named properties' {
        $script:cfg.SubscriptionId | Should -Be '58b41413-sub'
        $script:cfg.ResourceGroup  | Should -Be 'rg-cc-otel-interim'
        $script:cfg.AppObjectId    | Should -Be 'app-obj'
        $script:cfg.GhcrToken      | Should -Be 'ghtok'
    }
    It 'surfaces PG_FIREWALL_RULES so the deploy step can export it to Bicep' {
        # readEnvironmentVariable reads the az child process environment, so the
        # value has to reach Invoke-StepDeploy's $secretEnv - a required .env key
        # that never gets exported still deploys an empty rule array.
        $script:cfg.PgFirewallRules |
            Should -Be '[{"name":"Vpn1","startIpAddress":"10.0.0.1","endIpAddress":"10.0.0.2"}]'
    }
    It 'derives the flexible-server name ccotel-pg-<env>' {
        $script:cfg.ServerName | Should -Be 'ccotel-pg-interim'
    }
    It 'derives the container-app name ccotel-app-<env>' {
        $script:cfg.AppName | Should -Be 'ccotel-app-interim'
    }
    It 'derives the uppercase secret prefix' {
        $script:cfg.SecretPrefix | Should -Be 'INTERIM'
    }
    It 'derives the RG-scoped role-assignment scope' {
        $script:cfg.Scope | Should -Be '/subscriptions/58b41413-sub/resourceGroups/rg-cc-otel-interim'
    }
    It 'derives the lowercased operator rule name' {
        $script:cfg.RuleName | Should -Be 'operator-ag'
    }
    It 'records the environment' {
        $script:cfg.Environment | Should -Be 'interim'
    }
}

Describe 'Get-BootstrapConfig - missing-key validation' {
    It 'throws one consolidated error naming every missing required key' {
        $partial = "AZURE_TENANT_ID=t`nRESOURCE_GROUP=rg"
        $envFile = Join-Path $TestDrive '.env.partial'
        Set-Content -Path $envFile -Value $partial
        { Get-BootstrapConfig -Environment 'interim' -EnvFile $envFile } |
            Should -Throw -ExpectedMessage '*AZURE_SUBSCRIPTION_ID*'
    }
    It 'treats an empty value as missing' {
        $blank = ($script:FullEnv -replace 'GHCR_TOKEN=ghtok', 'GHCR_TOKEN=')
        $envFile = Join-Path $TestDrive '.env.blank'
        Set-Content -Path $envFile -Value $blank
        { Get-BootstrapConfig -Environment 'interim' -EnvFile $envFile } |
            Should -Throw -ExpectedMessage '*GHCR_TOKEN*'
    }
    It 'errors when the env file does not exist' {
        { Get-BootstrapConfig -Environment 'interim' -EnvFile (Join-Path $TestDrive 'nope.env') } |
            Should -Throw -ExpectedMessage '*nope.env*'
    }
}

Describe 'Get-MissingConfigKey' {
    It 'returns an empty array (not $null) when nothing is missing' {
        # Regression: a $null return failed to bind to precheck's Mandatory
        # -MissingEnvKey param, crashing precheck on a complete .env.
        $raw = ConvertFrom-DotEnv -Line ($script:FullEnv -split "`n")
        $result = Get-MissingConfigKey -Raw $raw -Required (Get-BootstrapRequiredKey)
        ($null -eq $result) | Should -BeFalse
        @($result).Count | Should -Be 0
    }
}
