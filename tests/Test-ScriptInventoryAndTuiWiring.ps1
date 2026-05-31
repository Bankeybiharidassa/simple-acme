function Invoke-TestScriptInventoryAndTuiWiring {
    param([scriptblock]$Assert)
    & $Assert 'phase-1 scripts are wired or advanced' {
        $setup = @(
            Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\setup\Form-Runner.psm1')
            Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\setup\Connector-Registry.ps1')
        ) -join "`n"
        foreach($name in @('cert2rds.ps1','deploy-rds-farm.ps1','cert2iis.ps1','cert2mail.ps1','cert2fw.ps1','cert2waf.ps1')) {
            if ($setup -notmatch [regex]::Escape($name)) { throw "missing wiring for $name" }
        }
    }
}
