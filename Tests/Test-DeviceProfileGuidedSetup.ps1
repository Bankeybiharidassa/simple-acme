function Invoke-TestDeviceProfileGuidedSetup {
    param([scriptblock]$Assert)

    $root = Split-Path $PSScriptRoot -Parent
    $runnerPath = Join-Path $root 'setup\Device-Profile-Runner.psm1'
    $schemaPath = Join-Path $root 'setup\Device-Schemas.ps1'
    $menuPath = Join-Path $root 'setup\Menu-Tree.ps1'
    $setupPath = Join-Path $root 'certificate-setup.ps1'

    & $Assert 'Generic device profile wizard is exported and wired into setup' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            'function Invoke-DeviceProfileWizard',
            'function Invoke-DeviceProfileInventory',
            'function Invoke-GuidedDeviceProfileForm',
            'function Invoke-DeviceProfileTcpTest',
            'function New-DeviceProfileId',
            'Read-DeviceProfileConsoleLine',
            'Export-ModuleMember -Function',
            'Invoke-DeviceProfileWizard',
            'Invoke-DeviceProfileInventory'
        )) {
            if ($runner -notlike "*$text*") { throw "Missing guided profile runner wiring: $text" }
        }

        $menu = Get-Content -LiteralPath $menuPath -Raw
        if ($menu -notlike '*Create or edit any device profile*' -or $menu -notlike "*Key='device-profile'*" -or $menu -notlike '*View configured devices*' -or $menu -notlike "*Key='device-inventory'*") {
            throw 'Deployment targets menu does not expose the generic device profile wizard.'
        }

        $setup = Get-Content -LiteralPath $setupPath -Raw
        foreach ($text in @(
            "Assert-SetupCommandAvailable -CommandName 'Invoke-DeviceProfileWizard'",
            "Assert-SetupCommandAvailable -CommandName 'Invoke-DeviceProfileInventory'",
            "'device-profile'",
            "'device-inventory'",
            'Invoke-DeviceProfileWizard -ProjectRoot $PSScriptRoot',
            'Invoke-DeviceProfileInventory -ProjectRoot $PSScriptRoot'
        )) {
            if ($setup -notlike "*$text*") { throw "certificate-setup.ps1 missing device-profile dispatch: $text" }
        }
    }

    & $Assert 'Guided device schemas cover common SSH/API/server/firewall families' {
        . $schemaPath
        foreach ($key in @(
            'nginx',
            'apache',
            'opnsense',
            'pfsense',
            'cisco_asa',
            'cisco_iosxe',
            'fortigate',
            'juniper_srx',
            'haproxy',
            'traefik',
            'generic_ssh',
            'generic_api'
        )) {
            if (-not $DeviceSchemas.ContainsKey($key)) { throw "Missing guided device schema: $key" }
            if (-not $DeviceSchemas[$key].ContainsKey('SetupMode') -or [string]$DeviceSchemas[$key].SetupMode -ne 'guided') {
                throw "Device schema is not guided: $key"
            }
            if (-not $DeviceSchemas[$key].ContainsKey('ConnectionMethods') -or @($DeviceSchemas[$key].ConnectionMethods).Count -lt 1) {
                throw "Device schema has no connection methods: $key"
            }
        }
    }

    & $Assert 'Guided device setup uses Esc-aware prompts and pauses after communication tests' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            '[Console]::ReadKey($true)',
            '[ConsoleKey]::Escape',
            'Press Esc at any question to cancel.',
            'Wait-DeviceProfileOperatorKey',
            'Communication test summary',
            'Protocol authentication was not attempted by the generic profile test'
        )) {
            if (-not $runner.Contains($text)) { throw "Missing guided interaction behavior: $text" }
        }
    }

    & $Assert 'Device profile persistence supports multiple devices with friendly names' {
        Import-Module $runnerPath -Force
        $tempRoot = Join-Path $env:TEMP ("simple-acme-device-profiles-{0}" -f ([guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            Save-DeviceProfile -ConfigDir $tempRoot -ConnectorType 'kemp' -Label 'Kemp LoadMaster' -FriendlyName 'Kemp lab A' -DeviceId 'kemp-lab-a' -Values @{ host='192.0.2.10'; port='443' }
            Save-DeviceProfile -ConfigDir $tempRoot -ConnectorType 'kemp' -Label 'Kemp LoadMaster' -FriendlyName 'Kemp lab B' -DeviceId 'kemp-lab-b' -Values @{ host='192.0.2.11'; port='443' }

            $devices = @(Get-AllDeviceConfigs -ConfigDir $tempRoot -SkipIntegrityFailures | Where-Object { $_['connector_type'] -eq 'kemp' })
            if ($devices.Count -ne 2) { throw "Expected 2 Kemp profiles, found $($devices.Count)." }
            $labels = @($devices | ForEach-Object { [string]($_['label']) } | Sort-Object)
            if (($labels -join '|') -ne 'Kemp lab A|Kemp lab B') { throw "Friendly names were not preserved: $($labels -join ', ')" }

            $currentA = Get-DeviceProfileCurrentValues -ConfigDir $tempRoot -ConnectorType 'kemp' -DeviceId 'kemp-lab-a'
            $currentB = Get-DeviceProfileCurrentValues -ConfigDir $tempRoot -ConnectorType 'kemp' -DeviceId 'kemp-lab-b'
            if ([string]$currentA['host'] -ne '192.0.2.10') { throw 'Device A current values were not loaded by device id.' }
            if ([string]$currentB['host'] -ne '192.0.2.11') { throw 'Device B current values were not loaded by device id.' }

            Save-DeviceProfile -ConfigDir $tempRoot -ConnectorType 'kemp' -Label 'Kemp LoadMaster' -FriendlyName 'Kemp generated' -Values @{ host='192.0.2.12'; port='443' }
            $nextId = New-DeviceProfileId -ConfigDir $tempRoot -ConnectorType 'kemp' -FriendlyName 'Kemp generated'
            if ($nextId -ne 'kemp-kemp-generated-2') { throw "Expected unique friendly-name id suffix, got '$nextId'." }
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }
}
