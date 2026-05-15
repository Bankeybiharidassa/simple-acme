Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hasLiveNetScaler = -not [string]::IsNullOrWhiteSpace($env:NETSCALER_HOST) -and`
    -not [string]::IsNullOrWhiteSpace($env:NETSCALER_USER) -and`
    -not [string]::IsNullOrWhiteSpace($env:NETSCALER_PASSWORD) -and`
    -not [string]::IsNullOrWhiteSpace($env:NETSCALER_TEST_VSERVER)

BeforeAll {
$script:repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')
    $script:modulePath = Join-Path $script:repoRoot 'Scripts/Modules/SimpleAcme.Netscaler/SimpleAcme.Netscaler.psd1'
}

Describe 'NetScaler live integration' -Skip:(-not $hasLiveNetScaler) {
    It 'can connect, read HA and vServer bindings, then disconnect' {
        Import-Module $script:modulePath -Force
        Connect-NetscalerNitroSession -HostName $env:NETSCALER_HOST -Username $env:NETSCALER_USER -Password $env:NETSCALER_PASSWORD
        try {
            { Get-NetscalerHAState } | Should -Not -Throw
            { Get-NetscalerSslVServerCertBindings -VServerName $env:NETSCALER_TEST_VSERVER } | Should -Not -Throw
        } finally {
            Disconnect-NetscalerNitroSession
        }
    }
}