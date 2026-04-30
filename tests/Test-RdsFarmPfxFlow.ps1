Set-StrictMode -Version Latest

function Invoke-TestRdsFarmPfxFlow {
    param([scriptblock]$Assert)

    & $Assert 'runtime directory gitignore exists' {
        $path = Join-Path $PSScriptRoot '..\runtime\.gitignore'
        if (-not (Test-Path -LiteralPath $path)) { throw 'runtime/.gitignore missing' }
    }

    & $Assert 'deploy-rds-sessionhost exits non-zero when pfx file is missing' {
        $script = Join-Path $PSScriptRoot '..\Scripts\deploy-rds-sessionhost.ps1'
        $secure = ConvertTo-SecureString -String 'dummy' -AsPlainText -Force
        & powershell -NoProfile -ExecutionPolicy Bypass -File $script '001122' 'C:\nope\missing.pfx' $secure 2>$null
        if ($LASTEXITCODE -eq 0) { throw 'Expected non-zero when pfx path missing' }
    }
}
