# Installer

Fleet setup for tracked machines. IS pushes `install.ps1` (SYSTEM context) on a
~90-minute cadence; every run verifies real machine state and repairs drift, so a
clean machine no-ops fast. `build-installer.ps1` bakes the collector endpoint +
fleet token into the artifact IS pushes.

| File | Role |
|---|---|
| `install.ps1` | Drift-repairing per-machine installer (Windows PowerShell 5.1 compatible) |
| `build-installer.ps1` | Bakes endpoint + fleet token, stamps, stages the `dist/` artifact |
| `install.Tests.ps1` | Pester unit + orchestration tests |

## `install.ps1`

Delivers Claude Code telemetry config from one baked source two ways:
`managed-settings.json` (`C:\Program Files\ClaudeCode\managed-settings.json` —
highest precedence, cannot be user-overridden, authoritative) and a **mirror** at
machine scope (so telemetry still routes if the tolerant managed-settings parser
drops an entry). All five PII content gates are pinned: `OTEL_LOG_TOOL_DETAILS=1`,
the other four `=0` (issue #8). No traces exporter (ADR-0001).

Each tick it repairs four drift surfaces: installed files (`managed-settings.json`
+ `cc-otel-wrapper.mjs`), machine-scope env vars, statusline wiring in each user's
`settings.json`, and stray telemetry keys in `C:\Users\*\.claude\settings*.json`
(backed up before edit). A per-distro stamp map in `.install-state.json` gates the
WSL leg — `wsl.exe -l -q` each run; a distro missing or below the current stamp
gets the leg; a distro without Node is skipped with a warning.

**Node is checked, never installed** (the LTS MSI is an IS prerequisite, issue
#31). Core telemetry installs regardless; statusline wiring is gated on Node and
self-heals the next tick once Node is present.

Exit codes: **0** success / no-op · **1** core failure · **2** partial (e.g. Node
absent → statusline deferred; a WSL distro skipped).

## `build-installer.ps1`

```powershell
$env:FLEET_TOKEN = '<fleet-bearer-token>'   # or a locally-exported .env value / CI secret
./build-installer.ps1 -Endpoint https://<collector-fqdn> -WrapperPath <path-to>/cc-otel-wrapper.mjs
```

Stages `dist/` with `install.ps1`, the baked `managed-settings.json`, the wrapper,
and `.install-stamp`, then prints the stamp — `SHA256(wrapper + managed-settings +
schema version)` — on stdout. Rotating the token changes the baked managed settings
and therefore the stamp, forcing every machine (and WSL distro) to overwrite.

The token is read from `$env:FLEET_TOKEN` (a GitHub/ACA secret in CI, issue #11, or
a locally-exported `.env` value); `-Token` overrides it. **It only ever lives in the
environment and the baked artifact — `installer/dist/` is gitignored and never
committed.** With no token set, the build warns and stages a non-authenticating
placeholder. The statusline wrapper (`cc-otel-wrapper.mjs`, ADR-0003) is a required
build input.

## Testing

```powershell
# from the repo root:
Invoke-ScriptAnalyzer -Path installer -Recurse   # must be clean (acceptance)
Invoke-Pester -Path installer                     # unit + orchestration
```

The unit tests cover the pure logic (config, stamp, drift predicates, WSL
gating, exit codes) and the orchestration off a real machine via boundary mocks.
The SYSTEM-context / real-WSL / MSI self-heal paths are the manual matrix in issue
#26. CI wiring for the PSScriptAnalyzer gate is tracked in issue #43.
