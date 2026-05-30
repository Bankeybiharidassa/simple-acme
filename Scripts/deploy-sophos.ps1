#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Firewall,

    [ValidateRange(1, 65535)]
    [int]$Port = 4444,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Username,

    [Parameter(ParameterSetName = 'Password', Mandatory = $true)]
    [SecureString]$Password,

    [Parameter(ParameterSetName = 'SecretName', Mandatory = $true)]
    [string]$PasswordSecretName,

    [Parameter(ParameterSetName = 'SecureFile', Mandatory = $true)]
    [string]$PasswordSecureFile,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9 ._-]+$')]
    [string]$CertificateName,

    [string]$PfxPath,

    [SecureString]$PfxPassword,

    [string]$PfxPasswordSecretName,

    [string]$PfxPasswordSecureFile,

    [string]$CertPath,

    [string]$KeyPath,

    [string]$ChainPath,

    [switch]$BindAdminPortal,

    [switch]$BindVpnPortal,

    [switch]$BindUserPortal,

    [string[]]$WafRuleNames = @(),

    [switch]$SkipCertificateCheck,

    [switch]$EnableSshExportRecovery,

    [ValidateRange(1, 65535)]
    [int]$SshPort = 22,

    [string]$SshUsername = 'admin',

    [SecureString]$SshPassword,

    [string]$SshPasswordSecretName,

    [string]$SshPasswordSecureFile,

    [string]$SshPrivateKeyPath,

    [string]$SshHostKeyFingerprint,

    [string]$ExportRecoveryPath,

    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'Modules/SimpleAcme.Sophos/SimpleAcme.Sophos.psd1'
Import-Module $modulePath -Force

$plannedActions = @()

function New-SophosDeploymentLogRecord {
    param(
        [string]$Status,
        [string]$Message,
        [object]$PlannedActions,
        [object]$ExportDiagnostic,
        [object]$Verification
    )

    [pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Firewall = $Firewall
        Port = $Port
        Username = $Username
        CertificateName = $CertificateName
        Status = $Status
        Message = $Message
        PlannedActions = @($PlannedActions)
        ExportDiagnostic = $ExportDiagnostic
        Verification = $Verification
        SshExportRecoveryEnabled = [bool]$EnableSshExportRecovery
    }
}

function Resolve-OptionalSophosPassword {
    param(
        [SecureString]$SecurePassword,
        [string]$SecretName,
        [string]$SecureFile
    )

    if ($null -ne $SecurePassword) { return Resolve-SophosPassword -Password $SecurePassword }
    if (-not [string]::IsNullOrWhiteSpace($SecretName)) { return Resolve-SophosPassword -PasswordSecretName $SecretName }
    if (-not [string]::IsNullOrWhiteSpace($SecureFile)) { return Resolve-SophosPassword -PasswordSecureFile $SecureFile }
    return ''
}

function Get-SophosDeploymentPlan {
    $actions = New-Object System.Collections.Generic.List[object]
    $source = if (-not [string]::IsNullOrWhiteSpace($PfxPath)) { 'PFX' } else { 'PEM' }
    $actions.Add([pscustomobject]@{ Action = 'Connect'; Target = $Firewall; Detail = 'Sophos XML API' }) | Out-Null
    $actions.Add([pscustomobject]@{ Action = 'UploadCertificate'; Target = $CertificateName; Detail = $source }) | Out-Null

    if ($BindAdminPortal -or $BindVpnPortal -or $BindUserPortal) {
        $selected = @()
        if ($BindAdminPortal) { $selected += 'admin portal' }
        if ($BindVpnPortal) { $selected += 'VPN portal' }
        if ($BindUserPortal) { $selected += 'user portal' }
        $actions.Add([pscustomobject]@{ Action = 'BindWebAdminSettings'; Target = ($selected -join ', '); Detail = 'Sophos exposes these through WebAdminSettings/Certificate on tested SFOS.' }) | Out-Null
    }

    foreach ($rule in @($WafRuleNames)) {
        if (-not [string]::IsNullOrWhiteSpace($rule)) {
            $actions.Add([pscustomobject]@{ Action = 'BindWafRule'; Target = $rule; Detail = 'FirewallRule/HTTPBasedPolicy/HTTPSCertificate' }) | Out-Null
        }
    }

    if ($EnableSshExportRecovery) {
        $actions.Add([pscustomobject]@{ Action = 'OptionalSshExportRecovery'; Target = $Firewall; Detail = 'Only used if HTTPS certificate export returns an empty body.' }) | Out-Null
    }

    $actions.ToArray()
}

try {
    $apiPassword = switch ($PSCmdlet.ParameterSetName) {
        'SecretName' { Resolve-SophosPassword -PasswordSecretName $PasswordSecretName }
        'SecureFile' { Resolve-SophosPassword -PasswordSecureFile $PasswordSecureFile }
        default { Resolve-SophosPassword -Password $Password }
    }

    $sshPasswordText = Resolve-OptionalSophosPassword -SecurePassword $SshPassword -SecretName $SshPasswordSecretName -SecureFile $SshPasswordSecureFile
    $resolvedPfxPassword = $PfxPassword
    if ($null -eq $resolvedPfxPassword) {
        $pfxPasswordText = Resolve-OptionalSophosPassword -SecurePassword $null -SecretName $PfxPasswordSecretName -SecureFile $PfxPasswordSecureFile
        if (-not [string]::IsNullOrEmpty($pfxPasswordText)) {
            $resolvedPfxPassword = ConvertTo-SecureString $pfxPasswordText -AsPlainText -Force
        }
    }
    $normalizedWafRuleNames = @()
    foreach ($ruleValue in @($WafRuleNames)) {
        if (-not [string]::IsNullOrWhiteSpace($ruleValue)) {
            $normalizedWafRuleNames += @([string]$ruleValue -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
    }
    $WafRuleNames = @($normalizedWafRuleNames)
    $plannedActions = @(Get-SophosDeploymentPlan)

    if ($PSCmdlet.ShouldProcess($Firewall, "Deploy Sophos certificate '$CertificateName'")) {
        $null = Connect-SophosFirewallApi -Firewall $Firewall -Port $Port -Username $Username -Password $apiPassword -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds

        $exportDiagnostic = Export-SophosCertificateArchive -OutputPath $ExportRecoveryPath -EnableSshExportRecovery:$EnableSshExportRecovery -SshUsername $SshUsername -SshPort $SshPort -SshHostKeyFingerprint $SshHostKeyFingerprint -SshPassword $sshPasswordText -SshPrivateKeyPath $SshPrivateKeyPath

        $null = Import-SophosCertificate -Name $CertificateName -PfxPath $PfxPath -PfxPassword $resolvedPfxPassword -CertPath $CertPath -KeyPath $KeyPath -ChainPath $ChainPath

        if ($BindAdminPortal -or $BindVpnPortal -or $BindUserPortal) {
            $null = Set-SophosAdminWebSettingsCertificate -CertificateName $CertificateName
        }

        foreach ($rule in @($WafRuleNames)) {
            if (-not [string]::IsNullOrWhiteSpace($rule)) {
                $null = Set-SophosWafRuleCertificate -RuleName $rule -CertificateName $CertificateName
            }
        }

        $verification = Test-SophosDeploymentVerification -CertificateName $CertificateName -BindAdminPortal:($BindAdminPortal -or $BindVpnPortal -or $BindUserPortal) -WafRuleNames $WafRuleNames
        if (-not $verification.Passed) { throw 'Sophos deployment verification failed.' }

        New-SophosDeploymentLogRecord -Status 'Completed' -Message 'Sophos deployment completed.' -PlannedActions $plannedActions -ExportDiagnostic $exportDiagnostic -Verification $verification
    } else {
        New-SophosDeploymentLogRecord -Status 'WhatIf' -Message 'WhatIf only. No Sophos API mutations were executed.' -PlannedActions $plannedActions -ExportDiagnostic $null -Verification $null
    }
} catch {
    $safeMessage = Protect-SophosLogText -Text $_.Exception.Message
    $failureActions = @()
    if ($plannedActions) { $failureActions = @($plannedActions) }
    New-SophosDeploymentLogRecord -Status 'Failed' -Message $safeMessage -PlannedActions $failureActions -ExportDiagnostic $null -Verification $null
    throw $safeMessage
}
