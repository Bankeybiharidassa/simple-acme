Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\core\Simple-Acme-Reconciler.psm1') -Force

function Invoke-TestWacsResolution {
    param([scriptblock]$Assert)

    & $Assert 'resolver prefers ACME_WACS_PATH when valid' {
        $tmp = Join-Path $env:TEMP ('wacs-'+[guid]::NewGuid().ToString('N')+'.exe')
        Set-Content -LiteralPath $tmp -Value 'stub'
        try {
            $resolved = Resolve-WacsExecutable -EnvValues @{ ACME_WACS_PATH = $tmp }
            if ($resolved -ne (Convert-Path $tmp)) { throw 'Configured path did not win.' }
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }
}
