function Invoke-TestPaloAltoFlow {
    param([scriptblock]$Assert)

    $root = Split-Path $PSScriptRoot -Parent
    $schemaPath = Join-Path $root 'setup\Device-Schemas.ps1'
    $runnerPath = Join-Path $root 'setup\Device-Profile-Runner.psm1'
    $deployPath = Join-Path $root 'Scripts\deploy-paloalto.ps1'
    $hookPath = Join-Path $root 'Scripts\cert2paloalto.ps1'
    $connectorHookPath = Join-Path $root 'Scripts\connectors\cert2paloalto.ps1'
    $docsPath = Join-Path $root 'docs\paloalto-lab-communication.md'
    $tuiPath = Join-Path $root 'core\Tui-Engine.psm1'
    $menuPath = Join-Path $root 'setup\Menu-Tree.ps1'
    $setupPath = Join-Path $root 'certificate-setup.ps1'

    & $Assert 'Palo Alto schema is guided and captures API deployment settings' {
        . $schemaPath
        if (-not $DeviceSchemas.ContainsKey('paloalto')) { throw 'Missing Palo Alto schema.' }
        $schema = $DeviceSchemas['paloalto']
        if (-not $schema.ContainsKey('SetupMode') -or [string]$schema.SetupMode -ne 'guided') { throw 'Palo Alto schema is not guided.' }
        $fieldNames = @($schema.Fields | ForEach-Object { [string]$_['Name'] })
        foreach ($required in @('host','port','api_key','username','password','skip_certificate_check','vsys','certificate_name','cert_path','key_path','chain_path','key_passphrase','binding_type','binding_target','rest_location','bind_target_names')) {
            if ($fieldNames -notcontains $required) { throw "Palo Alto schema missing field: $required" }
        }
        $bindingTargetField = @($schema.Fields | Where-Object { $_.Name -eq 'binding_target' })[0]
        if ([string]$bindingTargetField.Placeholder -ne '') { throw 'Palo Alto management binding target must not display a fake portal/gateway placeholder.' }
        $selectedTargetsField = @($schema.Fields | Where-Object { $_.Name -eq 'bind_target_names' })[0]
        if ([string]$selectedTargetsField.Placeholder -ne '') { throw 'Palo Alto selected targets summary must not display a fake placeholder value.' }
    }

    & $Assert 'Palo Alto profile action is exposed and uses the managed-device editor' {
        $menu = Get-Content -LiteralPath $menuPath -Raw
        $setup = Get-Content -LiteralPath $setupPath -Raw
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            'paloalto-profile',
            "Assert-SetupCommandAvailable -CommandName 'Invoke-PaloAltoProfileForm'",
            'Invoke-PaloAltoProfileForm -ProjectRoot $PSScriptRoot',
            'function Invoke-PaloAltoProfileForm',
            "Invoke-DeviceProfileConnectorWizard -ProjectRoot `$ProjectRoot -ConnectorType 'paloalto'"
        )) {
            if (-not ($menu.Contains($text) -or $setup.Contains($text) -or $runner.Contains($text))) {
                throw "Missing Palo Alto profile action wiring: $text"
            }
        }
    }

    & $Assert 'Palo Alto managed profile communication uses XML API and REST inventory' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            'function Invoke-PaloAltoDeviceProfileApiTest',
            "'paloalto' { return Invoke-PaloAltoDeviceProfileApiTest",
            'type=keygen',
            '<show><system><info></info></system></show>',
            'deviceconfig/setting/management/api/key/certificate',
            'ApiKeyCertificate',
            '/restapi/v12.1/Objects/Addresses',
            'location=vsys',
            'Palo Alto XML API connected'
        )) {
            if (-not $runner.Contains($text)) { throw "Missing Palo Alto communication behavior: $text" }
        }
    }

    & $Assert 'Palo Alto lab communication notes document XML and REST findings' {
        if (-not (Test-Path -LiteralPath $docsPath -PathType Leaf)) { throw "Missing Palo Alto lab notes: $docsPath" }
        $docs = Get-Content -LiteralPath $docsPath -Raw
        foreach ($text in @(
            'PAN-OS: `12.1.7`',
            'XML API key generation succeeds',
            'deprecated algorithm',
            'api key certificate',
            'deviceconfig/setting/management/api/key/certificate',
            'REST object and policy inventory requires location parameters',
            '/restapi/v12.1/Objects/Addresses?location=vsys&vsys=vsys1',
            'REST `System/Info` probes returned HTTP 501'
        )) {
            if (-not $docs.Contains($text)) { throw "Missing Palo Alto lab note: $text" }
        }
    }

    & $Assert 'Palo Alto deploy transport supports lab TLS and first import missing cert node' {
        $deploy = Get-Content -LiteralPath $deployPath -Raw
        foreach ($text in @(
            '[int]$Port = 443',
            '[switch]$SkipCertificateCheck',
            '[Environment]::OSVersion.Platform',
            'New-PaloAltoApiUriBuilder',
            'Invoke-PaloAltoApiWithCertificatePolicy',
            'Invoke-PaloAltoRestMethod',
            "Parameters.ContainsKey('SkipCertificateCheck')",
            'SimpleAcmePaloAltoCertificatePolicy',
            'TrustAnyCertificate',
            'RemoteCertificateValidationCallback',
            'Unable to load SimpleAcmePaloAltoCertificatePolicy',
            '[ValidateLength(0, 31)]',
            '$KeyPassphrase',
            'passphrase = $KeyPassphrase',
            "if (`$_.Exception.Message -match 'No such node') { return `$null }",
            'Get-ExistingCertificateFingerprint -Firewall $Firewall -Port $Port'
        )) {
            if (-not $deploy.Contains($text)) { throw "Missing Palo Alto deploy transport behavior: $text" }
        }
        foreach ($text in @(
            '<certificate>$(Get-XmlEscaped -Text $CertName)</certificate>',
            "[string]`$BindingTarget = ''",
            "throw 'waf BindingTarget is required.'",
            '$bindingSetXPath = $bindingXPath -replace ''/ssl-tls-service-profile$'', ''''',
            'decision = ''skip-upload''',
            'Upload-Certificate -Firewall $Firewall -Port $Port -ApiKey $resolvedApiKey',
            '$profileCert = [string]$profileResp.response.result.entry.certificate',
            '$certNode.PSObject.Properties[$propertyName]'
        )) {
            if (-not $deploy.Contains($text)) { throw "Missing Palo Alto binding/idempotency behavior: $text" }
        }
        if ($deploy.Contains('<certificate><member>$(Get-XmlEscaped -Text $CertName)</member></certificate>')) {
            throw 'Palo Alto SSL/TLS profile must write scalar certificate XML, not member XML.'
        }
        if ($deploy.Contains('decision = ''no-op''; reason = ''fingerprint-match''')) {
            throw 'Palo Alto deploy must not exit before binding when certificate fingerprint already matches.'
        }
        if ($deploy.Contains("if (`$certNode.'fingerprint')")) {
            throw 'Palo Alto deploy must not use strict-mode fragile direct fingerprint property access.'
        }
        if ($deploy -match 'ServerCertificateValidationCallback\s*=\s*\{') {
            throw 'Palo Alto deploy transport must use a compiled certificate callback, not a PowerShell scriptblock.'
        }
        if ($deploy -match '\$IsWindows') {
            throw 'Palo Alto deploy transport must not use PowerShell 6+ $IsWindows in Windows PowerShell 5.'
        }

        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            'SimpleAcmePaloAltoCertificatePolicy',
            'TrustAnyCertificate',
            'RemoteCertificateValidationCallback',
            'Unable to load SimpleAcmePaloAltoCertificatePolicy'
        )) {
            if (-not $runner.Contains($text)) { throw "Missing Palo Alto profile TLS callback behavior: $text" }
        }
        if ($runner -match 'ServerCertificateValidationCallback\s*=\s*\{\s*param') {
            throw 'Palo Alto profile test must use a compiled certificate callback, not a PowerShell scriptblock.'
        }
    }

    & $Assert 'Palo Alto first-run hook uses saved profile and PFX-to-PEM conversion' {
        foreach ($path in @($hookPath,$connectorHookPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing Palo Alto hook: $path" }
        }
        $registry = Get-Content -LiteralPath (Join-Path $root 'setup\Connector-Registry.ps1') -Raw
        foreach ($text in @(
            "-ConnectorId 'paloalto'",
            "-ScriptFileName 'cert2paloalto.ps1'",
            'FirstRunAcmeSupported $true',
            "-PfxPath '{CacheFile}' -CachePassword '{CachePassword}' -CertCommonName '{CertCommonName}'"
        )) {
            if (-not $registry.Contains($text)) { throw "Missing Palo Alto registry wiring: $text" }
        }
        $hook = Get-Content -LiteralPath $connectorHookPath -Raw
        foreach ($text in @(
            'Get-PaloAltoHookProfileSettings',
            'connector_type'') -or [string]$_[''connector_type''] -ne ''paloalto''',
            'hasHost -and ($hasApiKey -or $hasLogin)',
            'New-PaloAltoApiKeyFromCredentials',
            'Invoke-PaloAltoHookWebRequest',
            'Convert-ClavisterPfxToPemFiles',
            'deploy-paloalto.ps1',
            'SkipCertificateCheck',
            'Username',
            'Password',
            'BindingType',
            'BindingTarget'
        )) {
            if (-not $hook.Contains($text)) { throw "Missing Palo Alto hook behavior: $text" }
        }
    }

    & $Assert 'TUI form edits and help text stay inside the form box' {
        $tui = Get-Content -LiteralPath $tuiPath -Raw
        foreach ($text in @(
            '$replaceOnFirstPrintableKey = -not [string]::IsNullOrEmpty($buffer)',
            '$innerWidth = [Math]::Max(1, $layout.Width - 4)',
            'Get-TuiClippedText -Text $helpText -Width $innerWidth',
            'Write-TuiAt -X ($layout.X + 2) -Y $layout.HelpRow'
        )) {
            if (-not $tui.Contains($text)) { throw "Missing TUI form behavior: $text" }
        }
        if ($tui.Contains('Show-TuiStatus -Message $helpText -Type Info -Row $layout.HelpRow')) {
            throw 'TUI help text must be rendered inside the form box, not across the full console width.'
        }
    }
}
