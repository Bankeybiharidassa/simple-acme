Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/../core/Tui-Engine.psm1" -Force -Global
Import-Module "$PSScriptRoot/../core/Config-Store.psm1" -Force -Global

function Resolve-DeviceProfileConfigDir {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $configured = [Environment]::GetEnvironmentVariable('CERTIFICATE_CONFIG_DIR')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        return [IO.Path]::GetFullPath($configured)
    }

    return [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'config'))
}

function Test-DeviceProfileLikelyPlaintextSecret {
    param([object]$Value)

    if ($null -eq $Value) { return $false }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($text -match '[^A-Za-z0-9_.-]') { return $true }
    return $false
}

function Get-DeviceProfileCurrentValues {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$ConnectorType,
        [string[]]$CertificateRuntimeKeys = @(),
        [hashtable]$PlaintextSecretNameFields = @{}
    )

    $existing = @(Get-AllDeviceConfigs -ConfigDir $ConfigDir -SkipIntegrityFailures | Where-Object {
        $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]($_['connector_type']) -eq $ConnectorType
    } | Select-Object -First 1)
    if ($existing.Count -lt 1 -or $null -eq $existing[0]) { return @{} }
    if (-not ($existing[0] -is [System.Collections.IDictionary]) -or -not $existing[0].ContainsKey('settings')) { return @{} }
    $settings = $existing[0]['settings']
    if (-not ($settings -is [System.Collections.IDictionary])) { return @{} }

    $current = @{}
    foreach ($key in $settings.Keys) { $current[[string]$key] = [string]$settings[$key] }

    foreach ($secretNameField in $PlaintextSecretNameFields.Keys) {
        $secretField = [string]$PlaintextSecretNameFields[$secretNameField]
        if ([string]::IsNullOrWhiteSpace($secretField)) { continue }
        if (-not $current.ContainsKey($secretField) -and $current.ContainsKey($secretNameField) -and (Test-DeviceProfileLikelyPlaintextSecret -Value $current[$secretNameField])) {
            $current[$secretField] = [string]$current[$secretNameField]
            $current[$secretNameField] = ''
        }
    }

    foreach ($certificateKey in @($CertificateRuntimeKeys)) {
        if ($current.ContainsKey($certificateKey)) { $current.Remove($certificateKey) }
    }
    return $current
}

function Add-DeviceProfileDefaults {
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

function Remove-DeviceProfilePlaceholderValues {
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

function Save-DeviceProfile {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$ConnectorType,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][hashtable]$Values,
        [string[]]$SecretFields = @(),
        [string]$DefaultDeviceId = ''
    )

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $existing = @(Get-AllDeviceConfigs -ConfigDir $ConfigDir -SkipIntegrityFailures | Where-Object {
        $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]($_['connector_type']) -eq $ConnectorType
    } | Select-Object -First 1)

    $deviceId = if (-not [string]::IsNullOrWhiteSpace($DefaultDeviceId)) { $DefaultDeviceId } else { "$ConnectorType-device" }
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
        connector_type = $ConnectorType
        label = $Label
        created_at = $createdAt
        updated_at = $now
        settings = $settings
    }
    Save-DeviceConfig -Device $device -ConfigDir $ConfigDir -SecretFields $SecretFields | Out-Null
}

function Invoke-DeviceProfileForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConnectorType,
        [string]$Title = '',
        [string]$DefaultDeviceId = '',
        [string[]]$CertificateRuntimeKeys = @(),
        [hashtable]$PlaintextSecretNameFields = @{},
        [string[]]$SecretFields = @()
    )

    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    . $schemaPath
    if (-not $DeviceSchemas.ContainsKey($ConnectorType)) { throw "Device schema '$ConnectorType' was not found in $schemaPath" }

    $schema = $DeviceSchemas[$ConnectorType]
    $formTitle = if (-not [string]::IsNullOrWhiteSpace($Title)) { $Title } else { "{0} device profile" -f [string]$schema.Label }
    $label = if ($schema.ContainsKey('Label') -and -not [string]::IsNullOrWhiteSpace([string]$schema.Label)) { [string]$schema.Label } else { $ConnectorType }
    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $currentValues = Remove-DeviceProfilePlaceholderValues -Values (Get-DeviceProfileCurrentValues -ConfigDir $configDir -ConnectorType $ConnectorType -CertificateRuntimeKeys $CertificateRuntimeKeys -PlaintextSecretNameFields $PlaintextSecretNameFields) -Fields @($schema.Fields)
    $currentValues = Add-DeviceProfileDefaults -Values $currentValues -Fields @($schema.Fields)
    $values = Show-TuiForm -Fields ([hashtable[]]$schema.Fields) -CurrentValues $currentValues -Title $formTitle
    if ($null -eq $values) { return [pscustomobject]@{ Status = 'Canceled' } }
    $values = Remove-DeviceProfilePlaceholderValues -Values $values -Fields @($schema.Fields)
    $values = Add-DeviceProfileDefaults -Values $values -Fields @($schema.Fields)
    Save-DeviceProfile -ConfigDir $configDir -ConnectorType $ConnectorType -Label $label -Values $values -SecretFields $SecretFields -DefaultDeviceId $DefaultDeviceId
    Show-TuiStatus -Message ("{0} device profile saved." -f $label) -Type Success -Row ([Math]::Max(0,[Console]::WindowHeight)-2)
    Start-Sleep -Milliseconds 1200
    return [pscustomobject]@{ Status = 'Saved'; ConfigDir = $configDir }
}

Export-ModuleMember -Function Resolve-DeviceProfileConfigDir,Get-DeviceProfileCurrentValues,Add-DeviceProfileDefaults,Remove-DeviceProfilePlaceholderValues,Save-DeviceProfile,Invoke-DeviceProfileForm,Test-DeviceProfileLikelyPlaintextSecret
