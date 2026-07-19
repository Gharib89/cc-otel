# Local dev mirror of the ci-powerbi gate: runs the same three validators against
# the on-disk PBIP/PBIR report and TMDL model so an edit-then-validate loop closes
# on the dev machine before a push. Pinned to the exact tool versions CI pins
# (ajv 8.17.1, fab-inspector v3.4.0, Tabular Editor 2 2.28.0). A fourth leg runs
# Microsoft's conformance CLI, BLOCKING since issue #112 promoted it (it catches
# renders-but-wrong role/theme defects none of the other three can see).
#
# Usage:  pwsh .github/powerbi/validate.ps1
#
# Exit codes (match the retired POC contract):
#   0  clean
#   1  a validation error (a report/model bug)
#   2  tooling failure (download/env issue) -- not your report's fault
#
# fab-inspector and TE2 are cached under .pbi-tools/ (gitignored) and reused
# across runs; the ajv leg installs into a gitignored node_modules/ in the repo
# root (ESM bare-import resolution requires it there).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Report    = Join-Path $RepoRoot 'powerbi/cc-otel-report.Report'
$Model     = Join-Path $RepoRoot 'powerbi/cc-otel-report.SemanticModel/definition/model.tmdl'
$Rules     = Join-Path $RepoRoot '.github/powerbi/fab-inspector-rules.json'
$BpaRules  = Join-Path $RepoRoot '.github/powerbi/BPARules.json'
$ValidMjs  = Join-Path $RepoRoot '.github/powerbi/validate-pbir.mjs'
$Cache     = Join-Path $RepoRoot '.pbi-tools'

$FabVersion = 'v3.4.0'
$Te2Version = '2.28.0'
$AjvVersion = '8.17.1'
$MsCliSpec  = '@microsoft/powerbi-report-authoring-cli@0.1.4'

$failed  = $false   # a validator reported a report/model error -> exit 1
$tooling = $false   # a tool failed to run/download -> exit 2

function Section($name) { Write-Host ''; Write-Host "== $name ==" -ForegroundColor Cyan }
# Silent predicate: each leg decides whether a missing tool is a tooling failure
# (required) or just a skipped non-blocking check, and prints its own message.
function Have($tool) { [bool](Get-Command $tool -ErrorAction SilentlyContinue) }

# Outside any leg's try/catch, so guard it explicitly: a failure here must honour
# the exit-code contract (tooling failure = 2), not throw a bare non-2 exit.
try { New-Item -ItemType Directory -Force -Path $Cache -ErrorAction Stop | Out-Null }
catch { Write-Host "[TOOL] cannot create cache dir ${Cache}: $_" -ForegroundColor Red; exit 2 }

# --- 1. ajv PBIR schema validation ------------------------------------------
Section 'ajv PBIR schema'
if ((Have 'node') -and (Have 'npm')) {
  try {
    Push-Location $RepoRoot
    # --no-save + --no-package-lock keep the working tree clean (no package.json
    # or package-lock.json written); only the gitignored node_modules/ appears.
    & npm install --no-save --no-package-lock "ajv@$AjvVersion" 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
      Write-Host '[TOOL] npm install ajv failed' -ForegroundColor Red; $tooling = $true
    } else {
      & node $ValidMjs 'powerbi' 2>&1 | Out-Host
      if ($LASTEXITCODE -ne 0) { $failed = $true }
    }
  } catch {
    Write-Host "[TOOL] ajv leg failed to run: $_" -ForegroundColor Red; $tooling = $true
  } finally { Pop-Location }
} else {
  Write-Host '[TOOL] node + npm required for the ajv leg; see docs/agents/powerbi-tooling.md' -ForegroundColor Red
  $tooling = $true
}

# --- 2. fab-inspector PBIR rules --------------------------------------------
Section 'fab-inspector PBIR rules'
try {
  $fabDir = Join-Path $Cache "fab-inspector-$FabVersion"
  if (-not (Test-Path $fabDir)) {
    $zip = Join-Path $Cache 'fab.zip'
    $url = "https://github.com/NatVanG/fab-inspector/releases/download/$FabVersion/win-x64-FabInspCLI.zip"
    Invoke-WebRequest -Uri $url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $fabDir -Force
    Remove-Item $zip
  }
  $fabExe = Get-ChildItem -Path $fabDir -Recurse -Filter 'fab-inspector.exe' | Select-Object -First 1
  if (-not $fabExe) { throw "fab-inspector.exe not found under $fabDir" }
  # `-formats GitHub` is load-bearing: it makes fab-inspector exit non-zero on a
  # logType:error rule failure. Console format prints violations but exits 0.
  & $fabExe.FullName -fabricitem $Report -rules $Rules -formats GitHub 2>&1 | Out-Host
  if ($LASTEXITCODE -ne 0) { $failed = $true }
} catch {
  Write-Host "[TOOL] fab-inspector leg failed: $_" -ForegroundColor Red; $tooling = $true
}

# --- 3. Tabular Editor 2 Best Practice Analyzer -----------------------------
Section 'Tabular Editor 2 BPA'
try {
  $teDir = Join-Path $Cache "te2-$Te2Version"
  if (-not (Test-Path $teDir)) {
    $zip = Join-Path $Cache 'te2.zip'
    $url = "https://github.com/TabularEditor/TabularEditor/releases/download/$Te2Version/TabularEditor.Portable.zip"
    Invoke-WebRequest -Uri $url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $teDir -Force
    Remove-Item $zip
  }
  $teExe = Join-Path $teDir 'TabularEditor.exe'
  if (-not (Test-Path $teExe)) { throw "TabularEditor.exe not found under $teDir" }
  # TabularEditor.exe is a GUI-subsystem app: `& exe` does not propagate its exit
  # code to $LASTEXITCODE, so drive it via Start-Process -PassThru and read
  # .ExitCode (1 = an Error-severity rule was violated).
  $log = Join-Path $Cache 'te2-bpa.log'
  $err = Join-Path $Cache 'te2-bpa.err'
  $p = Start-Process -FilePath $teExe `
    -ArgumentList @($Model, '-A', $BpaRules) `
    -Wait -PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError $err
  Get-Content $log, $err -ErrorAction SilentlyContinue | Out-Host
  if ($p.ExitCode -ne 0) { $failed = $true }
} catch {
  Write-Host "[TOOL] Tabular Editor 2 leg failed: $_" -ForegroundColor Red; $tooling = $true
}

# --- 4. Microsoft conformance CLI -------------------------------------------
Section 'MS conformance CLI'
if (Have 'npx') {
  try {
    # First-party PBIR conformance validator, promoted to blocking by issue #112:
    # it catches role/theme defects that render silently wrong past the other legs.
    & npx -y $MsCliSpec validate $Report --format text 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { $failed = $true }
  } catch {
    Write-Host "[TOOL] MS conformance CLI failed to run: $_" -ForegroundColor Red; $tooling = $true
  }
} else {
  Write-Host '[TOOL] npx required for the MS conformance leg; see docs/agents/powerbi-tooling.md' -ForegroundColor Red
  $tooling = $true
}

# --- verdict ----------------------------------------------------------------
Write-Host ''
if ($tooling) { Write-Host 'RESULT: tooling failure (exit 2)' -ForegroundColor Red;    exit 2 }
if ($failed)  { Write-Host 'RESULT: validation errors (exit 1)' -ForegroundColor Red;   exit 1 }
Write-Host 'RESULT: clean (exit 0)' -ForegroundColor Green
exit 0
