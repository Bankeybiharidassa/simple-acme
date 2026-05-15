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

    [string]$NitroBaseUrl,

    [switch]$UseHttp,

    [switch]$DetectHA = $true,

    [switch]$NoDetectHA,

    [switch]$RequirePrimary = $true,

    [switch]$SyncHA = $true,

    [switch]$NoSyncHA,

    [switch]$SyncHAForce,

    [switch]$SaveConfig = $true,

    [switch]$NoSaveConfig,

    [Alias('ReplaceServerCertificate')]
    [switch]$ReplaceExistingServerCertificate,

    [SecureString]$KeyPassword,

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
Import-Module $modulePath

$effectiveDetectHA = [bool]$DetectHA -and -not [bool]$NoDetectHA
$effectiveRequirePrimary = [bool]$RequirePrimary
$effectiveSaveConfig = [bool]$SaveConfig -and -not [bool]$NoSaveConfig
$effectiveSyncHA = [bool]$SyncHA -and -not [bool]$NoSyncHA
$whatIfMode = [bool]$WhatIfPreference

$plannedActions = New-Object System.Collections.Generic.List[string]
$executedActions = New-Object System.Collections.Generic.List[string]
$skippedActions = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

$null = New-NetscalerNitroBaseUri -HostName $NetScalerHost -NitroBaseUrl $NitroBaseUrl -UseHttp:$UseHttp
$validatedFiles = Test-NetscalerLocalCertificateFiles -CertPath $CertPath -KeyPath $KeyPath -ChainPath $ChainPath
$passwordText = if ($PSCmdlet.ParameterSetName -eq 'SecretName') {
    Resolve-NetscalerPassword -PasswordSecretName $PasswordSecretName
} else {
    Resolve-NetscalerPassword -Password $Password
}

$changed = $false
$saved = $false
$haSynced = $false
$haState = [pscustomobject]@{ HAConfigured = $false; HAMasterState = 'NOT_DETECTED'; Raw = $null; Ambiguous = $false }
$verificationStatus = if ($whatIfMode) { 'Planned' } else { 'NotRun' }
$sourceMapVersion = $null

$sourceMapPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Docs/connectors/netscaler-source-map.json'
if (Test-Path -LiteralPath $sourceMapPath -PathType Leaf) {
    try {
        $sourceMap = Get-Content -LiteralPath $sourceMapPath -Raw | ConvertFrom-Json
        if ($sourceMap -is [array] -and $sourceMap.Count -gt 0 -and ($sourceMap[0].PSObject.Properties.Name -contains 'source_map_version')) {
            $sourceMapVersion = [string]$sourceMap[0].source_map_version
        }
    } catch {
        $warnings.Add('Source map version could not be read.') | Out-Null
    }
}

$certFileName = Split-Path -Leaf $validatedFiles.CertPath
$keyFileName = Split-Path -Leaf $validatedFiles.KeyPath
$chainFileName = if ($null -eq $validatedFiles.ChainPath) { $null } else { Split-Path -Leaf $validatedFiles.ChainPath }

foreach ($action in @("Upload certificate file $certFileName", "Upload key file $keyFileName")) { $plannedActions.Add($action) | Out-Null }
if ($null -ne $validatedFiles.ChainPath) { $plannedActions.Add("Upload chain file $chainFileName") | Out-Null }
$plannedActions.Add("Create or update sslcertkey $CertKeyName") | Out-Null
$plannedActions.Add("Bind sslcertkey $CertKeyName to SSL vServer $VServerName") | Out-Null
if ($ReplaceExistingServerCertificate) { $plannedActions.Add("Replace existing non-CA/non-SNI server certificate bindings on $VServerName") | Out-Null }
if ($effectiveSaveConfig) { $plannedActions.Add('Save NetScaler running configuration after successful verification') | Out-Null }
if ($effectiveSyncHA) { $plannedActions.Add('Synchronize HA configuration after successful verification when HA is configured') | Out-Null }

try {
    Connect-NetscalerNitroSession -HostName $NetScalerHost -Username $Username -Password $passwordText -NitroBaseUrl $NitroBaseUrl -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds

    if ($effectiveDetectHA) {
        $haState = Get-NetscalerHAState
        Assert-NetscalerPrimary -HAState $haState -RequirePrimary $effectiveRequirePrimary
    }

    $null = Get-NetscalerSslCertKey -CertKeyName $CertKeyName
    $null = Get-NetscalerSslVServerCertBindings -VServerName $VServerName

    $fileChanged = Send-NetscalerSslFile -Path $validatedFiles.CertPath -FileName $certFileName -WhatIf:$whatIfMode
    if ($fileChanged) { $executedActions.Add("Uploaded certificate file $certFileName") | Out-Null } else { $skippedActions.Add("Upload certificate file $certFileName") | Out-Null }
    $changed = $fileChanged -or $changed

    $fileChanged = Send-NetscalerSslFile -Path $validatedFiles.KeyPath -FileName $keyFileName -WhatIf:$whatIfMode
    if ($fileChanged) { $executedActions.Add("Uploaded key file $keyFileName") | Out-Null } else { $skippedActions.Add("Upload key file $keyFileName") | Out-Null }
    $changed = $fileChanged -or $changed

    if ($null -ne $validatedFiles.ChainPath) {
        $fileChanged = Send-NetscalerSslFile -Path $validatedFiles.ChainPath -FileName $chainFileName -WhatIf:$whatIfMode
        if ($fileChanged) { $executedActions.Add("Uploaded chain file $chainFileName") | Out-Null } else { $skippedActions.Add("Upload chain file $chainFileName") | Out-Null }
        $changed = $fileChanged -or $changed
    }

    $certKeyChanged = Set-NetscalerSslCertKey -CertKeyName $CertKeyName -CertFileName $certFileName -KeyFileName $keyFileName -ChainFileName $chainFileName -KeyPassword $KeyPassword -WhatIf:$whatIfMode
    if ($certKeyChanged) { $executedActions.Add("Created or updated sslcertkey $CertKeyName") | Out-Null } else { $skippedActions.Add("Create or update sslcertkey $CertKeyName") | Out-Null }
    $changed = $certKeyChanged -or $changed

    $bindingChanged = Set-NetscalerSslVServerCertBinding -VServerName $VServerName -CertKeyName $CertKeyName -ReplaceExistingServerCertificate:$ReplaceExistingServerCertificate -WhatIf:$whatIfMode
    if ($bindingChanged) { $executedActions.Add("Updated SSL vServer binding for $VServerName") | Out-Null } else { $skippedActions.Add("Update SSL vServer binding for $VServerName") | Out-Null }
    $changed = $bindingChanged -or $changed

    if ($whatIfMode) {
        $verificationStatus = 'Planned'
        $skippedActions.Add('Verification, save, and HA sync skipped because WhatIf does not mutate appliance state.') | Out-Null
    } else {
        $verificationStatus = Test-NetscalerDeploymentVerification -CertKeyName $CertKeyName -VServerName $VServerName
        if ($verificationStatus -ne 'Passed') {
            throw "NetScaler deployment verification failed with status '$verificationStatus'."
        }

        if ($effectiveSaveConfig) {
            $saved = Save-NetscalerConfig
            if ($saved) { $executedActions.Add('Saved NetScaler running configuration') | Out-Null }
        }

        if ($effectiveSyncHA -and $haState.HAConfigured) {
            $haSynced = Sync-NetscalerHA -Force:$SyncHAForce
            if ($haSynced) { $executedActions.Add('Synchronized NetScaler HA configuration') | Out-Null }
        }

        if ($saved -or $haSynced) {
            $postVerificationStatus = Test-NetscalerDeploymentVerification -CertKeyName $CertKeyName -VServerName $VServerName
            if ($postVerificationStatus -ne 'Passed') {
                throw "NetScaler post-save/sync verification failed with status '$postVerificationStatus'."
            }
            $verificationStatus = $postVerificationStatus
        }
    }
} finally {
    $passwordText = $null
    Disconnect-NetscalerNitroSession
}

[pscustomobject]@{
    Host                  = $NetScalerHost
    CertKeyName           = $CertKeyName
    VServerName           = $VServerName
    HAConfigured          = [bool]$haState.HAConfigured
    HAMasterState         = [string]$haState.HAMasterState
    Saved                 = [bool]$saved
    HASynced              = [bool]$haSynced
    Changed               = [bool]$changed
    VerificationStatus    = $verificationStatus
    Mode                  = if ($whatIfMode) { 'WhatIfConnected' } else { 'Execute' }
    PlannedActions        = @($plannedActions)
    ExecutedActions       = @($executedActions)
    SkippedActions        = @($skippedActions)
    Warnings              = @($warnings)
    SourceMapVersion      = $sourceMapVersion
    LiveNetScalerValidated = $false
}
