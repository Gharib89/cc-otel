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
