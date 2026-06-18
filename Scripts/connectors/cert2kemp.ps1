#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CertThumbprint = '',
    [string]$CacheFile = '',
    [string]$PfxPath = '',
    [string]$CachePassword = '',
    [SecureString]$PfxPassword,
    [string]$PemBundlePath = '',
    [string]$CertPath = '',
    [string]$KeyPath = '',
    [string]$ChainPath = '',
    [string]$ConfigDir = $env:CERTIFICATE_CONFIG_DIR,
    [string]$DeviceId = 'kemp-loadmaster',
    [string]$KempHost = '',
    [ValidateRange(1, 65535)][int]$Port = 443,
    [string]$Username = '',
    [SecureString]$Password,
    [string]$ApiKey = '',
    [string]$CertificateName = '',
    [string[]]$VirtualServiceIds = @(),
    [switch]$SkipCertificateCheck,
    [switch]$UseHttp,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules/SimpleAcme.Kemp/SimpleAcme.Kemp.psd1'
Import-Module $modulePath -Force

$configStorePath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'core/Config-Store.psm1'
if (Test-Path -LiteralPath $configStorePath -PathType Leaf) {
    Import-Module $configStorePath -Force
}

function ConvertTo-KempHookBoolean {
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

function Resolve-KempHookConfigDir {
    if (-not [string]::IsNullOrWhiteSpace($ConfigDir)) { return [IO.Path]::GetFullPath($ConfigDir) }
    $envConfigDir = [Environment]::GetEnvironmentVariable('CERTIFICATE_CONFIG_DIR')
    if (-not [string]::IsNullOrWhiteSpace($envConfigDir)) { return [IO.Path]::GetFullPath($envConfigDir) }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'config'))
}

function Get-KempHookProfileSettings {
    if (-not (Get-Command Get-DeviceConfig -CommandType Function -ErrorAction SilentlyContinue)) { return @{} }
    $resolvedConfigDir = Resolve-KempHookConfigDir
    $profile = Get-DeviceConfig -DeviceId $DeviceId -ConfigDir $resolvedConfigDir
    if ($null -eq $profile) {
        $profile = @(Get-AllDeviceConfigs -ConfigDir $resolvedConfigDir -SkipIntegrityFailures | Where-Object {
            $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]$_['connector_type'] -eq 'kemp'
        } | Select-Object -First 1)
        if ($profile.Count -gt 0) { $profile = $profile[0] }
    }
    if ($null -eq $profile -or -not ($profile -is [System.Collections.IDictionary]) -or -not $profile.ContainsKey('settings')) { return @{} }
    if (-not ($profile['settings'] -is [System.Collections.IDictionary])) { return @{} }
    return $profile['settings']
}

function Get-KempProfileValue {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Key,
        [string]$Default = ''
    )
    if ($Settings.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$Settings[$Key])) { return [string]$Settings[$Key] }
    return $Default
}

function Apply-KempHookProfileSettings {
    $settings = Get-KempHookProfileSettings
    if ($settings.Count -eq 0) { return }

    if ([string]::IsNullOrWhiteSpace($KempHost)) { $script:KempHost = Get-KempProfileValue -Settings $settings -Key 'host' }
    if (-not $PSBoundParameters.ContainsKey('Port')) {
        $profilePort = Get-KempProfileValue -Settings $settings -Key 'port' -Default '443'
        if (-not [string]::IsNullOrWhiteSpace($profilePort)) { $script:Port = [int]$profilePort }
    }
    if ([string]::IsNullOrWhiteSpace($Username)) { $script:Username = Get-KempProfileValue -Settings $settings -Key 'username' -Default 'bal' }
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { $script:ApiKey = Get-KempProfileValue -Settings $settings -Key 'api_key' }
    if ([string]::IsNullOrWhiteSpace($CertificateName)) { $script:CertificateName = Get-KempProfileValue -Settings $settings -Key 'certificate_name' }
    if ($VirtualServiceIds.Count -eq 0) {
        $selected = Get-KempProfileValue -Settings $settings -Key 'virtual_service_ids'
        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            $script:VirtualServiceIds = @($selected -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }
    if (-not $PSBoundParameters.ContainsKey('SkipCertificateCheck')) {
        $script:SkipCertificateCheck = ConvertTo-KempHookBoolean -Value (Get-KempProfileValue -Settings $settings -Key 'skip_certificate_check')
    }
    if (-not $PSBoundParameters.ContainsKey('UseHttp')) {
        $script:UseHttp = ConvertTo-KempHookBoolean -Value (Get-KempProfileValue -Settings $settings -Key 'use_http')
    }
    if ($null -eq $Password) {
        $plainPassword = Get-KempProfileValue -Settings $settings -Key 'password'
        if (-not [string]::IsNullOrWhiteSpace($plainPassword)) { $script:Password = ConvertTo-SecureString $plainPassword -AsPlainText -Force }
    }
}

function New-KempPemBundleFromParts {
    param(
        [Parameter(Mandatory)][string]$CertPath,
        [Parameter(Mandatory)][string]$KeyPath,
        [string]$ChainPath = ''
    )

    if (-not (Test-Path -LiteralPath $CertPath -PathType Leaf)) { throw "Certificate file was not found: $CertPath" }
    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) { throw "Private key file was not found: $KeyPath" }
    if (-not [string]::IsNullOrWhiteSpace($ChainPath) -and -not (Test-Path -LiteralPath $ChainPath -PathType Leaf)) { throw "Chain file was not found: $ChainPath" }
    $tempPath = Join-Path ([IO.Path]::GetTempPath()) ("simple-acme-kemp-{0}.pem" -f ([guid]::NewGuid().ToString('N')))
    $parts = @(
        Get-Content -LiteralPath $CertPath -Raw
        if (-not [string]::IsNullOrWhiteSpace($ChainPath)) { Get-Content -LiteralPath $ChainPath -Raw }
        Get-Content -LiteralPath $KeyPath -Raw
    )
    ($parts -join "`r`n") | Set-Content -LiteralPath $tempPath -Encoding ASCII
    return $tempPath
}

Apply-KempHookProfileSettings

if ([string]::IsNullOrWhiteSpace($KempHost)) { throw 'Kemp host is missing. Configure the Kemp device profile before running the hook.' }
if ([string]::IsNullOrWhiteSpace($CertificateName)) { throw 'Kemp certificate name is missing. Select Kemp targets from the TUI first.' }
if ($VirtualServiceIds.Count -lt 1) { throw 'Kemp virtual service selection is missing. Select Kemp targets from the TUI first.' }

$plainPassword = if ($null -ne $Password) { Resolve-KempPassword -Password $Password } else { '' }
$plainPfxPassword = if ($null -ne $PfxPassword) { Resolve-KempPassword -Password $PfxPassword } else { [string]$CachePassword }
$effectivePfxPath = if (-not [string]::IsNullOrWhiteSpace($PfxPath)) { $PfxPath } else { $CacheFile }
$tempBundle = ''

try {
    if ([string]::IsNullOrWhiteSpace($PemBundlePath)) {
        if (-not [string]::IsNullOrWhiteSpace($effectivePfxPath)) {
            $tempBundle = Convert-KempPfxToPemBundle -PfxPath $effectivePfxPath -Password $plainPfxPassword
            $PemBundlePath = $tempBundle
        } elseif (-not [string]::IsNullOrWhiteSpace($CertPath) -and -not [string]::IsNullOrWhiteSpace($KeyPath)) {
            $tempBundle = New-KempPemBundleFromParts -CertPath $CertPath -KeyPath $KeyPath -ChainPath $ChainPath
            $PemBundlePath = $tempBundle
        } else {
            throw 'Kemp certificate source is missing. Provide -PfxPath/-CacheFile or -CertPath plus -KeyPath.'
        }
    }

    $plan = [pscustomobject]@{
        Host = $KempHost
        Port = $Port
        CertificateName = $CertificateName
        VirtualServiceIds = @($VirtualServiceIds)
        Source = if (-not [string]::IsNullOrWhiteSpace($effectivePfxPath)) { 'PFX' } else { 'PEM' }
        Mode = if ($WhatIfPreference) { 'WhatIf' } else { 'Execute' }
    }

    if ($WhatIfPreference) {
        Write-Output $plan
        return
    }

    $null = Connect-KempLoadMaster -HostName $KempHost -Port $Port -ApiKey $ApiKey -Username $Username -Password $plainPassword -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
    $null = Import-KempCertificate -HostName $KempHost -Port $Port -CertificateName $CertificateName -PemBundlePath $PemBundlePath -ApiKey $ApiKey -Username $Username -Password $plainPassword -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -Replace -TimeoutSeconds $TimeoutSeconds

    $verification = @()
    foreach ($vsId in @($VirtualServiceIds)) {
        $null = Set-KempVirtualServiceCertificate -HostName $KempHost -Port $Port -VirtualServiceId $vsId -CertificateName $CertificateName -ApiKey $ApiKey -Username $Username -Password $plainPassword -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
        $verified = Test-KempVirtualServiceCertificate -HostName $KempHost -Port $Port -VirtualServiceId $vsId -CertificateName $CertificateName -ApiKey $ApiKey -Username $Username -Password $plainPassword -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
        $verification += [pscustomobject]@{ VirtualServiceId = $vsId; Verified = [bool]$verified }
    }

    if (@($verification | Where-Object { -not $_.Verified }).Count -gt 0) {
        throw 'Kemp deployment verification failed for one or more selected virtual services.'
    }

    [pscustomobject]@{
        Status = 'Succeeded'
        Host = $KempHost
        Port = $Port
        CertificateName = $CertificateName
        VirtualServiceIds = @($VirtualServiceIds)
        Verification = @($verification)
    }
} finally {
    $plainPassword = $null
    $plainPfxPassword = $null
    if (-not [string]::IsNullOrWhiteSpace($tempBundle) -and (Test-Path -LiteralPath $tempBundle -PathType Leaf)) {
        Remove-Item -LiteralPath $tempBundle -Force
    }
}
