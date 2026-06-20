Set-StrictMode -Version Latest

function Invoke-TestNoPlaceholdersInRuntimeMenus {
    param([scriptblock]$Assert)
    & $Assert 'phase-1 menu text has no placeholder markers' {
        $targets = @(
            (Join-Path $PSScriptRoot '..\certificate-setup.ps1'),
            (Join-Path $PSScriptRoot '..\setup\Form-Runner.psm1'),
            (Join-Path $PSScriptRoot '..\certificate-simple-acme-reconcile.ps1')
        )
        $bad = @('not implemented yet','coming soon')
        foreach ($t in $targets) {
            $txt = Get-Content -LiteralPath $t -Raw
            foreach ($b in $bad) {
                if ($txt.ToLowerInvariant().Contains($b)) { throw "Placeholder marker '$b' found in $t" }
            }
        }
    }

    & $Assert 'top-level menu exposes latest log viewer' {
        $menu = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\setup\Menu-Tree.ps1') -Raw
        $setup = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\certificate-setup.ps1') -Raw
        if (-not $menu.Contains("Label='View latest log'; Key='view-latest-log'")) { throw 'Top-level View latest log menu item is missing.' }
        if (-not $setup.Contains("'view-latest-log'")) { throw 'View latest log action is not routed in certificate-setup.ps1.' }
        if (-not $setup.Contains('Invoke-ViewLogsDiagnostics -ProjectRoot $PSScriptRoot')) { throw 'View latest log action must open the log diagnostics viewer.' }
    }
}
