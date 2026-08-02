#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the orchestrator's pure decision seams: step ordering and
    selection, the consolidated precheck report, the pg_cron pre-migrate gate and
    post-migrate verify predicates, and the seed-images halt decision. The
    effectful step bodies (az / dbmate / psql / gh) are exercised by a live
    bring-up, not here - the same split every other bootstrap script uses.
#>
BeforeAll {
    . (Join-Path $PSScriptRoot 'bootstrap.ps1') -Environment 'interim'
}

Describe 'Get-BootstrapStepList' {
    BeforeAll { $script:steps = Get-BootstrapStepList }

    It 'begins with precheck' {
        $script:steps[0].Slug | Should -Be 'precheck'
    }
    It 'orders the spine as designed' {
        ($script:steps.Slug) | Should -Be @(
            'precheck', 'federated-cred', 'rbac', 'seed-images', 'sync-secrets',
            'deploy', 'open-ip', 'pg-cron-gate', 'migrate', 'db-logins',
            'pg-cron-verify', 'powerbi', 'roll-image', 'verify', 'close-ip', 'identity'
        )
    }
    It 'keeps close-ip and identity out of the default run' {
        ($script:steps | Where-Object { -not $_.InDefaultRun }).Slug |
            Should -Be @('close-ip', 'identity')
    }
    It 'marks pg-cron-gate a gate and powerbi manual' {
        ($script:steps | Where-Object Slug -eq 'pg-cron-gate').Mode | Should -Be 'gate'
        ($script:steps | Where-Object Slug -eq 'powerbi').Mode | Should -Be 'manual'
    }
}

Describe 'Select-BootstrapStep' {
    BeforeAll { $script:all = Get-BootstrapStepList }

    It 'returns only the default-run steps when no step is named' {
        $sel = Select-BootstrapStep -All $script:all
        $sel.Slug | Should -Not -Contain 'close-ip'
        $sel.Slug | Should -Not -Contain 'identity'
        $sel[0].Slug | Should -Be 'precheck'
    }
    It 'returns a single step by slug (incl. on-demand)' {
        $sel = @(Select-BootstrapStep -All $script:all -Step 'close-ip')
        $sel.Count | Should -Be 1
        $sel[0].Slug | Should -Be 'close-ip'
    }
    It 'throws on an unknown slug, listing the valid ones' {
        { Select-BootstrapStep -All $script:all -Step 'nope' } |
            Should -Throw -ExpectedMessage '*nope*'
    }
}

Describe 'Get-PrecheckReport' {
    It 'passes when tools, sessions, identity, and env keys all check out' {
        Get-PrecheckReport -Tool @{ az = $true; gh = $true; psql = $true; dbmate = $true } `
            -Session @{ az = $true; gh = $true } -TenantMatch $true -SubMatch $true `
            -MissingEnvKey @() | Should -BeNullOrEmpty
    }
    It 'names a missing tool' {
        (Get-PrecheckReport -Tool @{ az = $true; gh = $true; psql = $false; dbmate = $true } `
                -Session @{ az = $true; gh = $true } -TenantMatch $true -SubMatch $true `
                -MissingEnvKey @()) -join '|' | Should -Match 'psql'
    }
    It 'names an unauthenticated session' {
        (Get-PrecheckReport -Tool @{ az = $true; gh = $true; psql = $true; dbmate = $true } `
                -Session @{ az = $false; gh = $true } -TenantMatch $true -SubMatch $true `
                -MissingEnvKey @()) -join '|' | Should -Match 'az'
    }
    It 'flags a tenant mismatch (the prod G3 guard)' {
        (Get-PrecheckReport -Tool @{ az = $true; gh = $true; psql = $true; dbmate = $true } `
                -Session @{ az = $true; gh = $true } -TenantMatch $false -SubMatch $true `
                -MissingEnvKey @()) -join '|' | Should -Match 'tenant'
    }
    It 'names every missing env key in one report' {
        $r = Get-PrecheckReport -Tool @{ az = $true; gh = $true; psql = $true; dbmate = $true } `
            -Session @{ az = $true; gh = $true } -TenantMatch $true -SubMatch $true `
            -MissingEnvKey @('GHCR_TOKEN', 'PG_ADMIN_PASSWORD')
        ($r -join '|') | Should -Match 'GHCR_TOKEN'
        ($r -join '|') | Should -Match 'PG_ADMIN_PASSWORD'
    }
}

Describe 'Test-PgCronPreloaded' {
    It 'is true when pg_cron is in the preload list' {
        Test-PgCronPreloaded -PreloadValue 'pg_cron,azure_extensions' | Should -BeTrue
        Test-PgCronPreloaded -PreloadValue 'azure_extensions, pg_cron' | Should -BeTrue
    }
    It 'is false when pg_cron is absent' {
        Test-PgCronPreloaded -PreloadValue 'azure_extensions' | Should -BeFalse
        Test-PgCronPreloaded -PreloadValue '' | Should -BeFalse
    }
    It 'does not match a substring like pg_cron_x' {
        Test-PgCronPreloaded -PreloadValue 'pg_cronies' | Should -BeFalse
    }
}

Describe 'Test-PgCronDatabaseApplied' {
    It 'is true only when the value matches and no restart is pending' {
        Test-PgCronDatabaseApplied -Value 'cc_otel' -Pending 'false' -Expected 'cc_otel' | Should -BeTrue
    }
    It 'is false when a restart is still pending (the #66 failure mode)' {
        Test-PgCronDatabaseApplied -Value 'cc_otel' -Pending 'true' -Expected 'cc_otel' | Should -BeFalse
    }
    It 'is false when the value targets the wrong database' {
        Test-PgCronDatabaseApplied -Value 'postgres' -Pending 'false' -Expected 'cc_otel' | Should -BeFalse
    }
    It 'treats the pending flag case-insensitively' {
        Test-PgCronDatabaseApplied -Value 'cc_otel' -Pending 'True' -Expected 'cc_otel' | Should -BeFalse
    }
}

Describe 'Azure CLI server shims' {
    # The az shims the pg-cron gate and the deploy step drive. All are
    # subscription-scoped, and a standalone `-Step pg-cron-gate` skips precheck's
    # subscription guard - so the subscription has to come from .env, not from
    # whatever `az` happens to be on (#389). The rest of the effectful step bodies
    # stay live-bring-up territory.
    BeforeEach {
        $script:AzArguments = @()
        Mock az {
            $script:AzArguments = @($args)
            $global:LASTEXITCODE = 0
            'false'
        }
    }

    It 'reads a server parameter pinned to the config subscription' {
        Get-PgParameter -SubscriptionId 'sub' -ResourceGroup 'rg' -ServerName 'server' `
            -Name 'cron.database_name' -Query 'value' | Should -Be 'false'
        $script:AzArguments -join ' ' | Should -Be (
            'postgres flexible-server parameter show --subscription sub --resource-group rg ' +
            '--server-name server --name cron.database_name --query value --output tsv'
        )
    }

    It 'restarts the server pinned to the config subscription' {
        Invoke-PostgresRestart -SubscriptionId 'sub' -ResourceGroup 'rg' -ServerName 'server' -Confirm:$false
        $script:AzArguments -join ' ' | Should -Be (
            'postgres flexible-server restart --subscription sub --resource-group rg ' +
            '--name server --output none'
        )
    }

    It 'reads the live container images with core az, pinned to the config subscription' {
        Mock az {
            $script:AzArguments = @($args)
            $global:LASTEXITCODE = 0
            # As az emits it: multi-line stdout, which PowerShell captures as a string[].
            '[', '  { "name": "collector", "image": "ghcr.io/x/collector:abc123" },',
            '  { "name": "sink", "image": "ghcr.io/x/sink:abc123" }', ']'
        }
        $map = Get-ContainerAppImageMap -SubscriptionId 'sub' -ResourceGroup 'rg' -AppName 'app'
        $map['collector'] | Should -Be 'ghcr.io/x/collector:abc123'
        $map['sink'] | Should -Be 'ghcr.io/x/sink:abc123'
        # `az resource show`, not `az containerapp show`: a missing containerapp
        # extension would look like "no app" and silently fall back to :latest.
        $script:AzArguments -join ' ' | Should -Be (
            'resource show --subscription sub --resource-group rg --name app ' +
            '--resource-type Microsoft.App/containerApps ' +
            '--query properties.template.containers[].{name:name,image:image} --output json'
        )
    }

    It 'returns an empty map when the app does not exist yet (virgin bring-up)' {
        Mock az { $global:LASTEXITCODE = 3 }
        (Get-ContainerAppImageMap -SubscriptionId 'sub' -ResourceGroup 'rg' -AppName 'app').Count |
            Should -Be 0
    }
}

Describe 'Get-PgCronJobReport' {
    BeforeAll {
        $script:expected = @('trim-processed-batches', 'refresh-marts', 'trim-mart-refresh-log')
        function Get-JobRow {
            param([string]$Name, [bool]$Active, [string]$Database)
            [pscustomobject]@{ JobName = $Name; Active = $Active; Database = $Database }
        }
    }
    It 'is clean when all three jobs are active on cc_otel' {
        $jobs = $script:expected | ForEach-Object { Get-JobRow -Name $_ -Active $true -Database 'cc_otel' }
        Get-PgCronJobReport -Job $jobs -ExpectedName $script:expected -Database 'cc_otel' |
            Should -BeNullOrEmpty
    }
    It 'reports a missing job' {
        $jobs = @(
            Get-JobRow -Name 'refresh-marts' -Active $true -Database 'cc_otel'
            Get-JobRow -Name 'trim-mart-refresh-log' -Active $true -Database 'cc_otel'
        )
        (Get-PgCronJobReport -Job $jobs -ExpectedName $script:expected -Database 'cc_otel') -join '|' |
            Should -Match 'trim-processed-batches'
    }
    It 'reports an inactive job (the owner-comment refinement)' {
        $jobs = @(
            Get-JobRow -Name 'trim-processed-batches' -Active $false -Database 'cc_otel'
            Get-JobRow -Name 'refresh-marts' -Active $true -Database 'cc_otel'
            Get-JobRow -Name 'trim-mart-refresh-log' -Active $true -Database 'cc_otel'
        )
        (Get-PgCronJobReport -Job $jobs -ExpectedName $script:expected -Database 'cc_otel') -join '|' |
            Should -Match 'inactive'
    }
    It 'reports a job scheduled against the wrong database' {
        $jobs = @(
            Get-JobRow -Name 'trim-processed-batches' -Active $true -Database 'postgres'
            Get-JobRow -Name 'refresh-marts' -Active $true -Database 'cc_otel'
            Get-JobRow -Name 'trim-mart-refresh-log' -Active $true -Database 'cc_otel'
        )
        (Get-PgCronJobReport -Job $jobs -ExpectedName $script:expected -Database 'cc_otel') -join '|' |
            Should -Match 'postgres'
    }
}

Describe 'Get-SeedImagesDecision' {
    It 'does not halt when both :latest images exist' {
        (Get-SeedImagesDecision -CollectorPresent $true -SinkPresent $true).Halt | Should -BeFalse
    }
    It 'halts and instructs when an image is missing' {
        $d = Get-SeedImagesDecision -CollectorPresent $true -SinkPresent $false
        $d.Halt | Should -BeTrue
        $d.Message | Should -Match 'sink'
    }
}

Describe 'Get-DeployImagePin' {
    It 'pins both images when the live app reports them' {
        $p = Get-DeployImagePin -ImageMap @{
            collector = 'ghcr.io/x/collector:abc123'; sink = 'ghcr.io/x/sink:abc123'
        }
        $p.Pinned | Should -BeTrue
        $p.CollectorImage | Should -Be 'ghcr.io/x/collector:abc123'
        $p.SinkImage | Should -Be 'ghcr.io/x/sink:abc123'
    }
    It 'does not pin when there is no app yet, naming the :latest fallback' {
        $p = Get-DeployImagePin -ImageMap @{}
        $p.Pinned | Should -BeFalse
        $p.Message | Should -Match ':latest'
    }
    It 'does not pin a half-read app - a partial pin would deploy an empty image ref' {
        (Get-DeployImagePin -ImageMap @{ collector = 'ghcr.io/x/collector:abc123' }).Pinned |
            Should -BeFalse
    }
}

Describe 'Invoke-NativeStep' {
    It 'returns the native command exit code' {
        Invoke-NativeStep -Command { cmd /c exit 4 } | Should -Be 4
    }
    It 'returns a scalar int even when the command emits stdout (the #143 leak shape)' {
        # The whole point of the shim: stdout goes to the host, never the pipeline,
        # so the return is a lone int - not @(<text>, 0) that a caller's `-ne 0`
        # would read as a truthy array and false-halt on.
        $rc = Invoke-NativeStep -Command { cmd /c "echo noise & exit 0" }
        $rc | Should -Be 0
        $rc | Should -BeOfType [int]
    }
}

Describe 'Invoke-Bootstrap (orchestration)' {
    # Mock the per-step dispatcher so the loop is exercised through the real
    # Invoke-Bootstrap interface without any az / psql / gh / .env dependency -
    # the same shim-mocking pattern install.Tests.ps1 uses for Invoke-Install.
    BeforeEach {
        $script:called = [System.Collections.Generic.List[string]]::new()
    }

    It 'runs the full default spine in order and returns 0' {
        Mock Invoke-BootstrapStep { $script:called.Add($Slug); 0 }
        Invoke-Bootstrap -Environment 'interim' | Should -Be 0
        $expected = (Get-BootstrapStepList | Where-Object InDefaultRun).Slug
        $script:called.ToArray() | Should -Be $expected
    }

    It 'halts at the first non-zero step, propagates its rc, and skips the rest' {
        Mock Invoke-BootstrapStep { $script:called.Add($Slug); if ($Slug -eq 'deploy') { 2 } else { 0 } }
        Invoke-Bootstrap -Environment 'interim' | Should -Be 2
        $script:called | Should -Contain 'deploy'
        $script:called | Should -Not -Contain 'open-ip'   # the step right after deploy
    }

    It 'converts a step throw into a clean rc 1 halt' {
        Mock Invoke-BootstrapStep { if ($Slug -eq 'precheck') { throw 'boom' } 0 }
        Invoke-Bootstrap -Environment 'interim' | Should -Be 1
    }

    It 'halts on the #143 leak shape (a step returning @(text, 0)) rather than passing it as success' {
        Mock Invoke-BootstrapStep { $script:called.Add($Slug); if ($Slug -eq 'precheck') { @('Applying: ...', 0) } else { 0 } }
        Invoke-Bootstrap -Environment 'interim' | Should -Not -Be 0
        $script:called | Should -Not -Contain 'federated-cred'   # halted at precheck
    }

    It 'runs exactly one step under -Step' {
        Mock Invoke-BootstrapStep { $script:called.Add($Slug); 0 }
        Invoke-Bootstrap -Environment 'interim' -Step 'migrate' | Should -Be 0
        $script:called.ToArray() | Should -Be @('migrate')
    }

    It 'throws on an unknown -Step slug' {
        { Invoke-Bootstrap -Environment 'interim' -Step 'nope' } | Should -Throw -ExpectedMessage '*nope*'
    }
}
