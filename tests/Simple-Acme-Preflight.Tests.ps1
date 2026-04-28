Import-Module "$PSScriptRoot/../core/Simple-Acme-Reconciler.psm1" -Force

Describe 'Simple ACME reconcile preflight' {
    It 'passes when wacs exists in package root and env values are valid' {
        $scriptFile = Join-Path $TestDrive 'hook.ps1'
        'Write-Host ok' | Set-Content -Path $scriptFile -Encoding UTF8
        $rootWacs = Join-Path $moduleRoot 'wacs.exe'
        $rootWacsBackup = Join-Path $TestDrive 'wacs.backup.exe'
        $hadOriginalWacs = Test-Path -LiteralPath $rootWacs
        if ($hadOriginalWacs) {
            Copy-Item -LiteralPath $rootWacs -Destination $rootWacsBackup -Force
        }
        'stub' | Set-Content -Path $rootWacs -Encoding UTF8

        try {
            $result = Assert-ReconcilePreflight -EnvValues @{
                ACME_DIRECTORY = 'https://acme.example.com/directory'
                ACME_KID = 'kid'
                ACME_HMAC_SECRET = 'secret'
                DOMAINS = 'example.com,www.example.com'
                ACME_SOURCE_PLUGIN = 'manual'
                ACME_ORDER_PLUGIN = 'single'
                ACME_STORE_PLUGIN = 'certificatestore'
                ACME_VALIDATION_MODE = 'none'
                ACME_INSTALLATION_PLUGINS = 'script'
                ACME_SCRIPT_PATH = $scriptFile
                ACME_SCRIPT_PARAMETERS = "'default' {RenewalId} {CertThumbprint} {OldCertThumbprint}"
                ACME_WACS_VERSION = '2.3.0'
            }

            $result.WacsPath | Should -Be (Convert-Path -LiteralPath $rootWacs)
            $result.DomainCount | Should -Be 2
            $result.ScriptPath | Should -Be $scriptFile
        } finally {
            Remove-Item -LiteralPath $rootWacs -Force -ErrorAction SilentlyContinue
            if ($hadOriginalWacs) {
                Move-Item -LiteralPath $rootWacsBackup -Destination $rootWacs -Force
            }
        }
    }

    It 'fails when wacs is missing' {
        $scriptFile = Join-Path $TestDrive 'hook.ps1'
        'Write-Host ok' | Set-Content -Path $scriptFile -Encoding UTF8
        Mock Test-Path { $false } -ParameterFilter { $PathType -eq 'Leaf' }
        Mock Get-Command { $null } -ParameterFilter { $Name -in @('wacs','wacs.exe') }

        {
            Assert-ReconcilePreflight -EnvValues @{
                ACME_DIRECTORY = 'https://acme.example.com/directory'
                ACME_KID = 'kid'
                ACME_HMAC_SECRET = 'secret'
                DOMAINS = 'example.com'
                ACME_SOURCE_PLUGIN = 'manual'
                ACME_ORDER_PLUGIN = 'single'
                ACME_STORE_PLUGIN = 'certificatestore'
                ACME_VALIDATION_MODE = 'none'
                ACME_INSTALLATION_PLUGINS = 'script'
                ACME_SCRIPT_PATH = $scriptFile
                ACME_SCRIPT_PARAMETERS = "'default' {RenewalId} {CertThumbprint} {OldCertThumbprint}"
                ACME_WACS_VERSION = '2.3.0'
            }
        } | Should -Throw '*simple-acme executable not found*'
    }

    It 'fails when script path is not absolute' {
        $rootWacs = Join-Path $moduleRoot 'wacs.exe'
        $rootWacsBackup = Join-Path $TestDrive 'wacs.backup.exe'
        $hadOriginalWacs = Test-Path -LiteralPath $rootWacs
        if ($hadOriginalWacs) {
            Copy-Item -LiteralPath $rootWacs -Destination $rootWacsBackup -Force
        }
        'stub' | Set-Content -Path $rootWacs -Encoding UTF8
        try {
        {
            Assert-ReconcilePreflight -EnvValues @{
                ACME_DIRECTORY = 'https://acme.example.com/directory'
                ACME_KID = 'kid'
                ACME_HMAC_SECRET = 'secret'
                DOMAINS = 'example.com'
                ACME_SOURCE_PLUGIN = 'manual'
                ACME_ORDER_PLUGIN = 'single'
                ACME_STORE_PLUGIN = 'certificatestore'
                ACME_VALIDATION_MODE = 'none'
                ACME_INSTALLATION_PLUGINS = 'script'
                ACME_SCRIPT_PATH = '.\relative.ps1'
                ACME_SCRIPT_PARAMETERS = "'default' {RenewalId} {CertThumbprint} {OldCertThumbprint}"
                ACME_WACS_VERSION = '2.3.0'
            }
            } | Should -Throw '*Script installation path does not exist*'
        } finally {
            Remove-Item -LiteralPath $rootWacs -Force -ErrorAction SilentlyContinue
            if ($hadOriginalWacs) {
                Move-Item -LiteralPath $rootWacsBackup -Destination $rootWacs -Force
            }
        }
    }
}


Describe 'WACS version detection policy' {
    It 'returns configured ACME_WACS_VERSION without launching processes' {
        Mock Resolve-WacsExecutable { throw 'should not resolve path' }
        Mock Invoke-NativeProcess { throw 'should not execute process' }

        $detected = Get-WacsVersion -EnvValues @{ ACME_WACS_VERSION = 'Software version 2.3.0.0 (release)' }
        $detected.ToString() | Should -Be '2.3.0.0'

        Should -Invoke Resolve-WacsExecutable -Times 0 -Exactly
        Should -Invoke Invoke-NativeProcess -Times 0 -Exactly
    }

    It 'extracts version from file metadata when present' {
        $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if ([string]::IsNullOrWhiteSpace([string]$pwshPath)) {
            $pwshPath = (Get-Command powershell -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        }
        if ([string]::IsNullOrWhiteSpace([string]$pwshPath)) {
            throw 'No PowerShell executable found to query file version metadata.'
        }

        $version = Get-WacsFileVersion -WacsPath $pwshPath
        $version | Should -Not -BeNullOrEmpty
    }

    It 'treats wacs --version timeout as warning and returns null by default' {
        Mock Resolve-WacsExecutable { 'C:\certificaat\wacs.exe' }
        Mock Get-WacsFileVersion { $null }
        Mock Invoke-NativeProcess {
            [pscustomobject]@{
                Succeeded = $false
                TimedOut = $true
                ExitCode = 0
                OutputLines = @()
            }
        }

        $warning = $null
        $result = Get-WacsVersion -EnvValues @{ ACME_REQUIRE_WACS_VERSION_CHECK = '0' } -WarningVariable warning

        $result | Should -BeNullOrEmpty
        @($warning) -join "`n" | Should -Match 'timed out'
    }

    It 'throws when wacs --version timeout occurs and check is required' {
        Mock Resolve-WacsExecutable { 'C:\certificaat\wacs.exe' }
        Mock Get-WacsFileVersion { $null }
        Mock Invoke-NativeProcess {
            [pscustomobject]@{
                Succeeded = $false
                TimedOut = $true
                ExitCode = 0
                OutputLines = @()
            }
        }

        {
            Get-WacsVersion -EnvValues @{ ACME_REQUIRE_WACS_VERSION_CHECK = '1' }
        } | Should -Throw '*wacs --version timed out.*'
    }

    It 'allows preflight to pass with unknown version when hard check is disabled' {
        $scriptFile = Join-Path $TestDrive 'hook.ps1'
        'Write-Host ok' | Set-Content -Path $scriptFile -Encoding UTF8
        $moduleRoot = Split-Path $PSScriptRoot -Parent
        $rootWacs = Join-Path $moduleRoot 'wacs.exe'
        $rootWacsBackup = Join-Path $TestDrive 'wacs.unknown.backup.exe'
        $hadOriginalWacs = Test-Path -LiteralPath $rootWacs
        if ($hadOriginalWacs) {
            Copy-Item -LiteralPath $rootWacs -Destination $rootWacsBackup -Force
        }
        'stub' | Set-Content -Path $rootWacs -Encoding UTF8

        Mock Get-WacsVersion { $null }

        try {
            $result = Assert-ReconcilePreflight -EnvValues @{
                ACME_DIRECTORY = 'https://test-acme.networking4all.com/dv'
                DOMAINS = 'example.com'
                ACME_SCRIPT_PATH = $scriptFile
            } -WarningAction SilentlyContinue

            $result.WacsVersion | Should -Be '(unknown)'
        } finally {
            Remove-Item -LiteralPath $rootWacs -Force -ErrorAction SilentlyContinue
            if ($hadOriginalWacs) {
                Move-Item -LiteralPath $rootWacsBackup -Destination $rootWacs -Force
            }
        }
    }

    It 'keeps issuance bound to configured ACME_DIRECTORY baseuri' {
        $captured = @()
        Mock Invoke-WacsWithRetry {
            param([string[]]$Args,[hashtable]$EnvValues)
            $script:captured = @($Args)
        }

        Invoke-WacsIssue -EnvValues @{
            ACME_DIRECTORY = 'https://test-acme.networking4all.com/dv'
            DOMAINS = 'example.com'
            ACME_SCRIPT_PATH = 'C:\certificaat\Scripts\cert2rds.ps1'
        }

        $baseUriIndex = [array]::IndexOf($captured, '--baseuri')
        $baseUriIndex | Should -BeGreaterThan -1
        $captured[$baseUriIndex + 1] | Should -Be 'https://test-acme.networking4all.com/dv'
    }

    It 'does not require version parsing for issuance output analysis' {
        $analysis = Get-WacsOutputAnalysis -OutputLines @(
            ' Running in mode: unattended',
            ' Renewal created successfully.'
        ) -RequireNonInteractiveMode

        $analysis.Version | Should -BeNullOrEmpty
        $analysis.EnteredInteractiveMenu | Should -BeFalse
    }
}
