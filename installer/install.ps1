#Requires -Version 5.1
<#
.SYNOPSIS
    cc-otel fleet installer - drift-repairing, idempotent, SYSTEM-context.

.DESCRIPTION
    Pushed by IS on a ~90-minute cadence (issue #26). Every run verifies real
    machine state against the baked payload and repairs drift; a clean machine
    no-ops fast and exits 0. The three drift surfaces verified each tick:

      1. Installed files    - managed-settings.json + cc-otel-wrapper.mjs match the payload.
      2. Machine env vars   - the telemetry env block mirrored at Machine scope.
      3. User telemetry keys - conflicting telemetry keys stripped from user settings*.json.

    Telemetry config is delivered from one baked source two ways: managed-settings.json
    (highest precedence, cannot be user-overridden - authoritative) and machine-scope
    env vars (a mirror, so telemetry still routes if a managed entry is dropped by the
    tolerant managed-settings parser). No traces exporter is set (ADR-0001).

    Statusline is delivered through managed-settings.json too: its statusLine.command
    runs the wrapper (cc-otel-wrapper.mjs, ADR-0003), which forwards to each user's own
    statusline and pushes rate-limit gauges. The installer never mutates a user's
    settings.json statusLine - managed settings win, and the wrapper resolves the user's
    real command at runtime.

    SELF-CONTAINED: build-installer.ps1 bakes the managed-settings.json (endpoint +
    fleet token + gates) and the statusline wrapper (ADR-0003) into this one script as
    base64. On each run it materializes both onto disk under $InstallRoot, so IS ships
    a single install.ps1. The committed source carries only placeholders (no secret).

.NOTES
    Exit codes: 0 success/no-op * 1 core failure * 2 partial (a WSL distro without
    Node skipped). Statusline delivery is core and Node-independent: managed settings
    carry it and the wrapper self-heals once Node appears, so Node absence on the
    Windows host no longer yields a partial. Node is checked, never installed inside a
    distro (the LTS MSI is an IS prerequisite, issue #31).
#>
param(
    # Install target root. C:\Program Files\ClaudeCode on a real fleet machine.
    [string]$InstallRoot = (Join-Path $env:ProgramFiles 'ClaudeCode')
)

# --- constants ---------------------------------------------------------------

# Bumped when the wrapper contract or managed-settings shape changes; part of the
# stamp so a schema bump forces every machine (and WSL distro) to re-converge.
# v2: managed-settings.json now carries statusLine (wrapper delivery, ADR-0003).
$script:InstallerSchemaVersion = 2

# Managed settings + wrapper paths inside a WSL distro (Linux system dir; verified
# against the Claude Code settings docs). Windows uses $InstallRoot\....
$script:WslManagedSettingsPath = '/etc/claude-code/managed-settings.json'
$script:WslManagedSettingsDir  = '/etc/claude-code'
$script:WslWrapperPath         = '/etc/claude-code/cc-otel-wrapper.mjs'

# --- baked payload -----------------------------------------------------------
# This script is SELF-CONTAINED: IS distributes a single install.ps1. build-installer.ps1
# base64-substitutes the managed-settings.json (endpoint + fleet token + gates) and the
# statusline wrapper into the two placeholders below, then gitignores the built copy.
# The committed source keeps the placeholders (no secret) - it is a template, not runnable
# as-is (Invoke-Install exits 1 with "not built" if the payload is still a placeholder).
$script:ManagedSettingsB64 = '__CC_OTEL_MANAGED_B64__'
$script:WrapperB64         = '__CC_OTEL_WRAPPER_B64__'

# =============================================================================
# Pure functions (no side effects) - the tested seam.
# =============================================================================

function Get-DesiredTelemetryEnv {
    <#
    .SYNOPSIS Builds the managed telemetry env block from a baked endpoint + token.
    .DESCRIPTION
        The single source of truth for what Claude Code telemetry config the fleet
        runs. TOOL_DETAILS=1 (needed for tool attribution); the other four PII
        content gates pinned to 0 (issue #8). No OTEL_TRACES_EXPORTER (ADR-0001).
    #>
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Token
    )
    return [ordered]@{
        CLAUDE_CODE_ENABLE_TELEMETRY  = '1'
        OTEL_METRICS_EXPORTER         = 'otlp'
        OTEL_LOGS_EXPORTER            = 'otlp'
        OTEL_EXPORTER_OTLP_PROTOCOL   = 'http/protobuf'
        OTEL_EXPORTER_OTLP_ENDPOINT   = $Endpoint
        OTEL_EXPORTER_OTLP_HEADERS    = "Authorization=Bearer $Token"
        OTEL_LOG_USER_PROMPTS         = '0'
        OTEL_LOG_ASSISTANT_RESPONSES  = '0'
        OTEL_LOG_TOOL_DETAILS         = '1'
        OTEL_LOG_TOOL_CONTENT         = '0'
        OTEL_LOG_RAW_API_BODIES       = '0'
    }
}

function ConvertTo-ManagedSettingsJson {
    <#
    .SYNOPSIS Wraps an env block + wrapper statusLine into the managed-settings.json document.
    .DESCRIPTION
        managed-settings.json is the SOLE statusline delivery mechanism (ADR-0003):
        its statusLine.command runs the wrapper (highest precedence, so Claude Code
        picks it up), and the wrapper resolves each user's real statusline at runtime.
        Both the build-time bake and the runtime materialization must produce identical
        text, so statusLine lives here in the shared builder - never in one path only.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$TelemetryEnv,
        [Parameter(Mandatory)][string]$WrapperPath
    )
    $doc = [ordered]@{
        env        = $TelemetryEnv
        statusLine = [ordered]@{
            type    = 'command'
            command = (Get-WrapperStatusLineCommand -WrapperPath $WrapperPath)
        }
    }
    return ($doc | ConvertTo-Json -Depth 5)
}

function Get-StringHash {
    <# .SYNOPSIS Lowercase hex SHA-256 of a string's UTF-8 bytes. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-InstallerStamp {
    <#
    .SYNOPSIS Deterministic installer stamp = SHA256(wrapper + managed-settings + schema).
    .DESCRIPTION
        Computed over the on-disk payload text so build-time and run-time stamps
        match regardless of PowerShell version. Rotating the fleet token changes
        the baked managed-settings text, which changes the stamp and forces every
        machine to overwrite (acceptance criterion).
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$WrapperContent,
        [Parameter(Mandatory)][string]$ManagedSettingsJson,
        [Parameter(Mandatory)][int]$SchemaVersion
    )
    return (Get-StringHash ($WrapperContent + $ManagedSettingsJson + $SchemaVersion))
}

function Get-WrapperStatusLineCommand {
    <#
    .SYNOPSIS The statusLine command that runs the wrapper via Node.
    .DESCRIPTION
        Forward-slash path, quoted for the space in "Program Files" (ADR-0003). Node
        accepts forward slashes on Windows, and it keeps the baked managed-settings.json
        portable (the same builder serves the WSL leg's Linux wrapper path).
    #>
    param([Parameter(Mandatory)][string]$WrapperPath)
    $forward = $WrapperPath -replace '\\', '/'
    return "node `"$forward`""
}

function Get-WslLegTarget {
    <#
    .SYNOPSIS Distros that need the WSL leg: absent from the stamp map or below the current stamp.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Distro,
        [Parameter(Mandatory)][System.Collections.IDictionary]$StampMap,
        [Parameter(Mandatory)][string]$Stamp
    )
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($d in $Distro) {
        if (-not $StampMap.Contains($d) -or $StampMap[$d] -ne $Stamp) { $targets.Add($d) }
    }
    return $targets.ToArray()
}

function Resolve-InstallExitCode {
    <# .SYNOPSIS 0 success/no-op * 1 core failure * 2 partial. #>
    param(
        [Parameter(Mandatory)][bool]$CoreOk,
        [Parameter(Mandatory)][bool]$Partial
    )
    if (-not $CoreOk) { return 1 }
    if ($Partial) { return 2 }
    return 0
}

# =============================================================================
# Effectful shims - thin wrappers over machine state, kept small on purpose.
# =============================================================================

function Write-InstallLog {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    Write-Information "[$Level] $Message" -InformationAction Continue
}

function Read-Text {
    <# .SYNOPSIS UTF-8 file text, or $null when the file is absent. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path)
}

function ConvertFrom-BakedPayload {
    <#
    .SYNOPSIS Decode a base64 payload baked in by build-installer.ps1.
    .DESCRIPTION Returns the UTF-8 text, or $null when the value is still the
        unbuilt placeholder / not valid base64 (the placeholder contains '_',
        which the standard base64 alphabet excludes, so it fails to decode).
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Base64)
    try { return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Base64)) }
    catch { return $null }
}

function Write-TextFile {
    <# .SYNOPSIS Write UTF-8 (no BOM) text, creating the parent directory. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Write file')) { return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        # .NET call: literal path, no PowerShell wildcard expansion (New-Item has no -LiteralPath).
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function Sync-InstalledFile {
    <#
    .SYNOPSIS Copy payload -> installed only when content differs (drift-repair).
    .OUTPUTS $true if a write happened, $false if already in sync.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$SourceText, [Parameter(Mandatory)][string]$TargetPath)
    $current = Read-Text -Path $TargetPath
    if ($current -eq $SourceText) { return $false }
    if (-not $PSCmdlet.ShouldProcess($TargetPath, 'Sync file')) { return $false }
    # Sync owns the decision; force the write so it can't be independently declined.
    Write-TextFile -Path $TargetPath -Content $SourceText -Confirm:$false
    return $true
}

function Set-MachineEnvVar {
    <# .SYNOPSIS Set a machine-scope env var only when its value has drifted. #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    $current = [System.Environment]::GetEnvironmentVariable($Name, 'Machine')
    if ($current -eq $Value) { return $false }
    if (-not $PSCmdlet.ShouldProcess("Machine env $Name", 'Set')) { return $false }
    [System.Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
    return $true
}

function Get-InstallState {
    <# .SYNOPSIS Read .install-state.json, or a fresh default when absent/unreadable. #>
    param([Parameter(Mandatory)][string]$Path)
    $default = [ordered]@{ schemaVersion = $script:InstallerSchemaVersion; stamp = $null; wsl = @{} }
    $text = Read-Text -Path $Path
    if (-not $text) { return $default }
    try {
        $parsed = $text | ConvertFrom-Json
        $wsl = @{}
        if ($parsed.PSObject.Properties['wsl'] -and $parsed.wsl) {
            foreach ($p in $parsed.wsl.PSObject.Properties) { $wsl[$p.Name] = $p.Value }
        }
        $stamp = if ($parsed.PSObject.Properties['stamp']) { $parsed.stamp } else { $null }
        return [ordered]@{ schemaVersion = $script:InstallerSchemaVersion; stamp = $stamp; wsl = $wsl }
    }
    catch {
        Write-InstallLog "State file $Path unreadable ($($_.Exception.Message)); treating as fresh." 'WARN'
        return $default
    }
}

function Save-InstallState {
    <# .SYNOPSIS Persist the stamp + per-distro WSL stamp map. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][System.Collections.IDictionary]$State)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Save install state')) { return }
    Write-TextFile -Path $Path -Content ($State | ConvertTo-Json -Depth 5) -Confirm:$false
}

function Get-UserSettingsPath {
    <#
    .SYNOPSIS Every C:\Users\*\.claude\settings*.json (SYSTEM enumerates real profiles).
    .DESCRIPTION SYSTEM has no %USERPROFILE%, so walk C:\Users\* directly (issue #26).
    #>
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if (-not (Test-Path -LiteralPath $usersRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName '.claude' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter 'settings*.json' -File -ErrorAction SilentlyContinue } |
        ForEach-Object { $_.FullName })
}

function Backup-File {
    <# .SYNOPSIS Copy path -> path.bak before an in-place edit (kept per issue #26). #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Backup')) { return }
    Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
}

function Clear-UserTelemetryKey {
    <#
    .SYNOPSIS Strip managed telemetry keys from a user's settings env block (backup first).
    .DESCRIPTION Managed settings win regardless, but a user's own OTEL_* keys are
        confusing drift; sanitize keeps user files clean (issue #26).
    .OUTPUTS $true if the file was changed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Key)
    $text = Read-Text -Path $Path
    if (-not $text) { return $false }
    $settings = $text | ConvertFrom-Json
    if (-not $settings.PSObject.Properties['env'] -or -not $settings.env) { return $false }
    $toRemove = @($Key | Where-Object { $settings.env.PSObject.Properties[$_] })
    if ($toRemove.Count -eq 0) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Strip telemetry keys')) { return $false }
    # Sanitize is confirmed; backup + write are mandatory parts of it, not separately declinable.
    Backup-File -Path $Path -Confirm:$false
    foreach ($k in $toRemove) { $settings.env.PSObject.Properties.Remove($k) }
    Write-TextFile -Path $Path -Content ($settings | ConvertTo-Json -Depth 10) -Confirm:$false
    return $true
}

function Get-WslDistro {
    <# .SYNOPSIS Installed WSL distro names, or empty when WSL is absent. #>
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
    try {
        # wsl.exe emits UTF-16LE; normalize and drop the "docker-desktop*" helpers.
        $raw = & wsl.exe -l -q 2>$null
        return @($raw |
            ForEach-Object { ($_ -replace '\0', '').Trim() } |
            Where-Object { $_ -and $_ -notmatch '^docker-desktop' })
    }
    catch { return @() }
}

function Invoke-WslLeg {
    <#
    .SYNOPSIS Install the wrapper + managed settings inside one WSL distro; skip (warn) if it lacks Node.
    .OUTPUTS $true on success, $false if skipped/failed (caller records partial).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$ManagedSettingsJson,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WrapperContent
    )
    try {
        $hasNode = & wsl.exe -d $Distro -- sh -c 'command -v node >/dev/null 2>&1 && echo yes' 2>$null
        if (("$hasNode").Trim() -ne 'yes') {
            Write-InstallLog "WSL distro '$Distro' has no Node; skipping." 'WARN'
            return $false
        }
        if (-not $PSCmdlet.ShouldProcess("WSL:$Distro", 'Install wrapper + managed settings')) { return $false }
        # Use the Linux dir constant, not Split-Path - on Windows PowerShell Split-Path
        # rewrites '/etc/...' to '\etc\...', which sh would treat as a bad relative path.
        # Materialize the wrapper first, then the managed settings that points at it.
        $WrapperContent | & wsl.exe -d $Distro -u root -- sh -c "mkdir -p '$script:WslManagedSettingsDir' && cat > '$script:WslWrapperPath'"
        if ($LASTEXITCODE -ne 0) {
            Write-InstallLog "WSL distro '$Distro' wrapper write failed (exit $LASTEXITCODE)." 'WARN'
            return $false
        }
        $ManagedSettingsJson | & wsl.exe -d $Distro -u root -- sh -c "cat > '$script:WslManagedSettingsPath'"
        if ($LASTEXITCODE -ne 0) {
            Write-InstallLog "WSL distro '$Distro' leg failed (exit $LASTEXITCODE)." 'WARN'
            return $false
        }
        return $true
    }
    catch {
        Write-InstallLog "WSL distro '$Distro' leg errored: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# =============================================================================
# Orchestration
# =============================================================================

function Invoke-Install {
    param([string]$InstallRoot)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $coreOk = $true
    $partial = $false

    $managedJson = ConvertFrom-BakedPayload -Base64 $script:ManagedSettingsB64
    if (-not $managedJson) {
        Write-InstallLog 'Managed settings payload missing - this install.ps1 was not built (run build-installer.ps1).' 'ERROR'
        return (Resolve-InstallExitCode -CoreOk $false -Partial $false)
    }
    $wrapperContent = ConvertFrom-BakedPayload -Base64 $script:WrapperB64   # $null if wrapper not baked
    $stamp = Get-InstallerStamp -WrapperContent ([string]$wrapperContent) -ManagedSettingsJson $managedJson -SchemaVersion $script:InstallerSchemaVersion

    $managedInstalledPath = Join-Path $InstallRoot 'managed-settings.json'
    $wrapperInstalledPath = Join-Path $InstallRoot 'cc-otel-wrapper.mjs'
    $statePath            = Join-Path $InstallRoot '.install-state.json'

    # --- 1. core: managed-settings.json file -------------------------------
    try {
        if (Sync-InstalledFile -SourceText $managedJson -TargetPath $managedInstalledPath) {
            Write-InstallLog "Managed settings written to $managedInstalledPath."
        }
    }
    catch {
        Write-InstallLog "Failed to write managed settings: $($_.Exception.Message)" 'ERROR'
        $coreOk = $false
    }

    # --- 2. core: mirror the env block at Machine scope --------------------
    $desiredEnv = @{}
    try {
        foreach ($p in (($managedJson | ConvertFrom-Json).env.PSObject.Properties)) {
            $desiredEnv[$p.Name] = [string]$p.Value
        }
        foreach ($name in $desiredEnv.Keys) {
            if (Set-MachineEnvVar -Name $name -Value $desiredEnv[$name]) {
                Write-InstallLog "Repaired machine env var $name."
            }
        }
    }
    catch {
        Write-InstallLog "Failed to set machine env vars: $($_.Exception.Message)" 'ERROR'
        $coreOk = $false
    }

    # --- 3. core: materialize the statusline wrapper -----------------------
    # Statusline delivery is via managed-settings.json (step 1), whose statusLine
    # already runs the wrapper (highest precedence). We only put the wrapper file
    # on disk; Claude Code picks it up and it self-heals once Node appears - so no
    # Node gate here, and no user settings.json is ever touched (ADR-0003).
    $userSettings = Get-UserSettingsPath
    if ($null -ne $wrapperContent) {
        try {
            if (Sync-InstalledFile -SourceText $wrapperContent -TargetPath $wrapperInstalledPath) {
                Write-InstallLog "Wrapper written to $wrapperInstalledPath."
            }
        }
        catch {
            Write-InstallLog "Failed to write wrapper: $($_.Exception.Message)" 'ERROR'
            $coreOk = $false
        }
    }
    else {
        Write-InstallLog 'Wrapper missing from payload - this install.ps1 was not built with a wrapper.' 'ERROR'
        $coreOk = $false
    }

    # --- 4. sanitize user telemetry keys -----------------------------------
    foreach ($path in $userSettings) {
        try {
            if (Clear-UserTelemetryKey -Path $path -Key $script:TelemetryEnvKey) {
                Write-InstallLog "Stripped telemetry keys from $path."
            }
        }
        catch { Write-InstallLog "Sanitize failed for ${path}: $($_.Exception.Message)" 'WARN' }
    }

    # --- 5. WSL leg (marker-gated per distro) ------------------------------
    # The baked managed JSON points statusLine at the Windows wrapper path, which
    # is meaningless inside a distro. Rebuild it against the Linux wrapper path -
    # same env block, retargeted statusLine (ADR-0003).
    $wslEnv = [ordered]@{}
    foreach ($p in (($managedJson | ConvertFrom-Json).env.PSObject.Properties)) { $wslEnv[$p.Name] = [string]$p.Value }
    $wslManagedJson = ConvertTo-ManagedSettingsJson -TelemetryEnv $wslEnv -WrapperPath $script:WslWrapperPath

    $state = Get-InstallState -Path $statePath
    $wslMap = $state.wsl
    $distros = @(Get-WslDistro)   # @() guard: a bare return collapses an empty array to $null
    foreach ($distro in (Get-WslLegTarget -Distro $distros -StampMap $wslMap -Stamp $stamp)) {
        if (Invoke-WslLeg -Distro $distro -ManagedSettingsJson $wslManagedJson -WrapperContent ([string]$wrapperContent)) {
            $wslMap[$distro] = $stamp
            Write-InstallLog "WSL distro '$distro' converged."
        }
        else { $partial = $true }
    }

    # --- 6. persist state ---------------------------------------------------
    if ($coreOk) {
        $newState = [ordered]@{ schemaVersion = $script:InstallerSchemaVersion; stamp = $stamp; wsl = $wslMap }
        try { Save-InstallState -Path $statePath -State $newState }
        catch { Write-InstallLog "Failed to persist install state: $($_.Exception.Message)" 'WARN'; $partial = $true }
    }

    $code = Resolve-InstallExitCode -CoreOk $coreOk -Partial $partial
    Write-InstallLog "install.ps1 finished with exit code $code."
    return $code
}

# The telemetry keys the installer manages; the sanitize pass strips these from user
# settings. Derived from the single desired-env source so the two can never drift.
$script:TelemetryEnvKey = @((Get-DesiredTelemetryEnv -Endpoint 'placeholder' -Token 'placeholder').Keys)

# Run only when executed directly; dot-sourcing (Pester) defines functions without running.
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-Install -InstallRoot $InstallRoot)
}
