Set-StrictMode -Version Latest

function Invoke-TestScriptsSyntax {
    param([scriptblock]$Assert)

    & $Assert 'cert2rds has mandatory positional thumbprint parameter' {
        $txt = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Scripts\cert2rds.ps1') -Raw
        if ($txt -notmatch 'Position\s*=\s*0') { throw 'Missing Position=0 for thumbprint parameter.' }
        if ($txt -notmatch 'Mandatory\s*=\$true') { throw 'Thumbprint parameter is not mandatory.' }
    }

    & $Assert 'cert2rds checks My and WebHosting stores' {
        $txt = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Scripts\cert2rds.ps1') -Raw
        if ($txt -notmatch 'Cert:\\LocalMachine\\My') { throw 'Missing My store check.' }
        if ($txt -notmatch 'Cert:\\LocalMachine\\WebHosting') { throw 'Missing WebHosting store check.' }
    }

    & $Assert 'cert2rds sets all expected RDS roles' {
        $txt = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Scripts\cert2rds.ps1') -Raw
        foreach ($role in @('RDGateway','RDWebAccess','RDPublishing','RDRedirector')) {
            if ($txt -notmatch [regex]::Escape($role)) { throw "Missing role $role" }
        }
    }
}
