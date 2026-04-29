Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\core\Simple-Acme-Reconciler.psm1') -Force

function Invoke-TestSecretMasking {
    param([scriptblock]$Assert)
    & $Assert 'masked argument output does not leak eab key secret' {
        $secret = 'DO_NOT_LEAK_TEST_SECRET_12345'
        $masked = Get-MaskedWacsArgumentsText -Args @('--accepttos','--eab-key',$secret,'--baseuri','https://test-acme.networking4all.com/dv')
        if ($masked -match [regex]::Escape($secret)) { throw 'Secret leaked in masked output.' }
        if ($masked -notmatch '--eab-key <hidden>') { throw 'Expected hidden eab marker missing.' }
    }
}
