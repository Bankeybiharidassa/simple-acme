Set-StrictMode -Version Latest

function Invoke-TestUnattendedScriptHardening {
    param([scriptblock]$Assert)

    & $Assert 'deploy-rds-farm has no interactive credential prompt' {
        $txt = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1') -Raw
        if ($txt -match 'Get-Credential') { throw 'Interactive Get-Credential is not allowed.' }
        if ($txt -notmatch 'SessionCredential') { throw 'SessionCredential parameter missing.' }
    }

    & $Assert 'deploy-rds-sessionhost accepts deterministic password token instead of SecureString remoting' {
        $txt = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Scripts\deploy-rds-sessionhost.ps1') -Raw
        if ($txt -match '\[System\.Security\.SecureString\]\$PfxPassword') { throw 'Legacy SecureString remoting parameter still present.' }
        if ($txt -notmatch 'PfxPasswordToken') { throw 'PfxPasswordToken parameter missing.' }
    }

    & $Assert 'connector scripts do real apply and verify instead of staged placeholders' {
        foreach ($file in @('cert2fw.ps1','cert2waf.ps1','cert2mail.ps1')) {
            $txt = Get-Content -LiteralPath (Join-Path $PSScriptRoot ('..\Scripts\connectors\' + $file)) -Raw
            if ($txt -match 'staged certificate') { throw "$file still contains staged placeholder text." }
            if ($txt -notmatch 'Write-ConnectorLog') { throw "$file missing structured logging." }
            if ($txt -notmatch 'ConvertFrom-Json') { throw "$file missing verify-state logic." }
        }
    }
}
