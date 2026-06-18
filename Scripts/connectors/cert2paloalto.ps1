#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CertThumbprint = '',
    [string]$CertCommonName = '',
    [string]$CacheFile = '',
    [string]$PfxPath = '',
    [string]$CachePassword = '',
    [SecureString]$PfxPassword,
    [string]$CertPath = '',
    [string]$KeyPath = '',
    [string]$ConfigDir = $env:CERTIFICATE_CONFIG_DIR,
    [string]$DeviceId = 'paloalto-firewall',
    [string]$Firewall = '',
    [ValidateRange(1, 65535)][int]$Port = 443,
    [string]$ApiKey = '',
    [string]$ApiKeySecureFile = '',
    [string]$CertName = '',
    [string]$BindingType = '',
    [string]$BindingTarget = '',
    [string]$Vsys = '',
    [string]$KeyPassphrase = '',
    [switch]$SkipCertificateCheck,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptsRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $scriptsRoot -Parent

$clavisterModulePath = Join-Path $scriptsRoot 'Modules/SimpleAcme.Clavister/SimpleAcme.Clavister.psd1'
Import-Module $clavisterModulePath -Force

$configStorePath = Join-Path $repoRoot 'core/Config-Store.psm1'
if (Test-Path -LiteralPath $configStorePath -PathType Leaf) {
    Import-Module $configStorePath -Force
}

function ConvertTo-PaloAltoHookBoolean {
    param([object]$Value, [bool]$Default = $false)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
    switch ($text.ToLowerInvariant()) {
        { $_ -in @('1','true','yes','y','on') } { return $true }
        { $_ -in @('0','false','no','n','off') } { return $false }
        default { return $Default }
    }
}

function Resolve-PaloAltoHookConfigDir {
    if (-not [string]::IsNullOrWhiteSpace($ConfigDir)) { return [IO.Path]::GetFullPath($ConfigDir) }
    $envConfigDir = [Environment]::GetEnvironmentVariable('CERTIFICATE_CONFIG_DIR')
    if (-not [string]::IsNullOrWhiteSpace($envConfigDir)) { return [IO.Path]::GetFullPath($envConfigDir) }
    return [IO.Path]::GetFullPath((Join-Path $repoRoot 'config'))
}

function Get-PaloAltoHookProfileSettings {
    if (-not (Get-Command Get-DeviceConfig -CommandType Function -ErrorAction SilentlyContinue)) { return @{} }
    $resolvedConfigDir = Resolve-PaloAltoHookConfigDir
    $profile = Get-DeviceConfig -DeviceId $DeviceId -ConfigDir $resolvedConfigDir
    if ($null -eq $profile) {
        $profiles = @(Get-AllDeviceConfigs -ConfigDir $resolvedConfigDir -SkipIntegrityFailures | Where-Object {
            $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]$_['connector_type'] -eq 'paloalto'
        } | Select-Object -First 1)
        if ($profiles.Count -gt 0) { $profile = $profiles[0] }
    }
    if ($null -eq $profile -or -not ($profile -is [System.Collections.IDictionary]) -or -not $profile.ContainsKey('settings')) { return @{} }
    if (-not ($profile['settings'] -is [System.Collections.IDictionary])) { return @{} }
    return $profile['settings']
}

function Get-PaloAltoProfileValue {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Key,
        [string]$Default = ''
    )
    if ($Settings.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$Settings[$Key])) { return [string]$Settings[$Key] }
    return $Default
}

function ConvertTo-PaloAltoCertificateName {
    param([string]$Name)
    $candidate = ([string]$Name).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = 'simple-acme-certificate' }
    $candidate = $candidate -replace '^\*\.', 'wildcard_'
    $candidate = $candidate -replace '[^a-zA-Z0-9._-]+', '_'
    $candidate = $candidate.Trim('._-')
    if ([string]::IsNullOrWhiteSpace($candidate)) { return 'simple-acme-certificate' }
    return $candidate
}

function ConvertFrom-PaloAltoSecureString {
    param([SecureString]$SecureString)
    if ($null -eq $SecureString) { return '' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}

function Apply-PaloAltoHookProfileSettings {
    $settings = Get-PaloAltoHookProfileSettings
    if ($settings.Count -eq 0) { return }

    if ([string]::IsNullOrWhiteSpace($Firewall)) { $script:Firewall = Get-PaloAltoProfileValue -Settings $settings -Key 'host' }
    if (-not $PSBoundParameters.ContainsKey('Port')) {
        $profilePort = Get-PaloAltoProfileValue -Settings $settings -Key 'port' -Default '443'
        if (-not [string]::IsNullOrWhiteSpace($profilePort)) { $script:Port = [int]$profilePort }
    }
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { $script:ApiKey = Get-PaloAltoProfileValue -Settings $settings -Key 'api_key' }
    if ([string]::IsNullOrWhiteSpace($CertName)) { $script:CertName = Get-PaloAltoProfileValue -Settings $settings -Key 'certificate_name' }
    if ([string]::IsNullOrWhiteSpace($BindingType)) { $script:BindingType = Get-PaloAltoProfileValue -Settings $settings -Key 'binding_type' -Default 'management' }
    if ([string]::IsNullOrWhiteSpace($BindingTarget)) { $script:BindingTarget = Get-PaloAltoProfileValue -Settings $settings -Key 'binding_target' }
    if ([string]::IsNullOrWhiteSpace($Vsys)) { $script:Vsys = Get-PaloAltoProfileValue -Settings $settings -Key 'vsys' -Default 'vsys1' }
    if ([string]::IsNullOrWhiteSpace($KeyPassphrase)) { $script:KeyPassphrase = Get-PaloAltoProfileValue -Settings $settings -Key 'key_passphrase' }
    if (-not $PSBoundParameters.ContainsKey('SkipCertificateCheck')) {
        $script:SkipCertificateCheck = ConvertTo-PaloAltoHookBoolean -Value (Get-PaloAltoProfileValue -Settings $settings -Key 'skip_certificate_check') -Default $true
    }
}

Apply-PaloAltoHookProfileSettings

if ([string]::IsNullOrWhiteSpace($Firewall)) { throw 'Palo Alto firewall address is missing. Configure the Palo Alto device profile before running the hook.' }
if ([string]::IsNullOrWhiteSpace($ApiKey) -and [string]::IsNullOrWhiteSpace($ApiKeySecureFile)) { throw 'Palo Alto API key is missing. Configure and test the Palo Alto device profile before running the hook.' }
if ([string]::IsNullOrWhiteSpace($CertName)) { $CertName = ConvertTo-PaloAltoCertificateName -Name $CertCommonName }
if ([string]::IsNullOrWhiteSpace($BindingType)) { $BindingType = 'management' }
if ([string]::IsNullOrWhiteSpace($Vsys)) { $Vsys = 'vsys1' }

$plainPfxPassword = if ($null -ne $PfxPassword) { ConvertFrom-PaloAltoSecureString -SecureString $PfxPassword } else { [string]$CachePassword }
$effectivePfxPath = if (-not [string]::IsNullOrWhiteSpace($PfxPath)) { $PfxPath } else { $CacheFile }
$tempDirectory = ''
$sourceCertPath = $CertPath
$sourceKeyPath = $KeyPath

try {
    if ([string]::IsNullOrWhiteSpace($sourceCertPath) -or [string]::IsNullOrWhiteSpace($sourceKeyPath)) {
        if ([string]::IsNullOrWhiteSpace($effectivePfxPath)) {
            throw 'Palo Alto certificate source is missing. Provide -PfxPath/-CacheFile or -CertPath plus -KeyPath.'
        }
        $pem = Convert-ClavisterPfxToPemFiles -PfxPath $effectivePfxPath -Password $plainPfxPassword
        $tempDirectory = [string]$pem.TempDirectory
        $sourceCertPath = [string]$pem.CertificatePath
        $sourceKeyPath = [string]$pem.KeyPath
    }

    $deployPath = Join-Path $scriptsRoot 'deploy-paloalto.ps1'
    if (-not (Test-Path -LiteralPath $deployPath -PathType Leaf)) { throw "Palo Alto deploy script not found: $deployPath" }

    $deployParams = @{
        Firewall = $Firewall
        Port = $Port
        CertName = $CertName
        CertPath = $sourceCertPath
        KeyPath = $sourceKeyPath
        BindingType = $BindingType
        BindingTarget = $BindingTarget
        Vsys = $Vsys
        TimeoutSeconds = $TimeoutSeconds
    }
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) { $deployParams.ApiKey = $ApiKey }
    if (-not [string]::IsNullOrWhiteSpace($ApiKeySecureFile)) { $deployParams.ApiKeySecureFile = $ApiKeySecureFile }
    if (-not [string]::IsNullOrWhiteSpace($KeyPassphrase)) { $deployParams.KeyPassphrase = $KeyPassphrase }
    if ($SkipCertificateCheck) { $deployParams.SkipCertificateCheck = $true }
    if ($WhatIfPreference) { $deployParams.WhatIf = $true }

    & $deployPath @deployParams
    exit $LASTEXITCODE
} finally {
    $plainPfxPassword = $null
    if (-not [string]::IsNullOrWhiteSpace($tempDirectory) -and (Test-Path -LiteralPath $tempDirectory -PathType Container)) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}
