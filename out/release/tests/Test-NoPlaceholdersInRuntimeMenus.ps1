Set-StrictMode -Version Latest

function Invoke-TestNoPlaceholdersInRuntimeMenus {
    param([scriptblock]$Assert)
    & $Assert 'phase-1 menu text has no placeholder markers' {
        $targets = @(
            (Join-Path $PSScriptRoot '..\certificate-setup.ps1'),
            (Join-Path $PSScriptRoot '..\setup\Form-Runner.psm1'),
            (Join-Path $PSScriptRoot '..\certificate-simple-acme-reconcile.ps1')
        )
        $bad = @('not implemented yet','coming soon','placeholder')
        foreach ($t in $targets) {
            $txt = Get-Content -LiteralPath $t -Raw
            foreach ($b in $bad) {
                if ($txt.ToLowerInvariant().Contains($b)) { throw "Placeholder marker '$b' found in $t" }
            }
        }
    }
}
