Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/../core/Tui-Engine.psm1" -Force -Global
Import-Module "$PSScriptRoot/../core/Config-Store.psm1" -Force -Global
Import-Module "$PSScriptRoot/../core/Env-Loader.psm1" -Force -Global
Import-Module "$PSScriptRoot/../core/Crypto.psm1" -Force -Global

function ConvertTo-SophosTuiBoolean {
    param([object]$Value, [bool]$Default = $false)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
    switch ($text.ToLowerInvariant()) {
        { $_ -in @('1','true','yes','y','on') } { return $true }
        { $_ -in @('0','false','no','n','off') } { return $false }
        default { throw "Invalid boolean value '$Value'. Use true or false." }
    }
}

function ConvertTo-SophosSafeValue {
    param([string]$Name, [object]$Value)
    if ($Name -match '(?i)password|secret|private_key|key_path') {
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
        if ($Name -match 'key_path') { return [IO.Path]::GetFileName([string]$Value) }
        return '<redacted>'
    }
    if ($Name -match '(?i)pfx_path|cert_path|chain_path|ssh_private_key_path') {
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
        return [IO.Path]::GetFileName([string]$Value)
    }
    $Value
}

function Get-SophosTuiLogRoot {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $configuredRoot = if (-not [string]::IsNullOrWhiteSpace($env:CERTIFICATE_LOG_DIR)) { [string]$env:CERTIFICATE_LOG_DIR } else { Join-Path $ProjectRoot 'logs' }
    $logRoot = [IO.Path]::GetFullPath($configuredRoot)
    if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) { New-Item -ItemType Directory -Path $logRoot -Force | Out-Null }
    $logRoot
}

function Write-SophosTuiJsonLog {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][object]$Data
    )
    $logRoot = Get-SophosTuiLogRoot -ProjectRoot $ProjectRoot
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $path = Join-Path $logRoot ("{0}-{1}.json" -f $Prefix, $stamp)
    $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

function Resolve-SophosTuiConfigDir {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $configured = [Environment]::GetEnvironmentVariable('CERTIFICATE_CONFIG_DIR')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        return [IO.Path]::GetFullPath($configured)
    }

    return [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'config'))
}

function Test-SophosLikelyPlaintextPassword {
    param([object]$Value)

    if ($null -eq $Value) { return $false }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($text -match '[^A-Za-z0-9_.-]') { return $true }
    return $false
}

function Write-SophosTuiSecureValueFile {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Plaintext
    )

    $secretDir = Join-Path $ConfigDir 'secrets'
    if (-not (Test-Path -LiteralPath $secretDir -PathType Container)) {
        New-Item -ItemType Directory -Path $secretDir -Force | Out-Null
    }
    $cipher = Protect-DpapiValue -Plaintext $Plaintext -Scope LocalMachine
    $payload = [ordered]@{
        scope = 'LocalMachine'
        ciphertext = $cipher
        created_by = 'certificate-setup sophos tui'
        updated_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $path = Join-Path $secretDir ("{0}.json" -f $Name)
    $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
    return [string]$path
}

function Resolve-SophosDefaultPfxPath {
    $defaultDir = 'C:\certs'
    if (-not (Test-Path -LiteralPath $defaultDir -PathType Container)) { return '' }
    $latest = Get-ChildItem -LiteralPath $defaultDir -Filter '*.pfx' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latest) { return '' }
    return [string]$latest.FullName
}

function ConvertTo-SophosCertificateObjectName {
    param(
        [string]$Domains = '',
        [string]$PfxPath = ''
    )

    $source = ''
    if (-not [string]::IsNullOrWhiteSpace($Domains)) {
        $source = @($Domains -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })[0]
    }
    if ([string]::IsNullOrWhiteSpace($source) -and -not [string]::IsNullOrWhiteSpace($PfxPath)) {
        $source = [IO.Path]::GetFileNameWithoutExtension($PfxPath)
    }
    if ([string]::IsNullOrWhiteSpace($source)) { $source = 'simple-acme-certificate' }
    $source = $source.Replace('*.', 'wildcard-').Replace('*', 'wildcard').Replace('_', '-')
    $safe = ($source -replace '[^A-Za-z0-9.-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'simple-acme-certificate' }
    return $safe
}

function Get-SophosCertificateDeploymentContext {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigDir
    )

    $envValues = @{}
    try {
        $envPath = Resolve-BootstrapEnvPath -ProjectRoot $ProjectRoot
        if (Test-Path -LiteralPath $envPath -PathType Leaf) {
            $envValues = Read-EffectiveEnvFile -Path $envPath -AllowIncomplete
        }
    } catch {
        Write-Verbose "Could not read certificate.env for Sophos deployment defaults: $($_.Exception.Message)"
    }

    $pfxPath = ''
    if ($envValues.ContainsKey('ACME_PFX_FILE_PATH') -and -not [string]::IsNullOrWhiteSpace([string]$envValues['ACME_PFX_FILE_PATH'])) {
        $configuredPfx = [string]$envValues['ACME_PFX_FILE_PATH']
        if (Test-Path -LiteralPath $configuredPfx -PathType Leaf) { $pfxPath = $configuredPfx }
        elseif (Test-Path -LiteralPath $configuredPfx -PathType Container) {
            $latest = Get-ChildItem -LiteralPath $configuredPfx -Filter '*.pfx' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($null -ne $latest) { $pfxPath = [string]$latest.FullName }
        }
    }
    if ([string]::IsNullOrWhiteSpace($pfxPath)) { $pfxPath = Resolve-SophosDefaultPfxPath }

    $domains = if ($envValues.ContainsKey('DOMAINS')) { [string]$envValues['DOMAINS'] } else { '' }
    $pfxPassword = if ($envValues.ContainsKey('ACME_PFX_PASSWORD')) { [string]$envValues['ACME_PFX_PASSWORD'] } else { '' }

    return @{
        pfx_path = $pfxPath
        certificate_name = ConvertTo-SophosCertificateObjectName -Domains $domains -PfxPath $pfxPath
        pfx_password = $pfxPassword
    }
}

function Get-SophosDeploymentCurrentValues {
    param([Parameter(Mandatory)][string]$ConfigDir)

    $existing = @(Get-AllDeviceConfigs -ConfigDir $ConfigDir -SkipIntegrityFailures | Where-Object {
        $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]($_['connector_type']) -eq 'sophos'
    } | Select-Object -First 1)
    if ($existing.Count -lt 1 -or $null -eq $existing[0]) { return @{} }
    if (-not ($existing[0] -is [System.Collections.IDictionary]) -or -not $existing[0].ContainsKey('settings')) { return @{} }
    $settings = $existing[0]['settings']
    if (-not ($settings -is [System.Collections.IDictionary])) { return @{} }

    $current = @{}
    foreach ($key in $settings.Keys) { $current[[string]$key] = [string]$settings[$key] }
    if (-not $current.ContainsKey('password') -and $current.ContainsKey('password_secret_name') -and (Test-SophosLikelyPlaintextPassword -Value $current['password_secret_name'])) {
        $current['password'] = [string]$current['password_secret_name']
        $current['password_secret_name'] = ''
    }
    foreach ($certificateKey in @('certificate_name','pfx_path','pfx_password','pfx_password_secret_name','pfx_password_secure_file','cert_path','key_path','chain_path','enable_ssh_export_recovery','ssh_username','ssh_port','ssh_password_secret_name','ssh_private_key_path','ssh_host_key_fingerprint','export_recovery_path')) {
        if ($current.ContainsKey($certificateKey)) { $current.Remove($certificateKey) }
    }
    return $current
}

function Add-SophosFieldDefaults {
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][object[]]$Fields
    )

    $withDefaults = @{}
    foreach ($key in $Values.Keys) { $withDefaults[[string]$key] = [string]$Values[$key] }
    foreach ($field in @($Fields)) {
        if (-not ($field -is [System.Collections.IDictionary])) { continue }
        if (-not $field.ContainsKey('Name') -or -not $field.ContainsKey('Default')) { continue }
        $name = [string]$field['Name']
        $defaultValue = [string]$field['Default']
        if (-not $withDefaults.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string]$withDefaults[$name])) {
            $withDefaults[$name] = $defaultValue
        }
    }
    return $withDefaults
}

function Save-SophosDeploymentCurrentValues {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $existing = @(Get-AllDeviceConfigs -ConfigDir $ConfigDir -SkipIntegrityFailures | Where-Object {
        $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]($_['connector_type']) -eq 'sophos'
    } | Select-Object -First 1)
    $deviceId = 'sophos-firewall'
    $createdAt = $now
    if ($existing.Count -gt 0 -and $null -ne $existing[0] -and $existing[0] -is [System.Collections.IDictionary]) {
        if ($existing[0].ContainsKey('device_id') -and -not [string]::IsNullOrWhiteSpace([string]$existing[0]['device_id'])) {
            $deviceId = [string]$existing[0]['device_id']
        }
        if ($existing[0].ContainsKey('created_at') -and -not [string]::IsNullOrWhiteSpace([string]$existing[0]['created_at'])) {
            $createdAt = [string]$existing[0]['created_at']
        }
    }

    $settings = @{}
    foreach ($key in $Values.Keys) { $settings[[string]$key] = [string]$Values[$key] }
    $device = @{
        device_id = $deviceId
        connector_type = 'sophos'
        label = 'Sophos firewall'
        created_at = $createdAt
        updated_at = $now
        settings = $settings
    }
    Save-DeviceConfig -Device $device -ConfigDir $ConfigDir -SecretFields @('password') | Out-Null
}

function Remove-SophosPlaceholderValues {
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][object[]]$Fields
    )

    $clean = @{}
    foreach ($key in $Values.Keys) { $clean[[string]$key] = [string]$Values[$key] }
    foreach ($field in @($Fields)) {
        if (-not ($field -is [System.Collections.IDictionary])) { continue }
        if (-not $field.ContainsKey('Name') -or -not $field.ContainsKey('Placeholder')) { continue }
        if ($field.ContainsKey('Default')) { continue }
        if ($field.ContainsKey('Required') -and [bool]$field['Required']) { continue }
        $name = [string]$field['Name']
        if (-not $clean.ContainsKey($name)) { continue }
        $placeholder = [string]$field['Placeholder']
        $value = [string]$clean[$name]
        if (-not [string]::IsNullOrWhiteSpace($placeholder) -and $value -eq $placeholder) {
            $clean[$name] = ''
        }
    }
    return $clean
}

function Convert-SophosFormValuesToArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$FormValues,
        [string]$ConfigDir = ''
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    $required = @('host','username')
    foreach ($key in $required) {
        if (-not $FormValues.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$FormValues[$key])) {
            throw "Required Sophos field '$key' is missing."
        }
    }
    $password = if ($FormValues.ContainsKey('password')) { [string]$FormValues['password'] } else { '' }
    $passwordSecretName = if ($FormValues.ContainsKey('password_secret_name')) { [string]$FormValues['password_secret_name'] } else { '' }
    $passwordSecureFile = if ($FormValues.ContainsKey('password_secure_file')) { [string]$FormValues['password_secure_file'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($password) -and [string]::IsNullOrWhiteSpace($passwordSecretName) -and [string]::IsNullOrWhiteSpace($passwordSecureFile)) {
        throw "Sophos admin password is missing. Open Sophos Firewall - Create or edit device profile and enter the firewall admin password."
    }
    if (-not [string]::IsNullOrWhiteSpace($password) -and [string]::IsNullOrWhiteSpace($ConfigDir)) {
        throw "Sophos API password needs a config directory so it can be passed as an encrypted DPAPI secure file."
    }

    $pfxPath = if ($FormValues.ContainsKey('pfx_path')) { [string]$FormValues['pfx_path'] } else { '' }
    $certPath = if ($FormValues.ContainsKey('cert_path')) { [string]$FormValues['cert_path'] } else { '' }
    $keyPath = if ($FormValues.ContainsKey('key_path')) { [string]$FormValues['key_path'] } else { '' }
    $pfxPassword = if ($FormValues.ContainsKey('pfx_password')) { [string]$FormValues['pfx_password'] } else { '' }
    $pfxPasswordSecureFile = if ($FormValues.ContainsKey('pfx_password_secure_file')) { [string]$FormValues['pfx_password_secure_file'] } else { '' }
    $hasPfx = -not [string]::IsNullOrWhiteSpace($pfxPath)
    $hasPemPair = (-not [string]::IsNullOrWhiteSpace($certPath)) -or (-not [string]::IsNullOrWhiteSpace($keyPath))

    if ($hasPfx -and $hasPemPair) {
        throw "Provide either 'pfx_path' or the PEM 'cert_path'/'key_path' pair, not both."
    }
    if (-not $hasPfx -and ([string]::IsNullOrWhiteSpace($certPath) -or [string]::IsNullOrWhiteSpace($keyPath))) {
        throw "No issued certificate file was found for Sophos deployment. Request the certificate first, or make sure the PFX exists under the configured PFX folder or C:\certs."
    }
    if ($hasPfx -and -not [string]::IsNullOrWhiteSpace($pfxPassword) -and [string]::IsNullOrWhiteSpace($ConfigDir)) {
        throw "Sophos PFX password needs a config directory so it can be passed as an encrypted DPAPI secure file."
    }

    $bindAdminPortal = ConvertTo-SophosTuiBoolean -Value $(if ($FormValues.ContainsKey('bind_admin_portal')) { $FormValues['bind_admin_portal'] } else { $false })
    $bindVpnPortal = ConvertTo-SophosTuiBoolean -Value $(if ($FormValues.ContainsKey('bind_vpn_portal')) { $FormValues['bind_vpn_portal'] } else { $false })
    $bindUserPortal = ConvertTo-SophosTuiBoolean -Value $(if ($FormValues.ContainsKey('bind_user_portal')) { $FormValues['bind_user_portal'] } else { $false })
    $bindWaf = ConvertTo-SophosTuiBoolean -Value $(if ($FormValues.ContainsKey('bind_waf')) { $FormValues['bind_waf'] } else { $false })
    $wafRuleNames = if ($FormValues.ContainsKey('waf_rule_names')) { [string]$FormValues['waf_rule_names'] } else { '' }
    if (-not ($bindAdminPortal -or $bindVpnPortal -or $bindUserPortal -or $bindWaf)) {
        throw "Select at least one Sophos certificate target: admin portal, VPN portal, user portal, or WAF."
    }
    if ($bindWaf -and [string]::IsNullOrWhiteSpace($wafRuleNames)) {
        throw "Sophos WAF binding requires 'waf_rule_names'."
    }

    $enableSshRecovery = ConvertTo-SophosTuiBoolean -Value $(if ($FormValues.ContainsKey('enable_ssh_export_recovery')) { $FormValues['enable_ssh_export_recovery'] } else { $false })
    if ($enableSshRecovery) {
        $sshHostKey = if ($FormValues.ContainsKey('ssh_host_key_fingerprint')) { [string]$FormValues['ssh_host_key_fingerprint'] } else { '' }
        $exportPath = if ($FormValues.ContainsKey('export_recovery_path')) { [string]$FormValues['export_recovery_path'] } else { '' }
        $sshPasswordSecret = if ($FormValues.ContainsKey('ssh_password_secret_name')) { [string]$FormValues['ssh_password_secret_name'] } else { '' }
        $sshPrivateKey = if ($FormValues.ContainsKey('ssh_private_key_path')) { [string]$FormValues['ssh_private_key_path'] } else { '' }
        if ([string]::IsNullOrWhiteSpace($sshHostKey)) { throw "Sophos SSH export recovery requires 'ssh_host_key_fingerprint'." }
        if ([string]::IsNullOrWhiteSpace($exportPath)) { throw "Sophos SSH export recovery requires 'export_recovery_path'." }
        if ([string]::IsNullOrWhiteSpace($sshPasswordSecret) -and [string]::IsNullOrWhiteSpace($sshPrivateKey)) {
            throw "Sophos SSH export recovery requires 'ssh_password_secret_name' or 'ssh_private_key_path'."
        }
    }

    $map = [ordered]@{
        host = '-Firewall'
        port = '-Port'
        username = '-Username'
        certificate_name = '-CertificateName'
        pfx_path = '-PfxPath'
        pfx_password_secret_name = '-PfxPasswordSecretName'
        cert_path = '-CertPath'
        key_path = '-KeyPath'
        chain_path = '-ChainPath'
        ssh_username = '-SshUsername'
        ssh_port = '-SshPort'
        ssh_password_secret_name = '-SshPasswordSecretName'
        ssh_private_key_path = '-SshPrivateKeyPath'
        ssh_host_key_fingerprint = '-SshHostKeyFingerprint'
        export_recovery_path = '-ExportRecoveryPath'
    }

    foreach ($key in $map.Keys) {
        if ($FormValues.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$FormValues[$key])) {
            $arguments.Add($map[$key]) | Out-Null
            $arguments.Add([string]$FormValues[$key]) | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($password)) {
        $arguments.Add('-PasswordSecureFile') | Out-Null
        $arguments.Add((Write-SophosTuiSecureValueFile -ConfigDir $ConfigDir -Name 'sophos-api-password' -Plaintext $password)) | Out-Null
    } elseif (-not [string]::IsNullOrWhiteSpace($passwordSecureFile)) {
        $arguments.Add('-PasswordSecureFile') | Out-Null
        $arguments.Add($passwordSecureFile) | Out-Null
    } else {
        $arguments.Add('-PasswordSecretName') | Out-Null
        $arguments.Add($passwordSecretName) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($pfxPassword)) {
        $arguments.Add('-PfxPasswordSecureFile') | Out-Null
        $arguments.Add((Write-SophosTuiSecureValueFile -ConfigDir $ConfigDir -Name 'sophos-pfx-password' -Plaintext $pfxPassword)) | Out-Null
    } elseif (-not [string]::IsNullOrWhiteSpace($pfxPasswordSecureFile)) {
        $arguments.Add('-PfxPasswordSecureFile') | Out-Null
        $arguments.Add($pfxPasswordSecureFile) | Out-Null
    }

    if ($bindAdminPortal) { $arguments.Add('-BindAdminPortal') | Out-Null }
    if ($bindVpnPortal) { $arguments.Add('-BindVpnPortal') | Out-Null }
    if ($bindUserPortal) { $arguments.Add('-BindUserPortal') | Out-Null }
    if (ConvertTo-SophosTuiBoolean -Value $(if ($FormValues.ContainsKey('skip_certificate_check')) { $FormValues['skip_certificate_check'] } else { $false })) { $arguments.Add('-SkipCertificateCheck') | Out-Null }
    if ($enableSshRecovery) { $arguments.Add('-EnableSshExportRecovery') | Out-Null }

    if ($bindWaf -and $FormValues.ContainsKey('waf_rule_names') -and -not [string]::IsNullOrWhiteSpace([string]$FormValues['waf_rule_names'])) {
        $arguments.Add('-WafRuleNames') | Out-Null
        $arguments.Add([string]$FormValues['waf_rule_names']) | Out-Null
    }

    @($arguments)
}

function Invoke-SophosConnectorScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$WhatIfMode
    )
    $invokeArgs = @($Arguments)
    if ($WhatIfMode) { $invokeArgs += '-WhatIf' }
    & $ScriptPath @invokeArgs
}

function Invoke-SophosProfileForm {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    . $schemaPath
    if (-not $DeviceSchemas.ContainsKey('sophos')) { throw "Device schema 'sophos' was not found in $schemaPath" }

    $schema = $DeviceSchemas['sophos']
    $configDir = Resolve-SophosTuiConfigDir -ProjectRoot $ProjectRoot
    $currentValues = Remove-SophosPlaceholderValues -Values (Get-SophosDeploymentCurrentValues -ConfigDir $configDir) -Fields @($schema.Fields)
    $currentValues = Add-SophosFieldDefaults -Values $currentValues -Fields @($schema.Fields)
    $values = Show-TuiForm -Fields ([hashtable[]]$schema.Fields) -CurrentValues $currentValues -Title 'Sophos device profile'
    if ($null -eq $values) { return [pscustomobject]@{ Status = 'Canceled' } }
    $values = Remove-SophosPlaceholderValues -Values $values -Fields @($schema.Fields)
    $values = Add-SophosFieldDefaults -Values $values -Fields @($schema.Fields)
    Save-SophosDeploymentCurrentValues -ConfigDir $configDir -Values $values
    Show-TuiStatus -Message 'Sophos device profile saved.' -Type Success -Row ([Math]::Max(0,[Console]::WindowHeight)-2)
    Start-Sleep -Milliseconds 1200
    return [pscustomobject]@{ Status = 'Saved'; ConfigDir = $configDir }
}

function Invoke-SophosDeploymentForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$WhatIfMode
    )

    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    . $schemaPath
    if (-not $DeviceSchemas.ContainsKey('sophos')) { throw "Device schema 'sophos' was not found in $schemaPath" }

    $schema = $DeviceSchemas['sophos']
    $configDir = Resolve-SophosTuiConfigDir -ProjectRoot $ProjectRoot
    $values = Add-SophosFieldDefaults -Values (Get-SophosDeploymentCurrentValues -ConfigDir $configDir) -Fields @($schema.Fields)
    if ($values.Count -eq 0 -or -not $values.ContainsKey('host') -or [string]::IsNullOrWhiteSpace([string]$values['host'])) {
        Write-Host 'No Sophos device profile exists yet. Create the profile first.' -ForegroundColor Yellow
        $profileResult = Invoke-SophosProfileForm -ProjectRoot $ProjectRoot
        if ($null -eq $profileResult -or [string]$profileResult.Status -ne 'Saved') { return [pscustomobject]@{ Status = 'Canceled'; LogPath = $null } }
        $values = Add-SophosFieldDefaults -Values (Get-SophosDeploymentCurrentValues -ConfigDir $configDir) -Fields @($schema.Fields)
    }
    $certificateContext = Get-SophosCertificateDeploymentContext -ProjectRoot $ProjectRoot -ConfigDir $configDir
    foreach ($key in $certificateContext.Keys) {
        if (-not [string]::IsNullOrWhiteSpace([string]$certificateContext[$key])) { $values[[string]$key] = [string]$certificateContext[$key] }
    }

    $scriptPath = Join-Path $ProjectRoot 'Scripts/deploy-sophos.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Sophos deployment script not found: $scriptPath" }

    $safeValues = [ordered]@{}
    foreach ($key in $values.Keys) { $safeValues[$key] = ConvertTo-SophosSafeValue -Name ([string]$key) -Value $values[$key] }

    $status = 'PreviewFailed'
    $message = ''
    $previewResult = $null
    $deploymentResult = $null
    $arguments = @()
    $jsonPath = $null
    $textPath = $null
    try {
        $arguments = @(Convert-SophosFormValuesToArguments -FormValues $values -ConfigDir $configDir)
        Write-Host 'Running Sophos WhatIf preview first. No firewall mutations should occur during this step.'
        $previewResult = Invoke-SophosConnectorScript -ScriptPath $scriptPath -Arguments $arguments -WhatIfMode
        if ($WhatIfMode) {
            $status = 'PreviewCompleted'
            $message = 'WhatIf preview completed. Real deployment was not requested.'
        } else {
            Write-Host ''
            Write-Host 'WhatIf preview completed. Type DEPLOY to execute the real Sophos deployment.'
            $confirmation = [string](Read-Host 'Confirmation')
            if ($confirmation -cne 'DEPLOY') {
                $status = 'CanceledAfterPreview'
                $message = 'Operator did not type DEPLOY after preview. Real deployment was not executed.'
            } else {
                $deploymentResult = Invoke-SophosConnectorScript -ScriptPath $scriptPath -Arguments $arguments
                $status = 'DeploymentCompleted'
                $message = 'Real Sophos deployment completed after explicit confirmation.'
            }
        }
    } catch {
        $message = $_.Exception.Message
        Write-Host "Sophos deployment validation/execution failed: $message" -ForegroundColor Red
        throw
    } finally {
        $record = [pscustomobject]@{
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            Status = $status
            Message = $message
            ScriptPath = $scriptPath
            SafeFormValues = $safeValues
            ArgumentNames = @($arguments | Where-Object { $_ -like '-*' })
            PreviewResult = $previewResult
            DeploymentResult = $deploymentResult
        }
        $jsonPath = Write-SophosTuiJsonLog -ProjectRoot $ProjectRoot -Prefix 'sophos-tui-deploy' -Data $record
        $textPath = [IO.Path]::ChangeExtension($jsonPath, '.log')
        @(
            "TimestampUtc=$($record.TimestampUtc)"
            "Status=$status"
            "Message=$message"
            "ScriptPath=$scriptPath"
            "Host=$($record.SafeFormValues.host)"
            "Username=$($record.SafeFormValues.username)"
            "CertificateName=$($record.SafeFormValues.certificate_name)"
            "ArgumentNames=$($record.ArgumentNames -join ',')"
        ) | Set-Content -LiteralPath $textPath -Encoding UTF8
    }

    [pscustomobject]@{
        Status = $status
        Message = $message
        PreviewResult = $previewResult
        DeploymentResult = $deploymentResult
        JsonLogPath = $jsonPath
        TextLogPath = $textPath
    }
}

function Test-SophosTuiWiring {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $menuPath = Join-Path $ProjectRoot 'setup/Menu-Tree.ps1'
    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    $setupPath = Join-Path $ProjectRoot 'certificate-setup.ps1'
    $runnerPath = Join-Path $ProjectRoot 'setup/Sophos-Runner.psm1'
    $scriptPath = Join-Path $ProjectRoot 'Scripts/deploy-sophos.ps1'
    $manifestPath = Join-Path $ProjectRoot 'Scripts/Modules/SimpleAcme.Sophos/SimpleAcme.Sophos.psd1'
    $releasePath = Join-Path $ProjectRoot 'build/release-file-list.txt'
    . $schemaPath

    $schemaFields = if ($DeviceSchemas.ContainsKey('sophos')) { @($DeviceSchemas['sophos'].Fields | ForEach-Object { [string]$_.Name }) } else { @() }
    $menuText = if (Test-Path -LiteralPath $menuPath) { Get-Content -LiteralPath $menuPath -Raw } else { '' }
    $setupText = if (Test-Path -LiteralPath $setupPath) { Get-Content -LiteralPath $setupPath -Raw } else { '' }
    $releaseText = if (Test-Path -LiteralPath $releasePath) { Get-Content -LiteralPath $releasePath -Raw } else { '' }
    $requiredFields = @('host','port','username','password','password_secret_name','password_secure_file','bind_admin_portal','bind_vpn_portal','bind_user_portal','bind_waf','waf_rule_names','skip_certificate_check')

    [pscustomobject]@{
        ScriptExists = Test-Path -LiteralPath $scriptPath -PathType Leaf
        ModuleManifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
        RunnerExists = Test-Path -LiteralPath $runnerPath -PathType Leaf
        SchemaPresent = $DeviceSchemas.ContainsKey('sophos')
        MissingSchemaFields = @($requiredFields | Where-Object { $_ -notin $schemaFields })
        MenuKeysPresent = @('sophos-profile','sophos-deploy','sophos-whatif','sophos-diagnostics','sophos-export-recovery') | ForEach-Object { [pscustomobject]@{ Key = $_; Present = ($menuText -match [regex]::Escape($_)) } }
        SetupDispatchPresent = @('sophos-profile','sophos-deploy','sophos-whatif','sophos-diagnostics','sophos-export-recovery') | ForEach-Object { [pscustomobject]@{ Key = $_; Present = ($setupText -match [regex]::Escape($_)) } }
        ReleaseManifestIncludesRuntime = ($releaseText -match 'setup/Sophos-Runner\.psm1' -and $releaseText -match 'scripts/modules/SimpleAcme\.Sophos/SimpleAcme\.Sophos\.psd1')
    }
}

function Invoke-SophosDiagnostics {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check { param([string]$Name,[bool]$Passed,[string]$Detail = '') $checks.Add([pscustomobject]@{ Name=$Name; Passed=$Passed; Detail=$Detail }) | Out-Null }

    $wiring = Test-SophosTuiWiring -ProjectRoot $ProjectRoot
    Add-Check -Name 'Sophos script exists' -Passed ([bool]$wiring.ScriptExists)
    Add-Check -Name 'Sophos module manifest exists' -Passed ([bool]$wiring.ModuleManifestExists)
    Add-Check -Name 'Sophos runner exists' -Passed ([bool]$wiring.RunnerExists)
    Add-Check -Name 'Sophos schema present' -Passed ([bool]$wiring.SchemaPresent)
    Add-Check -Name 'Sophos schema has required fields' -Passed (@($wiring.MissingSchemaFields).Count -eq 0) -Detail (@($wiring.MissingSchemaFields) -join ',')
    foreach ($menu in @($wiring.MenuKeysPresent)) { Add-Check -Name "Menu key present: $($menu.Key)" -Passed ([bool]$menu.Present) }
    foreach ($dispatch in @($wiring.SetupDispatchPresent)) { Add-Check -Name "Setup dispatch present: $($dispatch.Key)" -Passed ([bool]$dispatch.Present) }
    Add-Check -Name 'Release manifest includes Sophos runtime files' -Passed ([bool]$wiring.ReleaseManifestIncludesRuntime)

    $manifestPath = Join-Path $ProjectRoot 'Scripts/Modules/SimpleAcme.Sophos/SimpleAcme.Sophos.psd1'
    try {
        $module = Import-Module $manifestPath -Force -PassThru
        Add-Check -Name 'Sophos module imports' -Passed ($null -ne $module)
    } catch {
        Add-Check -Name 'Sophos module imports' -Passed $false -Detail $_.Exception.Message
    }

    $checkArray = @($checks.ToArray())
    $result = [pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Checks = $checkArray
        Passed = (@($checkArray | Where-Object { -not $_.Passed }).Count -eq 0)
    }
    $logPath = Write-SophosTuiJsonLog -ProjectRoot $ProjectRoot -Prefix 'sophos-tui-diagnostic' -Data $result
    $result | Add-Member -NotePropertyName LogPath -NotePropertyValue $logPath -Force

    Write-Host 'Sophos TUI diagnostic summary:'
    foreach ($check in $checkArray) {
        $prefix = '[FAIL]'
        if ($check.Passed) { $prefix = '[PASS]' }
        Write-Host ("{0} {1} {2}" -f $prefix, $check.Name, $check.Detail)
    }
    Write-Host "Diagnostic JSON: $logPath"
    $result
}

function Invoke-SophosCertificateExportRecovery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    Write-Host 'Sophos SSH export recovery is diagnostics-only.'
    Write-Host 'Advanced Shell may affect vendor support and certificate exports contain private keys.'
    Invoke-SophosDeploymentForm -ProjectRoot $ProjectRoot -WhatIfMode
}

Export-ModuleMember -Function Invoke-SophosProfileForm,Invoke-SophosDeploymentForm,Invoke-SophosDiagnostics,Invoke-SophosCertificateExportRecovery,Convert-SophosFormValuesToArguments,Test-SophosTuiWiring
