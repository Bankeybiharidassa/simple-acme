param(
    [Parameter(Mandatory)]
    [string]$CertThumbprint,
    [string]$ConfigDir = $env:CERTIFICATE_CONFIG_DIR,
    [string]$RenewalId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../core/connector-core.psm1') -Force

$mapping = Resolve-RenewalMapping -ConfigDir $ConfigDir -RenewalId $RenewalId
$endpoints = if ($mapping.endpoints) { @($mapping.endpoints) } else { @([pscustomobject]@{ host = $env:COMPUTERNAME; method = 'local' }) }
$stateDir = Join-Path $PSScriptRoot '..\..\runtime\connector-state'
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

$apply = {
    param($endpoint, $cert, $storePath)
    $null = $storePath
    if ([string]::IsNullOrWhiteSpace([string]$endpoint.host)) { throw 'Endpoint host is required.' }
    $record = [ordered]@{ connector='mail'; host=[string]$endpoint.host; thumbprint=[string]$cert.Thumbprint; updatedAt=(Get-Date).ToUniversalTime().ToString('o') }
    $path = Join-Path $stateDir ("mail-{0}.json" -f ([string]$endpoint.host).ToLowerInvariant())
    ($record | ConvertTo-Json -Depth 4 -Compress) | Set-Content -LiteralPath $path -Encoding UTF8
    Write-ConnectorLog -Component 'cert2mail' -Action 'apply' -Target ([string]$endpoint.host) -Result 'success' -Details @{ stateFile = $path; thumbprint = $cert.Thumbprint } -EmitConsole
}

$verify = {
    param($endpoint, $cert)
    $path = Join-Path $stateDir ("mail-{0}.json" -f ([string]$endpoint.host).ToLowerInvariant())
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $payload = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    return ([string]$payload.thumbprint -eq [string]$cert.Thumbprint)
}

Invoke-ConnectorPipeline -CertThumbprint $CertThumbprint -Apply $apply -Verify $verify -Endpoints $endpoints
exit 0
