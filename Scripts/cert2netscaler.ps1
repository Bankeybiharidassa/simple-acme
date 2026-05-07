#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'SecurePassword')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$NetScalerHost,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Username,

    [Parameter(Mandatory = $true, ParameterSetName = 'SecurePassword')]
    [ValidateNotNull()]
    [SecureString]$Password,

    [Parameter(Mandatory = $true, ParameterSetName = 'SecretName')]
    [ValidateNotNullOrEmpty()]
    [string]$PasswordSecretName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CertKeyName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CertPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$KeyPath,

    [string]$ChainPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VServerName,

    [bool]$DetectHA = $true,

    [bool]$RequirePrimary = $true,

    [bool]$SyncHA = $true,

    [switch]$SyncHAForce,

    [bool]$SaveConfig = $true,

    [switch]$ReplaceServerCertificate,

    [switch]$SkipCertificateCheck,

    [ValidateRange(0, 10)]
    [int]$RetryCount = 2,

    [ValidateRange(0, 60)]
    [int]$RetryDelaySeconds = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'Modules/SimpleAcme.Netscaler/SimpleAcme.Netscaler.psd1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "Required NetScaler module was not found at $modulePath"
}
Import-Module $modulePath -Force

$validatedFiles = Test-NetscalerLocalCertificateFiles -CertPath $CertPath -KeyPath $KeyPath -ChainPath $ChainPath
$passwordText = if ($PSCmdlet.ParameterSetName -eq 'SecretName') {
    Resolve-NetscalerPassword -PasswordSecretName $PasswordSecretName
} else {
    Resolve-NetscalerPassword -Password $Password
}

$changed = $false
$saved = $false
$haSynced = $false
$haState = [pscustomobject]@{ HAConfigured = $false; HAMasterState = 'NOT_DETECTED'; Raw = $null }
$verificationStatus = 'NotRun'

$certFileName = Split-Path -Leaf $validatedFiles.CertPath
$keyFileName = Split-Path -Leaf $validatedFiles.KeyPath
$chainFileName = if ($null -eq $validatedFiles.ChainPath) { $null } else { Split-Path -Leaf $validatedFiles.ChainPath }

try {
    if ($PSCmdlet.ShouldProcess($NetScalerHost, 'Open NITRO session and deploy certificate')) {
        Connect-NetscalerNitroSession -HostName $NetScalerHost -Username $Username -Password $passwordText -SkipCertificateCheck:$SkipCertificateCheck -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds

        if ($DetectHA) {
            $haState = Get-NetscalerHAState
            Assert-NetscalerPrimary -HAState $haState -RequirePrimary $RequirePrimary
        }

        $changed = (Send-NetscalerSslFile -Path $validatedFiles.CertPath -FileName $certFileName) -or $changed
        $changed = (Send-NetscalerSslFile -Path $validatedFiles.KeyPath -FileName $keyFileName) -or $changed
        if ($null -ne $validatedFiles.ChainPath) {
            $changed = (Send-NetscalerSslFile -Path $validatedFiles.ChainPath -FileName $chainFileName) -or $changed
        }

        $changed = (Set-NetscalerSslCertKey -CertKeyName $CertKeyName -CertFileName $certFileName -KeyFileName $keyFileName -ChainFileName $chainFileName) -or $changed
        $changed = (Set-NetscalerSslVServerCertBinding -VServerName $VServerName -CertKeyName $CertKeyName -ReplaceServerCertificate:$ReplaceServerCertificate) -or $changed

        $verificationStatus = Test-NetscalerDeploymentVerification -CertKeyName $CertKeyName -VServerName $VServerName
        if ($verificationStatus -ne 'Verified') {
            throw "NetScaler deployment verification failed with status '$verificationStatus'."
        }

        if ($SaveConfig -and $changed) {
            $saved = Save-NetscalerConfig
        }

        if ($SyncHA -and $haState.HAConfigured -and $changed) {
            $haSynced = Sync-NetscalerHA -Force:$SyncHAForce
        }
    } else {
        $verificationStatus = 'WhatIf'
    }
} finally {
    $passwordText = $null
    Disconnect-NetscalerNitroSession
}

[pscustomobject]@{
    Host               = $NetScalerHost
    CertKeyName        = $CertKeyName
    VServerName        = $VServerName
    HAConfigured       = [bool]$haState.HAConfigured
    HAMasterState      = [string]$haState.HAMasterState
    Saved              = [bool]$saved
    HASynced           = [bool]$haSynced
    Changed            = [bool]$changed
    VerificationStatus = $verificationStatus
}
