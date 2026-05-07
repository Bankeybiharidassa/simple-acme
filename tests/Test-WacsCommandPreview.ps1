function Invoke-TestWacsCommandPreview {
    param([scriptblock]$Assert)
    & $Assert 'preview includes baseuri and masked eab' {
        $setup = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\setup\Form-Runner.psm1')
        $certificateSetup = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\certificate-setup.ps1')
        $reconciler = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\core\Simple-Acme-Reconciler.psm1')
        if ($setup -notmatch '--baseuri') { throw 'preview missing --baseuri' }
        if ($setup -notmatch '--pfxfilepath') { throw 'preview missing pfxfilepath' }
        if ($setup -notmatch '--pfxpassword <hidden>') { throw 'preview missing masked pfx password' }
        if ($certificateSetup -notmatch 'Get-WacsIssueArguments') { throw 'initial reconcile preview does not use WACS issue argument builder' }
        if ($certificateSetup -notmatch 'ConvertTo-WacsCommandLineText') { throw 'initial reconcile preview does not format WACS command line' }
        if ($reconciler -notmatch "\$arg -eq '--pfxpassword'") { throw 'masking does not include pfxpassword' }
        if ($setup -notmatch '--eab-key <hidden>') { throw 'preview missing secret masking' }
    }
}
