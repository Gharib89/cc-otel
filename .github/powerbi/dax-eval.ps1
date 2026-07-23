# Headless DAX query against Power BI Desktop's embedded Analysis Services.
# Powers powerbi-ship's model/mixed-class verification loop: with the report open
# in Desktop, read a measure value unattended and assert it (cross-checked against
# the same value from Postgres) so a wrong-but-rendering measure cannot slip past a
# screenshot. Issue #200.
#
# Runtime: pwsh 7 (.NET 8), same as validate.ps1. Loads the ADOMD.NET client
# (Microsoft.AnalysisServices.AdomdClient) net8 build; MSOLAP/DAX Studio were
# rejected (see docs/agents/powerbi-tooling.md). The DLLs self-fetch from NuGet
# into .pbi-tools/ (gitignored) on first run, the same cache convention as TE2 and
# fab-inspector. No admin, no machine-wide registration, no MSAL (a local embedded
# connection uses no auth).
#
# Usage:
#   pwsh .github/powerbi/dax-eval.ps1 'EVALUATE ROW("v", [Total Sessions])'
#   pwsh .github/powerbi/dax-eval.ps1 '[Total Sessions]'          # bare scalar auto-wrapped
#   pwsh .github/powerbi/dax-eval.ps1 -Query '...' -Port 61754    # explicit port
#
# Output: tab-separated rows on stdout, a header row of column names first.
# Exit codes:
#   0  query ran (prints a header row of column names, then any result rows)
#   1  a query/DAX error (bad measure name, syntax) -- your DAX, not the tool
#   2  tooling failure (no msmdsrv found, ambiguous port, download/load failure)

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Query,
  [int]$Port
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AdomdVersion = '19.114.8'   # Microsoft.AnalysisServices.AdomdClient (net8 build)
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Cache    = Join-Path $RepoRoot '.pbi-tools'
$AdomdDir = Join-Path $Cache "adomd-$AdomdVersion"

# Write to stderr and exit WITHOUT Write-Error: under $ErrorActionPreference=Stop
# a Write-Error is terminating and would pre-empt the explicit exit code with 1.
function Fail-Tooling($msg) { [Console]::Error.WriteLine($msg); exit 2 }

# --- 1. Ensure the ADOMD.NET client is cached (self-fetch on first run) -------
# One nupkg (a zip) yields the four files a local embedded connection needs: the
# managed client + its two Runtime companions (net8) and the native msasxpress.dll.
# No MSAL: it is referenced only on the Azure AD auth path, never for localhost.
$needed = @(
  'Microsoft.AnalysisServices.AdomdClient.dll',
  'Microsoft.AnalysisServices.Runtime.Core.dll',
  'Microsoft.AnalysisServices.Runtime.Windows.dll',
  'msasxpress.dll'
)
$haveAll = (Test-Path $AdomdDir) -and -not ($needed | Where-Object { -not (Test-Path (Join-Path $AdomdDir $_)) })
if (-not $haveAll) {
  try {
    New-Item -ItemType Directory -Force -Path $AdomdDir | Out-Null
    $zip = Join-Path $Cache "adomd-$AdomdVersion.zip"
    $url = "https://api.nuget.org/v3-flatcontainer/microsoft.analysisservices.adomdclient/$AdomdVersion/microsoft.analysisservices.adomdclient.$AdomdVersion.nupkg"
    Invoke-WebRequest -Uri $url -OutFile $zip
    $expand = Join-Path $Cache "adomd-$AdomdVersion-nupkg"
    if (Test-Path $expand) { Remove-Item -Recurse -Force $expand }
    Expand-Archive -Path $zip -DestinationPath $expand -Force
    $srcMap = @{
      'Microsoft.AnalysisServices.AdomdClient.dll'         = 'lib/net8.0/Microsoft.AnalysisServices.AdomdClient.dll'
      'Microsoft.AnalysisServices.Runtime.Core.dll'        = 'lib/net8.0/Microsoft.AnalysisServices.Runtime.Core.dll'
      'Microsoft.AnalysisServices.Runtime.Windows.dll'     = 'lib/net8.0/Microsoft.AnalysisServices.Runtime.Windows.dll'
      'msasxpress.dll'                                      = 'runtimes/win-x64/native/msasxpress.dll'
    }
    foreach ($name in $needed) {
      $src = Join-Path $expand ($srcMap[$name] -replace '/', '\')
      if (-not (Test-Path $src)) { throw "expected $src in the nupkg" }
      Copy-Item $src (Join-Path $AdomdDir $name) -Force
    }
    Remove-Item -Recurse -Force $expand
    Remove-Item -Force $zip
  } catch {
    Fail-Tooling "ADOMD.NET download/extract failed: $_"
  }
}

# --- 2. Load ADOMD; a resolver pulls the Runtime companions from the cache ----
$onResolve = {
  param($s, $e)
  $n = ($e.Name -split ',')[0]
  $p = Join-Path $AdomdDir "$n.dll"
  if (Test-Path $p) { return [System.Reflection.Assembly]::LoadFrom($p) }
  return $null
}
try {
  [System.AppDomain]::CurrentDomain.add_AssemblyResolve($onResolve)
  $asm = [System.Reflection.Assembly]::LoadFrom((Join-Path $AdomdDir 'Microsoft.AnalysisServices.AdomdClient.dll'))
  $connType = $asm.GetType('Microsoft.AnalysisServices.AdomdClient.AdomdConnection', $true)
} catch {
  Fail-Tooling "ADOMD.NET load failed: $($_.Exception.Message)"
}

# --- 3. Discover the embedded msmdsrv port (or take an explicit -Port) --------
# Every open Desktop spawns its own msmdsrv; with more than one instance the port
# is ambiguous, so require -Port rather than guess.
# Wrapped whole: a throw from Get-Process/Get-NetTCPConnection (cmdlet missing,
# permission) would otherwise escape to exit 1 and break the exit-2 contract.
# Fail-Tooling's `exit 2` is not caught here -- `exit` terminates, it is not an
# exception -- so the intended tooling-failure paths still exit 2 cleanly.
if (-not $Port) {
  try {
    $msm = @(Get-Process msmdsrv -ErrorAction SilentlyContinue)
    if ($msm.Count -eq 0) { Fail-Tooling 'no msmdsrv process found -- open the report in Power BI Desktop first' }
    $ports = @($msm | ForEach-Object {
        Get-NetTCPConnection -OwningProcess $_.Id -State Listen -ErrorAction SilentlyContinue |
          Where-Object { $_.LocalAddress -eq '127.0.0.1' -or $_.LocalAddress -eq '::1' } |
          Select-Object -ExpandProperty LocalPort
      } | Sort-Object -Unique)
    if ($ports.Count -eq 0) { Fail-Tooling 'msmdsrv is running but not listening on loopback yet -- wait for the data model to load' }
    if ($ports.Count -gt 1) { Fail-Tooling "multiple embedded instances on ports $($ports -join ', ') -- pass -Port to disambiguate" }
    $Port = $ports[0]
  } catch {
    Fail-Tooling "port discovery failed: $($_.Exception.Message)"
  }
}

# --- 4. A bare scalar expression is wrapped so measures verify ergonomically --
$q = if ($Query -match '(?is)^\s*(EVALUATE|DEFINE)\b') { $Query } else { "EVALUATE ROW(`"value`", $Query)" }

# --- 5. Run the query and print rows tab-separated ----------------------------
$conn = $null
try {
  $conn = [Activator]::CreateInstance($connType, @("Data Source=localhost:$Port"))
  $conn.Open()
} catch {
  Fail-Tooling "cannot connect to localhost:${Port}: $($_.Exception.Message)"
}
try {
  $cmd = $conn.CreateCommand()
  $cmd.CommandText = $q
  $reader = $cmd.ExecuteReader()
  $cols = @(0..($reader.FieldCount - 1) | ForEach-Object { $reader.GetName($_) })
  Write-Output ($cols -join "`t")
  while ($reader.Read()) {
    $vals = @(0..($reader.FieldCount - 1) | ForEach-Object { $reader.GetValue($_) })
    Write-Output ($vals -join "`t")
  }
  $reader.Close()
} catch {
  # A DAX/query error (bad measure name, syntax) -- the caller's query, exit 1.
  [Console]::Error.WriteLine("DAX query failed: $($_.Exception.Message)")
  $conn.Close()
  exit 1
}
$conn.Close()
exit 0
