function Invoke-TestOPNsenseFlow {
    param([scriptblock]$Assert)

    $root = Split-Path $PSScriptRoot -Parent
    $schemaPath = Join-Path $root 'setup\Device-Schemas.ps1'
    $runnerPath = Join-Path $root 'setup\Device-Profile-Runner.psm1'
    $modulePath = Join-Path $root 'Scripts\Modules\SimpleAcme.OPNsense\OPNsenseApi.psm1'
    $manifestPath = Join-Path $root 'Scripts\Modules\SimpleAcme.OPNsense\SimpleAcme.OPNsense.psd1'
    $releaseListPath = Join-Path $root 'build\release-file-list.txt'

    & $Assert 'OPNsense schema is guided API key and secret, not generic token' {
        . $schemaPath
        if (-not $DeviceSchemas.ContainsKey('opnsense')) { throw 'Missing OPNsense schema.' }
        $schema = $DeviceSchemas['opnsense']
        if (-not $schema.ContainsKey('SetupMode') -or [string]$schema.SetupMode -ne 'guided') { throw 'OPNsense schema is not guided.' }
        $methodKeys = @($schema.ConnectionMethods | ForEach-Object { [string]$_['Key'] })
        if ($methodKeys -notcontains 'api_key_secret') { throw 'OPNsense schema must use API key/secret method.' }
        $fieldNames = @($schema.Fields | ForEach-Object { [string]$_['Name'] })
        foreach ($required in @('host','port','api_key','api_secret','skip_certificate_check','certificate_name','bind_target_ids','bind_target_names')) {
            if ($fieldNames -notcontains $required) { throw "OPNsense schema missing field: $required" }
        }
        if ($fieldNames -contains 'api_token') { throw 'OPNsense schema still uses generic api_token.' }
    }

    & $Assert 'OPNsense managed profile communication uses firmware API and service inventory' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            'function Invoke-OPNsenseDeviceProfileApiTest',
            "'opnsense' { return Invoke-OPNsenseDeviceProfileApiTest",
            'Test-OPNsenseApiConnection -HostName $hostName -Port $port',
            'Get-OPNsenseCertificateServiceInventory -HostName $hostName -Port $port',
            'OPNsense API connected. Inventory returned'
        )) {
            if (-not $runner.Contains($text)) { throw "Missing OPNsense device profile API behavior: $text" }
        }
    }

    & $Assert 'OPNsense module documents certificate import and binding inventory surfaces' {
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) { throw "Missing OPNsense module: $modulePath" }
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Missing OPNsense manifest: $manifestPath" }
        $module = Get-Content -LiteralPath $modulePath -Raw
        foreach ($text in @(
            'Invoke-OPNsenseApi',
            '/api/core/firmware/status',
            '/api/trust/cert/search',
            'New-OPNsenseCertificateImportPayload',
            'crt_payload',
            'prv_payload',
            'Get-OPNsenseCertificateServiceInventory',
            'HAProxy frontends',
            'Nginx locations/upstreams',
            'OpenVPN servers',
            'IPsec certificate services',
            'manual-api-discovery-required'
        )) {
            if (-not $module.Contains($text)) { throw "Missing OPNsense API behavior: $text" }
        }
    }

    & $Assert 'OPNsense files are included in release inventory' {
        $releaseList = Get-Content -LiteralPath $releaseListPath -Raw
        foreach ($text in @(
            'scripts/modules/SimpleAcme.OPNsense/OPNsenseApi.psm1',
            'scripts/modules/SimpleAcme.OPNsense/SimpleAcme.OPNsense.psd1'
        )) {
            if (-not $releaseList.Contains($text)) { throw "Release file list missing OPNsense file: $text" }
        }
    }
}
