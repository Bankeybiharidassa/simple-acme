function Invoke-TestWacsCommandPreview {
    param([scriptblock]$Assert)
    & $Assert 'preview includes baseuri and masked eab' {
        $certificateSetup = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\certificate-setup.ps1')
        $reconciler = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\core\Simple-Acme-Reconciler.psm1')
        Import-Module (Join-Path $PSScriptRoot '..\core\Simple-Acme-Reconciler.psm1') -Force
        $preview = Get-MaskedWacsIssueCommandPreview -EnvValues @{
            ACME_DIRECTORY = 'https://test-acme.networking4all.com/dv'
            DOMAINS = 'example.com'
            ACME_REQUIRES_EAB = '1'
            ACME_KID = 'kid-value'
            ACME_HMAC_SECRET = 'secret-value'
            ACME_STORE_PLUGIN = 'pfxfile,certificatestore'
            ACME_PFX_FILE_PATH = 'C:\certs'
            ACME_PFX_PASSWORD = 'pfx-secret'
            ACME_SCRIPT_PATH = 'C:\certificaat\Scripts\cert2rds.ps1'
            ACME_SCRIPT_PARAMETERS = '{CertThumbprint}'
        } -CsrAlgorithm 'rsa'
        if ($preview -notmatch '--baseuri') { throw 'preview missing --baseuri' }
        if ($preview -notmatch '--pfxfilepath') { throw 'preview missing pfxfilepath' }
        if ($preview -notmatch '--pfxpassword <hidden>') { throw 'preview missing masked pfx password' }
        if ($certificateSetup -notmatch 'Get-MaskedWacsIssueCommandPreview') { throw 'initial reconcile preview does not use WACS preview helper' }
        if ($reconciler -notmatch 'Get-WacsIssueArguments') { throw 'WACS preview helper does not use issue argument builder' }
        if ($reconciler -notmatch 'ConvertTo-WacsCommandLineText') { throw 'WACS preview helper does not format WACS command line' }
        if ($reconciler -notmatch '\$arg -eq ''--pfxpassword''') { throw 'masking does not include pfxpassword' }
        if ($preview -notmatch '--eab-key <hidden>') { throw 'preview missing secret masking' }
    }
}
