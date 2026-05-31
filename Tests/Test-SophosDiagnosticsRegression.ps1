Set-StrictMode -Version Latest

function Invoke-TestSophosDiagnosticsRegression {
    param([scriptblock]$Assert)

    & $Assert 'Sophos diagnostics builds result from plain check array' {
        $path = Join-Path $PSScriptRoot '..\setup\Sophos-Runner.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        if ($raw -notmatch '\$checkArray\s*=\s*@\(\$checks\.ToArray\(\)\)') {
            throw 'Sophos diagnostics does not normalize Generic.List checks before building result object.'
        }
        if ($raw -notmatch 'Checks\s*=\s*\$checkArray') {
            throw 'Sophos diagnostics result does not use the normalized check array.'
        }
    }
}
