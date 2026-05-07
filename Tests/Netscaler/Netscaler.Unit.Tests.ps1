Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-TestNetscalerUnit {
    param([scriptblock]$Assert)

    $repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')
    $modulePath = Join-Path $repoRoot 'Scripts/Modules/SimpleAcme.Netscaler/SimpleAcme.Netscaler.psd1'
    $scriptPath = Join-Path $repoRoot 'Scripts/cert2netscaler.ps1'

    & $Assert 'NetScaler module imports' {
        Import-Module $modulePath -Force
        foreach ($name in @('Connect-NetscalerNitroSession','Invoke-NetscalerNitroRequest','Assert-NetscalerPrimary','Set-NetscalerSslVServerCertBinding')) {
            if (-not (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) {
                throw "Missing exported function $name."
            }
        }
    }

    & $Assert 'Certificate file validation fails before API interaction' {
        Import-Module $modulePath -Force
        try {
            Test-NetscalerLocalCertificateFiles -CertPath (Join-Path $PSScriptRoot 'missing.crt') -KeyPath (Join-Path $PSScriptRoot 'missing.key') | Out-Null
            throw 'Validation unexpectedly succeeded.'
        } catch {
            if ($_.Exception.Message -notmatch 'CertPath') { throw }
        }
    }

    & $Assert 'HA primary enforcement stops on secondary node' {
        Import-Module $modulePath -Force
        $ha = [pscustomobject]@{ HAConfigured = $true; HAMasterState = 'SECONDARY'; Raw = @() }
        try {
            Assert-NetscalerPrimary -HAState $ha -RequirePrimary $true
            throw 'HA enforcement unexpectedly succeeded.'
        } catch {
            if ($_.Exception.Message -notmatch 'not PRIMARY') { throw }
        }
    }

    & $Assert 'HA primary enforcement can be explicitly disabled' {
        Import-Module $modulePath -Force
        $ha = [pscustomobject]@{ HAConfigured = $true; HAMasterState = 'SECONDARY'; Raw = @() }
        Assert-NetscalerPrimary -HAState $ha -RequirePrimary $false
    }

    & $Assert 'Script supports ShouldProcess and WhatIf' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        if ($text -notmatch 'SupportsShouldProcess\s*=\s*\$true') { throw 'Script does not enable SupportsShouldProcess.' }
        if ($text -notmatch 'ShouldProcess') { throw 'Script does not call ShouldProcess.' }
    }

    & $Assert 'Binding logic avoids duplicate binds and preserves CA plus SNI metadata' {
        $text = Get-Content -LiteralPath (Join-Path $repoRoot 'Scripts/Modules/SimpleAcme.Netscaler/NetscalerNitro.psm1') -Raw
        if ($text -notmatch '\$alreadyBound\.Count\s*-eq\s*0') { throw 'Binding logic does not check for existing certkey binding.' }
        if ($text -notmatch 'snicert') { throw 'Binding replacement logic does not account for SNI bindings.' }
        if ($text -notmatch '\$_.ca') { throw 'Binding replacement logic does not account for CA bindings.' }
    }
}
