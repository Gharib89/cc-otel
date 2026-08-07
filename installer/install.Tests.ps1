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

    It 'shortens the metric export interval so short sessions flush (default 60s is too long)' {
        $env['OTEL_METRIC_EXPORT_INTERVAL'] | Should -Be '10000'
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
    BeforeAll {
        $script:wrapper = 'C:\Program Files\ClaudeCode\cc-otel-wrapper.mjs'
    }
    It 'produces a document with the env block under the managed-settings key' {
        $json = ConvertTo-ManagedSettingsJson -TelemetryEnv (Get-DesiredTelemetryEnv -Endpoint 'https://c' -Token 't') -WrapperPath $wrapper
        $parsed = $json | ConvertFrom-Json
        $parsed.env.CLAUDE_CODE_ENABLE_TELEMETRY | Should -Be '1'
        $parsed.env.OTEL_EXPORTER_OTLP_HEADERS   | Should -Be 'Authorization=Bearer t'
    }
    It 'carries the wrapper statusLine (forward-slash path) as the delivery mechanism (ADR-0003)' {
        $parsed = (ConvertTo-ManagedSettingsJson -TelemetryEnv (Get-DesiredTelemetryEnv -Endpoint 'https://c' -Token 't') -WrapperPath $wrapper) | ConvertFrom-Json
        $parsed.statusLine.type    | Should -Be 'command'
        $parsed.statusLine.command | Should -Be 'node "C:/Program Files/ClaudeCode/cc-otel-wrapper.mjs"'
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
        $jsonA = ConvertTo-ManagedSettingsJson -TelemetryEnv $envA -WrapperPath 'C:\Program Files\ClaudeCode\cc-otel-wrapper.mjs'
        $jsonB = ConvertTo-ManagedSettingsJson -TelemetryEnv $envB -WrapperPath 'C:\Program Files\ClaudeCode\cc-otel-wrapper.mjs'
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

Describe 'Add-InstallerStampAttribute' {
    BeforeAll {
        $script:managedBase = ConvertTo-ManagedSettingsJson `
            -TelemetryEnv (Get-DesiredTelemetryEnv -Endpoint 'https://c' -Token 't') `
            -WrapperPath 'C:\Program Files\ClaudeCode\cc-otel-wrapper.mjs'
    }

    It 'carries the stamp as an OTel resource attribute so every signal names the config (#432)' {
        $parsed = (Add-InstallerStampAttribute -ManagedSettingsJson $managedBase -Stamp 'abc123') | ConvertFrom-Json
        $parsed.env.OTEL_RESOURCE_ATTRIBUTES | Should -Be 'installer.stamp=abc123'
    }

    It 'leaves the rest of the document intact' {
        $parsed = (Add-InstallerStampAttribute -ManagedSettingsJson $managedBase -Stamp 'abc123') | ConvertFrom-Json
        $parsed.env.OTEL_EXPORTER_OTLP_ENDPOINT | Should -Be 'https://c'
        $parsed.env.OTEL_EXPORTER_OTLP_HEADERS  | Should -Be 'Authorization=Bearer t'
        $parsed.env.OTEL_LOG_TOOL_DETAILS       | Should -Be '1'
        $parsed.statusLine.command | Should -Be 'node "C:/Program Files/ClaudeCode/cc-otel-wrapper.mjs"'
    }

    It 'is never an input to its own hash - the stamp is computed over the unstamped text' {
        # The fixed point that makes the injection safe: Invoke-Install hashes the baked
        # payload, then stamps it. Hashing the stamped text would give a different digest,
        # so the attribute would report a stamp no other artifact knows.
        $stamp   = Get-InstallerStamp -WrapperContent 'w' -ManagedSettingsJson $managedBase -SchemaVersion 2
        $stamped = Add-InstallerStampAttribute -ManagedSettingsJson $managedBase -Stamp $stamp
        (Get-InstallerStamp -WrapperContent 'w' -ManagedSettingsJson $stamped -SchemaVersion 2) | Should -Not -Be $stamp
        (($stamped | ConvertFrom-Json).env.OTEL_RESOURCE_ATTRIBUTES) | Should -Be "installer.stamp=$stamp"
    }

    It 'overwrites a stamp already present, so a re-push cannot leave two' {
        $once  = Add-InstallerStampAttribute -ManagedSettingsJson $managedBase -Stamp 'one'
        $twice = Add-InstallerStampAttribute -ManagedSettingsJson $once -Stamp 'two'
        (($twice | ConvertFrom-Json).env.OTEL_RESOURCE_ATTRIBUTES) | Should -Be 'installer.stamp=two'
    }

    It 'stamps a key the machine-env mirror will carry (OTEL_ prefixed, so the prune spares it)' {
        $stamped = Add-InstallerStampAttribute -ManagedSettingsJson $managedBase -Stamp 'abc123'
        $desired = @((($stamped | ConvertFrom-Json).env.PSObject.Properties).Name)
        $desired | Should -Contain 'OTEL_RESOURCE_ATTRIBUTES'
        (Select-StaleTelemetryVar -Existing $desired -Desired $desired) | Should -BeNullOrEmpty
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

Describe 'Get-WslDistro' {
    It 'returns empty when wsl.exe exits non-zero (SYSTEM context) rather than parsing its error text as distro names' {
        Mock wsl.exe { $global:LASTEXITCODE = -1; 'Running WSL as local system is not supported.'; 'Error code: Wsl/WSL_E_LOCAL_SYSTEM_NOT_SUPPORTED' }
        (Get-WslDistro).Count | Should -Be 0
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

Describe 'Select-StaleTelemetryVar' {
    It 'prunes a stale OTEL_ var absent from the desired block (the metrics-endpoint hijacker)' {
        Select-StaleTelemetryVar `
            -Existing @('OTEL_EXPORTER_OTLP_METRICS_ENDPOINT', 'OTEL_METRICS_EXPORTER', 'CLAUDE_CODE_ENABLE_TELEMETRY', 'Path') `
            -Desired  @('OTEL_METRICS_EXPORTER', 'CLAUDE_CODE_ENABLE_TELEMETRY') |
            Should -Be 'OTEL_EXPORTER_OTLP_METRICS_ENDPOINT'
    }
    It 'keeps OTEL_ vars that are in the desired block' {
        (Select-StaleTelemetryVar -Existing @('OTEL_METRICS_EXPORTER') -Desired @('OTEL_METRICS_EXPORTER')).Count | Should -Be 0
    }
    It 'never touches non-OTEL vars, even when absent from the desired block' {
        (Select-StaleTelemetryVar -Existing @('Path', 'CLAUDE_CODE_ENHANCED_TELEMETRY_BETA') -Desired @()).Count | Should -Be 0
    }
}

Describe 'Get-WrapperStatusLineCommand' {
    It 'invokes the wrapper via node with a quoted forward-slash path (ADR-0003)' {
        Get-WrapperStatusLineCommand -WrapperPath 'C:\Program Files\ClaudeCode\cc-otel-wrapper.mjs' |
            Should -Be 'node "C:/Program Files/ClaudeCode/cc-otel-wrapper.mjs"'
    }
}

Describe 'Invoke-Install (orchestration)' {
    # The OS-boundary shims are mocked so orchestration runs off a real machine; file
    # I/O uses a throwaway temp dir. The embedded payload is set here to mimic what
    # build-installer.ps1 bakes in. Covers the runnable slice of the #26 matrix.
    BeforeEach {
        $script:target = Join-Path ([System.IO.Path]::GetTempPath()) ("cctgt-" + [guid]::NewGuid())
        $b64 = { param($t) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($t)) }
        $managed = ConvertTo-ManagedSettingsJson -TelemetryEnv (Get-DesiredTelemetryEnv -Endpoint 'https://c.example.com' -Token 'tok') -WrapperPath 'C:\Program Files\ClaudeCode\cc-otel-wrapper.mjs'
        $script:ManagedSettingsB64 = & $b64 $managed
        $script:WrapperB64         = & $b64 '// wrapper'
        Mock Set-MachineEnvVar { $false }   # pretend machine env already correct
        Mock Get-MachineEnvName { @() }     # no stale machine vars unless a test says so
        Mock Remove-MachineEnvVar { $false }
        Mock Get-WslDistro { @() }
        Mock Get-UserSettingsPath { @() }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:target -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'materializes managed settings + wrapper as core and exits 0 (no Node gate)' {
        Invoke-Install -InstallRoot $script:target | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:target 'managed-settings.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:target 'cc-otel-wrapper.mjs')   | Should -BeTrue
    }

    It 'stamps the materialized managed settings and the env mirror with the persisted stamp (#432)' {
        Invoke-Install -InstallRoot $script:target | Should -Be 0
        $state = [System.IO.File]::ReadAllText((Join-Path $script:target '.install-state.json')) | ConvertFrom-Json
        $state.stamp | Should -Match '^[0-9a-f]{64}$'
        $attr = "installer.stamp=$($state.stamp)"
        $onDisk = [System.IO.File]::ReadAllText((Join-Path $script:target 'managed-settings.json')) | ConvertFrom-Json
        $onDisk.env.OTEL_RESOURCE_ATTRIBUTES | Should -Be $attr
        # The mirror is what a *new* Claude Code process reads, so the stamp has to reach it too.
        Should -Invoke Set-MachineEnvVar -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'OTEL_RESOURCE_ATTRIBUTES' -and $Value -eq $attr
        }
    }

    It 'is idempotent - a clean second run also exits 0' {
        Invoke-Install -InstallRoot $script:target | Out-Null
        Invoke-Install -InstallRoot $script:target | Should -Be 0
    }

    It 'never mutates a user settings.json statusLine (managed settings own delivery, ADR-0003)' {
        $userClaude = Join-Path $script:target 'UserProfile\.claude'
        New-Item -ItemType Directory -Path $userClaude -Force | Out-Null
        $userSettings = Join-Path $userClaude 'settings.json'
        $original = '{"statusLine":{"type":"command","command":"my own bar"}}'
        [System.IO.File]::WriteAllText($userSettings, $original)
        Mock Get-UserSettingsPath { @($userSettings) }
        Invoke-Install -InstallRoot $script:target | Should -Be 0
        [System.IO.File]::ReadAllText($userSettings) | Should -Be $original
    }

    It 'exits 1 when the payload is still the unbuilt placeholder' {
        $script:ManagedSettingsB64 = '__CC_OTEL_MANAGED_B64__'   # as committed, not built
        Invoke-Install -InstallRoot $script:target | Should -Be 1
    }

    It 'still exits 0 when a WSL distro does not converge (WSL is best-effort)' {
        Mock Get-WslDistro { @('Ubuntu') }
        Mock Invoke-WslLeg { $false }   # e.g. distro has no Node, or SYSTEM-context refusal
        Invoke-Install -InstallRoot $script:target | Should -Be 0
    }

    It 'prunes a stale machine-scope OTEL_ var not in the managed block' {
        Mock Get-MachineEnvName { @('OTEL_EXPORTER_OTLP_METRICS_ENDPOINT', 'OTEL_METRICS_EXPORTER', 'Path') }
        Invoke-Install -InstallRoot $script:target | Out-Null
        Should -Invoke Remove-MachineEnvVar -Times 1 -Exactly -ParameterFilter { $Name -eq 'OTEL_EXPORTER_OTLP_METRICS_ENDPOINT' }
        Should -Invoke Remove-MachineEnvVar -Times 0 -Exactly -ParameterFilter { $Name -eq 'OTEL_METRICS_EXPORTER' }
    }
}

Describe 'build-installer pure seam' {
    BeforeAll {
        # Dot-source with a dummy -Environment; the script's guard defines its
        # functions without baking, and the nested config-loader dot-source is
        # inert (guard-skipped, so no .env read or az call at load).
        . (Join-Path $PSScriptRoot 'build-installer.ps1') -Environment 'interim'
    }

    Context 'Select-FleetToken' {
        It 'bakes the first token of the FLEET_TOKENS JSON array' {
            Select-FleetToken -FleetTokens '["first","second"]' | Should -Be 'first'
        }
        It 'handles a single-element array' {
            Select-FleetToken -FleetTokens '["only"]' | Should -Be 'only'
        }
        It 'throws on an empty list' {
            { Select-FleetToken -FleetTokens '[]' } | Should -Throw -ExpectedMessage '*FLEET_TOKENS is empty*'
        }
    }

    Context 'ConvertTo-CollectorEndpoint' {
        It 'prepends https:// to a bare ingress FQDN' {
            ConvertTo-CollectorEndpoint -Fqdn 'ccotel-app-interim.region.azurecontainerapps.io' |
                Should -Be 'https://ccotel-app-interim.region.azurecontainerapps.io'
        }
        It 'throws on an empty FQDN' {
            { ConvertTo-CollectorEndpoint -Fqdn '  ' } | Should -Throw -ExpectedMessage '*FQDN is empty*'
        }
    }
}
