Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\core\Simple-Acme-Reconciler.psm1') -Force

function Invoke-TestCsrExecutionPlan {
    param([scriptblock]$Assert)
    & $Assert 'ec with fallback disabled produces ec only' {
        $plan = Get-CsrExecutionPlan -EnvValues @{ ACME_CSR_ALGORITHM='ec'; ACME_ALLOW_CSR_FALLBACK='0' }
        if (@($plan).Count -ne 1 -or $plan[0] -ne 'ec') { throw 'Unexpected plan for ec/0' }
    }
    & $Assert 'ec with fallback enabled produces ec then rsa' {
        $plan = Get-CsrExecutionPlan -EnvValues @{ ACME_CSR_ALGORITHM='ec'; ACME_ALLOW_CSR_FALLBACK='1' }
        if ((@($plan) -join ',') -ne 'ec,rsa') { throw 'Unexpected plan for ec/1' }
    }
}
