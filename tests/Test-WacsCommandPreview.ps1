function Invoke-TestWacsCommandPreview {
    param([scriptblock]$Assert)
    & $Assert 'preview includes baseuri and masked eab' {
        $setup = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\setup\Form-Runner.psm1')
        if ($setup -notmatch '--baseuri') { throw 'preview missing --baseuri' }
        if ($setup -notmatch '--eab-key <hidden>') { throw 'preview missing secret masking' }
    }
}
