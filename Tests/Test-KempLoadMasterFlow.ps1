function Invoke-TestKempLoadMasterFlow {
    param([scriptblock]$Assert)

    $root = Split-Path $PSScriptRoot -Parent
    $schemaPath = Join-Path $root 'setup\Device-Schemas.ps1'
    $runnerPath = Join-Path $root 'setup\Kemp-Runner.psm1'
    $setupPath = Join-Path $root 'certificate-setup.ps1'
    $menuPath = Join-Path $root 'setup\Menu-Tree.ps1'
    $registryPath = Join-Path $root 'setup\Connector-Registry.ps1'
    $hookPath = Join-Path $root 'Scripts\connectors\cert2kemp.ps1'
    $modulePath = Join-Path $root 'Scripts\Modules\SimpleAcme.Kemp\KempLoadMaster.psm1'
    $manifestPath = Join-Path $root 'Scripts\Modules\SimpleAcme.Kemp\SimpleAcme.Kemp.psd1'
    $releasePath = Join-Path $root 'build\release-file-list.txt'

    & $Assert 'Kemp schema is guided and no longer asks for env-var placeholders' {
        . $schemaPath
        if (-not $DeviceSchemas.ContainsKey('kemp')) { throw 'Missing Kemp schema.' }
        $schema = $DeviceSchemas['kemp']
        if (-not $schema.ContainsKey('SetupMode') -or [string]$schema.SetupMode -ne 'guided') { throw 'Kemp schema is not guided.' }
        $fieldNames = @($schema.Fields | ForEach-Object { [string]$_['Name'] })
        foreach ($required in @('host','port','username','password','api_key','skip_certificate_check','virtual_service_ids','certificate_name')) {
            if ($fieldNames -notcontains $required) { throw "Kemp schema missing field: $required" }
        }
        foreach ($removed in @('user_env','password_env','vs_id')) {
            if ($fieldNames -contains $removed) { throw "Kemp schema still contains old field: $removed" }
        }
    }

    & $Assert 'Kemp TUI actions are exposed and imported by certificate setup' {
        $menu = Get-Content -LiteralPath $menuPath -Raw
        foreach ($text in @('kemp-profile','kemp-whatif','kemp-deploy','kemp-diagnostics')) {
            if (-not $menu.Contains($text)) { throw "Menu missing Kemp action: $text" }
        }

        $setup = Get-Content -LiteralPath $setupPath -Raw
        foreach ($text in @(
            'setup/Kemp-Runner.psm1',
            "Assert-SetupCommandAvailable -CommandName 'Invoke-KempProfileForm'",
            "Assert-SetupCommandAvailable -CommandName 'Invoke-KempCertificateRequestSetup'",
            'Invoke-KempDeploymentForm -ProjectRoot $PSScriptRoot',
            'Invoke-KempDiagnostics -ProjectRoot $PSScriptRoot'
        )) {
            if (-not $setup.Contains($text)) { throw "certificate-setup missing Kemp wiring: $text" }
        }
    }

    & $Assert 'Dedicated Kemp profile action uses shared managed-device editor' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            "Invoke-DeviceProfileConnectorWizard -ProjectRoot `$ProjectRoot -ConnectorType 'kemp'",
            'function Invoke-DeviceProfileConnectorWizard',
            'Invoke-DeviceProfileEditorForChoice -ProjectRoot $ProjectRoot'
        )) {
            $source = if ($text -eq 'function Invoke-DeviceProfileConnectorWizard' -or $text -eq 'Invoke-DeviceProfileEditorForChoice -ProjectRoot $ProjectRoot') {
                Get-Content -LiteralPath (Join-Path $root 'setup\Device-Profile-Runner.psm1') -Raw
            } else {
                $runner
            }
            if (-not $source.Contains($text)) { throw "Missing shared Kemp profile editor wiring: $text" }
        }
    }

    & $Assert 'Kemp is supported during first-run issuance with PFX hook parameters' {
        $registry = Get-Content -LiteralPath $registryPath -Raw
        foreach ($text in @(
            "ConnectorId 'kemp'",
            'FirstRunAcmeSupported $true',
            "-PfxPath '{CacheFile}' -CachePassword '{CachePassword}'"
        )) {
            if (-not $registry.Contains($text)) { throw "Connector registry missing Kemp first-run contract: $text" }
        }

        $form = Get-Content -LiteralPath (Join-Path $root 'setup\Form-Runner.psm1') -Raw
        foreach ($text in @(
            'Kemp LoadMaster (issue now and save renewal hook targets)',
            'Invoke-KempCertificateRequestSetup',
            'Kemp LoadMaster deployment needs a PFX file'
        )) {
            if (-not $form.Contains($text)) { throw "Form runner missing Kemp first-run flow: $text" }
        }
    }

    & $Assert 'Kemp first-run setup pins renewal hook to the selected device profile' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            "Invoke-DeviceProfileConnectorWizard -ProjectRoot `$ProjectRoot -ConnectorType 'kemp'",
            "ACME_TARGET_DEVICE_ID",
            '-DeviceId $(ConvertTo-KempSingleQuotedArgument -Value $deviceId)'
        )) {
            if (-not $runner.Contains($text)) { throw "Missing Kemp device-specific setup behavior: $text" }
        }
    }

    & $Assert 'Kemp hook supports APIv2 and classic REST deployment code, not placeholders' {
        foreach ($path in @($hookPath,$modulePath,$manifestPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Kemp runtime file: $path" }
        }
        $hook = Get-Content -LiteralPath $hookPath -Raw
        $module = Get-Content -LiteralPath $modulePath -Raw
        foreach ($text in @(
            'Convert-KempPfxToPemBundle',
            "'-legacy'",
            'Invoke-KempOpenSsl',
            'Import-KempCertificate',
            'Set-KempVirtualServiceCertificate',
            'Test-KempVirtualServiceCertificate',
            'accessv2',
            "ApiVersion classic",
            'Invoke-KempClassicApi',
            'Invoke-KempApi',
            'Test-KempManagementUi',
            'addcert',
            'modvs',
            'SSLAcceleration',
            'CertFile'
        )) {
            if (-not ($hook.Contains($text) -or $module.Contains($text))) { throw "Missing Kemp API deployment behavior: $text" }
        }
        if ($hook.Contains('Placeholder: implement Kemp REST upload')) { throw 'Kemp hook still contains placeholder upload code.' }
    }

    & $Assert 'Kemp TLS bypass type loader tolerates module reloads' {
        $module = Get-Content -LiteralPath $modulePath -Raw
        foreach ($text in @(
            "'SimpleAcmeKempCertificatePolicy' -as [type]",
            'Unable to load SimpleAcmeKempCertificatePolicy',
            'RemoteCertificateValidationCallback',
            'TrustAnyCertificate'
        )) {
            if (-not $module.Contains($text)) { throw "Missing Kemp reload-safe TLS callback behavior: $text" }
        }
    }

    & $Assert 'Kemp files are included in release inventory' {
        $release = Get-Content -LiteralPath $releasePath -Raw
        foreach ($text in @(
            'scripts/modules/SimpleAcme.Kemp/KempLoadMaster.psm1',
            'scripts/modules/SimpleAcme.Kemp/SimpleAcme.Kemp.psd1',
            'setup/Kemp-Runner.psm1'
        )) {
            if (-not $release.Contains($text)) { throw "Release file list missing: $text" }
        }
    }
}
