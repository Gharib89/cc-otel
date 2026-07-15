#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'bootstrap-environment.ps1') -Environment interim
}

Describe 'Invoke-BootstrapDeployment' {
    BeforeEach {
        Mock Get-MicrosoftAppRegistrationState { 'Registered' }
        Mock Get-PostgresSkuCapability {
            [pscustomobject]@{
                supportedServerEditions = @(
                    [pscustomobject]@{
                        supportedServerSkus = @(
                            [pscustomobject]@{
                                name = 'Standard_B2s'
                                supportedZones = @('1', '2', '3')
                            }
                            [pscustomobject]@{
                                name = 'Standard_B2ms'
                                supportedZones = @('1', '2', '3')
                            }
                        )
                    }
                )
            }
        }
    }

    It 'succeeds using Azure automatic zone selection first' {
        Mock Invoke-AzureGroupDeployment {
            [pscustomobject]@{ Succeeded = $true; Error = $null }
        }

        $result = Invoke-BootstrapDeployment -EnvironmentConfig ([pscustomobject]@{
            Environment = 'interim'
            ResourceGroup = 'rg-cc-otel-interim'
            ParameterFile = 'iac/params/interim.bicepparam'
            Location = 'swedencentral'
            PostgresSkuName = 'Standard_B2s'
        })

        $result.SelectedZone | Should -BeNullOrEmpty
        $result.Attempts | Should -Be @('automatic')
        Should -Invoke Invoke-AzureGroupDeployment -Times 1 -Exactly -ParameterFilter {
            $ResourceGroup -eq 'rg-cc-otel-interim' -and
            $ParameterFile -eq 'iac/params/interim.bicepparam'
        }
    }

    It 'retries a nested PostgreSQL CapacityNotAvailable error in a supported zone' {
        $script:attempt = 0
        Mock Invoke-AzureGroupDeployment {
            $script:attempt++
            if ($script:attempt -eq 1) {
                return [pscustomobject]@{
                    Succeeded = $false
                    Error = [pscustomobject]@{
                        code = 'DeploymentFailed'
                        details = @(
                            [pscustomobject]@{
                                code = 'ResourceDeploymentFailure'
                                details = @(
                                    [pscustomobject]@{ code = 'CapacityNotAvailable' }
                                )
                            }
                        )
                    }
                }
            }
            [pscustomobject]@{ Succeeded = $true; Error = $null }
        }

        $result = Invoke-BootstrapDeployment -EnvironmentConfig ([pscustomobject]@{
            Environment = 'interim'
            ResourceGroup = 'rg-cc-otel-interim'
            ParameterFile = 'iac/params/interim.bicepparam'
            Location = 'swedencentral'
            PostgresSkuName = 'Standard_B2s'
        })

        $result.SelectedZone | Should -Be '1'
        $result.Attempts | Should -Be @('automatic', '1')
    }

    It 'fails after exhausting automatic selection and every supported zone' {
        Mock Invoke-AzureGroupDeployment {
            [pscustomobject]@{
                Succeeded = $false
                Error = [pscustomobject]@{
                    code = 'DeploymentFailed'
                    details = @([pscustomobject]@{ code = 'CapacityNotAvailable' })
                }
            }
        }

        {
            Invoke-BootstrapDeployment -EnvironmentConfig ([pscustomobject]@{
                Environment = 'interim'
                ResourceGroup = 'rg-cc-otel-interim'
                ParameterFile = 'iac/params/interim.bicepparam'
                Location = 'swedencentral'
                PostgresSkuName = 'Standard_B2s'
            })
        } | Should -Throw -ExpectedMessage '*automatic, 1, 2, 3*'

        Should -Invoke Invoke-AzureGroupDeployment -Times 4 -Exactly
    }

    It 'fails immediately on a non-capacity ARM error' {
        Mock Invoke-AzureGroupDeployment {
            [pscustomobject]@{
                Succeeded = $false
                Error = [pscustomobject]@{
                    code = 'DeploymentFailed'
                    details = @([pscustomobject]@{ code = 'AuthorizationFailed' })
                }
            }
        }

        {
            Invoke-BootstrapDeployment -EnvironmentConfig ([pscustomobject]@{
                Environment = 'prod'
                ResourceGroup = 'rg-cc-otel-prod'
                ParameterFile = 'iac/params/prod.bicepparam'
                Location = 'swedencentral'
                PostgresSkuName = 'Standard_B2ms'
            })
        } | Should -Throw -ExpectedMessage '*AuthorizationFailed*'

        Should -Invoke Invoke-AzureGroupDeployment -Times 1 -Exactly
    }

    It 'fails before deployment when Microsoft.App is not registered' {
        Mock Get-MicrosoftAppRegistrationState { 'NotRegistered' }
        Mock Invoke-AzureGroupDeployment {
            throw 'deployment should not be called'
        }

        {
            Invoke-BootstrapDeployment -EnvironmentConfig ([pscustomobject]@{
                Environment = 'prod'
                ResourceGroup = 'rg-cc-otel-prod'
                ParameterFile = 'iac/params/prod.bicepparam'
                Location = 'swedencentral'
                PostgresSkuName = 'Standard_B2ms'
            })
        } | Should -Throw -ExpectedMessage '*az provider register --namespace Microsoft.App --wait*'

        Should -Invoke Invoke-AzureGroupDeployment -Times 0 -Exactly
    }
}

Describe 'Get-BootstrapEnvironmentConfig' {
    It 'maps each environment to its tracked parameter file and env resource group' {
        $interim = Get-BootstrapEnvironmentConfig -Environment interim -Values @{
            RESOURCE_GROUP = 'rg-cc-otel-interim'
        }
        $prod = Get-BootstrapEnvironmentConfig -Environment prod -Values @{
            RESOURCE_GROUP = 'rg-cc-otel-prod'
        }

        $interim.ParameterFile | Should -Be 'iac/params/interim.bicepparam'
        $interim.ResourceGroup | Should -Be 'rg-cc-otel-interim'
        $interim.PostgresSkuName | Should -Be 'Standard_B2s'
        $prod.ParameterFile | Should -Be 'iac/params/prod.bicepparam'
        $prod.ResourceGroup | Should -Be 'rg-cc-otel-prod'
        $prod.PostgresSkuName | Should -Be 'Standard_B2ms'
    }
}

Describe 'Import-BootstrapEnvironmentFile' {
    BeforeEach {
        $script:requiredValues = [ordered]@{
            AZURE_TENANT_ID = 'tenant'
            AZURE_SUBSCRIPTION_ID = 'subscription'
            AZURE_CLIENT_ID = 'client'
            AZURE_APP_OBJECT_ID = 'app-object'
            AZURE_SP_OBJECT_ID = 'sp-object'
            RESOURCE_GROUP = 'rg-cc-otel-interim'
            OPERATOR_INITIALS = 'ag'
            PG_ADMIN_PASSWORD = 'admin-password'
            MIGRATION_DATABASE_URL = 'postgres://ccotel_admin:x@ccotel-pg-interim.postgres.database.azure.com:5432/cc_otel?sslmode=require'
            DATABASE_URL = 'postgres://cc_otel_ingest_user:x@ccotel-pg-interim.postgres.database.azure.com:5432/cc_otel?sslmode=require'
            CC_OTEL_INGEST_PASSWORD = 'ingest-password'
            CC_OTEL_READ_PASSWORD = 'read-password'
            FLEET_TOKENS = '["token"]'
            GHCR_USERNAME = 'owner'
            GHCR_TOKEN = 'pat'
        }
    }

    It 'loads the complete file and overwrites stale process values' {
        $path = Join-Path $TestDrive '.env.interim'
        ($script:requiredValues.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) |
            Set-Content -LiteralPath $path
        $env:RESOURCE_GROUP = 'stale-rg'

        $values = Import-BootstrapEnvironmentFile -Path $path

        $values['RESOURCE_GROUP'] | Should -Be 'rg-cc-otel-interim'
        $env:RESOURCE_GROUP | Should -Be 'rg-cc-otel-interim'
    }

    It 'reports every missing required variable in one actionable error' {
        $path = Join-Path $TestDrive '.env.prod'
        'AZURE_TENANT_ID=tenant' | Set-Content -LiteralPath $path

        {
            Import-BootstrapEnvironmentFile -Path $path
        } | Should -Throw -ExpectedMessage '*MIGRATION_DATABASE_URL*GHCR_TOKEN*'
    }
}
Describe 'Assert-GhcrPullCredential' {
    It 'accepts the configured owner and read-packages scope' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                Headers = @{ 'X-OAuth-Scopes' = 'repo, read:packages' }
                Content = '{"login":"owner"}'
            }
        }

        { Assert-GhcrPullCredential -Username 'owner' -Value 'secret' } |
            Should -Not -Throw
    }

    It 'rejects a classic PAT without read-packages scope' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{
                Headers = @{ 'X-OAuth-Scopes' = 'repo' }
                Content = '{"login":"owner"}'
            }
        }

        { Assert-GhcrPullCredential -Username 'owner' -Value 'secret' } |
            Should -Throw -ExpectedMessage '*read:packages*'
    }
}
Describe 'Invoke-BootstrapEnvironment location handling' {
    It 'does not mutate the interactive shell location' {
        $before = (Get-Location).Path
        $command = $ExecutionContext.SessionState.InvokeCommand
        $previousAction = $command.LocationChangedAction
        try {
            $command.LocationChangedAction = { throw 'unexpected location change' }.GetNewClosure()
            Mock Import-BootstrapEnvironmentFile { throw 'reached bootstrap body' }

            { Invoke-BootstrapEnvironment -Environment interim } |
                Should -Throw -ExpectedMessage '*reached bootstrap body*'
            (Get-Location).Path | Should -Be $before
        }
        finally {
            $command.LocationChangedAction = $previousAction
        }
    }
}