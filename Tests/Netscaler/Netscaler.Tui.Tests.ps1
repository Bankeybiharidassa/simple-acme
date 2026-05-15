Set-StrictMode -Version Latest

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
    $script:runnerPath = Join-Path $script:repoRoot 'setup/NetScaler-Runner.psm1'
    Import-Module $script:runnerPath -Force
}

Describe 'NetScaler TUI wiring files' {
    It 'menu tree contains NetScaler action keys' {
        $menu = Get-Content -LiteralPath (Join-Path $script:repoRoot 'setup/Menu-Tree.ps1') -Raw
        $menu | Should -Match 'netscaler-deploy'
        $menu | Should -Match 'netscaler-whatif'
        $menu | Should -Match 'netscaler-diagnostics'
    }

    It 'device schemas include complete netscaler schema' {
        . (Join-Path $script:repoRoot 'setup/Device-Schemas.ps1')
        $DeviceSchemas.ContainsKey('netscaler') | Should -BeTrue
        $fieldNames = @($DeviceSchemas['netscaler'].Fields | ForEach-Object { $_.Name })
        @(
            'host'
            'username'
            'password_secret_name'
            'certkey_name'
            'cert_path'
            'key_path'
            'chain_path'
            'vserver_name'
            'require_primary'
            'sync_ha'
            'save_config'
            'replace_existing_server_certificate'
            'skip_certificate_check'
        ) | ForEach-Object { $fieldNames | Should -Contain $_ }
    }

    It 'certificate setup imports the NetScaler runner and dispatches actions' {
        $setup = Get-Content -LiteralPath (Join-Path $script:repoRoot 'certificate-setup.ps1') -Raw
        $setup | Should -Match 'setup/NetScaler-Runner\.psm1'
        $setup | Should -Match 'Invoke-NetScalerDeploymentForm'
        $setup | Should -Match "'netscaler-deploy'"
        $setup | Should -Match "'netscaler-whatif'"
        $setup | Should -Match "'netscaler-diagnostics'"
    }

    It 'NetScaler runner imports successfully and exports required commands' {
        $module = Import-Module $script:runnerPath -Force -PassThru
        @(
            'Invoke-NetScalerDeploymentForm'
            'Invoke-NetScalerDiagnostics'
            'Convert-NetScalerFormValuesToArguments'
            'Test-NetScalerTuiWiring'
        ) | ForEach-Object { $module.ExportedCommands.ContainsKey($_) | Should -BeTrue }
    }

    It 'release manifest includes the NetScaler TUI runner' {
        Get-Content -LiteralPath (Join-Path $script:repoRoot 'build/release-file-list.txt') -Raw | Should -Match 'setup/NetScaler-Runner\.psm1'
    }
}

Describe 'Convert-NetScalerFormValuesToArguments' {
    It 'maps all required parameters and optional flags correctly' {
        $values = @{
            host = 'adc01.example.local'
            username = 'nsroot'
            password_secret_name = 'NETSCALER_PASSWORD'
            certkey_name = 'wildcard_example_com'
            cert_path = '/tmp/fullchain.crt'
            key_path = '/tmp/privkey.key'
            chain_path = '/tmp/chain.crt'
            vserver_name = 'ssl-vsrv'
            require_primary = 'true'
            sync_ha = 'true'
            save_config = 'true'
            replace_existing_server_certificate = 'true'
            skip_certificate_check = 'true'
        }
        $args = @(Convert-NetScalerFormValuesToArguments -FormValues $values)
        $joined = $args -join ' '
        $joined | Should -Match '-NetScalerHost adc01\.example\.local'
        $joined | Should -Match '-Username nsroot'
        $joined | Should -Match '-PasswordSecretName NETSCALER_PASSWORD'
        $joined | Should -Match '-CertKeyName wildcard_example_com'
        $joined | Should -Match '-CertPath /tmp/fullchain\.crt'
        $joined | Should -Match '-KeyPath /tmp/privkey\.key'
        $joined | Should -Match '-ChainPath /tmp/chain\.crt'
        $joined | Should -Match '-VServerName ssl-vsrv'
        $args | Should -Contain '-ReplaceExistingServerCertificate'
        $args | Should -Contain '-SkipCertificateCheck'
    }

    It 'maps false booleans to negative switches and explicit RequirePrimary false' {
        $values = @{
            host = 'adc01.example.local'
            username = 'nsroot'
            password_secret_name = 'NETSCALER_PASSWORD'
            certkey_name = 'wildcard_example_com'
            cert_path = '/tmp/fullchain.crt'
            key_path = '/tmp/privkey.key'
            chain_path = ''
            vserver_name = 'ssl-vsrv'
            require_primary = 'false'
            sync_ha = 'false'
            save_config = 'false'
            replace_existing_server_certificate = 'false'
            skip_certificate_check = 'false'
        }
        $args = @(Convert-NetScalerFormValuesToArguments -FormValues $values)
        $args | Should -Contain '-RequirePrimary:$false'
        $args | Should -Contain '-NoSyncHA'
        $args | Should -Contain '-NoSaveConfig'
        $args | Should -Not -Contain '-ChainPath'
        $args | Should -Not -Contain '-ReplaceExistingServerCertificate'
        $args | Should -Not -Contain '-SkipCertificateCheck'
    }
}

Describe 'NetScaler deployment safety flow' {
    BeforeEach {
        Import-Module $script:runnerPath -Force
        $env:CERTIFICATE_LOG_DIR = Join-Path $TestDrive 'logs'
        $script:callOrder = [System.Collections.Generic.List[string]]::new()
        $formValues = @{
            host = 'adc01.example.local'
            username = 'nsroot'
            password_secret_name = 'SECRET_NAME_ONLY'
            certkey_name = 'wildcard_example_com'
            cert_path = '/tmp/fullchain.crt'
            key_path = '/tmp/privkey.key'
            chain_path = ''
            vserver_name = 'ssl-vsrv'
            require_primary = 'true'
            sync_ha = 'false'
            save_config = 'false'
            replace_existing_server_certificate = 'false'
            skip_certificate_check = 'true'
        }
        Mock -ModuleName NetScaler-Runner Show-TuiForm { $formValues }
    }

    AfterEach {
        Remove-Item Env:CERTIFICATE_LOG_DIR -ErrorAction SilentlyContinue
    }

    It 'runs WhatIf preview before real deployment and requires explicit confirmation' {
        Mock -ModuleName NetScaler-Runner Invoke-NetScalerConnectorScript {
            if ($WhatIfMode) { $script:callOrder.Add('preview') | Out-Null; return [pscustomobject]@{ Mode = 'WhatIfConnected' } }
            $script:callOrder.Add('deploy') | Out-Null
            [pscustomobject]@{ Mode = 'Execute' }
        }
        Mock -ModuleName NetScaler-Runner Read-Host { 'DEPLOY' }

        $result = Invoke-NetScalerDeploymentForm -ProjectRoot $script:repoRoot
        $result.Status | Should -Be 'DeploymentCompleted'
        @($script:callOrder) | Should -Be @('preview','deploy')
    }

    It 'does not deploy when confirmation is not exactly DEPLOY after preview' {
        Mock -ModuleName NetScaler-Runner Invoke-NetScalerConnectorScript {
            if ($WhatIfMode) { $script:callOrder.Add('preview') | Out-Null; return [pscustomobject]@{ Mode = 'WhatIfConnected' } }
            $script:callOrder.Add('deploy') | Out-Null
            [pscustomobject]@{ Mode = 'Execute' }
        }
        Mock -ModuleName NetScaler-Runner Read-Host { '' }

        $result = Invoke-NetScalerDeploymentForm -ProjectRoot $script:repoRoot
        $result.Status | Should -Be 'CanceledAfterPreview'
        @($script:callOrder) | Should -Be @('preview')
    }
}

Describe 'NetScaler diagnostics output' {
    BeforeEach {
        Import-Module $script:runnerPath -Force
        $env:CERTIFICATE_LOG_DIR = Join-Path $TestDrive 'logs'
    }

    AfterEach {
        Remove-Item Env:CERTIFICATE_LOG_DIR -ErrorAction SilentlyContinue
    }

    It 'creates diagnostic JSON without secret values' {
        $result = Invoke-NetScalerDiagnostics -ProjectRoot $script:repoRoot 6>$null
        $result.LogPath | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $result.LogPath | Should -BeTrue
        $json = Get-Content -LiteralPath $result.LogPath -Raw
        { $json | ConvertFrom-Json } | Should -Not -Throw
        $json | Should -Not -Match 'SUPER_SECRET_VALUE'
        $json | Should -Not -Match 'passplain'
        $result.Passed | Should -BeTrue
    }
}
