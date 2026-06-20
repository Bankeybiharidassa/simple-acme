#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Firewall,

    [ValidateRange(1, 65535)]
    [int]$Port = 4444,

    [string]$Username,

    [SecureString]$Password,

    [string]$PasswordSecretName,

    [string]$PasswordSecureFile,

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
    [int]$TimeoutSeconds = 120,

    [string]$ConfigDir = '',

    [string]$DeviceId = 'sophos-firewall'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'Modules/SimpleAcme.Sophos/SimpleAcme.Sophos.psd1'
Import-Module $modulePath -Force
$configStorePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'core/Config-Store.psm1'
if (Test-Path -LiteralPath $configStorePath -PathType Leaf) {
    Import-Module $configStorePath -Force
}

$plannedActions = @()

function ConvertTo-SophosHookBoolean {
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

function Resolve-SophosHookConfigDir {
    if (-not [string]::IsNullOrWhiteSpace($ConfigDir)) { return [IO.Path]::GetFullPath($ConfigDir) }
    $envConfigDir = [Environment]::GetEnvironmentVariable('CERTIFICATE_CONFIG_DIR')
    if (-not [string]::IsNullOrWhiteSpace($envConfigDir)) { return [IO.Path]::GetFullPath($envConfigDir) }
    return [IO.Path]::GetFullPath((Join-Path (Split-Path $PSScriptRoot -Parent) 'config'))
}

function Get-SophosHookProfileSettings {
    if (-not (Get-Command Get-DeviceConfig -CommandType Function -ErrorAction SilentlyContinue)) { return @{} }
    $resolvedConfigDir = Resolve-SophosHookConfigDir
    $profile = Get-DeviceConfig -DeviceId $DeviceId -ConfigDir $resolvedConfigDir
    if ($null -eq $profile) {
        $profile = @(Get-AllDeviceConfigs -ConfigDir $resolvedConfigDir -SkipIntegrityFailures | Where-Object {
            $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]$_['connector_type'] -eq 'sophos'
        } | Select-Object -First 1)
        if ($profile.Count -gt 0) { $profile = $profile[0] }
    }
    if ($null -eq $profile -or -not ($profile -is [System.Collections.IDictionary]) -or -not $profile.ContainsKey('settings')) { return @{} }
    if (-not ($profile['settings'] -is [System.Collections.IDictionary])) { return @{} }
    return $profile['settings']
}

function Get-SophosProfileValue {
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [Parameter(Mandatory)][string]$Key,
        [string]$Default = ''
    )
    if ($Settings.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace([string]$Settings[$Key])) { return [string]$Settings[$Key] }
    return $Default
}

function Apply-SophosHookProfileSettings {
    $settings = Get-SophosHookProfileSettings
    if ($settings.Count -eq 0) { return }

    if ([string]::IsNullOrWhiteSpace($Firewall)) { $script:Firewall = Get-SophosProfileValue -Settings $settings -Key 'host' }
    if (-not $PSBoundParameters.ContainsKey('Port')) {
        $profilePort = Get-SophosProfileValue -Settings $settings -Key 'port' -Default '4444'
        if (-not [string]::IsNullOrWhiteSpace($profilePort)) { $script:Port = [int]$profilePort }
    }
    if ([string]::IsNullOrWhiteSpace($Username)) { $script:Username = Get-SophosProfileValue -Settings $settings -Key 'username' -Default 'admin' }
    if ([string]::IsNullOrWhiteSpace($CertificateName)) { $script:CertificateName = Get-SophosProfileValue -Settings $settings -Key 'certificate_name' }

    if (-not $PSBoundParameters.ContainsKey('Password') -and -not $PSBoundParameters.ContainsKey('PasswordSecretName') -and -not $PSBoundParameters.ContainsKey('PasswordSecureFile')) {
        $script:PasswordSecureFile = Get-SophosProfileValue -Settings $settings -Key 'password_secure_file'
        $script:PasswordSecretName = Get-SophosProfileValue -Settings $settings -Key 'password_secret_name'
        $plainPassword = Get-SophosProfileValue -Settings $settings -Key 'password'
        if (-not [string]::IsNullOrWhiteSpace($plainPassword)) { $script:Password = ConvertTo-SecureString $plainPassword -AsPlainText -Force }
    }

    if ([string]::IsNullOrWhiteSpace($PfxPasswordSecureFile)) { $script:PfxPasswordSecureFile = Get-SophosProfileValue -Settings $settings -Key 'pfx_password_secure_file' }
    if ([string]::IsNullOrWhiteSpace($PfxPasswordSecretName)) { $script:PfxPasswordSecretName = Get-SophosProfileValue -Settings $settings -Key 'pfx_password_secret_name' }
    if ($null -eq $PfxPassword) {
        $plainPfxPassword = Get-SophosProfileValue -Settings $settings -Key 'pfx_password'
        if (-not [string]::IsNullOrWhiteSpace($plainPfxPassword)) { $script:PfxPassword = ConvertTo-SecureString $plainPfxPassword -AsPlainText -Force }
    }

    if (-not $PSBoundParameters.ContainsKey('BindAdminPortal')) { $script:BindAdminPortal = ConvertTo-SophosHookBoolean -Value (Get-SophosProfileValue -Settings $settings -Key 'bind_admin_portal') }
    if (-not $PSBoundParameters.ContainsKey('BindVpnPortal')) { $script:BindVpnPortal = ConvertTo-SophosHookBoolean -Value (Get-SophosProfileValue -Settings $settings -Key 'bind_vpn_portal') }
    if (-not $PSBoundParameters.ContainsKey('BindUserPortal')) { $script:BindUserPortal = ConvertTo-SophosHookBoolean -Value (Get-SophosProfileValue -Settings $settings -Key 'bind_user_portal') }
    if (-not $PSBoundParameters.ContainsKey('SkipCertificateCheck')) { $script:SkipCertificateCheck = ConvertTo-SophosHookBoolean -Value (Get-SophosProfileValue -Settings $settings -Key 'skip_certificate_check') }

    if ($WafRuleNames.Count -eq 0 -and (ConvertTo-SophosHookBoolean -Value (Get-SophosProfileValue -Settings $settings -Key 'bind_waf'))) {
        $script:WafRuleNames = @(Get-SophosProfileValue -Settings $settings -Key 'waf_rule_names' -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

function Initialize-DpapiSupport {
    $scopeType = 'System.Security.Cryptography.DataProtectionScope' -as [type]
    $protectedDataType = 'System.Security.Cryptography.ProtectedData' -as [type]
    if ($null -ne $scopeType -and $null -ne $protectedDataType) { return }

    $assemblies = @('System.Security', 'System.Security.Cryptography.ProtectedData')
    foreach ($assembly in $assemblies) {
        try {
            Add-Type -AssemblyName $assembly -ErrorAction Stop
        } catch {
        }

        $scopeType = 'System.Security.Cryptography.DataProtectionScope' -as [type]
        $protectedDataType = 'System.Security.Cryptography.ProtectedData' -as [type]
        if ($null -ne $scopeType -and $null -ne $protectedDataType) { return }
    }

    throw 'Windows DPAPI support is unavailable. Run this command in Windows PowerShell 5.1 or install the System.Security.Cryptography.ProtectedData assembly.'
}

function Unprotect-DpapiValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CiphertextBase64,
        [ValidateSet('LocalMachine')][string]$Scope = 'LocalMachine'
    )

    Initialize-DpapiSupport
    $entropy = [System.Text.Encoding]::UTF8.GetBytes('certificate-dpapi-entropy-v1')
    $scopeEnum = [System.Security.Cryptography.DataProtectionScope]::$Scope
    $bytes = [Convert]::FromBase64String($CiphertextBase64)
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $entropy, $scopeEnum)
    [System.Text.Encoding]::UTF8.GetString($plainBytes)
}

function Resolve-DpapiSecureFileValue {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Secure file not found: $Path" }
    $raw = (Get-Content -LiteralPath $Path -Raw).Trim()
    if ($raw.StartsWith('{')) {
        $payload = $raw | ConvertFrom-Json
        $scope = if ($payload.scope) { [string]$payload.scope } else { 'LocalMachine' }
        if ($scope -ne 'LocalMachine') { throw "Unsupported DPAPI scope '$scope'. Expected LocalMachine." }
        return Unprotect-DpapiValue -CiphertextBase64 ([string]$payload.ciphertext) -Scope 'LocalMachine'
    }

    return Unprotect-DpapiValue -CiphertextBase64 $raw -Scope 'LocalMachine'
}

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
    if (-not [string]::IsNullOrWhiteSpace($SecureFile)) { return Resolve-DpapiSecureFileValue -Path $SecureFile }
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
    Apply-SophosHookProfileSettings
    if ([string]::IsNullOrWhiteSpace($Firewall)) { throw 'Sophos firewall address is missing. Configure the Sophos device profile before running the hook.' }
    if ([string]::IsNullOrWhiteSpace($Username)) { throw 'Sophos admin username is missing. Configure the Sophos device profile before running the hook.' }
    if ([string]::IsNullOrWhiteSpace($CertificateName)) { throw 'Sophos certificate object name is missing. Configure the Sophos certificate target selection before running the hook.' }

    if ($null -ne $Password) { $apiPassword = Resolve-SophosPassword -Password $Password }
    elseif (-not [string]::IsNullOrWhiteSpace($PasswordSecureFile)) { $apiPassword = Resolve-DpapiSecureFileValue -Path $PasswordSecureFile }
    elseif (-not [string]::IsNullOrWhiteSpace($PasswordSecretName)) { $apiPassword = Resolve-SophosPassword -PasswordSecretName $PasswordSecretName }
    else { throw 'Sophos admin password is missing. Configure the Sophos device profile before running the hook.' }

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
