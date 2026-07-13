#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Unit tests for the pure logic in install.ps1 (dot-sourced so its functions are
    defined without running the installer). The effectful shims - machine env vars,
    file copies, WSL invocation, SYSTEM profile enumeration - are exercised by the
    manual matrix in issue #26, not here.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'install.ps1')
}

Describe 'Get-DesiredTelemetryEnv' {
    BeforeAll {
        $script:env = Get-DesiredTelemetryEnv -Endpoint 'https://collector.example.com' -Token 'tok-123'
    }

    It 'enables telemetry over OTLP http/protobuf' {
        $env['CLAUDE_CODE_ENABLE_TELEMETRY'] | Should -Be '1'
        $env['OTEL_METRICS_EXPORTER']        | Should -Be 'otlp'
        $env['OTEL_LOGS_EXPORTER']           | Should -Be 'otlp'
        $env['OTEL_EXPORTER_OTLP_PROTOCOL']  | Should -Be 'http/protobuf'
    }

    It 'bakes the endpoint and the bearer token' {
        $env['OTEL_EXPORTER_OTLP_ENDPOINT'] | Should -Be 'https://collector.example.com'
        $env['OTEL_EXPORTER_OTLP_HEADERS']  | Should -Be 'Authorization=Bearer tok-123'
    }

    It 'pins TOOL_DETAILS on and the other four PII gates off (issue #8)' {
        $env['OTEL_LOG_TOOL_DETAILS']       | Should -Be '1'
        $env['OTEL_LOG_USER_PROMPTS']       | Should -Be '0'
        $env['OTEL_LOG_ASSISTANT_RESPONSES']| Should -Be '0'
        $env['OTEL_LOG_TOOL_CONTENT']       | Should -Be '0'
        $env['OTEL_LOG_RAW_API_BODIES']     | Should -Be '0'
    }

    It 'sets no traces exporter (ADR-0001)' {
        $env.Contains('OTEL_TRACES_EXPORTER') | Should -BeFalse
    }
}

Describe 'ConvertTo-ManagedSettingsJson' {
    It 'produces a document with the env block under the managed-settings key' {
        $json = ConvertTo-ManagedSettingsJson -TelemetryEnv (Get-DesiredTelemetryEnv -Endpoint 'https://c' -Token 't')
        $parsed = $json | ConvertFrom-Json
        $parsed.env.CLAUDE_CODE_ENABLE_TELEMETRY | Should -Be '1'
        $parsed.env.OTEL_EXPORTER_OTLP_HEADERS   | Should -Be 'Authorization=Bearer t'
    }
}

Describe 'Get-StringHash' {
    It 'matches the known SHA-256 of "abc"' {
        # Independent source of truth: the canonical SHA-256 digest of "abc".
        Get-StringHash -Text 'abc' | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }
    It 'matches the known SHA-256 of the empty string' {
        Get-StringHash -Text '' | Should -Be 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    }
}

Describe 'Get-InstallerStamp' {
    It 'is a 64-char lowercase hex digest' {
        $stamp = Get-InstallerStamp -WrapperContent 'w' -ManagedSettingsJson 'm' -SchemaVersion 1
        $stamp | Should -Match '^[0-9a-f]{64}$'
    }
    It 'is stable for identical inputs' {
        $a = Get-InstallerStamp -WrapperContent 'w' -ManagedSettingsJson 'm' -SchemaVersion 1
        $b = Get-InstallerStamp -WrapperContent 'w' -ManagedSettingsJson 'm' -SchemaVersion 1
        $a | Should -Be $b
    }
    It 'changes when the baked token (managed settings) rotates - forces overwrite' {
        $envA = Get-DesiredTelemetryEnv -Endpoint 'https://c' -Token 'old-token'
        $envB = Get-DesiredTelemetryEnv -Endpoint 'https://c' -Token 'new-token'
        $jsonA = ConvertTo-ManagedSettingsJson -TelemetryEnv $envA
        $jsonB = ConvertTo-ManagedSettingsJson -TelemetryEnv $envB
        $stampA = Get-InstallerStamp -WrapperContent 'w' -ManagedSettingsJson $jsonA -SchemaVersion 1
        $stampB = Get-InstallerStamp -WrapperContent 'w' -ManagedSettingsJson $jsonB -SchemaVersion 1
        $stampA | Should -Not -Be $stampB
    }
    It 'changes when the wrapper content changes' {
        $a = Get-InstallerStamp -WrapperContent 'w1' -ManagedSettingsJson 'm' -SchemaVersion 1
        $b = Get-InstallerStamp -WrapperContent 'w2' -ManagedSettingsJson 'm' -SchemaVersion 1
        $a | Should -Not -Be $b
    }
    It 'changes when the schema version bumps' {
        $a = Get-InstallerStamp -WrapperContent 'w' -ManagedSettingsJson 'm' -SchemaVersion 1
        $b = Get-InstallerStamp -WrapperContent 'w' -ManagedSettingsJson 'm' -SchemaVersion 2
        $a | Should -Not -Be $b
    }
}

Describe 'Get-WslLegTarget' {
    It 'targets a distro absent from the stamp map' {
        (Get-WslLegTarget -Distro @('Ubuntu') -StampMap @{} -Stamp 's') | Should -Be 'Ubuntu'
    }
    It 'targets a distro below the current stamp' {
        (Get-WslLegTarget -Distro @('Ubuntu') -StampMap @{ Ubuntu = 'old' } -Stamp 'new') | Should -Be 'Ubuntu'
    }
    It 'skips a distro already at the current stamp' {
        (Get-WslLegTarget -Distro @('Ubuntu') -StampMap @{ Ubuntu = 's' } -Stamp 's').Count | Should -Be 0
    }
    It 'returns nothing when no distros are installed' {
        (Get-WslLegTarget -Distro @() -StampMap @{} -Stamp 's').Count | Should -Be 0
    }
}

Describe 'Resolve-InstallExitCode' {
    It 'returns 0 on full success' {
        Resolve-InstallExitCode -CoreOk $true -Partial $false | Should -Be 0
    }
    It 'returns 2 when core succeeded but something partial failed' {
        Resolve-InstallExitCode -CoreOk $true -Partial $true | Should -Be 2
    }
    It 'returns 1 when the core install failed' {
        Resolve-InstallExitCode -CoreOk $false -Partial $false | Should -Be 1
        Resolve-InstallExitCode -CoreOk $false -Partial $true  | Should -Be 1
    }
}

Describe 'Get-WrapperStatusLineCommand' {
    It 'invokes the wrapper via node with a quoted path' {
        Get-WrapperStatusLineCommand -WrapperPath 'C:\Program Files\ClaudeCode\cc-otel-wrapper.mjs' |
            Should -Be 'node "C:\Program Files\ClaudeCode\cc-otel-wrapper.mjs"'
    }
}

Describe 'Invoke-Install (orchestration)' {
    # The OS-boundary shims are mocked so orchestration runs off a real machine; file
    # I/O uses a throwaway temp dir. The embedded payload is set here to mimic what
    # build-installer.ps1 bakes in. Covers the runnable slice of the #26 matrix.
    BeforeEach {
        $script:target = Join-Path ([System.IO.Path]::GetTempPath()) ("cctgt-" + [guid]::NewGuid())
        $b64 = { param($t) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t)) }
        $managed = ConvertTo-ManagedSettingsJson -TelemetryEnv (Get-DesiredTelemetryEnv -Endpoint 'https://c.example.com' -Token 'tok')
        $script:ManagedSettingsB64 = & $b64 $managed
        $script:WrapperB64         = & $b64 '// wrapper'
        Mock Set-MachineEnvVar { $false }   # pretend machine env already correct
        Mock Get-WslDistro { @() }
        Mock Get-UserSettingsPath { @() }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:target -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'materializes managed settings and exits 0 when Node is present' {
        Mock Test-NodePresent { $true }
        Invoke-Install -InstallRoot $script:target | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:target 'managed-settings.json') | Should -BeTrue
    }

    It 'is idempotent - a clean second run also exits 0' {
        Mock Test-NodePresent { $true }
        Invoke-Install -InstallRoot $script:target | Out-Null
        Invoke-Install -InstallRoot $script:target | Should -Be 0
    }

    It 'exits 2 (partial) when Node is absent but installs core telemetry' {
        Mock Test-NodePresent { $false }
        Invoke-Install -InstallRoot $script:target | Should -Be 2
        Test-Path -LiteralPath (Join-Path $script:target 'managed-settings.json') | Should -BeTrue
    }

    It 'exits 1 when the payload is still the unbuilt placeholder' {
        $script:ManagedSettingsB64 = '__CC_OTEL_MANAGED_B64__'   # as committed, not built
        Invoke-Install -InstallRoot $script:target | Should -Be 1
    }
}
