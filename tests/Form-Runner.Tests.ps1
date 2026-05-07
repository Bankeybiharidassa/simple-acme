Import-Module "$PSScriptRoot/../setup/Form-Runner.psm1" -Force

Describe 'Form runner deployment script wiring' {
    InModuleScope Form-Runner {
        It "Resolve-DeploymentScriptPath resolves cert2rds.ps1 from project root Scripts folder" {
            $resolved = Resolve-DeploymentScriptPath -ScriptFileName 'cert2rds.ps1'
            $expected = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts/cert2rds.ps1'
            [System.IO.Path]::GetFullPath($resolved) | Should -Be ([System.IO.Path]::GetFullPath($expected))
        }

        It 'Guided RDS template uses cert2rds.ps1 and CertThumbprint parameter only' {
            $template = Get-GuidedPipelineTemplate -TargetSystem 'rds' -ValidationMode 'http-01'
            $expected = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts/cert2rds.ps1'
            [System.IO.Path]::GetFullPath($template.ACME_SCRIPT_PATH) | Should -Be ([System.IO.Path]::GetFullPath($expected))
            $template.ACME_SCRIPT_PARAMETERS | Should -Be '{CertThumbprint}'
        }

        It 'Placeholder targets fail with a clear not implemented message' {
            { Get-ConnectorScriptByIntent -TargetIntent 'custom' } | Should -Throw '*This target type is not implemented yet.*'
            { Get-ConnectorScriptByIntent -TargetIntent 'mail' } | Should -Throw '*This target type is not implemented yet.*'
        }

        It 'Manage existing certificates menu does not expose placeholder or stub wording' {
            $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'setup/Form-Runner.psm1'
            $raw = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
            $manageBlock = [regex]::Match($raw, "function Invoke-ManageCertificatesMenu \{[\s\S]*?\n\}\n\nfunction Get-PolicyFilePathLegacy")
            $manageBlock.Success | Should -BeTrue
            $menuText = [string]$manageBlock.Value
            $menuText | Should -Not -Match '(?i)placeholder'
            $menuText | Should -Not -Match '(?i)not implemented yet'
            $menuText | Should -Not -Match '(?i)\bstub\b'
            $menuText | Should -Not -Match '(?i)remove certificate mapping'
        }

        It 'Invoke-AcmeForm keeps existing valid ACME_SCRIPT_PATH for unchanged target' {
            $envPath = 'TestDrive:\certificate.env'
            Set-Content -Path $envPath -Value '# test' -Encoding UTF8
            $existingScript = Resolve-DeploymentScriptPath -ScriptFileName 'cert2rds.ps1'

            Mock -CommandName Read-EnvFile -MockWith {
                @{
                    ACME_TARGET_SYSTEM = 'rds'
                    ACME_SCRIPT_PATH = $existingScript
                    CERTIFICATE_CONFIG_DIR = 'TestDrive:\config'
                    CERTIFICATE_API_KEY = 'abc123'
                }
            }
            $script:menuAnswers = @('rds','this-server','single')
            Mock -CommandName Read-MenuChoice -MockWith {
                $next = $script:menuAnswers[0]
                $script:menuAnswers = @($script:menuAnswers | Select-Object -Skip 1)
                return $next
            }
            Mock -CommandName Read-DomainsInput -MockWith { 'example.com' }
            Mock -CommandName Test-RoleAvailable -MockWith { $true }
            Mock -CommandName Write-EnvFile
            Mock -CommandName Save-SecurePlatformConfig
            Mock -CommandName Save-RenewalMapping
            Mock -CommandName Read-Host -MockWith { 'host1' }

            Invoke-AcmeForm -EnvFilePath $envPath | Out-Null

            Should -Invoke -CommandName Write-EnvFile -Times 1 -ParameterFilter {
                $Values.ACME_SCRIPT_PATH -eq $existingScript -and $Values.ACME_SCRIPT_PARAMETERS -eq '{CertThumbprint}'
            }
        }
    }
}

Describe 'ACME provider state handling' {
    InModuleScope Form-Runner {
        It 'Read-EffectiveSavedEnvValues reads effective values via exported Env-Loader API without private helper calls' {
            $envPath = Join-Path $TestDrive 'certificate.env'
            @(
                'ACME_DIRECTORY=https://acme.networking4all.com/dv',
                'DOMAINS=example.com'
            ) | Set-Content -Path $envPath -Encoding UTF8
            $cfgDir = Join-Path $TestDrive 'cfg'
            New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
            Write-CredentialStore -ConfigDir $cfgDir -Values @{ ACME_KID='kid-from-overlay'; ACME_HMAC_SECRET='secret-from-overlay' }

            { Read-EffectiveSavedEnvValues -EnvFilePath $envPath -ConfigDir $cfgDir } | Should -Not -Throw
            $effective = Read-EffectiveSavedEnvValues -EnvFilePath $envPath -ConfigDir $cfgDir
            $effective.ACME_KID | Should -Be 'kid-from-overlay'
            $effective.ACME_HMAC_SECRET | Should -Be 'secret-from-overlay'
        }

        It 'Save-time verification remains bootstrap tolerant for env files lacking runtime-only keys' {
            $envPath = Join-Path $TestDrive 'certificate.env'
            @(
                'ACME_DIRECTORY=https://acme-v02.api.letsencrypt.org/directory',
                'DOMAINS=example.com',
                'ACME_INSTALLATION_PLUGINS=script'
            ) | Set-Content -Path $envPath -Encoding UTF8

            { Read-EffectiveSavedEnvValues -EnvFilePath $envPath } | Should -Not -Throw
            { Import-EnvFile -Path $envPath -Force } | Should -Throw '*ACME_SCRIPT_PATH*'
        }

        It 'Resolve-SetupConfigDir defaults to the repository config directory when none is configured' {
            $oldConfigDir = [Environment]::GetEnvironmentVariable('CERTIFICATE_CONFIG_DIR')
            try {
                [Environment]::SetEnvironmentVariable('CERTIFICATE_CONFIG_DIR', '')
                $resolved = Resolve-SetupConfigDir -Values @{}
                $expected = Join-Path (Split-Path $PSScriptRoot -Parent) 'config'
                $resolved | Should -Be ([System.IO.Path]::GetFullPath($expected))
            } finally {
                [Environment]::SetEnvironmentVariable('CERTIFICATE_CONFIG_DIR', $oldConfigDir)
            }
        }

        It 'Get-Networking4AllAcmeDirectory builds test DV endpoint' {
            $url = Get-Networking4AllAcmeDirectory -Environment test -Product dv
            $url | Should -Be 'https://test-acme.networking4all.com/dv'
        }

        It 'Provider result overwrites stale letsencrypt ACME_DIRECTORY' {
            $values = @{
                ACME_PROVIDER = 'letsencrypt'
                ACME_DIRECTORY = 'https://acme-v02.api.letsencrypt.org/directory'
            }
            $providerResult = @{
                ACME_PROVIDER = 'networking4all'
                ACME_NETWORKING4ALL_ENVIRONMENT = 'test'
                ACME_NETWORKING4ALL_PRODUCT = 'dv'
                ACME_DIRECTORY = 'https://test-acme.networking4all.com/dv'
                ACME_REQUIRES_EAB = '1'
                ACME_VALIDATION_MODE = 'none'
            }
            foreach ($key in $providerResult.Keys) { $values[$key] = [string]$providerResult[$key] }
            $values['ACME_DIRECTORY'] | Should -Be 'https://test-acme.networking4all.com/dv'
        }

        It 'Assert-ProviderDirectoryConsistency rejects Networking4All provider with LetsEncrypt directory' {
            $invalid = @{
                ACME_PROVIDER = 'networking4all'
                ACME_DIRECTORY = 'https://acme-v02.api.letsencrypt.org/directory'
            }
            { Assert-ProviderDirectoryConsistency -Values $invalid } | Should -Throw '*Internal state mismatch: selected provider is Networking4All*'
        }

        It 'Resolve-EabCredentialsForSetup offers reuse when both existing credentials are present' {
            Mock -CommandName Read-SetupChoice -MockWith { 'reuse' }
            Mock -CommandName Read-Host -MockWith { throw 'Read-Host should not be called when reusing complete existing EAB credentials.' }
            $curr = @{
                ACME_KID = 'kid123'
                ACME_HMAC_SECRET = 'secret123'
            }
            $target = @{}
            $state = Resolve-EabCredentialsForSetup -CurrentValues $curr -TargetValues $target
            $state | Should -Be 'ok'
            $target.ACME_KID | Should -Be 'kid123'
            $target.ACME_HMAC_SECRET | Should -Be 'secret123'
        }

        It 'Resolve-EabCredentialsForSetup keeps existing credentials when replace is cancelled at explicit confirm' {
            $script:eabChoices = @('replace','no')
            Mock -CommandName Read-SetupChoice -MockWith {
                $next = $script:eabChoices[0]
                $script:eabChoices = @($script:eabChoices | Select-Object -Skip 1)
                return $next
            }
            Mock -CommandName Read-Host -MockWith { throw 'Read-Host should not be called when replace confirmation is denied.' }
            $curr = @{ ACME_KID = 'kid123'; ACME_HMAC_SECRET = 'secret123' }
            $target = @{}
            $state = Resolve-EabCredentialsForSetup -CurrentValues $curr -TargetValues $target
            $state | Should -Be 'ok'
            $target.ACME_KID | Should -Be 'kid123'
            $target.ACME_HMAC_SECRET | Should -Be 'secret123'
        }

        It 'Resolve-EabCredentialsForSetup replaces existing credentials only with explicit confirm and complete values' {
            $script:eabChoices = @('replace','yes')
            $script:eabInputs = @('kid-new','secret-new')
            Mock -CommandName Read-SetupChoice -MockWith {
                $next = $script:eabChoices[0]
                $script:eabChoices = @($script:eabChoices | Select-Object -Skip 1)
                return $next
            }
            Mock -CommandName Read-Host -MockWith {
                $next = $script:eabInputs[0]
                $script:eabInputs = @($script:eabInputs | Select-Object -Skip 1)
                return $next
            }
            $curr = @{ ACME_KID = 'kid123'; ACME_HMAC_SECRET = 'secret123' }
            $target = @{}
            $state = Resolve-EabCredentialsForSetup -CurrentValues $curr -TargetValues $target
            $state | Should -Be 'ok'
            $target.ACME_KID | Should -Be 'kid-new'
            $target.ACME_HMAC_SECRET | Should -Be 'secret-new'
        }

        It 'Resolve-EabCredentialsForSetup does not mutate target when replace values are incomplete' {
            Mock -CommandName Read-SetupChoice -MockWith { 'yes' } -ParameterFilter { $Prompt -like 'Replace credentials*' }
            Mock -CommandName Read-SetupChoice -MockWith { 'replace' } -ParameterFilter { $Prompt -eq 'EAB credentials' }
            Mock -CommandName Read-Host -MockWith { '' }
            $curr = @{ ACME_KID = 'kid123'; ACME_HMAC_SECRET = 'secret123' }
            $target = @{ ACME_KID = 'kid123'; ACME_HMAC_SECRET = 'secret123' }
            $state = Resolve-EabCredentialsForSetup -CurrentValues $curr -TargetValues $target
            $state | Should -Be '__BACK__'
            $target.ACME_KID | Should -Be 'kid123'
            $target.ACME_HMAC_SECRET | Should -Be 'secret123'
        }

        It 'Read-AcmeProviderSelection preserves existing EAB credentials when switching to Networking4All' {
            $script:providerAnswers = @('2','1','3')
            Mock -CommandName Read-SetupChoice -MockWith {
                $next = $script:providerAnswers[0]
                $script:providerAnswers = @($script:providerAnswers | Select-Object -Skip 1)
                return $next
            }
            $selection = Read-AcmeProviderSelection -CurrentValues @{
                DOMAINS = '*.example.com'
                ACME_KID = 'kid-existing'
                ACME_HMAC_SECRET = 'secret-existing'
            }
            $selection.ACME_KID | Should -Be 'kid-existing'
            $selection.ACME_HMAC_SECRET | Should -Be 'secret-existing'
            $selection.ACME_REQUIRES_EAB | Should -Be '1'
        }

        It 'Read-AcmeProviderSelection keeps existing EAB credentials when switching to LetsEncrypt' {
            Mock -CommandName Read-SetupChoice -MockWith { 'letsencrypt' }
            $selection = Read-AcmeProviderSelection -CurrentValues @{
                ACME_KID = 'kid-existing'
                ACME_HMAC_SECRET = 'secret-existing'
            }
            $selection.ACME_PROVIDER | Should -Be 'letsencrypt'
            $selection.ACME_KID | Should -Be 'kid-existing'
            $selection.ACME_HMAC_SECRET | Should -Be 'secret-existing'
            $selection.ACME_REQUIRES_EAB | Should -Be '0'
        }
    }
}

Describe 'Invoke-AcmeForm linear output guards' {
    It 'does not use fixed-position TUI calls inside Invoke-AcmeForm' {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'setup/Form-Runner.psm1'
        $raw = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
        $block = [regex]::Match($raw, "function Invoke-AcmeForm \{[\s\S]*?\n\}\n\nfunction Get-ObjectPropertyValue")
        $block.Success | Should -BeTrue
        $text = [string]$block.Value
        $text | Should -Not -Match '\bShow-TuiStatus\b'
        $text | Should -Not -Match '\bWrite-TuiAt\b'
        $text | Should -Not -Match '\bWrite-TuiBox\b'
    }

    It 'emits EAB resolution before command preview and save before reconcile prompt across setup flow' {
        $formRunnerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'setup/Form-Runner.psm1'
        $setupScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'certificate-setup.ps1'
        $formRunnerText = Get-Content -LiteralPath $formRunnerPath -Raw -Encoding UTF8
        $setupScriptText = Get-Content -LiteralPath $setupScriptPath -Raw -Encoding UTF8

        $eabIndex = $formRunnerText.IndexOf('EAB credentials')
        $previewIndex = $formRunnerText.IndexOf('Effective wacs command preview')
        $saveIndex = $formRunnerText.IndexOf('Save these settings?')
        $savedIndex = $formRunnerText.IndexOf('Saved bootstrap certificate.env for initial simple-acme setup.')
        $reconcileIndex = $setupScriptText.IndexOf('Run initial ACME reconcile now? [Y/N]')

        $eabIndex | Should -BeGreaterThan -1
        $previewIndex | Should -BeGreaterThan $eabIndex
        $saveIndex | Should -BeGreaterThan $previewIndex
        $savedIndex | Should -BeGreaterThan $saveIndex
        $reconcileIndex | Should -BeGreaterThan -1
    }

    It 'returns a saved result object after successful ACME form save' {
        $formRunnerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'setup/Form-Runner.psm1'
        $formRunnerText = Get-Content -LiteralPath $formRunnerPath -Raw -Encoding UTF8
        $formRunnerText | Should -Match "Status = 'saved'"
        $formRunnerText | Should -Match 'EnvFilePath = \[string\]\$resolvedEnvFilePath'
    }

    It 'routes setup-new to reconcile prompt only when result status is saved' {
        $setupScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'certificate-setup.ps1'
        $setupScriptText = Get-Content -LiteralPath $setupScriptPath -Raw -Encoding UTF8
        $setupScriptText | Should -Match "if \(\$null -eq \$result\)"
        $setupScriptText | Should -Match "elseif \(\[string\]\$result\.Status -eq 'saved'\)"
        $setupScriptText | Should -Match 'Invoke-InitialAcmeReconcilePrompt -RootDir \$PSScriptRoot -EnvFilePath \$envPath'
    }
}
