Import-Module "$PSScriptRoot/../core/Simple-Acme-Reconciler.psm1" -Force

function Invoke-TestSimpleAcmeReconciler {
    param([scriptblock]$Assert)

    & $Assert 'normalizes domains' {
        $actual = Get-NormalizedDomains -Domains 'WWW.Example.com, example.com ,api.example.com'
        if (($actual -join ',') -ne 'api.example.com,example.com,www.example.com') {
            throw "Unexpected domains: $($actual -join ',')"
        }
    }

    & $Assert 'settings merge writes scheduled task values' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            $path = Join-Path $root 'settings.json'
            @{ Existing = @{ Keep = 'yes' } } | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
            Set-SimpleAcmeSettings -SimpleAcmeDir $root
            $jsonObject = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $json = ConvertTo-HashtableRecursive -InputObject $jsonObject
            if ($json.Existing.Keep -ne 'yes') { throw 'Existing key not preserved.' }
            if ($json.ScheduledTask.RenewalDays -ne 199) { throw 'RenewalDays not set.' }
            if ($json.ScheduledTask.RenewalMinimumValidDays -ne 16) { throw 'RenewalMinimumValidDays not set.' }
        } finally {
            Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    & $Assert 'compare detects mismatch when script path differs' {
        $summary = [pscustomobject]@{
            Hosts = @('example.com')
            BaseUri = 'https://acme.networking4all.com/dv'
            EabKid = 'kid-1'
            SourcePlugin = 'manual'
            OrderPlugin = 'single'
            StorePlugin = 'certificatestore'
            AccountName = ''
            HasValidationNone = $true
            HasScriptInstallation = $true
            InstallationPlugins = @('script')
            ScriptPaths = @('C:\wrong.ps1')
            StorePlugins = @('certificatestore')
        }
        $envValues = @{
            DOMAINS = 'example.com'
            ACME_DIRECTORY = 'https://acme.networking4all.com/dv'
            ACME_KID = 'kid-1'
            ACME_SCRIPT_PATH = 'C:\correct.ps1'
            ACME_SOURCE_PLUGIN = 'manual'
            ACME_ORDER_PLUGIN = 'single'
            ACME_STORE_PLUGIN = 'certificatestore'
            ACME_VALIDATION_MODE = 'none'
            ACME_INSTALLATION_PLUGINS = 'script'
            ACME_ACCOUNT_NAME = ''
        }

        $result = Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $envValues
        if ($result.Matches) { throw 'Expected mismatch.' }
        if (-not ($result.Mismatches -contains 'Script path')) { throw 'Expected Script path mismatch.' }
    }

    & $Assert 'exact domain set matching rejects partial overlap' {
        if (-not (Test-ExactDomainSetMatch -Requested @('a.example.com','b.example.com') -Actual @('b.example.com','a.example.com'))) {
            throw 'Expected exact set match.'
        }
        if (Test-ExactDomainSetMatch -Requested @('a.example.com') -Actual @('a.example.com','b.example.com')) {
            throw 'Expected partial overlap to fail exact matching.'
        }
    }

    & $Assert 'installation plugins are parsed and normalized' {
        $plugins = Get-InstallationPlugins -EnvValues @{ ACME_INSTALLATION_PLUGINS = 'script, iis,script' }
        if (($plugins -join ',') -ne 'iis,script') {
            throw "Unexpected plugins: $($plugins -join ',')"
        }
    }

    & $Assert 'config hash is deterministic for equivalent values' {
        $envA = @{
            DOMAINS = 'b.example.com, a.example.com'
            ACME_VALIDATION_MODE = 'none'
            ACME_CSR_ALGORITHM = 'ec'
            ACME_KEY_TYPE = 'ec'
            ACME_SCRIPT_PATH = 'C:\scripts\install.ps1'
            ACME_INSTALLATION_PLUGINS = 'script,iis'
            ACME_STORE_PLUGIN = 'certificatestore'
        }
        $envB = @{
            DOMAINS = 'a.example.com,b.example.com'
            ACME_VALIDATION_MODE = 'none'
            ACME_CSR_ALGORITHM = 'ec'
            ACME_KEY_TYPE = 'ec'
            ACME_SCRIPT_PATH = 'C:\scripts\install.ps1'
            ACME_INSTALLATION_PLUGINS = 'iis,script'
            ACME_STORE_PLUGIN = 'certificatestore'
        }

        $hashA = New-ReconcileConfigHash -EnvValues $envA
        $hashB = New-ReconcileConfigHash -EnvValues $envB
        if ($hashA -ne $hashB) {
            throw "Expected deterministic hash but got '$hashA' and '$hashB'."
        }
    }

    & $Assert 'wacs resolver prefers ACME_WACS_PATH and supports package-local exe names' {
        $root = Split-Path $PSScriptRoot -Parent
        $wacsPath = Join-Path $root 'wacs.exe'
        $simpleAcmePath = Join-Path $root 'simple-acme.exe'
        $hadWacs = Test-Path -LiteralPath $wacsPath
        $hadSimpleAcme = Test-Path -LiteralPath $simpleAcmePath
        $backupWacs = ''
        $backupSimpleAcme = ''

        try {
            if ($hadWacs) {
                $backupWacs = [System.IO.File]::ReadAllText($wacsPath, [System.Text.Encoding]::UTF8)
            }
            if ($hadSimpleAcme) {
                $backupSimpleAcme = [System.IO.File]::ReadAllText($simpleAcmePath, [System.Text.Encoding]::UTF8)
            }

            [System.IO.File]::WriteAllText($simpleAcmePath, 'placeholder', [System.Text.Encoding]::UTF8)
            $resolvedPackageLocal = Resolve-WacsExecutable -EnvValues @{}
            if ($resolvedPackageLocal -ne $simpleAcmePath) {
                throw "Expected package-local simple-acme.exe, got '$resolvedPackageLocal'"
            }

            [System.IO.File]::WriteAllText($wacsPath, 'placeholder', [System.Text.Encoding]::UTF8)
            $resolvedWacs = Resolve-WacsExecutable -EnvValues @{}
            if ($resolvedWacs -ne $wacsPath) {
                throw "Expected package-local wacs.exe, got '$resolvedWacs'"
            }

            $resolvedOverride = Resolve-WacsExecutable -EnvValues @{ ACME_WACS_PATH = $simpleAcmePath }
            if ($resolvedOverride -ne $simpleAcmePath) {
                throw "Expected ACME_WACS_PATH override, got '$resolvedOverride'"
            }
        } finally {
            if ($hadWacs) {
                [System.IO.File]::WriteAllText($wacsPath, $backupWacs, [System.Text.Encoding]::UTF8)
            } elseif (Test-Path -LiteralPath $wacsPath) {
                Remove-Item -LiteralPath $wacsPath -Force -ErrorAction SilentlyContinue
            }

            if ($hadSimpleAcme) {
                [System.IO.File]::WriteAllText($simpleAcmePath, $backupSimpleAcme, [System.Text.Encoding]::UTF8)
            } elseif (Test-Path -LiteralPath $simpleAcmePath) {
                Remove-Item -LiteralPath $simpleAcmePath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    & $Assert 'wacs version parser handles noisy output and interactive menu detection' {
        $sample = @'
Error loading assembly C:\certificaat\Microsoft.Extensions.FileProviders.Abstractions.dll
Error loading assembly C:\certificaat\System.Diagnostics.EventLog.dll
Error loading assembly C:\certificaat\System.Net.Http.WinHttpHandler.dll
Error loading assembly C:\certificaat\System.Security.Cryptography.Pkcs.dll
Error loading some types from DigitalOcean.API, Version=5.2.0.0, Culture=neutral, PublicKeyToken=null (C:\certificaat\DigitalOcean.API.dll)

A simple cross platform ACME client (WACS)
Software version 2.3.0.0 (release, pluggable, standalone, 64-bit)
Connecting to https://acme-v02.api.letsencrypt.org/...
Scheduled task not configured yet
Check the manual at https://simple-acme.com
Please leave a star at https://github.com/simple-acme/simple-acme

N: Create certificate (default settings)
M: Create certificate (full options)
R: Run renewals (0 currently due)
A: Manage renewals (0 total)
O: More options...
Q: Quit

Please choose from the menu:
'@
        $lines = @($sample -split "`r?`n")
        $analysis = Get-WacsOutputAnalysis -OutputLines $lines
        if ($analysis.Version.ToString() -ne '2.3.0.0') {
            throw "Expected parsed version 2.3.0.0, got '$($analysis.Version)'."
        }
        if ($analysis.AssemblyDiagnosticCount -lt 1) {
            throw 'Expected assembly diagnostics to be detected.'
        }
        if (-not $analysis.EnteredInteractiveMenu) {
            throw 'Expected interactive menu marker to be detected from sample output.'
        }

        $detectedVersion = Get-WacsVersion -EnvValues @{ ACME_WACS_VERSION = $sample }
        if ($detectedVersion.ToString() -ne '2.3.0.0') {
            throw "Expected Get-WacsVersion to return 2.3.0.0, got '$detectedVersion'."
        }

        $threw = $false
        try {
            $null = Get-WacsOutputAnalysis -OutputLines $lines -RequireNonInteractiveMode
        } catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'entered interactive mode') {
                throw "Expected interactive-mode guidance, got '$($_.Exception.Message)'."
            }
        }
        if (-not $threw) {
            throw 'Expected RequireNonInteractiveMode to fail for interactive menu output.'
        }
    }

    & $Assert 'preflight skips optional windows role validation when key is missing' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            $wacsPath = Join-Path $root 'wacs.exe'
            $scriptPath = Join-Path $root 'cert2rds.ps1'
            [System.IO.File]::WriteAllText($wacsPath, 'placeholder', [System.Text.Encoding]::UTF8)
            [System.IO.File]::WriteAllText($scriptPath, 'param([string]$CertThumbprint)', [System.Text.Encoding]::UTF8)
            $envValues = @{
                ACME_DIRECTORY = 'https://test-acme.networking4all.com/dv'
                DOMAINS = 'remote4.itsecured.nl'
                ACME_SCRIPT_PATH = $scriptPath
                ACME_SCRIPT_PARAMETERS = '{CertThumbprint}'
                ACME_WACS_PATH = $wacsPath
                ACME_WACS_VERSION = 'Software version 2.3.0.0 (release)'
            }
            $null = Assert-ReconcilePreflight -EnvValues $envValues
        } finally {
            Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    & $Assert 'strictmode guard rejects direct dot access on EnvValues hashtable' {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'core/Simple-Acme-Reconciler.psm1'
        $raw = Get-Content -LiteralPath $modulePath -Raw -Encoding UTF8
        $matches = [regex]::Matches($raw, '\$EnvValues\.[A-Za-z0-9_]+')
        if ($matches.Count -gt 0) {
            $bad = @($matches | ForEach-Object { $_.Value } | Select-Object -Unique)
            throw "Found strictmode-unsafe EnvValues property access: $($bad -join ', ')"
        }
    }

    & $Assert 'Get-WacsVersion remains pure and emits no diagnostics to host' {
        $transcriptDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
        $transcriptPath = Join-Path $transcriptDir 'pure-version.log'
        try {
            Start-Transcript -Path $transcriptPath -Force | Out-Null
            $detectedVersion = Get-WacsVersion -EnvValues @{ ACME_WACS_VERSION = 'Software version 2.3.0.0 (release)' }
            Stop-Transcript | Out-Null
            if ($detectedVersion.ToString() -ne '2.3.0.0') {
                throw "Expected Get-WacsVersion to return 2.3.0.0, got '$detectedVersion'."
            }
            $transcriptText = Get-Content -LiteralPath $transcriptPath -Raw -Encoding UTF8
            if ($transcriptText -match 'simple-acme diagnostics') {
                throw 'Expected Get-WacsVersion to avoid printing diagnostics.'
            }
        } finally {
            if ((Get-Variable -Name transcriptPath -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $transcriptPath)) {
                Remove-Item -LiteralPath $transcriptPath -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -Path $transcriptDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    & $Assert 'reconcile failure formatting keeps diagnostics on separate lines' {
        $transcriptDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $transcriptDir -Force | Out-Null
        $transcriptPath = Join-Path $transcriptDir 'diagnostics-format.log'
        try {
            Start-Transcript -Path $transcriptPath -Force | Out-Null
            try {
                throw 'simulated failure'
            } catch {
                Write-Host ''
                Write-Host ('ACME reconcile failed: ' + $_.Exception.Message) -ForegroundColor Red
                Write-Host ''
                Write-ReconcileDiagnostics -Context 'simple-acme diagnostics'
            }
            Stop-Transcript | Out-Null
            $transcriptText = Get-Content -LiteralPath $transcriptPath -Raw -Encoding UTF8
            if ($transcriptText -notmatch 'ACME reconcile failed: simulated failure') {
                throw 'Expected reconcile failure line in transcript output.'
            }
            if ($transcriptText -notmatch '\r?\n\r?\nsimple-acme diagnostics\r?\n') {
                throw 'Expected diagnostics section to start on a new line after a blank line.'
            }
            foreach ($badToken in @('thesimple-acme', 'txttest-acme', 'Inspect: preview:')) {
                if ($transcriptText -match [regex]::Escape($badToken)) {
                    throw "Detected corrupted concatenated output token '$badToken'."
                }
            }
        } finally {
            if ((Get-Variable -Name transcriptPath -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $transcriptPath)) {
                Remove-Item -LiteralPath $transcriptPath -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -Path $transcriptDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
