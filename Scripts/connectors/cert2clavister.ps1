#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CertThumbprint = '',
    [string]$CacheFile = '',
    [string]$PfxPath = '',
    [string]$CachePassword = '',
    [SecureString]$PfxPassword,
    [string]$CertPath = '',
    [string]$KeyPath = '',
    [string]$ConfigDir = $env:CERTIFICATE_CONFIG_DIR,
    [string]$DeviceId = 'clavister-netwall',
    [string]$ClavisterHost = '',
    [ValidateRange(1, 65535)][int]$Port = 22,
    [string]$Username = '',
    [SecureString]$Password,
    [string]$PrivateKeyPath = '',
    [string]$SshHostKeyFingerprint = '',
    [string]$CertificateName = '',
    [switch]$Commit,
    [switch]$Activate,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules/SimpleAcme.Clavister/SimpleAcme.Clavister.psd1'
Import-Module $modulePath -Force

$configStorePath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'core/Config-Store.psm1'
if (Test-Path -LiteralPath $configStorePath -PathType Leaf) {
    Import-Module $configStorePath -Force
}

function ConvertTo-ClavisterHookBoolean {
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

function Resolve-ClavisterHookConfigDir {
    if (-not [string]::IsNullOrWhiteSpace($ConfigDir)) { return [IO.Path]::GetFullPath($ConfigDir) }
    $envConfigDir = [Environment]::GetEnvironmentVariable('CERTIFICATE_CONFIG_DIR')
    if (-not [string]::IsNullOrWhiteSpace($envConfigDir)) { return [IO.Path]::GetFullPath($envConfigDir) }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'config'))
}

function Get-ClavisterHookProfileSettings {
    if (-not (Get-Command Get-DeviceConfig -CommandType Function -ErrorAction SilentlyContinue)) { return @{} }
    $resolvedConfigDir = Resolve-ClavisterHookConfigDir
    $profile = Get-DeviceConfig -DeviceId $DeviceId -ConfigDir $resolvedConfigDir
    if ($null -eq $profile) {
        $profiles = @(Get-AllDeviceConfigs -ConfigDir $resolvedConfigDir -SkipIntegrityFailures | Where-Object {
            $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]$_['connector_type'] -eq 'clavister'
        } | Select-Object -First 1)
        if ($profiles.Count -gt 0) { $profile = $profiles[0] }
    }
    if ($null -eq $profile -or -not ($profile -is [System.Collections.IDictionary]) -or -not $profile.ContainsKey('settings')) { return @{} }
    if (-not ($profile['settings'] -is [System.Collections.IDictionary])) { return @{} }
    return $profile['settings']
}

function Get-ClavisterProfileValue {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Key,
        [string]$Default = ''
    )
    if ($Settings.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$Settings[$Key])) { return [string]$Settings[$Key] }
    return $Default
}

function Apply-ClavisterHookProfileSettings {
    $settings = Get-ClavisterHookProfileSettings
    if ($settings.Count -eq 0) { return }

    if ([string]::IsNullOrWhiteSpace($ClavisterHost)) { $script:ClavisterHost = Get-ClavisterProfileValue -Settings $settings -Key 'host' }
    if (-not $PSBoundParameters.ContainsKey('Port')) {
        $profilePort = Get-ClavisterProfileValue -Settings $settings -Key 'port' -Default '22'
        if (-not [string]::IsNullOrWhiteSpace($profilePort)) { $script:Port = [int]$profilePort }
    }
    if ([string]::IsNullOrWhiteSpace($Username)) { $script:Username = Get-ClavisterProfileValue -Settings $settings -Key 'username' -Default 'admin' }
    if ([string]::IsNullOrWhiteSpace($PrivateKeyPath)) { $script:PrivateKeyPath = Get-ClavisterProfileValue -Settings $settings -Key 'private_key_path' }
    if ([string]::IsNullOrWhiteSpace($SshHostKeyFingerprint)) { $script:SshHostKeyFingerprint = Get-ClavisterProfileValue -Settings $settings -Key 'ssh_host_key_fingerprint' }
    if ([string]::IsNullOrWhiteSpace($CertificateName)) { $script:CertificateName = Get-ClavisterProfileValue -Settings $settings -Key 'certificate_name' }
    if (-not $PSBoundParameters.ContainsKey('Commit')) { $script:Commit = ConvertTo-ClavisterHookBoolean -Value (Get-ClavisterProfileValue -Settings $settings -Key 'commit_after_upload') -Default $true }
    if (-not $PSBoundParameters.ContainsKey('Activate')) { $script:Activate = ConvertTo-ClavisterHookBoolean -Value (Get-ClavisterProfileValue -Settings $settings -Key 'activate_after_commit') -Default $true }
    if ($null -eq $Password) {
        $plainPassword = Get-ClavisterProfileValue -Settings $settings -Key 'password'
        if (-not [string]::IsNullOrWhiteSpace($plainPassword)) { $script:Password = ConvertTo-SecureString $plainPassword -AsPlainText -Force }
    }
}

Apply-ClavisterHookProfileSettings

if ([string]::IsNullOrWhiteSpace($ClavisterHost)) { throw 'Clavister host is missing. Configure the Clavister device profile before running the hook.' }
if ([string]::IsNullOrWhiteSpace($Username)) { throw 'Clavister username is missing. Configure the Clavister device profile before running the hook.' }
if ([string]::IsNullOrWhiteSpace($CertificateName)) { throw 'Clavister certificate object name is missing. Configure the Clavister device profile before running the hook.' }

$plainPassword = if ($null -ne $Password) { ConvertFrom-ClavisterSecureString -SecureString $Password } else { '' }
$plainPfxPassword = if ($null -ne $PfxPassword) { ConvertFrom-ClavisterSecureString -SecureString $PfxPassword } else { [string]$CachePassword }
$effectivePfxPath = if (-not [string]::IsNullOrWhiteSpace($PfxPath)) { $PfxPath } else { $CacheFile }
$tempDirectory = ''
$sourceCertPath = $CertPath
$sourceKeyPath = $KeyPath

try {
    if ([string]::IsNullOrWhiteSpace($sourceCertPath) -or [string]::IsNullOrWhiteSpace($sourceKeyPath)) {
        if ([string]::IsNullOrWhiteSpace($effectivePfxPath)) {
            throw 'Clavister certificate source is missing. Provide -PfxPath/-CacheFile or -CertPath plus -KeyPath.'
        }
        $pem = Convert-ClavisterPfxToPemFiles -PfxPath $effectivePfxPath -Password $plainPfxPassword
        $tempDirectory = [string]$pem.TempDirectory
        $sourceCertPath = [string]$pem.CertificatePath
        $sourceKeyPath = [string]$pem.KeyPath
    }

    if ($WhatIfPreference) {
        [pscustomobject]@{
            Status = 'WhatIf'
            Host = $ClavisterHost
            Port = $Port
            CertificateName = $CertificateName
            RemotePath = "certificate/$CertificateName"
            Commit = [bool]$Commit
            Activate = [bool]$Activate
        }
        return
    }

    $certUpload = Invoke-ClavisterScpUpload -HostName $ClavisterHost -Port $Port -Username $Username -Password $plainPassword -PrivateKeyPath $PrivateKeyPath -HostKeyFingerprint $SshHostKeyFingerprint -LocalPath $sourceCertPath -CertificateName $CertificateName -TimeoutSeconds $TimeoutSeconds
    $keyUpload = Invoke-ClavisterScpUpload -HostName $ClavisterHost -Port $Port -Username $Username -Password $plainPassword -PrivateKeyPath $PrivateKeyPath -HostKeyFingerprint $SshHostKeyFingerprint -LocalPath $sourceKeyPath -CertificateName $CertificateName -TimeoutSeconds $TimeoutSeconds

    $commitResult = $null
    $activateResult = $null
    if ($Commit) {
        $commitResult = Invoke-ClavisterSshCommand -HostName $ClavisterHost -Port $Port -Username $Username -Password $plainPassword -PrivateKeyPath $PrivateKeyPath -HostKeyFingerprint $SshHostKeyFingerprint -Command 'commit' -TimeoutSeconds $TimeoutSeconds
    }
    if ($Activate) {
        $activateResult = Invoke-ClavisterSshCommand -HostName $ClavisterHost -Port $Port -Username $Username -Password $plainPassword -PrivateKeyPath $PrivateKeyPath -HostKeyFingerprint $SshHostKeyFingerprint -Command 'activate' -TimeoutSeconds $TimeoutSeconds
    }

    [pscustomobject]@{
        Status = 'Succeeded'
        Host = $ClavisterHost
        Port = $Port
        CertificateName = $CertificateName
        RemotePath = "certificate/$CertificateName"
        CertificateUpload = $certUpload.Status
        KeyUpload = $keyUpload.Status
        Commit = if ($null -eq $commitResult) { 'Skipped' } else { $commitResult.Status }
        Activate = if ($null -eq $activateResult) { 'Skipped' } else { $activateResult.Status }
    }
} finally {
    $plainPassword = $null
    $plainPfxPassword = $null
    if (-not [string]::IsNullOrWhiteSpace($tempDirectory) -and (Test-Path -LiteralPath $tempDirectory -PathType Container)) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
}
