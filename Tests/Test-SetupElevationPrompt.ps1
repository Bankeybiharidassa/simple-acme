Set-StrictMode -Version Latest

function Invoke-TestSetupElevationPrompt {
    param([scriptblock]$Assert)

    & $Assert 'certificate setup asks for elevation before privileged actions' {
        $setupPath = Join-Path $PSScriptRoot '..\certificate-setup.ps1'
        $raw = Get-Content -LiteralPath $setupPath -Raw
        if ($raw -notmatch 'function\s+Request-ElevationForPrivilegedAction') {
            throw 'Elevation prompt helper was not found.'
        }
        if ($raw -notmatch 'Start-Process[\s\S]*-Verb\s+RunAs') {
            throw 'Elevated relaunch does not use Start-Process -Verb RunAs.'
        }
        if ($raw -notmatch 'Test-ReconcileLikelyRequiresElevation[\s\S]*Request-ElevationForPrivilegedAction') {
            throw 'Initial reconcile does not ask for elevation when privileged work is likely.'
        }
        if ($raw -notmatch 'function\s+Invoke-OrchestratorTaskRegistration[\s\S]*Request-ElevationForPrivilegedAction') {
            throw 'Scheduled task registration does not ask for elevation.'
        }
        if ($raw -notmatch 'Continue in this non-elevated window anyway') {
            throw 'Elevation prompt must allow the operator to continue without a hard deny.'
        }
        if ($raw -notmatch 'function\s+Ensure-SetupEnvFileReadable' -or $raw -notmatch 'certificate\.env is not readable') {
            throw 'Setup does not detect unreadable certificate.env ACLs before opening the TUI.'
        }
        if ($raw -notmatch 'catch\s+\[System\.IO\.FileNotFoundException\][\s\S]*catch\s+\[System\.IO\.DirectoryNotFoundException\]') {
            throw 'Readability detection must open certificate.env directly and only treat missing files as harmless.'
        }
        if ($raw -notmatch 'setup-new[\s\S]*Ensure-SetupEnvFileReadable[\s\S]*Invoke-AcmeForm') {
            throw 'Setup-new action does not re-check certificate.env readability before opening the form.'
        }
        if ($raw -notmatch "'acme'[\s\S]*Ensure-SetupEnvFileReadable[\s\S]*Invoke-AcmeSettingsMenu") {
            throw 'ACME settings action does not re-check certificate.env readability before opening settings.'
        }
    }

    & $Assert 'env loader reports certificate.env ACL failures with repair guidance' {
        $envLoaderPath = Join-Path $PSScriptRoot '..\core\Env-Loader.psm1'
        $raw = Get-Content -LiteralPath $envLoaderPath -Raw
        if ($raw -notmatch 'catch\s+\[System\.UnauthorizedAccessException\]') {
            throw 'Read-EnvFile does not catch UnauthorizedAccessException.'
        }
        if ($raw -notmatch 'accept the elevation/repair prompt') {
            throw 'Read-EnvFile access denied message does not guide the operator toward repair/elevation.'
        }
    }
}
