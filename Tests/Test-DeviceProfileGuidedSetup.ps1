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
            'function Invoke-DeviceProfileManager',
            'function Invoke-DeviceProfileInventory',
            'function Invoke-DeviceProfileAdd',
            'function Invoke-DeviceProfileEdit',
            'function Invoke-DeviceProfileDelete',
            'function Invoke-GuidedDeviceProfileForm',
            'function Invoke-DeviceProfileTcpTest',
            'function New-DeviceProfileId',
            'Read-DeviceProfileConsoleLine',
            'Export-ModuleMember -Function',
            'Invoke-DeviceProfileWizard',
            'Invoke-DeviceProfileManager',
            'Invoke-DeviceProfileInventory'
        )) {
            if ($runner -notlike "*$text*") { throw "Missing guided profile runner wiring: $text" }
        }

        $menu = Get-Content -LiteralPath $menuPath -Raw
        if ($menu -notlike '*Create or edit any device profile*' -or $menu -notlike "*Key='device-profile'*" -or $menu -notlike '*Manage configured devices (view/add/change/delete)*' -or $menu -notlike "*Key='device-manager'*") {
            throw 'Deployment targets menu does not expose the generic device profile wizard.'
        }

        $setup = Get-Content -LiteralPath $setupPath -Raw
        foreach ($text in @(
            "Assert-SetupCommandAvailable -CommandName 'Invoke-DeviceProfileWizard'",
            "Assert-SetupCommandAvailable -CommandName 'Invoke-DeviceProfileManager'",
            "Assert-SetupCommandAvailable -CommandName 'Invoke-DeviceProfileInventory'",
            "'device-profile'",
            "'device-manager'",
            'Invoke-DeviceProfileWizard -ProjectRoot $PSScriptRoot',
            'Invoke-DeviceProfileManager -ProjectRoot $PSScriptRoot',
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
            'clavister',
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

    & $Assert 'Secret prompt defaults are displayed as hidden' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            '$displayDefault = if ($Secret) { ''<hidden>'' } else { $Default }',
            '$suffix = " [$displayDefault]"'
        )) {
            if (-not $runner.Contains($text)) { throw "Missing hidden secret prompt default behavior: $text" }
        }
        if ($runner -match '\$suffix\s*=\s*if \(\[string\]::IsNullOrWhiteSpace\(\$Default\)\) \{ '''' \} else \{ " \[\$Default\]" \}') {
            throw 'Secret prompt helper still renders raw default values.'
        }
    }

    & $Assert 'Kemp managed profile communication uses Kemp API not TCP only' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            'function Invoke-DeviceProfileCommunicationTest',
            "'kemp' { return Invoke-KempDeviceProfileApiTest",
            'Test-KempManagementUi -HostName $hostName -Port $port',
            'Kemp management UI is reachable',
            'Management UI: {0} ({1})',
            'Connect-KempLoadMaster -HostName $hostName -Port $port',
            'Get-KempVirtualServices -HostName $hostName -Port $port',
            'Kemp API connected and returned'
        )) {
            if (-not $runner.Contains($text)) { throw "Missing Kemp API communication test wiring: $text" }
        }
    }

    & $Assert 'Clavister managed profile communication uses SSH helper not TCP only' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            'function Invoke-ClavisterDeviceProfileSshTest',
            "'clavister' { return Invoke-ClavisterDeviceProfileSshTest",
            'Test-ClavisterSshConnection -HostName $hostName -Port $port',
            'Clavister module was not found'
        )) {
            if (-not $runner.Contains($text)) { throw "Missing Clavister SSH communication test wiring: $text" }
        }
    }

    & $Assert 'OPNsense managed profile communication uses OPNsense API not TCP only' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            'function Invoke-OPNsenseDeviceProfileApiTest',
            "'opnsense' { return Invoke-OPNsenseDeviceProfileApiTest",
            'Test-OPNsenseApiConnection -HostName $hostName -Port $port',
            'Get-OPNsenseCertificateServiceInventory -HostName $hostName -Port $port'
        )) {
            if (-not $runner.Contains($text)) { throw "Missing OPNsense API communication test wiring: $text" }
        }
    }

    & $Assert 'Device manager exposes view add change and delete actions' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        foreach ($text in @(
            "function Invoke-DeviceProfileManager",
            "View configured devices",
            "Add new device",
            "Change existing device",
            "Delete existing device",
            "function Invoke-DeviceProfileDelete",
            "Delete this configured device profile?",
            "Remove-DeviceConfig -ConfigDir `$configDir -DeviceId `$deviceId"
        )) {
            if ($runner -notlike "*$text*") { throw "Missing device manager behavior: $text" }
        }
    }

    & $Assert 'Device inventory wraps profile list before Count access' {
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        if (-not $runner.Contains('$devices = @(Get-DeviceProfileList -ConfigDir $configDir)')) {
            throw 'Device inventory must wrap Get-DeviceProfileList output before using .Count.'
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

            Remove-DeviceConfig -ConfigDir $tempRoot -DeviceId 'kemp-lab-a'
            $afterDelete = @(Get-AllDeviceConfigs -ConfigDir $tempRoot -SkipIntegrityFailures | Where-Object { $_['connector_type'] -eq 'kemp' })
            if ($afterDelete.Count -ne 2) { throw "Expected 2 Kemp profiles after deleting one, found $($afterDelete.Count)." }
            if (@($afterDelete | Where-Object { [string]($_['device_id']) -eq 'kemp-lab-a' }).Count -ne 0) { throw 'Deleted device profile is still present.' }
        } finally {
            if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
        }
    }
}
