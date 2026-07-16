#Requires -Version 5.1
<#
.SYNOPSIS
    The single place `.env.<env>` becomes the derived values every bootstrap
    script and the orchestrator consume.
.DESCRIPTION
    Bootstrap step for issue #64. Before this, each script re-declared the same
    derivations (server name, RG scope, operator rule name, secret prefix) from
    granular params the operator hand-filled from `$env:*` - the copy-paste-and-
    swap friction (#48). This loader parses `.env.<env>` once and returns one
    typed object with the raw keys as named properties plus the derived values,
    so a script (or the orchestrator) takes only `-Environment`.

    Pure and side-effect free apart from reading the env file: it makes no Azure
    or GitHub calls, so it is unit-tested directly.
.NOTES
    Run indirectly via a bootstrap script's `-Environment` param, or directly to
    print the resolved object for debugging.
#>
param(
    [Parameter(Mandatory)][ValidateSet('interim', 'prod')][string]$Environment,
    # Defaults to .env.<environment> at the repo root (two levels above lib/).
    [string]$EnvFile
)

# =============================================================================
# Pure functions (no side effects) - the tested seam.
# =============================================================================

# The keys a full bring-up requires; the loader's default validation set.
$script:CoreRequiredKeys = @(
    'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'AZURE_CLIENT_ID',
    'AZURE_APP_OBJECT_ID', 'AZURE_SP_OBJECT_ID', 'RESOURCE_GROUP',
    'OPERATOR_INITIALS', 'DATABASE_URL', 'PG_ADMIN_PASSWORD',
    'CC_OTEL_INGEST_PASSWORD', 'CC_OTEL_READ_PASSWORD', 'FLEET_TOKENS',
    'GHCR_USERNAME', 'GHCR_TOKEN'
)

function Get-BootstrapRequiredKey {
    <# .SYNOPSIS The keys a full bring-up requires (the default validation set). #>
    [OutputType([string[]])]
    param()
    return $script:CoreRequiredKeys
}

function ConvertFrom-DotEnv {
    <#
    .SYNOPSIS
        Parse dotenv lines into an ordered key->value map.
    .DESCRIPTION
        Splits on the first `=` (so `=` inside a value, e.g. a connection string,
        survives), skips blank lines and `#` comments, and strips one layer of
        surrounding matching single or double quotes.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Line)

    $map = [ordered]@{}
    foreach ($raw in $Line) {
        if ($raw -match '^\s*(#|$)') { continue }
        $idx = $raw.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = ($raw.Substring(0, $idx).Trim()) -replace '^export\s+', ''
        $value = $raw.Substring($idx + 1).Trim()
        if ($value.Length -ge 2 -and
            (($value[0] -eq '"' -and $value[-1] -eq '"') -or
             ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $map[$key] = $value
    }
    return $map
}

function Get-MissingConfigKey {
    <# .SYNOPSIS Required keys that are absent or empty in the parsed map. #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Raw,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Required
    )
    $missing = foreach ($key in $Required) {
        if (-not $Raw.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$Raw[$key])) { $key }
    }
    return [string[]]$missing
}

function Get-DotEnvValue {
    <# .SYNOPSIS A key's value from the parsed map, or $null when absent. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Raw,
        [Parameter(Mandatory)][string]$Key
    )
    if ($Raw.Contains($Key)) { return [string]$Raw[$Key] }
    return $null
}

function Get-DerivedBootstrapConfig {
    <# .SYNOPSIS Build the typed config object from the parsed map. #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Raw,
        [Parameter(Mandatory)][string]$Environment
    )
    $sub = Get-DotEnvValue -Raw $Raw -Key 'AZURE_SUBSCRIPTION_ID'
    $rg = Get-DotEnvValue -Raw $Raw -Key 'RESOURCE_GROUP'
    $initials = Get-DotEnvValue -Raw $Raw -Key 'OPERATOR_INITIALS'

    [pscustomobject]@{
        Environment     = $Environment
        TenantId        = Get-DotEnvValue -Raw $Raw -Key 'AZURE_TENANT_ID'
        SubscriptionId  = $sub
        ClientId        = Get-DotEnvValue -Raw $Raw -Key 'AZURE_CLIENT_ID'
        AppObjectId     = Get-DotEnvValue -Raw $Raw -Key 'AZURE_APP_OBJECT_ID'
        SpObjectId      = Get-DotEnvValue -Raw $Raw -Key 'AZURE_SP_OBJECT_ID'
        ResourceGroup   = $rg
        Initials        = $initials
        DatabaseUrl     = Get-DotEnvValue -Raw $Raw -Key 'DATABASE_URL'
        PgAdminPassword = Get-DotEnvValue -Raw $Raw -Key 'PG_ADMIN_PASSWORD'
        IngestPassword  = Get-DotEnvValue -Raw $Raw -Key 'CC_OTEL_INGEST_PASSWORD'
        ReadPassword    = Get-DotEnvValue -Raw $Raw -Key 'CC_OTEL_READ_PASSWORD'
        FleetTokens     = Get-DotEnvValue -Raw $Raw -Key 'FLEET_TOKENS'
        GhcrUsername    = Get-DotEnvValue -Raw $Raw -Key 'GHCR_USERNAME'
        GhcrToken       = Get-DotEnvValue -Raw $Raw -Key 'GHCR_TOKEN'
        # Derived (null-safe when the source key is absent).
        ServerName      = "ccotel-pg-$Environment"
        SecretPrefix    = $Environment.ToUpperInvariant()
        Scope           = if ($sub -and $rg) { "/subscriptions/$sub/resourceGroups/$rg" } else { $null }
        RuleName        = if ($initials) { "operator-$($initials.ToLowerInvariant())" } else { $null }
    }
}

function Get-BootstrapConfig {
    <#
    .SYNOPSIS
        Load, validate, and derive the bootstrap config for an environment.
    .OUTPUTS
        A [pscustomobject] with the raw keys as named properties plus the derived
        ServerName / SecretPrefix / Scope / RuleName.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('interim', 'prod')][string]$Environment,
        [string]$EnvFile
    )
    if ([string]::IsNullOrWhiteSpace($EnvFile)) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $EnvFile = Join-Path $repoRoot ".env.$Environment"
    }
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        throw "Env file not found: $EnvFile (expected .env.$Environment). Create it from the key list in bootstrap/README.md."
    }

    $raw = ConvertFrom-DotEnv -Line (Get-Content -LiteralPath $EnvFile)
    $missing = Get-MissingConfigKey -Raw $raw -Required $script:CoreRequiredKeys
    if ($missing.Count -gt 0) {
        throw "Missing required .env.$Environment keys: $($missing -join ', ')."
    }
    return Get-DerivedBootstrapConfig -Raw $raw -Environment $Environment
}

# Run only when executed directly; dot-sourcing (tests, orchestrator) defines
# functions without loading a file or emitting output.
if ($MyInvocation.InvocationName -ne '.') {
    Get-BootstrapConfig -Environment $Environment -EnvFile $EnvFile
}
