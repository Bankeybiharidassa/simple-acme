function Invoke-TestGlobalDeviceSpecificRenewalHooks {
    param([scriptblock]$Assert)

    $root = Split-Path $PSScriptRoot -Parent

    & $Assert 'Device profile saves return the selected profile identity' {
        $runner = Get-Content -LiteralPath (Join-Path $root 'setup\Device-Profile-Runner.psm1') -Raw
        foreach ($text in @(
            'DeviceId = $deviceId',
            'ConnectorType = $ConnectorType',
            'ConvertTo-DeviceProfileSingleQuotedArgument'
        )) {
            if (-not $runner.Contains($text)) { throw "Missing global device profile identity behavior: $text" }
        }
    }

    & $Assert 'External appliance first-run hooks include ConfigDir and DeviceId' {
        $files = @(
            Join-Path $root 'setup\Kemp-Runner.psm1'
            Join-Path $root 'setup\Clavister-Runner.psm1'
            Join-Path $root 'setup\Sophos-Runner.psm1'
            Join-Path $root 'setup\Device-Profile-Runner.psm1'
        )
        foreach ($file in $files) {
            $raw = Get-Content -LiteralPath $file -Raw
            if (-not $raw.Contains('-ConfigDir')) { throw "Missing -ConfigDir renewal hook parameter in $file" }
            if (-not $raw.Contains('-DeviceId')) { throw "Missing -DeviceId renewal hook parameter in $file" }
            if (-not $raw.Contains('ACME_TARGET_DEVICE_ID')) { throw "Missing ACME_TARGET_DEVICE_ID persistence in $file" }
        }
    }

    & $Assert 'Connector hooks accept explicit DeviceId for scheduled renewals' {
        $files = @(
            Join-Path $root 'Scripts\connectors\cert2kemp.ps1'
            Join-Path $root 'Scripts\connectors\cert2clavister.ps1'
            Join-Path $root 'Scripts\connectors\cert2paloalto.ps1'
            Join-Path $root 'Scripts\deploy-sophos.ps1'
        )
        foreach ($file in $files) {
            $raw = Get-Content -LiteralPath $file -Raw
            if (-not $raw.Contains('[string]$DeviceId')) { throw "Hook does not accept -DeviceId: $file" }
            if (-not $raw.Contains('Get-DeviceConfig -DeviceId $DeviceId')) { throw "Hook does not load the explicit device profile: $file" }
        }
    }
}
