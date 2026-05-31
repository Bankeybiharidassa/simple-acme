Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


function New-ConnectorError {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message
    )
    return ('[{0}] {1}' -f $Code, $Message)
}


function Assert-RequiredString {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Code
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw (New-ConnectorError -Code $Code -Message ("{0} is required and cannot be empty." -f $Name))
    }

    return $Value
}

function Assert-CertThumbprint {
    param([Parameter(Mandatory)][string]$CertThumbprint)

    $required = Assert-RequiredString -Value $CertThumbprint -Name 'CertThumbprint' -Code 'CERT_THUMBPRINT_REQUIRED'
    $normalized = ($required -replace '\s','').ToUpperInvariant()
    if ($normalized -notmatch '^[A-F0-9]{40}$') {
        throw (New-ConnectorError -Code 'CERT_THUMBPRINT_INVALID' -Message "CertThumbprint '$CertThumbprint' is not a valid SHA-1 thumbprint.")
    }
    return $normalized
}

function Get-CertificateByThumbprint {
    param([Parameter(Mandatory)][string]$Thumbprint)

    $normalized = ($Thumbprint -replace '\s','').ToUpperInvariant()
    $stores = @('Cert:\LocalMachine\WebHosting','Cert:\LocalMachine\My')
    foreach ($store in $stores) {
        $cert = Get-ChildItem -Path $store -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $normalized } | Select-Object -First 1
        if ($null -ne $cert) {
            return [pscustomobject]@{ Certificate = $cert; StorePath = $store }
        }
    }

    throw "Certificate with thumbprint '$Thumbprint' was not found in WebHosting or My stores."
}

function Test-ThumbprintFormat {
    param([Parameter(Mandatory)][string]$Thumbprint)
    $normalized = ($Thumbprint -replace '\s','').ToUpperInvariant()
    return ($normalized -match '^[A-F0-9]{40}$')
}

function Ensure-CertificateInMyStore {
    param(
        [Parameter(Mandatory)]$Certificate,
        [Parameter(Mandatory)][string]$StorePath
    )

    if ($StorePath -eq 'Cert:\LocalMachine\My') {
        return [pscustomobject]@{ Certificate = $Certificate; StorePath = $StorePath }
    }

    if ($StorePath -ne 'Cert:\LocalMachine\WebHosting') {
        throw "Unsupported source store '$StorePath'."
    }

    $targetStorePath = 'Cert:\LocalMachine\My'
    $existing = Get-ChildItem -Path $targetStorePath -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $Certificate.Thumbprint } | Select-Object -First 1
    if ($null -ne $existing) {
        return [pscustomobject]@{ Certificate = $existing; StorePath = $targetStorePath }
    }

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My','LocalMachine')
    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($Certificate)
    } finally {
        $store.Close()
    }

    $copied = Get-ChildItem -Path $targetStorePath -ErrorAction Stop | Where-Object { $_.Thumbprint -eq $Certificate.Thumbprint } | Select-Object -First 1
    if ($null -eq $copied) {
        throw "Failed to normalize certificate into LocalMachine\\My for thumbprint '$($Certificate.Thumbprint)'."
    }

    return [pscustomobject]@{ Certificate = $copied; StorePath = $targetStorePath }
}


function Read-ConnectorDeploymentConfigFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return @{} }
    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "Deployment config file not found: $resolvedPath. Re-run setup or pass explicit connector parameters."
    }

    $extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
    if ($extension -eq '.json') {
        $json = Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $result = @{}
        foreach ($prop in $json.PSObject.Properties) { $result[$prop.Name.ToUpperInvariant()] = [string]$prop.Value }
        return $result
    }

    $values = @{}
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadAllLines($resolvedPath)) {
        $lineNo++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trimmed = $line.TrimStart()
        if ($trimmed.StartsWith('#')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { throw "Invalid deployment config line $lineNo in '$resolvedPath'. Expected KEY=VALUE format." }
        $key = $line.Substring(0, $idx).Trim().ToUpperInvariant()
        $value = $line.Substring($idx + 1)
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) { $value = $value.Substring(1, $value.Length - 2) }
        if ($values.ContainsKey($key)) { throw "Duplicate deployment config key '$key' found at line $lineNo in '$resolvedPath'." }
        $values[$key] = $value
    }
    return $values
}

function Resolve-ConnectorConfigValue {
    param(
        [hashtable]$Config,
        [string[]]$Keys,
        [string]$Fallback = ''
    )

    foreach ($key in $Keys) {
        $normalizedKey = $key.ToUpperInvariant()
        if ($Config.ContainsKey($normalizedKey) -and -not [string]::IsNullOrWhiteSpace([string]$Config[$normalizedKey])) { return [string]$Config[$normalizedKey] }
    }
    return $Fallback
}

function Resolve-ConnectorConfigDir {
    param(
        [string]$ExplicitConfigDir = '',
        [string]$ConfigFile = '',
        [string]$FallbackConfigDir = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitConfigDir)) { return [string]$ExplicitConfigDir }
    $config = Read-ConnectorDeploymentConfigFile -Path $ConfigFile
    $fromConfig = Resolve-ConnectorConfigValue -Config $config -Keys @('CONFIG_DIR','CERTIFICATE_CONFIG_DIR')
    if (-not [string]::IsNullOrWhiteSpace($fromConfig)) { return $fromConfig }
    if (-not [string]::IsNullOrWhiteSpace($FallbackConfigDir)) { return [string]$FallbackConfigDir }
    throw 'Connector config directory is required. Pass -ConfigDir, set CONFIG_DIR or CERTIFICATE_CONFIG_DIR in -ConfigFile, or set CERTIFICATE_CONFIG_DIR in the scheduled-task environment.'
}

function Resolve-RenewalMapping {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [string]$RenewalId = ''
    )

    $candidatePaths = @(
        (Join-Path $ConfigDir 'mappings.json'),
        (Join-Path $ConfigDir 'mapping.json')
    )
    $mappingPath = @($candidatePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if ($mappingPath.Count -lt 1) {
        throw "Mapping file not found. Expected one of: $($candidatePaths -join ', ')"
    }
    $mappingPath = [string]$mappingPath[0]

    $mappings = @(Get-Content -Raw -LiteralPath $mappingPath -Encoding UTF8 | ConvertFrom-Json)
    if ([string]::IsNullOrWhiteSpace($RenewalId)) {
        return $mappings | Select-Object -First 1
    }

    $mapping = @($mappings | Where-Object { $_.renewalId -eq $RenewalId }) | Select-Object -First 1
    if ($null -eq $mapping) {
        throw "No mapping found for renewalId '$RenewalId'."
    }

    return $mapping
}

function Invoke-EndpointAction {
    param(
        [Parameter(Mandatory)][object]$Endpoint,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $method = ([string]$Endpoint.method).ToLowerInvariant()
    $hostName = [string]$Endpoint.host
    if ([string]::IsNullOrWhiteSpace($hostName)) { throw 'Endpoint.host is required.' }

    switch ($method) {
        'winrm' {
            Invoke-Command -ComputerName $hostName -ScriptBlock $Action -ErrorAction Stop
        }
        'local' {
            & $Action
        }
        default {
            throw "Unsupported endpoint method '$method' for host '$hostName'."
        }
    }
}

function Invoke-ConnectorPipeline {
    param(
        [Parameter(Mandatory)][string]$CertThumbprint,
        [Parameter(Mandatory)][scriptblock]$Apply,
        [Parameter(Mandatory)][scriptblock]$Verify,
        [object[]]$Endpoints = @([pscustomobject]@{ host = $env:COMPUTERNAME; method = 'local' })
    )

    $normalizedThumbprint = Assert-CertThumbprint -CertThumbprint $CertThumbprint

    $found = Get-CertificateByThumbprint -Thumbprint $normalizedThumbprint
    if ($null -eq $found.Certificate) { throw 'Certificate lookup returned null.' }
    $normalized = Ensure-CertificateInMyStore -Certificate $found.Certificate -StorePath $found.StorePath

    $failures = @()
    foreach ($endpoint in @($Endpoints)) {
        try {
            & $Apply $endpoint $normalized.Certificate $normalized.StorePath
            $ok = & $Verify $endpoint $normalized.Certificate
            if (-not $ok) { throw "Verification failed for endpoint '$($endpoint.host)'." }
        } catch {
            $failures += [pscustomobject]@{ host = [string]$endpoint.host; error = $_.Exception.Message }
        }
    }

    if ($failures.Count -gt 0) {
        $details = ($failures | ForEach-Object { "[$($_.host)] $($_.error)" }) -join '; '
        throw "Connector deployment failed (no partial success allowed): $details"
    }
}

function Write-ConnectorLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][ValidateSet('success','fail','info')][string]$Result,
        [hashtable]$Details = @{},
        [string]$LogDir = '',
        [switch]$EmitConsole
    )

    $resolvedLogDir = if ([string]::IsNullOrWhiteSpace($LogDir)) {
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { 'C:\ProgramData\acme-connector\logs' } else { Join-Path $PSScriptRoot '..\logs' }
    } else { $LogDir }
    if (-not (Test-Path -LiteralPath $resolvedLogDir)) {
        New-Item -Path $resolvedLogDir -ItemType Directory -Force | Out-Null
    }
    $file = Join-Path $resolvedLogDir ("connector-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    $entry = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        component = $Component
        action    = $Action
        target    = $Target
        result    = $Result
        details   = $Details
    }
    $json = $entry | ConvertTo-Json -Depth 8 -Compress
    Add-Content -Path $file -Value $json -Encoding UTF8
    if ($EmitConsole) { Write-Host $json }
}

$FunctionsToExport = New-Object System.Collections.Generic.List[string]
$FunctionsToExport.Add('New-ConnectorError')
$FunctionsToExport.Add('Assert-RequiredString')
$FunctionsToExport.Add('Assert-CertThumbprint')
$FunctionsToExport.Add('Get-CertificateByThumbprint')
$FunctionsToExport.Add('Test-ThumbprintFormat')
$FunctionsToExport.Add('Ensure-CertificateInMyStore')
$FunctionsToExport.Add('Resolve-RenewalMapping')
$FunctionsToExport.Add('Resolve-ConnectorConfigDir')
$FunctionsToExport.Add('Resolve-ConnectorConfigValue')
$FunctionsToExport.Add('Read-ConnectorDeploymentConfigFile')
$FunctionsToExport.Add('Invoke-EndpointAction')
$FunctionsToExport.Add('Invoke-ConnectorPipeline')
$FunctionsToExport.Add('Write-ConnectorLog')

$MissingExports = @()
foreach ($fn in $FunctionsToExport) {
    if (-not (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) {
        $MissingExports += $fn
    }
}

if ($MissingExports.Count -gt 0) {
    throw ('Export list contains missing function(s): ' + ($MissingExports -join ', '))
}

Export-ModuleMember -Function ([string[]]$FunctionsToExport.ToArray())
