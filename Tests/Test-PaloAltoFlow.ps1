function Invoke-TestPaloAltoFlow {
    param([scriptblock]$Assert)

    $root = Split-Path $PSScriptRoot -Parent
    $schemaPath = Join-Path $root 'setup\Device-Schemas.ps1'
    $runnerPath = Join-Path $root 'setup\Device-Profile-Runner.psm1'
    $deployPath = Join-Path $root 'Scripts\deploy-paloalto.ps1'
    $docsPath = Join-Path $root 'docs\paloalto-lab-communication.md'

    & $Assert 'Palo Alto schema is guided and captures API deployment settings' {
        . $schemaPath
        if (-not $DeviceSchemas.ContainsKey('paloalto')) { throw 'Missing Palo Alto schema.' }
        $schema = $DeviceSchemas['paloalto']
        if (-not $schema.ContainsKey('SetupMode') -or [string]$schema.SetupMode -ne 'guided') { throw 'Palo Alto schema is not guided.' }
        $fieldNames = @($schema.Fields | ForEach-Object { [string]$_['Name'] })
        foreach ($required in @('host','port','api_key','username','password','skip_certificate_check','vsys','certificate_name','binding_type','binding_target','rest_location','bind_target_names')) {
            if ($fieldNames -notcontains $required) { throw "Palo Alto schema missing field: $required" }
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
            'New-PaloAltoApiUriBuilder',
            'Invoke-PaloAltoApiWithCertificatePolicy',
            'Invoke-PaloAltoRestMethod',
            "Parameters.ContainsKey('SkipCertificateCheck')",
            "if (`$_.Exception.Message -match 'No such node') { return `$null }",
            'Get-ExistingCertificateFingerprint -Firewall $Firewall -Port $Port'
        )) {
            if (-not $deploy.Contains($text)) { throw "Missing Palo Alto deploy transport behavior: $text" }
        }
    }
}
