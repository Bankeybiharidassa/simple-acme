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

    & $Assert 'renewal ACME directory matching separates test and production endpoints' {
        $envValues = @{ ACME_DIRECTORY = 'https://acme.networking4all.com/dv' }
        $testSummary = [pscustomobject]@{ BaseUri = 'https://test-acme.networking4all.com/dv' }
        $prodSummary = [pscustomobject]@{ BaseUri = 'https://acme.networking4all.com/dv' }
        $legacySummary = [pscustomobject]@{ BaseUri = '' }

        if (Test-RenewalAcmeDirectoryMatch -RenewalSummary $testSummary -EnvValues $envValues) {
            throw 'Test ACME renewal should not match production ACME setup.'
        }
        if (-not (Test-RenewalAcmeDirectoryMatch -RenewalSummary $prodSummary -EnvValues $envValues)) {
            throw 'Production ACME renewal should match production ACME setup.'
        }
        if (-not (Test-RenewalAcmeDirectoryMatch -RenewalSummary $legacySummary -EnvValues $envValues)) {
            throw 'Renewals without BaseUri should remain compatible.'
        }
    }

    & $Assert 'installation plugins are parsed and normalized' {
        $plugins = Get-InstallationPlugins -EnvValues @{ ACME_INSTALLATION_PLUGINS = 'script, iis,script' }
        if (($plugins -join ',') -ne 'iis,script') {
            throw "Unexpected plugins: $($plugins -join ',')"
        }
    }

    & $Assert 'installation plugins tolerate pfxfile token as store-only compatibility' {
        $plugins = Get-InstallationPlugins -EnvValues @{ ACME_INSTALLATION_PLUGINS = 'pfxfile' }
        if ((@($plugins).Count) -ne 0) {
            throw "Expected no installation plugins but got: $($plugins -join ',')"
        }
    }

    & $Assert 'installation plugins keep script and ignore pfxfile token' {
        $plugins = Get-InstallationPlugins -EnvValues @{ ACME_INSTALLATION_PLUGINS = 'script,pfxfile' }
        if (($plugins -join ',') -ne 'script') {
            throw "Expected script only but got: $($plugins -join ',')"
        }
    }

    & $Assert 'installation plugins still reject unknown token' {
        $threw = $false
        try {
            $null = Get-InstallationPlugins -EnvValues @{ ACME_INSTALLATION_PLUGINS = 'script,totally-unknown' }
        } catch {
            $threw = $true
        }
        if (-not $threw) {
            throw 'Expected unknown installation plugin token to throw.'
        }
    }

    & $Assert 'store plugin auto-repairs concatenated token and emits warning' {
        $warned = $false
        $oldWarning = $WarningPreference
        try {
            $WarningPreference = 'SilentlyContinue'
            Set-Variable -Name 'WarningPreference' -Value 'Continue' -Scope 1
            # pfxfilecertificatestore should be auto-split; WACS invocation will fail (no exe) but not on the token
            try {
                $null = Invoke-WacsIssue -EnvValues @{
                    DOMAINS = 'example.com'
                    ACME_DIRECTORY = 'https://acme.networking4all.com/dv'
                    ACME_SOURCE_PLUGIN = 'manual'
                    ACME_ORDER_PLUGIN = 'single'
                    ACME_VALIDATION_MODE = 'none'
                    ACME_INSTALLATION_PLUGINS = 'script'
                    ACME_SCRIPT_PATH = 'C:\install.ps1'
                    ACME_STORE_PLUGIN = 'pfxfilecertificatestore'
                    ACME_PFX_FILE_PATH = 'C:\certs'
                }
            } catch {
                # Expected: WACS exe not found or similar — NOT "unrecognized token"
                if ($_.Exception.Message -match 'unrecognized token') {
                    throw "Auto-repair should have split 'pfxfilecertificatestore' into known plugins before reaching the allow-list guard, but got: $($_.Exception.Message)"
                }
            }
        } finally { $WarningPreference = $oldWarning }
    }

    & $Assert 'store plugin rejects completely unknown value' {
        $threw = $false
        try {
            $null = Invoke-WacsIssue -EnvValues @{
                DOMAINS = 'example.com'
                ACME_DIRECTORY = 'https://acme.networking4all.com/dv'
                ACME_SOURCE_PLUGIN = 'manual'
                ACME_ORDER_PLUGIN = 'single'
                ACME_VALIDATION_MODE = 'none'
                ACME_INSTALLATION_PLUGINS = ''
                ACME_STORE_PLUGIN = 'nosuchthing'
            }
        } catch {
            if ($_.Exception.Message -match 'unrecognized token') { $threw = $true }
        }
        if (-not $threw) {
            throw 'Expected unknown store plugin token to throw with unrecognized token message.'
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

    & $Assert 'Get-WacsOutputAnalysis parses version output when required' {
        $sample = @'
Error loading assembly C:\certificaat\Some.dll
Software version 2.3.0.0 (release, pluggable, standalone, 64-bit)
'@
        $lines = @($sample -split "`r?`n")
        $analysis = Get-WacsOutputAnalysis -OutputLines $lines -RequireVersion -RequireNonInteractiveMode
        if ($analysis.Version.ToString() -ne '2.3.0.0') {
            throw "Expected parsed version 2.3.0.0, got '$($analysis.Version)'."
        }

        $detectedVersion = Get-WacsVersion -EnvValues @{ ACME_WACS_VERSION = $sample }
        if ($detectedVersion.ToString() -ne '2.3.0.0') {
            throw "Expected Get-WacsVersion to return 2.3.0.0, got '$detectedVersion'."
        }
    }

    & $Assert 'Get-WacsOutputAnalysis allows issuance output without version' {
        $sample = @'
Connecting to https://test-acme.networking4all.com/dv
Creating order
Authorization pending
'@
        $lines = @($sample -split "`r?`n")
        $analysis = Get-WacsOutputAnalysis -OutputLines $lines -RequireNonInteractiveMode
        if ($null -ne $analysis.Version) {
            throw "Expected Version to be null for issuance output, got '$($analysis.Version)'."
        }
        if ($null -ne $analysis.VersionText) {
            throw "Expected VersionText to be null for issuance output, got '$($analysis.VersionText)'."
        }
    }

    & $Assert 'Get-WacsOutputAnalysis does not throw version errors for issuance failures' {
        $sample = @'
Connecting to https://test-acme.networking4all.com/dv
Error creating order
'@
        $lines = @($sample -split "`r?`n")
        $analysis = Get-WacsOutputAnalysis -OutputLines $lines -RequireNonInteractiveMode
        if ($null -ne $analysis.Version) {
            throw "Expected Version to be null for issuance failure output, got '$($analysis.Version)'."
        }
        if ($null -ne $analysis.VersionText) {
            throw "Expected VersionText to be null for issuance failure output, got '$($analysis.VersionText)'."
        }
    }

    & $Assert 'Get-WacsOutputAnalysis detects accidental interactive mode' {
        $sample = @'
N: Create certificate
Please choose from the menu:
'@
        $lines = @($sample -split "`r?`n")
        $threw = $false
        try {
            $null = Get-WacsOutputAnalysis -OutputLines $lines -RequireNonInteractiveMode
        } catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'interactive menu') {
                throw "Expected interactive-mode guidance, got '$($_.Exception.Message)'."
            }
        }
        if (-not $threw) {
            throw 'Expected RequireNonInteractiveMode to fail for interactive menu output.'
        }
    }

    & $Assert 'Get-WacsOutputAnalysis throws when version is required but missing' {
        $sample = @'
Connecting to server
No version here
'@
        $lines = @($sample -split "`r?`n")
        $threw = $false
        try {
            $null = Get-WacsOutputAnalysis -OutputLines $lines -RequireVersion
        } catch {
            $threw = $true
            if ($_.Exception.Message -notmatch 'Unable to parse simple-acme/wacs version from output') {
                throw "Expected version parse failure, got '$($_.Exception.Message)'."
            }
        }
        if (-not $threw) {
            throw 'Expected missing version to throw when -RequireVersion is used.'
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
                ACME_SCRIPT_PARAMETERS = '{CacheFile}'
                ACME_WACS_PATH = $wacsPath
                ACME_WACS_VERSION = 'Software version 2.3.0.0 (release)'
                ACME_STORE_PLUGIN = 'pfxfile'
                ACME_PFX_FILE_PATH = $root
            }
            $null = Test-ReconcilePreflight -EnvValues $envValues
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


    & $Assert 'csr plan defaults to ec,rsa fallback when env is empty' {
        $plan = Get-CsrExecutionPlan -EnvValues @{}
        if (($plan -join ',') -ne 'ec,rsa') { throw "Expected ec,rsa by default, got $($plan -join ',')" }
    }


    & $Assert 'csr plan no fallback returns ec only and count one' {
        $envValues = @{ ACME_CSR_ALGORITHM='ec'; ACME_ALLOW_CSR_FALLBACK='0' }
        $plan = @(Get-CsrExecutionPlan -EnvValues $envValues)
        if (($plan -join ',') -ne 'ec') { throw "Expected ec, got $($plan -join ',')" }
        if (@($plan).Count -ne 1) { throw "Expected count 1, got $(@($plan).Count)" }
    }

    & $Assert 'masked args handles scalar and masks secret under strict mode' {
        Set-StrictMode -Version Latest
        $single = @(Get-MaskedWacsArgumentsText -Args '--csr')
        if (($single -join ',') -ne '--csr') { throw 'Expected scalar arg to be preserved.' }
        $masked = @(Get-MaskedWacsArgumentsText -Args @('--eab-key','secret'))
        if (($masked -join ',') -ne '--eab-key,<hidden>') { throw "Expected masked secret, got $($masked -join ',')" }
    }

    & $Assert 'wacs deferred retry detects processing and rate limit output' {
        if (-not (Test-WacsDeferredRetrySuggested -OutputLines @('Unexpected order status processing'))) {
            throw 'Expected processing status to request deferred retry.'
        }
        if (-not (Test-WacsDeferredRetrySuggested -OutputLines @('detail":"Please wait a short moment before retrying this request.'))) {
            throw 'Expected ACME short-moment rate-limit detail to request deferred retry.'
        }
        if (Test-WacsDeferredRetrySuggested -OutputLines @('Create certificate failed')) {
            throw 'Generic certificate failure should not force deferred retry handling.'
        }
    }

    & $Assert 'wacs deferred retry can reuse pending order by dropping nocache' {
        $args = @('--accepttos','--nocache','--csr','ec')
        $normal = @(Get-WacsRetryArgumentList -Args $args)
        if (($normal -join ',') -ne ($args -join ',')) {
            throw "Expected normal retry args unchanged, got: $($normal -join ',')"
        }
        $deferred = @(Get-WacsRetryArgumentList -Args $args -AllowCache)
        if ($deferred -contains '--nocache') {
            throw 'Expected deferred retry args to remove --nocache.'
        }
        if (($deferred -join ',') -ne '--accepttos,--csr,ec') {
            throw "Unexpected deferred retry args: $($deferred -join ',')"
        }
    }

    & $Assert 'csr plan supports explicit rsa' {
        $plan = Get-CsrExecutionPlan -EnvValues @{ ACME_CSR_ALGORITHM = 'rsa'; ACME_ALLOW_CSR_FALLBACK = '0' }
        if (($plan -join ',') -ne 'rsa') { throw "Expected rsa only, got $($plan -join ',')" }
    }

    & $Assert 'csr plan supports ec to rsa fallback when enabled' {
        $plan = Get-CsrExecutionPlan -EnvValues @{ ACME_CSR_ALGORITHM = 'ec'; ACME_ALLOW_CSR_FALLBACK = '1' }
        if (($plan -join ',') -ne 'ec,rsa') { throw "Expected ec,rsa fallback plan, got $($plan -join ',')" }
    }

    & $Assert 'Compare-RenewalWithEnv matches when env has pfxfile,certificatestore' {
        $summary = [pscustomobject]@{
            Hosts = @('example.com')
            BaseUri = 'https://acme.networking4all.com/dv'
            EabKid = ''
            SourcePlugin = 'manual'
            OrderPlugin = 'single'
            AccountName = ''
            HasValidationNone = $true
            HasScriptInstallation = $true
            InstallationPlugins = @('script')
            ScriptPaths = @('C:\deploy.ps1')
            ScriptParameters = @('{CertThumbprint}')
            StorePlugins = @('certificatestore','pfxfile')
            CsrPlugin = $null
            KeyType = $null
        }
        $envValues = @{
            DOMAINS = 'example.com'
            ACME_DIRECTORY = 'https://acme.networking4all.com/dv'
            ACME_KID = ''
            ACME_SCRIPT_PATH = 'C:\deploy.ps1'
            ACME_SOURCE_PLUGIN = 'manual'
            ACME_ORDER_PLUGIN = 'single'
            ACME_STORE_PLUGIN = 'pfxfile,certificatestore'
            ACME_VALIDATION_MODE = 'none'
            ACME_INSTALLATION_PLUGINS = 'script'
            ACME_ACCOUNT_NAME = ''
        }
        $result = Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $envValues
        if (-not $result.Matches) { throw "Expected match but got mismatches: $($result.Mismatches -join ', ')" }
    }

    & $Assert 'Compare-RenewalWithEnv auto-adds certificatestore to expected when installation is script' {
        $summary = [pscustomobject]@{
            Hosts = @('example.com')
            BaseUri = 'https://acme.networking4all.com/dv'
            EabKid = ''
            SourcePlugin = 'manual'
            OrderPlugin = 'single'
            AccountName = ''
            HasValidationNone = $true
            HasScriptInstallation = $true
            InstallationPlugins = @('script')
            ScriptPaths = @('C:\deploy.ps1')
            ScriptParameters = @('{CertThumbprint}')
            StorePlugins = @('certificatestore','pfxfile')
            CsrPlugin = $null
            KeyType = $null
        }
        $envValues = @{
            DOMAINS = 'example.com'
            ACME_DIRECTORY = 'https://acme.networking4all.com/dv'
            ACME_KID = ''
            ACME_SCRIPT_PATH = 'C:\deploy.ps1'
            ACME_SOURCE_PLUGIN = 'manual'
            ACME_ORDER_PLUGIN = 'single'
            ACME_STORE_PLUGIN = 'pfxfile'
            ACME_VALIDATION_MODE = 'none'
            ACME_INSTALLATION_PLUGINS = 'script'
            ACME_ACCOUNT_NAME = ''
        }
        $result = Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $envValues
        if (-not $result.Matches) { throw "Expected auto-inject of certificatestore to produce a match, but got mismatches: $($result.Mismatches -join ', ')" }
    }

    & $Assert 'Get-WacsIssueArguments does not force certificatestore for PFX-only appliance hooks' {
        $args = Get-WacsIssueArguments -EnvValues @{
            DOMAINS = 'kemp.example.com'
            ACME_DIRECTORY = 'https://test-acme.networking4all.com/dv'
            ACME_SOURCE_PLUGIN = 'manual'
            ACME_ORDER_PLUGIN = 'single'
            ACME_VALIDATION_MODE = 'none'
            ACME_INSTALLATION_PLUGINS = 'script'
            ACME_SCRIPT_PATH = 'C:\certificaat\Scripts\cert2kemp.ps1'
            ACME_SCRIPT_PARAMETERS = "-PfxPath '{CacheFile}' -CachePassword '{CachePassword}' -ConfigDir 'C:\certificaat\config'"
            ACME_STORE_PLUGIN = 'pfxfile'
            ACME_PFX_FILE_PATH = 'C:\certs'
            ACME_PFX_PASSWORD = 'secret-password'
            ACME_PRIVATE_KEY_STRATEGY = 'pfx-distribution'
        } -CsrAlgorithm 'ec'
        $storeIndex = [Array]::IndexOf([object[]]$args, '--store')
        if ($storeIndex -lt 0) { throw 'Expected --store argument.' }
        if ($args[$storeIndex + 1] -ne 'pfxfile') {
            throw "Expected pfxfile-only store for Kemp hook, got '$($args[$storeIndex + 1])'."
        }
    }

    & $Assert 'Compare-RenewalWithEnv accepts PFX-only appliance hooks' {
        $summary = [pscustomobject]@{
            Hosts = @('kemp.example.com')
            BaseUri = 'https://test-acme.networking4all.com/dv'
            EabKid = ''
            SourcePlugin = 'manual'
            OrderPlugin = 'single'
            AccountName = ''
            HasValidationNone = $true
            HasScriptInstallation = $true
            InstallationPlugins = @('script')
            ScriptPaths = @('C:\certificaat\Scripts\cert2kemp.ps1')
            ScriptParameters = @("-PfxPath '{CacheFile}' -CachePassword '{CachePassword}' -ConfigDir 'C:\certificaat\config'")
            StorePlugins = @('pfxfile')
            CsrPlugin = $null
            KeyType = $null
        }
        $envValues = @{
            DOMAINS = 'kemp.example.com'
            ACME_DIRECTORY = 'https://test-acme.networking4all.com/dv'
            ACME_KID = ''
            ACME_SCRIPT_PATH = 'C:\certificaat\Scripts\cert2kemp.ps1'
            ACME_SOURCE_PLUGIN = 'manual'
            ACME_ORDER_PLUGIN = 'single'
            ACME_STORE_PLUGIN = 'pfxfile'
            ACME_VALIDATION_MODE = 'none'
            ACME_INSTALLATION_PLUGINS = 'script'
            ACME_SCRIPT_PARAMETERS = "-PfxPath '{CacheFile}' -CachePassword '{CachePassword}' -ConfigDir 'C:\certificaat\config'"
            ACME_ACCOUNT_NAME = ''
        }
        $result = Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $envValues
        if (-not $result.Matches) { throw "Expected PFX-only Kemp hook to match, but got mismatches: $($result.Mismatches -join ', ')" }
    }

    & $Assert 'Compare-RenewalWithEnv reports Store plugin mismatch when stores differ' {
        $summary = [pscustomobject]@{
            Hosts = @('example.com')
            BaseUri = 'https://acme.networking4all.com/dv'
            EabKid = ''
            SourcePlugin = 'manual'
            OrderPlugin = 'single'
            AccountName = ''
            HasValidationNone = $true
            HasScriptInstallation = $false
            InstallationPlugins = @()
            ScriptPaths = @()
            ScriptParameters = @()
            StorePlugins = @('pemfiles')
            CsrPlugin = $null
            KeyType = $null
        }
        $envValues = @{
            DOMAINS = 'example.com'
            ACME_DIRECTORY = 'https://acme.networking4all.com/dv'
            ACME_KID = ''
            ACME_SCRIPT_PATH = ''
            ACME_SOURCE_PLUGIN = 'manual'
            ACME_ORDER_PLUGIN = 'single'
            ACME_STORE_PLUGIN = 'certificatestore'
            ACME_VALIDATION_MODE = 'none'
            ACME_INSTALLATION_PLUGINS = 'iis'
            ACME_ACCOUNT_NAME = ''
        }
        $result = Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $envValues
        if ($result.Matches) { throw 'Expected store mismatch to be detected.' }
        if (-not ($result.Mismatches -contains 'Store plugin')) { throw "Expected 'Store plugin' in mismatches, got: $($result.Mismatches -join ', ')" }
    }

    & $Assert 'Get-WacsIssueArguments includes all required PFX distribution command line switches' {
        $args = Get-WacsIssueArguments -EnvValues @{
            DOMAINS = '*.itsecured.nl'
            ACME_DIRECTORY = 'https://test-acme.networking4all.com/dv-wildcard'
            ACME_SOURCE_PLUGIN = 'manual'
            ACME_ORDER_PLUGIN = 'single'
            ACME_VALIDATION_MODE = 'none'
            ACME_INSTALLATION_PLUGINS = 'script'
            ACME_SCRIPT_PATH = 'C:\certificaat\Scripts\deploy-rds-farm.ps1'
            ACME_SCRIPT_PARAMETERS = "-CertThumbprint '{CertThumbprint}' -CachePassword '{CachePassword}' -CacheFile '{CacheFile}' -ConfigFile 'C:\certificaat\runtime\deployment\rds-farm.env'"
            ACME_STORE_PLUGIN = 'pfxfile,certificatestore'
            ACME_PFX_FILE_PATH = 'C:\certs'
            ACME_PFX_PASSWORD = 'secret-password'
            ACME_REQUIRES_EAB = '1'
            ACME_KID = 'kid'
            ACME_HMAC_SECRET = 'hmac'
            ACME_TARGET_SYSTEM = 'rds-farm'
        } -CsrAlgorithm 'ec'
        foreach ($required in @('--pfxfilepath','C:\certs','--pfxpassword','secret-password','--certificatestore','My','--eab-key-identifier','kid','--eab-key','hmac','--csr','ec')) {
            if ($args -notcontains $required) { throw "Missing required WACS argument '$required'. Actual: $($args -join ' ')" }
        }
        $masked = Get-MaskedWacsArgumentsText -Args $args
        if ($masked -contains 'secret-password') { throw 'PFX password was not masked.' }
        if ($masked -contains 'hmac') { throw 'EAB HMAC was not masked.' }
    }

    & $Assert 'Get-WacsIssueArguments requires PFX password for RDS farm PFX distribution' {
        $threw = $false
        try {
            $null = Get-WacsIssueArguments -EnvValues @{
                DOMAINS = '*.itsecured.nl'
                ACME_DIRECTORY = 'https://test-acme.networking4all.com/dv-wildcard'
                ACME_INSTALLATION_PLUGINS = 'script'
                ACME_SCRIPT_PATH = 'C:\certificaat\Scripts\deploy-rds-farm.ps1'
                ACME_STORE_PLUGIN = 'pfxfile,certificatestore'
                ACME_PFX_FILE_PATH = 'C:\certs'
                ACME_TARGET_SYSTEM = 'rds-farm'
            } -CsrAlgorithm 'ec'
        } catch {
            if ($_.Exception.Message -match 'ACME_PFX_PASSWORD is empty') { $threw = $true }
        }
        if (-not $threw) { throw 'Expected missing ACME_PFX_PASSWORD to throw for RDS farm PFX distribution.' }
    }

    & $Assert 'Preflight blocks certificate store reconcile before cancellation when PowerShell is not elevated' {
        $raw = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\core\Simple-Acme-Reconciler.psm1') -Raw
        foreach ($text in @(
            'function Test-IsAdministrator',
            'function Get-EffectiveWacsStorePlugins',
            "`$effectiveStorePlugins = @(Get-EffectiveWacsStorePlugins -EnvValues `$EnvValues)",
            "`$effectiveStorePlugins -contains 'certificatestore'",
            'current Windows PowerShell is not elevated',
            'Run Windows PowerShell as Administrator before reconcile/renewal',
            "Invoke-WacsWithRetry -Args @('--baseuri'"
        )) {
            if (-not $raw.Contains($text)) { throw "Missing preflight certificate-store elevation behavior: $text" }
        }
        if ($raw.IndexOf('current Windows PowerShell is not elevated') -gt $raw.IndexOf("Invoke-WacsWithRetry -Args @('--baseuri'")) {
            throw 'Certificate-store elevation guard must appear before WACS cancel/update execution.'
        }
    }

    & $Assert 'Effective WACS store plugins auto-add certificate store for thumbprint scripts' {
        $plugins = @(Get-EffectiveWacsStorePlugins -EnvValues @{
            ACME_STORE_PLUGIN = 'pfxfile'
            ACME_INSTALLATION_PLUGINS = 'script'
            ACME_SCRIPT_PARAMETERS = "-PfxPath '{CacheFile}' -CertThumbprint '{CertThumbprint}'"
        })
        if (-not ($plugins -contains 'pfxfile')) { throw "Expected pfxfile store plugin, got: $($plugins -join ',')" }
        if (-not ($plugins -contains 'certificatestore')) { throw "Expected certificatestore auto-add, got: $($plugins -join ',')" }
    }

    & $Assert 'Invoke-WacsIssue throws when ACME_PFX_FILE_PATH is a file path with extension' {
        $threw = $false
        try {
            $null = Invoke-WacsIssue -EnvValues @{
                DOMAINS = 'example.com'
                ACME_DIRECTORY = 'https://acme.networking4all.com/dv'
                ACME_SOURCE_PLUGIN = 'manual'
                ACME_ORDER_PLUGIN = 'single'
                ACME_VALIDATION_MODE = 'none'
                ACME_INSTALLATION_PLUGINS = 'script'
                ACME_SCRIPT_PATH = 'C:\deploy.ps1'
                ACME_STORE_PLUGIN = 'pfxfile'
                ACME_PFX_FILE_PATH = 'C:\certs\certificate.pfx'
            }
        } catch {
            if ($_.Exception.Message -match 'must be a directory path') { $threw = $true }
        }
        if (-not $threw) { throw 'Expected file-path ACME_PFX_FILE_PATH to throw with directory-required message.' }
    }

    & $Assert 'Get-RenewalSummary handles WACS 2.3.6 format without throwing' {
        $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $json = @'
{
  "$schema": "https://simple-acme.com/schema/renewal.json",
  "Id": "NJ9mrLwBdk6d121A48zNvQ",
  "TargetPluginOptions": {
    "CommonName": "*.example.com",
    "AlternativeNames": ["*.example.com"],
    "Plugin": "e239db3b-0000-0000-0000-000000000000"
  },
  "StorePluginOptions": [
    { "Path": "c:\\certs", "PfxPassword": null, "Plugin": "2a2c576f-0000-0000-0000-000000000000" },
    { "Plugin": "e30adc8e-0000-0000-0000-000000000000" }
  ],
  "InstallationPluginOptions": [
    { "Script": "Scripts\\deploy-rds-farm.ps1", "ScriptParameters": "{CertThumbprint}", "Plugin": "3bb22c70-0000-0000-0000-000000000000" }
  ],
  "History": []
}
'@
            $path = Join-Path $tmpDir 'NJ9mrLwBdk6d121A48zNvQ.renewal.json'
            [System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::UTF8)
            $file = Get-Item -LiteralPath $path
            $summary = Get-RenewalSummary -File $file
            if ($summary.RenewalId -ne 'NJ9mrLwBdk6d121A48zNvQ') { throw "Wrong RenewalId: $($summary.RenewalId)" }
            if ($summary.SourcePlugin -ne 'manual') { throw "Expected SourcePlugin 'manual', got: $($summary.SourcePlugin)" }
            if ($summary.OrderPlugin -ne 'single') { throw "Expected OrderPlugin 'single', got: $($summary.OrderPlugin)" }
            if (-not ($summary.StorePlugins -contains 'pfxfile')) { throw "Expected 'pfxfile' in StorePlugins: $($summary.StorePlugins -join ',')" }
            if (-not ($summary.StorePlugins -contains 'certificatestore')) { throw "Expected 'certificatestore' in StorePlugins: $($summary.StorePlugins -join ',')" }
            if (-not ($summary.InstallationPlugins -contains 'script')) { throw "Expected 'script' in InstallationPlugins: $($summary.InstallationPlugins -join ',')" }
            if (-not ($summary.ScriptPaths -contains 'Scripts\deploy-rds-farm.ps1')) { throw "Expected script path, got: $($summary.ScriptPaths -join ',')" }
            if (-not ($summary.ScriptParameters -contains '{CertThumbprint}')) { throw "Expected '{CertThumbprint}' in ScriptParameters." }
            if (-not ($summary.Hosts -contains '*.example.com')) { throw "Expected '*.example.com' in Hosts: $($summary.Hosts -join ',')" }
        } finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    & $Assert 'Compare-RenewalWithEnv matches for WACS 2.3.6 renewal with correct env' {
        $summary = [pscustomobject]@{
            Hosts = @('*.example.com')
            BaseUri = 'https://acme-v02.api.letsencrypt.org/directory'
            EabKid = ''
            SourcePlugin = 'manual'
            OrderPlugin = 'single'
            AccountName = ''
            HasValidationNone = $true
            HasScriptInstallation = $true
            InstallationPlugins = @('script')
            ScriptPaths = @('C:\scripts\deploy-rds-farm.ps1')
            ScriptParameters = @('{CertThumbprint}')
            StorePlugins = @('certificatestore','pfxfile')
            CsrPlugin = $null
            KeyType = $null
        }
        $envValues = @{
            DOMAINS = '*.example.com'
            ACME_DIRECTORY = 'https://acme-v02.api.letsencrypt.org/directory'
            ACME_KID = ''
            ACME_SCRIPT_PATH = 'C:\scripts\deploy-rds-farm.ps1'
            ACME_SOURCE_PLUGIN = 'manual'
            ACME_ORDER_PLUGIN = 'single'
            ACME_STORE_PLUGIN = 'pfxfile,certificatestore'
            ACME_VALIDATION_MODE = 'none'
            ACME_INSTALLATION_PLUGINS = 'script'
            ACME_ACCOUNT_NAME = ''
        }
        $result = Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $envValues
        if (-not $result.Matches) { throw "Expected match but got mismatches: $($result.Mismatches -join ', ')" }
    }

    & $Assert 'Certificate health check matches exact and single-label wildcard domains' {
        if (-not (Test-CertificateDomainPatternMatch -Pattern 'example.com' -Domain 'example.com')) { throw 'Exact certificate/domain match failed.' }
        if (-not (Test-CertificateDomainPatternMatch -Pattern '*.example.com' -Domain 'www.example.com')) { throw 'Wildcard certificate/domain match failed.' }
        if (Test-CertificateDomainPatternMatch -Pattern '*.example.com' -Domain 'deep.www.example.com') { throw 'Wildcard matched more than one label.' }
        if (Test-CertificateDomainPatternMatch -Pattern '*.example.com' -Domain 'example.com') { throw 'Wildcard matched the apex domain.' }
    }

    & $Assert 'Reconcile matching renewal delegates lifecycle timing to simple-acme ARI' {
        $raw = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\core\Simple-Acme-Reconciler.psm1') -Raw
        foreach ($text in @(
            'function Test-RenewalCertificateHealth',
            'ACME Renewal Information (ARI, RFC 9773)',
            'Renewal timing belongs to simple-acme',
            '$forceInstallRepair = ([string]$certificateHealth.Status -eq ''InstallationFailed'')',
            'Invoke-WacsRenewalCheck -EnvValues $EnvValues -RenewalId $renewalId -Force:$forceInstallRepair | Out-Null',
            'simple-acme ARI renewal check completed',
            'Previous installation failed, so simple-acme renewal was forced to rerun the installation hook',
            "Status = 'Revoked'",
            "Status = 'Missing'",
            "Status = 'InstallationFailed'",
            'LatestThumbprint',
            'LatestOrderErrorMessages',
            'Renewal history recorded certificate/order error(s)',
            "Renewal certificate '`$latestThumbprint' was not found",
            'simple-acme ARI remains authoritative for renewal timing.'
        )) {
            if (-not $raw.Contains($text)) { throw "Missing ARI-aware certificate-health reconcile behavior: $text" }
        }
        foreach ($forbidden in @(
            'ACME_CERTIFICATE_REISSUE_WITHIN_DAYS',
            'ExpiringSoon',
            'ShouldRunWacsRenewal',
            'ForceWacsRenewal',
            'ShouldReissue',
            'Renewal configuration already matches .env. Certificate health'
        )) {
            if ($raw.Contains($forbidden)) { throw "Wrapper must not override simple-acme ARI with local renewal decision: $forbidden" }
        }
        if (-not $raw.Contains("-Force:`$forceInstallRepair")) {
            throw 'Forced simple-acme renewal must be tied only to previous installation failure repair.'
        }
    }
}
