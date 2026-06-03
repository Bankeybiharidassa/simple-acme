function Invoke-TestClavisterFlow {
    param([scriptblock]$Assert)

    $root = Split-Path $PSScriptRoot -Parent
    $schemaPath = Join-Path $root 'setup\Device-Schemas.ps1'
    $registryPath = Join-Path $root 'setup\Connector-Registry.ps1'
    $formPath = Join-Path $root 'setup\Form-Runner.psm1'
    $setupPath = Join-Path $root 'certificate-setup.ps1'
    $menuPath = Join-Path $root 'setup\Menu-Tree.ps1'
    $runnerPath = Join-Path $root 'setup\Clavister-Runner.psm1'
    $wrapperPath = Join-Path $root 'Scripts\cert2clavister.ps1'
    $hookPath = Join-Path $root 'Scripts\connectors\cert2clavister.ps1'
    $modulePath = Join-Path $root 'Scripts\Modules\SimpleAcme.Clavister\ClavisterSsh.psm1'
    $manifestPath = Join-Path $root 'Scripts\Modules\SimpleAcme.Clavister\SimpleAcme.Clavister.psd1'
    $releasePath = Join-Path $root 'build\release-file-list.txt'

    & $Assert 'Clavister schema is guided SSH/SCP and noob-readable' {
        . $schemaPath
        if (-not $DeviceSchemas.ContainsKey('clavister')) { throw 'Missing Clavister schema.' }
        $schema = $DeviceSchemas['clavister']
        if (-not $schema.ContainsKey('SetupMode') -or [string]$schema.SetupMode -ne 'guided') { throw 'Clavister schema is not guided.' }
        $fieldNames = @($schema.Fields | ForEach-Object { [string]$_['Name'] })
        foreach ($required in @('host','port','username','password','private_key_path','ssh_host_key_fingerprint','certificate_name','commit_after_upload','activate_after_commit')) {
            if ($fieldNames -notcontains $required) { throw "Clavister schema missing field: $required" }
        }
        $methodKeys = @($schema.ConnectionMethods | ForEach-Object { [string]$_['Key'] })
        foreach ($method in @('ssh_key','ssh_password')) {
            if ($methodKeys -notcontains $method) { throw "Clavister schema missing method: $method" }
        }
    }

    & $Assert 'Clavister first-run issuance is mapped to PFX hook' {
        $registry = Get-Content -LiteralPath $registryPath -Raw
        foreach ($text in @(
            "ConnectorId 'clavister'",
            'FirstRunAcmeSupported $true',
            "-PfxPath '{CacheFile}' -CachePassword '{CachePassword}'"
        )) {
            if (-not $registry.Contains($text)) { throw "Connector registry missing Clavister contract: $text" }
        }

        $form = Get-Content -LiteralPath $formPath -Raw
        foreach ($text in @(
            'Clavister NetWall / cOS Core (issue now and save SSH/SCP renewal hook)',
            'Invoke-ClavisterCertificateRequestSetup',
            'Clavister deployment needs a PFX file'
        )) {
            if (-not $form.Contains($text)) { throw "Form runner missing Clavister first-run flow: $text" }
        }
    }

    & $Assert 'Clavister TUI runner is imported and menu action is exposed' {
        foreach ($path in @($runnerPath,$wrapperPath,$hookPath,$modulePath,$manifestPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Clavister runtime file: $path" }
        }
        $menu = Get-Content -LiteralPath $menuPath -Raw
        if (-not $menu.Contains('clavister-profile')) { throw 'Menu missing Clavister profile action.' }
        $setup = Get-Content -LiteralPath $setupPath -Raw
        foreach ($text in @(
            'setup/Clavister-Runner.psm1',
            "Assert-SetupCommandAvailable -CommandName 'Invoke-ClavisterProfileForm'",
            "Assert-SetupCommandAvailable -CommandName 'Invoke-ClavisterCertificateRequestSetup'",
            'Invoke-ClavisterProfileForm -ProjectRoot $PSScriptRoot'
        )) {
            if (-not $setup.Contains($text)) { throw "certificate-setup missing Clavister wiring: $text" }
        }
    }

    & $Assert 'Clavister hook implements documented SCP certificate upload and commit activate commands' {
        $hook = Get-Content -LiteralPath $hookPath -Raw
        $module = Get-Content -LiteralPath $modulePath -Raw
        foreach ($text in @(
            'Convert-ClavisterPfxToPemFiles',
            'certificate/$CertificateName',
            'Invoke-ClavisterScpUpload',
            'Invoke-ClavisterSshCommand',
            "-Command 'commit'",
            "-Command 'activate'",
            'pscp.exe',
            'scp.exe',
            'plink.exe',
            'ssh.exe'
        )) {
            if (-not ($hook.Contains($text) -or $module.Contains($text))) { throw "Missing Clavister deployment behavior: $text" }
        }
    }

    & $Assert 'Clavister files are included in release inventory' {
        $release = Get-Content -LiteralPath $releasePath -Raw
        foreach ($text in @(
            'scripts/cert2clavister.ps1',
            'scripts/connectors/cert2clavister.ps1',
            'scripts/modules/SimpleAcme.Clavister/ClavisterSsh.psm1',
            'scripts/modules/SimpleAcme.Clavister/SimpleAcme.Clavister.psd1',
            'setup/Clavister-Runner.psm1'
        )) {
            if (-not $release.Contains($text)) { throw "Release file list missing: $text" }
        }
    }
}
