Set-StrictMode -Version Latest

function Invoke-TestSecurePlatformConfig {
    param([scriptblock]$Assert)

    & $Assert 'secure platform config skips blank optional protected values' {
        Import-Module (Join-Path $PSScriptRoot '..\setup\Form-Runner.psm1') -Force
        $module = Get-Module Form-Runner
        $configDir = Join-Path $env:TEMP ('simple-acme-secure-config-' + [Guid]::NewGuid().ToString('N'))
        try {
            & $module {
                param([string]$ConfigDir)
                Save-SecurePlatformConfig -ConfigDir $ConfigDir -Values @{
                    DOMAINS = 'itsecured.nl'
                    ACME_DIRECTORY = 'https://test-acme.networking4all.com/dv'
                    ACME_KID = 'kid-value'
                    ACME_HMAC_SECRET = 'hmac-value'
                    ACME_PFX_PASSWORD = ''
                    ACME_RSA_KEY_SIZE = ''
                    ACME_ACCOUNT_NAME = ''
                }
            } $configDir

            if (-not (Test-Path -LiteralPath (Join-Path $configDir 'credentials.sec'))) { throw 'credentials.sec was not written.' }
            if (-not (Test-Path -LiteralPath (Join-Path $configDir 'env.secure'))) { throw 'env.secure was not written.' }
            $credentialText = Get-Content -LiteralPath (Join-Path $configDir 'credentials.sec') -Raw
            $envText = Get-Content -LiteralPath (Join-Path $configDir 'env.secure') -Raw
            if ($credentialText -match 'ACME_PFX_PASSWORD') { throw 'Blank ACME_PFX_PASSWORD should not be stored.' }
            if ($envText -match 'ACME_RSA_KEY_SIZE|ACME_ACCOUNT_NAME') { throw 'Blank optional env values should not be stored.' }
        } finally {
            Remove-Item -LiteralPath $configDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
