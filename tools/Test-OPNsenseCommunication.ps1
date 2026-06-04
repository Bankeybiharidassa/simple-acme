#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseUrl,
    [Parameter(Mandatory)][string]$ApiKey,
    [Parameter(Mandatory)][string]$ApiSecret,
    [switch]$SkipCertificateCheck,
    [ValidateRange(1, 120)][int]$TimeoutSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-OPNsenseRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$ApiSecret,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 20
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $previous = [Net.ServicePointManager]::ServerCertificateValidationCallback
    if ($SkipCertificateCheck) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }

    try {
        $pair = '{0}:{1}' -f $ApiKey, $ApiSecret
        $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
        Invoke-RestMethod -Uri $Uri -Method $Method -Headers @{ Authorization = "Basic $basic" } -TimeoutSec $TimeoutSeconds
    } finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $previous
    }
}

$base = $BaseUrl.TrimEnd('/')
$endpoint = "$base/api/core/firmware/status"
$started = Get-Date
$attempts = New-Object System.Collections.Generic.List[object]

try {
    $result = $null
    foreach ($method in @('GET', 'POST')) {
        $attemptStarted = Get-Date
        try {
            $result = Invoke-OPNsenseRequest -Uri $endpoint -Method $method -ApiKey $ApiKey -ApiSecret $ApiSecret -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
            $attempts.Add([pscustomobject]@{
                Method = $method
                Status = 'Succeeded'
                ElapsedMilliseconds = [int]((Get-Date) - $attemptStarted).TotalMilliseconds
            })
            break
        } catch {
            $attempts.Add([pscustomobject]@{
                Method = $method
                Status = 'Failed'
                ElapsedMilliseconds = [int]((Get-Date) - $attemptStarted).TotalMilliseconds
                Message = $_.Exception.Message
            })
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -in @(401, 403)) {
                throw
            }
        }
    }

    if ($null -eq $result) {
        throw "OPNsense API did not return a successful response."
    }

    [pscustomobject]@{
        Status = 'Succeeded'
        Endpoint = $endpoint
        ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
        Attempts = @($attempts.ToArray())
        Response = $result
    } | ConvertTo-Json -Depth 10
    exit 0
} catch {
    [pscustomobject]@{
        Status = 'Failed'
        Endpoint = $endpoint
        ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
        Attempts = @($attempts.ToArray())
        Message = $_.Exception.Message
    } | ConvertTo-Json -Depth 10
    exit 1
}
