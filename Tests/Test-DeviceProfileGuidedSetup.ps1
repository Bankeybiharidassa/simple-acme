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
            'function Invoke-GuidedDeviceProfileForm',
            'function Invoke-DeviceProfileTcpTest',
            'Read-DeviceProfileConsoleLine',
            'Export-ModuleMember -Function',
            'Invoke-DeviceProfileWizard'
        )) {
            if ($runner -notlike "*$text*") { throw "Missing guided profile runner wiring: $text" }
        }

        $menu = Get-Content -LiteralPath $menuPath -Raw
        if ($menu -notlike '*Create or edit any device profile*' -or $menu -notlike "*Key='device-profile'*") {
            throw 'Deployment targets menu does not expose the generic device profile wizard.'
        }

        $setup = Get-Content -LiteralPath $setupPath -Raw
        foreach ($text in @(
            "Assert-SetupCommandAvailable -CommandName 'Invoke-DeviceProfileWizard'",
            "'device-profile'",
            'Invoke-DeviceProfileWizard -ProjectRoot $PSScriptRoot'
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
}
