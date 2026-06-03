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

    $Values['ACME_TARGET_SYSTEM'] = 'clavister'
    $Values['TARGET_SYSTEM'] = 'clavister'
    $Values['ACME_TARGET_DEVICE_TYPE'] = 'clavister'
    $Values['ACME_TARGET_DEVICE_LABEL'] = 'Clavister NetWall / cOS Core'
    $Values['ACME_INSTALLATION_PLUGINS'] = 'script'
    $Values['ACME_STORE_PLUGIN'] = 'pfxfile,certificatestore'
    $Values['ACME_SCRIPT_PATH'] = Join-Path $ProjectRoot 'Scripts\cert2clavister.ps1'
    $Values['ACME_SCRIPT_PARAMETERS'] = "-PfxPath '{CacheFile}' -CachePassword '{CachePassword}' -ConfigDir $(ConvertTo-ClavisterSingleQuotedArgument -Value $configDir)"

    return $Values
}

Export-ModuleMember -Function Invoke-ClavisterProfileForm,Invoke-ClavisterCertificateRequestSetup
