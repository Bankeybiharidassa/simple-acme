param(
    [Parameter(Mandatory)]
    [string]$CertThumbprint,
    [string]$ConfigDir = $env:CERTIFICATE_CONFIG_DIR,
    [string]$ConfigFile = '',
    [string]$RenewalId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../core/connector-core.psm1') -Force

$mapping = $null
try {
    $resolvedConfigDir = if ($PSBoundParameters.ContainsKey('ConfigDir')) { [string]$ConfigDir } else { Resolve-ConnectorConfigDir -ConfigFile $ConfigFile -FallbackConfigDir $ConfigDir }
    $mapping = Resolve-RenewalMapping -ConfigDir $resolvedConfigDir -RenewalId $RenewalId
} catch {
    Write-ConnectorLog -Component 'cert2waf' -Action 'mapping' -Target 'generic-waf-hook' -Result 'info' -Details @{ message = $_.Exception.Message } -EmitConsole
}
$endpointsProperty = if ($null -ne $mapping -and $null -ne $mapping.PSObject.Properties['endpoints']) { $mapping.PSObject.Properties['endpoints'].Value } else { $null }
$endpoints = if ($null -ne $endpointsProperty -and @($endpointsProperty).Count -gt 0) {
    @($endpointsProperty)
} else {
    @([pscustomobject]@{ host = $(if ([string]::IsNullOrWhiteSpace([string]$env:COMPUTERNAME)) { 'local-waf-hook' } else { [string]$env:COMPUTERNAME }); method = 'local' })
}
$stateDir = Join-Path $PSScriptRoot '..\..\runtime\connector-state'
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

$apply = {
    param($endpoint, $cert, $storePath)
    $null = $storePath
    if ([string]::IsNullOrWhiteSpace([string]$endpoint.host)) { throw 'Endpoint host is required.' }
    $record = [ordered]@{ connector='waf'; host=[string]$endpoint.host; thumbprint=[string]$cert.Thumbprint; updatedAt=(Get-Date).ToUniversalTime().ToString('o') }
    $path = Join-Path $stateDir ("waf-{0}.json" -f ([string]$endpoint.host).ToLowerInvariant())
    ($record | ConvertTo-Json -Depth 4 -Compress) | Set-Content -LiteralPath $path -Encoding UTF8
    Write-ConnectorLog -Component 'cert2waf' -Action 'apply' -Target ([string]$endpoint.host) -Result 'success' -Details @{ stateFile = $path; thumbprint = $cert.Thumbprint } -EmitConsole
}

$verify = {
    param($endpoint, $cert)
    $path = Join-Path $stateDir ("waf-{0}.json" -f ([string]$endpoint.host).ToLowerInvariant())
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $payload = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    return ([string]$payload.thumbprint -eq [string]$cert.Thumbprint)
}

Invoke-ConnectorPipeline -CertThumbprint $CertThumbprint -Apply $apply -Verify $verify -Endpoints $endpoints
exit 0
