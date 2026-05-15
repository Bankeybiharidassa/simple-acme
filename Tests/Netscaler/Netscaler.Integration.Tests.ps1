Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-TestNetscalerIntegration {
    param([scriptblock]$Assert)

    & $Assert 'NetScaler integration smoke test is opt-in' {
        $required = @('NETSCALER_HOST','NETSCALER_USER','NETSCALER_PASSWORD','NETSCALER_TEST_VSERVER')
        $missing = @($required | Where-Object { [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
        if ($missing.Count -gt 0) {
            Write-Host ('[SKIP] Missing integration environment variables: {0}' -f ($missing -join ', '))
            return
        }

        $repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')
        $modulePath = Join-Path $repoRoot 'Scripts/Modules/SimpleAcme.Netscaler/SimpleAcme.Netscaler.psd1'
        Import-Module $modulePath -Force

        $password = [Environment]::GetEnvironmentVariable('NETSCALER_PASSWORD')
        try {
            Connect-NetscalerNitroSession -HostName ([Environment]::GetEnvironmentVariable('NETSCALER_HOST')) -Username ([Environment]::GetEnvironmentVariable('NETSCALER_USER')) -Password $password
            $null = Invoke-NetscalerNitroRequest -Method GET -Path '/stat/hanode'
            $null = Get-NetscalerSslVServerCertBindings -VServerName ([Environment]::GetEnvironmentVariable('NETSCALER_TEST_VSERVER'))
        } finally {
            Disconnect-NetscalerNitroSession
        }
    }
}
