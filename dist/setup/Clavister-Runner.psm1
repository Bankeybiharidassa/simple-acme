Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-ClavisterSingleQuotedArgument {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return "''" }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Invoke-ClavisterProfileForm {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    Invoke-DeviceProfileConnectorWizard -ProjectRoot $ProjectRoot -ConnectorType 'clavister'
}

function Get-ClavisterConfiguredProfile {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [string]$DeviceId = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($DeviceId)) {
        $device = Get-DeviceConfig -ConfigDir $ConfigDir -DeviceId $DeviceId
        if ($null -ne $device) { return $device }
    }

    $devices = @(Get-AllDeviceConfigs -ConfigDir $ConfigDir -SkipIntegrityFailures | Where-Object {
        $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]$_['connector_type'] -eq 'clavister'
    } | Sort-Object @{ Expression = { if ($_.ContainsKey('updated_at')) { [string]$_['updated_at'] } else { '' } } } -Descending)
    if ($devices.Count -lt 1) { return $null }
    return $devices[0]
}

function Get-ClavisterProfileSetting {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Device,
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = ''
    )

    if (-not $Device.ContainsKey('settings') -or -not ($Device['settings'] -is [System.Collections.IDictionary])) { return $Default }
    $settings = $Device['settings']
    if ($settings.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace([string]$settings[$Name])) { return [string]$settings[$Name] }
    return $Default
}

function Read-ClavisterTargetSelection {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [string]$DefaultSelection = '1'
    )

    $selectable = @($Items | Where-Object { [string]$_.Kind -ne 'diagnostic' })
    if ($selectable.Count -lt 1) { return @() }

    while ($true) {
        $answer = Read-DeviceProfileConsoleLine -Prompt 'Select target numbers' -Default $DefaultSelection
        if ($null -eq $answer) { return $null }
        $tokens = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($tokens.Count -lt 1) {
            Write-Host 'Enter one or more numbers from the list.' -ForegroundColor Yellow
            continue
        }

        $selected = New-Object System.Collections.Generic.List[object]
        $invalid = $false
        foreach ($token in $tokens) {
            $number = 0
            if (-not [int]::TryParse($token, [ref]$number) -or $number -lt 1 -or $number -gt $selectable.Count) {
                Write-Host ("Invalid selection: {0}. Use numbers only." -f $token) -ForegroundColor Yellow
                $invalid = $true
                break
            }
            $item = $selectable[$number - 1]
            if (@($selected | Where-Object { [string]$_.Id -eq [string]$item.Id }).Count -lt 1) {
                $selected.Add($item)
            }
        }
        if ($invalid) { continue }
        return @($selected)
    }
}

function Invoke-ClavisterCertificateTargetSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigDir,
        [string]$DeviceId = ''
    )

    $device = Get-ClavisterConfiguredProfile -ConfigDir $ConfigDir -DeviceId $DeviceId
    if ($null -eq $device) {
        Write-Host ''
        Write-Host 'No Clavister device profile was found.' -ForegroundColor Yellow
        Wait-DeviceProfileOperatorKey
        return $null
    }

    $modulePath = Join-Path $ProjectRoot 'Scripts/Modules/SimpleAcme.Clavister/SimpleAcme.Clavister.psd1'
    Import-Module $modulePath -Force

    $settings = $device['settings']
    $hostName = Get-ClavisterProfileSetting -Device $device -Name 'host'
    $port = [int](Get-ClavisterProfileSetting -Device $device -Name 'port' -Default '22')
    $username = Get-ClavisterProfileSetting -Device $device -Name 'username' -Default 'admin'
    $password = Get-ClavisterProfileSetting -Device $device -Name 'password'
    $privateKeyPath = Get-ClavisterProfileSetting -Device $device -Name 'private_key_path'
    $fingerprint = Get-ClavisterProfileSetting -Device $device -Name 'ssh_host_key_fingerprint'

    Clear-Host
    Write-Host 'Reading Clavister certificate targets from the firewall...'
    Write-Host ''
    $items = @(Get-ClavisterCertificateServiceInventory -HostName $hostName -Port $port -Username $username -Password $password -PrivateKeyPath $privateKeyPath -HostKeyFingerprint $fingerprint -TimeoutSeconds 60)

    Clear-Host
    Write-Host 'Clavister certificate target selection'
    Write-Host '-------------------------------------'
    Write-Host ("Endpoint: {0}:{1}" -f $hostName, $port)
    Write-Host 'Numbers only. The saved selection is reused by scheduled renewals.'
    Write-Host ''

    $selectable = @($items | Where-Object { [string]$_.Kind -ne 'diagnostic' })
    for ($i = 0; $i -lt $selectable.Count; $i++) {
        $item = $selectable[$i]
        $detail = ''
        if ($item.PSObject.Properties.Name -contains 'AuthMethod' -and -not [string]::IsNullOrWhiteSpace([string]$item.AuthMethod)) { $detail += " auth=$($item.AuthMethod)" }
        if ($item.PSObject.Properties.Name -contains 'RemoteEndpoint' -and -not [string]::IsNullOrWhiteSpace([string]$item.RemoteEndpoint)) { $detail += " remote=$($item.RemoteEndpoint)" }
        $current = if ([string]::IsNullOrWhiteSpace([string]$item.CurrentCertificate)) { '<empty>' } else { [string]$item.CurrentCertificate }
        Write-Host ("[{0}] {1}  current-cert={2}{3}" -f ($i + 1), [string]$item.Name, $current, $detail)
    }
    foreach ($diagnostic in @($items | Where-Object { [string]$_.Kind -eq 'diagnostic' })) {
        Write-Host ("Diagnostic: {0}: {1}" -f [string]$diagnostic.Name, [string]$diagnostic.Details) -ForegroundColor Yellow
    }
    Write-Host ''

    $default = '1'
    $existing = Get-ClavisterProfileSetting -Device $device -Name 'bind_target_ids'
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        $ids = @($existing -split ',' | ForEach-Object { $_.Trim() })
        $numbers = @()
        for ($i = 0; $i -lt $selectable.Count; $i++) {
            if ($ids -contains [string]$selectable[$i].Id) { $numbers += [string]($i + 1) }
        }
        if ($numbers.Count -gt 0) { $default = $numbers -join ',' }
    }

    $selected = @(Read-ClavisterTargetSelection -Items $items -DefaultSelection $default)
    if ($null -eq $selected -or $selected.Count -lt 1) { return $null }

    $values = @{}
    foreach ($key in $settings.Keys) { $values[[string]$key] = [string]$settings[$key] }
    $values['bind_target_ids'] = [string]::Join(',', @($selected | ForEach-Object { [string]$_.Id }))
    $values['bind_target_names'] = [string]::Join(', ', @($selected | ForEach-Object { [string]$_.Name }))
    $label = if ($device.ContainsKey('label') -and -not [string]::IsNullOrWhiteSpace([string]$device['label'])) { [string]$device['label'] } else { 'Clavister NetWall / cOS Core' }
    $deviceIdValue = if ($device.ContainsKey('device_id')) { [string]$device['device_id'] } else { '' }
    Save-DeviceProfile -ConfigDir $ConfigDir -ConnectorType 'clavister' -Label 'Clavister NetWall / cOS Core' -Values $values -SecretFields @('password') -DeviceId $deviceIdValue -FriendlyName $label | Out-Null

    Write-Host ''
    Write-Host 'Saved Clavister certificate targets'
    Write-Host '-----------------------------------'
    foreach ($item in $selected) { Write-Host ("- {0}" -f [string]$item.Name) }
    Wait-DeviceProfileOperatorKey
    return [pscustomobject]@{ Status='Saved'; DeviceId=$deviceIdValue; TargetIds=$values['bind_target_ids']; TargetNames=$values['bind_target_names'] }
}

function Invoke-ClavisterCertificateRequestSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $configDir = if ($Values.ContainsKey('CERTIFICATE_CONFIG_DIR') -and -not [string]::IsNullOrWhiteSpace([string]$Values['CERTIFICATE_CONFIG_DIR'])) {
        [IO.Path]::GetFullPath([string]$Values['CERTIFICATE_CONFIG_DIR'])
    } else {
        Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    }
    $Values['CERTIFICATE_CONFIG_DIR'] = $configDir

    $profileResult = Invoke-DeviceProfileConnectorWizard -ProjectRoot $ProjectRoot -ConnectorType 'clavister'
    if ($null -eq $profileResult -or [string]$profileResult.Status -eq 'Canceled') {
        return $null
    }
    $deviceId = [string]$profileResult.DeviceId
    if ([string]::IsNullOrWhiteSpace($deviceId)) { throw 'Clavister device profile was saved without a device id.' }

    $targetResult = Invoke-ClavisterCertificateTargetSelection -ProjectRoot $ProjectRoot -ConfigDir $configDir -DeviceId $deviceId
    if ($null -eq $targetResult -or [string]$targetResult.Status -ne 'Saved') {
        return $null
    }

    $Values['ACME_TARGET_SYSTEM'] = 'clavister'
    $Values['TARGET_SYSTEM'] = 'clavister'
    $Values['ACME_TARGET_DEVICE_TYPE'] = 'clavister'
    $Values['ACME_TARGET_DEVICE_LABEL'] = 'Clavister NetWall / cOS Core'
    $Values['ACME_TARGET_DEVICE_ID'] = $deviceId
    $Values['ACME_INSTALLATION_PLUGINS'] = 'script'
    $Values['ACME_STORE_PLUGIN'] = 'pfxfile,certificatestore'
    $Values['ACME_SCRIPT_PATH'] = Join-Path $ProjectRoot 'Scripts\cert2clavister.ps1'
    $Values['ACME_SCRIPT_PARAMETERS'] = "-PfxPath '{CacheFile}' -CachePassword '{CachePassword}' -ConfigDir $(ConvertTo-ClavisterSingleQuotedArgument -Value $configDir) -DeviceId $(ConvertTo-ClavisterSingleQuotedArgument -Value $deviceId)"

    return $Values
}

Export-ModuleMember -Function Invoke-ClavisterProfileForm,Invoke-ClavisterCertificateRequestSetup,Invoke-ClavisterCertificateTargetSelection
