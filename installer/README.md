# Installer

Fleet setup for tracked machines. IS pushes `install.ps1` (SYSTEM context) on a
~90-minute cadence; every run verifies real machine state and repairs drift, so a
clean machine no-ops fast. `build-installer.ps1` bakes the collector endpoint +
fleet token into the artifact IS pushes.

| File | Role |
|---|---|
| `install.ps1` | Drift-repairing per-machine installer (Windows PowerShell 5.1 compatible) |
| `build-installer.ps1` | Bakes endpoint + fleet token + wrapper, stamps, stages the `dist/` artifact |
| `cc-otel-wrapper.mjs` | Statusline wrapper (ADR-0003): forwards to the user's statusline, pushes rate-limit gauges |
| `install.Tests.ps1` | Pester unit + orchestration tests |
| `test_wrapper.mjs` | `node --test` suite for the wrapper |

## `install.ps1`

Delivers Claude Code telemetry config from one baked source two ways:
`managed-settings.json` (`C:\Program Files\ClaudeCode\managed-settings.json` —
highest precedence, cannot be user-overridden, authoritative) and a **mirror** at
machine scope (so telemetry still routes if the tolerant managed-settings parser
drops an entry). All five PII content gates are pinned: `OTEL_LOG_TOOL_DETAILS=1`,
the other four `=0` (issue #8). No traces exporter (ADR-0001).

**Statusline** is delivered through `managed-settings.json` too (ADR-0003): its
`statusLine.command` runs the wrapper (`cc-otel-wrapper.mjs`), which forwards to
each user's own statusline and pushes rate-limit gauges. Managed settings win, so
the installer **never mutates a user's `settings.json`** — the wrapper resolves the
user's real command at runtime.

Each tick it repairs three drift surfaces: installed files (`managed-settings.json`
+ `cc-otel-wrapper.mjs`), machine-scope env vars, and stray telemetry keys in
`C:\Users\*\.claude\settings*.json` (backed up before edit). A per-distro stamp map
in `.install-state.json` gates the WSL leg — `wsl.exe -l -q` each run; a distro
missing or below the current stamp gets the leg (wrapper + Linux-retargeted managed
settings); a distro without Node is skipped with a warning.

**Node is checked, never installed** (the LTS MSI is an IS prerequisite, issue
#31). Statusline delivery is core and Node-independent: managed settings carry it
and the wrapper self-heals once Node appears, so Node absence on the Windows host no
longer yields a partial — only the per-distro WSL Node check does.

Exit codes: **0** success / no-op · **1** core failure · **2** partial (a WSL distro
without Node skipped).

## `build-installer.ps1`

```powershell
./build-installer.ps1 -Environment interim   # or prod
```

Bootstrap-style: the only input is `-Environment`. Every value is derived from
`.env.<env>` via `bootstrap/lib/Get-BootstrapConfig.ps1` (the same loader
`bootstrap.ps1` uses) — the **collector endpoint** is the `ccotel-app-<env>`
container app's public ingress FQDN (resolved live via `az`, so an authenticated
`az` session is required), and the **fleet token** is the first entry of the
`FLEET_TOKENS` list (the collector accepts every token in the list; the build bakes
one). `FLEET_TOKENS` is a JSON array string in `.env.<env>` — e.g.
`FLEET_TOKENS=["tokenA","tokenB"]` — not comma-separated.

Bakes the generated `managed-settings.json` (endpoint + token + gates) and the
wrapper into a **single self-contained `dist/install.ps1`** as base64, then prints
the stamp — `SHA256(wrapper + managed-settings + schema version)` — on stdout.
Rotating the token changes the baked managed settings and therefore the stamp,
forcing every machine (and WSL distro) to overwrite. On each run the script
materializes the managed settings and wrapper back onto disk under the install root.

**`dist/install.ps1` is the only file handed to IS** — a single script their managed
tool distributes fleet-wide. **The token only ever lives in the gitignored
`.env.<env>` and the baked `dist/install.ps1` — `installer/dist/` is gitignored and
never committed; the committed `install.ps1` carries only placeholders.** The
statusline wrapper (`cc-otel-wrapper.mjs`, ADR-0003) is a required build input.

## Testing

```powershell
# from the repo root:
Invoke-ScriptAnalyzer -Path installer -Recurse   # must be clean (acceptance)
Invoke-Pester -Path installer                     # unit + orchestration
node --test installer/test_wrapper.mjs            # wrapper contract (ADR-0003)
```

The Pester tests cover the pure logic (config, stamp, drift predicates, WSL
gating, exit codes) and the orchestration off a real machine via boundary mocks;
`test_wrapper.mjs` covers the wrapper contract (identity, self-skip, throttle, OTLP
body shape, endpoint/header resolution). The SYSTEM-context / real-WSL / MSI
self-heal paths are the manual matrix in issue #26.

CI runs these three gates on every `installer/**` change (`.github/workflows/installer.yml`):
PSScriptAnalyzer and `node --test` on `ubuntu-latest`, and Pester on `windows-latest`
under `pwsh` (the suite dot-sources the Windows-only `install.ps1`). Run them locally
before pushing to keep CI green on the first try.
