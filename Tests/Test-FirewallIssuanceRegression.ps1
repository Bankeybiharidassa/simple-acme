Set-StrictMode -Version Latest

function Invoke-TestFirewallIssuanceRegression {
    param([scriptblock]$Assert)

    & $Assert 'generic firewall connector tolerates mappings without endpoints' {
        $path = Join-Path $PSScriptRoot '..\Scripts\connectors\cert2fw.ps1'
        $raw = Get-Content -LiteralPath $path -Raw
        if ($raw -notmatch "PSObject\.Properties\['endpoints'\]") {
            throw 'cert2fw still uses strict direct .endpoints access.'
        }
        if ($raw -notmatch 'local-firewall-hook') {
            throw 'cert2fw does not provide a local fallback endpoint for generic issuance hooks.'
        }
        if ($raw -notmatch 'catch[\s\S]*Write-ConnectorLog[\s\S]*generic-firewall-hook') {
            throw 'cert2fw does not tolerate missing mapping files for generic issuance hooks.'
        }
    }

    & $Assert 'generic WAF connector also tolerates missing mappings and endpoints' {
        $path = Join-Path $PSScriptRoot '..\Scripts\connectors\cert2waf.ps1'
        $raw = Get-Content -LiteralPath $path -Raw
        if ($raw -notmatch "PSObject\.Properties\['endpoints'\]") {
            throw 'cert2waf still uses strict direct .endpoints access.'
        }
        if ($raw -notmatch 'local-waf-hook') {
            throw 'cert2waf does not provide a local fallback endpoint for generic issuance hooks.'
        }
        if ($raw -notmatch 'catch[\s\S]*Write-ConnectorLog[\s\S]*generic-waf-hook') {
            throw 'cert2waf does not tolerate missing mapping files for generic issuance hooks.'
        }
    }

    & $Assert 'connector core logging is Windows PowerShell 5.1 compatible under strict mode' {
        $path = Join-Path $PSScriptRoot '..\Scripts\core\connector-core.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        if ($raw -match '\$IsWindows') {
            throw 'connector-core uses $IsWindows, which is not available in Windows PowerShell 5.1 strict mode.'
        }
        if ($raw -notmatch 'OSVersion\.Platform') {
            throw 'connector-core does not use a PowerShell 5.1-compatible Windows platform check.'
        }
    }

    & $Assert 'renewal comparison tolerates WACS 2.3.6 files with absent optional metadata' {
        Import-Module (Join-Path $PSScriptRoot '..\core\Simple-Acme-Reconciler.psm1') -Force
        $summary = [pscustomobject]@{
            Hosts = @('*.itsecured.nl')
            BaseUri = ''
            EabKid = ''
            SourcePlugin = 'manual'
            OrderPlugin = 'single'
            AccountName = ''
            HasValidationMetadata = $false
            HasValidationNone = $false
            HasScriptInstallation = $true
            InstallationPlugins = @('script')
            ScriptPaths = @('D:\GitHub\simple-acme\test\certificaat\Scripts\cert2fw.ps1')
            ScriptParameters = @('{CertThumbprint}')
            StorePlugins = @('certificatestore','pfxfile')
            CsrPlugin = 'ec'
            KeyType = $null
        }
        $envValues = @{
            DOMAINS = '*.itsecured.nl'
            ACME_DIRECTORY = 'https://test-acme.networking4all.com/dv-wildcard'
            ACME_KID = 'kid-is-set'
            ACME_SCRIPT_PATH = 'D:\GitHub\simple-acme\test\certificaat\Scripts\cert2fw.ps1'
            ACME_SOURCE_PLUGIN = 'manual'
            ACME_ORDER_PLUGIN = 'single'
            ACME_STORE_PLUGIN = 'certificatestore,pfxfile'
            ACME_VALIDATION_MODE = 'none'
            ACME_INSTALLATION_PLUGINS = 'script'
            ACME_ACCOUNT_NAME = ''
            ACME_CSR_ALGORITHM = 'ec'
            ACME_ALLOW_CSR_FALLBACK = '0'
        }
        $result = Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $envValues
        if (-not $result.Matches) { throw "Expected match but got mismatches: $($result.Mismatches -join ', ')" }
    }

    & $Assert 'WACS 2.3.6 no-validation plugin id is normalized to none' {
        $reconcilerPath = Join-Path $PSScriptRoot '..\core\Simple-Acme-Reconciler.psm1'
        $raw = Get-Content -LiteralPath $reconcilerPath -Raw
        if ($raw -notmatch 'a37b41dc-b45a-42fe-8d81-82ca409a5491') {
            throw 'No-validation plugin id observed in WACS 2.3.6 renewal JSON is not normalized.'
        }
        if ($raw -notmatch "\+ 'none'") {
            throw 'No-validation plugin id is not mapped to validation none.'
        }
    }
}
