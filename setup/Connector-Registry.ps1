Set-StrictMode -Version Latest

function New-AcmeConnectorRegistryEntry {
    param(
        [Parameter(Mandatory)][string]$ConnectorId,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$NoobDescription,
        [Parameter(Mandatory)][string]$Category,
        [string]$ScriptFileName = '',
        [bool]$FirstRunAcmeSupported = $false,
        [bool]$PostIssuanceDeploySupported = $true,
        [string]$DefaultSourcePlugin = 'manual',
        [string]$DefaultOrderPlugin = 'single',
        [string]$DefaultStorePlugin = 'certificatestore',
        [string]$DefaultInstallationPlugin = 'script',
        [string]$DefaultScriptParameters = '{CertThumbprint}',
        [bool]$RequiresPfx = $false,
        [bool]$RequiresCertStore = $true,
        [bool]$RequiresExportableKey = $false,
        [bool]$RequiresManualTargetConfig = $false
    )

    return [pscustomobject]@{
        ConnectorId = $ConnectorId
        Label = $Label
        OperatorLabel = $Label
        NoobDescription = $NoobDescription
        Category = $Category
        ScriptFileName = $ScriptFileName
        ScriptPath = $(if ([string]::IsNullOrWhiteSpace($ScriptFileName)) { '' } else { Join-Path 'Scripts' $ScriptFileName })
        FirstRunAcmeSupported = $FirstRunAcmeSupported
        first_run_acme_supported = $FirstRunAcmeSupported
        PostIssuanceDeploySupported = $PostIssuanceDeploySupported
        post_issuance_deploy_supported = $PostIssuanceDeploySupported
        DefaultSourcePlugin = $DefaultSourcePlugin
        DefaultOrderPlugin = $DefaultOrderPlugin
        DefaultStorePlugin = $DefaultStorePlugin
        DefaultInstallationPlugin = $DefaultInstallationPlugin
        DefaultScriptParameters = $DefaultScriptParameters
        default_script_parameters = $DefaultScriptParameters
        RequiresPfx = $RequiresPfx
        requires_pfx = $RequiresPfx
        RequiresCertStore = $RequiresCertStore
        requires_cert_store = $RequiresCertStore
        RequiresExportableKey = $RequiresExportableKey
        RequiresManualTargetConfig = $RequiresManualTargetConfig
        script_path = $(if ([string]::IsNullOrWhiteSpace($ScriptFileName)) { '' } else { Join-Path 'Scripts' $ScriptFileName })
        operator_label = $Label
        noob_description = $NoobDescription
    }
}

function Get-AcmeConnectorRegistry {
    $entries = @(
        New-AcmeConnectorRegistryEntry -ConnectorId 'iis' -Label 'Website on IIS' -NoobDescription 'Issue and install directly into IIS on this Windows server.' -Category 'local_windows' -ScriptFileName 'cert2iis.ps1' -FirstRunAcmeSupported $true -PostIssuanceDeploySupported $true -DefaultSourcePlugin 'iis' -DefaultInstallationPlugin 'iis' -DefaultScriptParameters '' -RequiresManualTargetConfig $false
        New-AcmeConnectorRegistryEntry -ConnectorId 'rds' -Label 'Remote Desktop Gateway / RD Web' -NoobDescription 'Issue a certificate and run the Remote Desktop Gateway / RD Web deployment script.' -Category 'local_windows' -ScriptFileName 'cert2rds.ps1' -FirstRunAcmeSupported $true
        New-AcmeConnectorRegistryEntry -ConnectorId 'rds-farm' -Label 'Remote Desktop Gateway + Session Hosts farm' -NoobDescription 'Issue once, export PFX, and fan out to RDS Gateway and Session Hosts.' -Category 'local_windows' -ScriptFileName 'deploy-rds-farm.ps1' -FirstRunAcmeSupported $true -DefaultStorePlugin 'pfxfile,certificatestore' -DefaultScriptParameters "-CertThumbprint '{CertThumbprint}' -CachePassword '{CachePassword}' -CacheFile '{CacheFile}'" -RequiresPfx $true -RequiresExportableKey $true -RequiresManualTargetConfig $true
        New-AcmeConnectorRegistryEntry -ConnectorId 'mail' -Label 'Mail server' -NoobDescription 'Issue a certificate and run the mail server deployment hook.' -Category 'server' -ScriptFileName 'cert2mail.ps1' -FirstRunAcmeSupported $true
        New-AcmeConnectorRegistryEntry -ConnectorId 'firewall' -Label 'Firewall / VPN' -NoobDescription 'Issue a certificate and run the generic firewall/VPN deployment hook.' -Category 'network_appliance' -ScriptFileName 'cert2fw.ps1' -FirstRunAcmeSupported $true -RequiresManualTargetConfig $true
        New-AcmeConnectorRegistryEntry -ConnectorId 'waf' -Label 'Load balancer / WAF' -NoobDescription 'Issue a certificate and run the generic load balancer / WAF deployment hook.' -Category 'network_appliance' -ScriptFileName 'cert2waf.ps1' -FirstRunAcmeSupported $true -RequiresManualTargetConfig $true
        New-AcmeConnectorRegistryEntry -ConnectorId 'kemp' -Label 'Kemp LoadMaster' -NoobDescription 'Available after certificate issuance / post-deployment only. Configure appliance fields from Deployment targets.' -Category 'network_appliance' -ScriptFileName 'cert2kemp.ps1' -FirstRunAcmeSupported $false -PostIssuanceDeploySupported $true -RequiresPfx $true -RequiresManualTargetConfig $true
        New-AcmeConnectorRegistryEntry -ConnectorId 'netscaler' -Label 'NetScaler / Citrix ADC' -NoobDescription 'Available after certificate issuance / post-deployment only. Use the NetScaler deployment target workflow.' -Category 'network_appliance' -ScriptFileName 'cert2netscaler.ps1' -FirstRunAcmeSupported $false -PostIssuanceDeploySupported $true -RequiresPfx $true -RequiresManualTargetConfig $true
        New-AcmeConnectorRegistryEntry -ConnectorId 'paloalto' -Label 'Palo Alto firewall' -NoobDescription 'Available after certificate issuance / post-deployment only. Configure firewall deployment separately.' -Category 'network_appliance' -ScriptFileName 'deploy-paloalto.ps1' -FirstRunAcmeSupported $false -PostIssuanceDeploySupported $true -RequiresPfx $true -RequiresManualTargetConfig $true
        New-AcmeConnectorRegistryEntry -ConnectorId 'sophos' -Label 'Sophos firewall' -NoobDescription 'Issue a certificate and run the Sophos XGS deployment hook from saved device profile and target bindings.' -Category 'network_appliance' -ScriptFileName 'deploy-sophos.ps1' -FirstRunAcmeSupported $true -PostIssuanceDeploySupported $true -DefaultStorePlugin 'pfxfile,certificatestore' -DefaultScriptParameters "-PfxPath '{CacheFile}'" -RequiresPfx $true -RequiresManualTargetConfig $true
        New-AcmeConnectorRegistryEntry -ConnectorId 'custom' -Label 'Custom script' -NoobDescription 'Issue a certificate and run an operator-provided deployment script with operator-provided parameters.' -Category 'custom' -ScriptFileName '' -FirstRunAcmeSupported $true -PostIssuanceDeploySupported $true -RequiresManualTargetConfig $true
    )

    $registry = @{}
    foreach ($entry in $entries) { $registry[$entry.ConnectorId] = $entry }
    return $registry
}

function Get-AcmeConnectorRegistryEntry {
    param([Parameter(Mandatory)][string]$ConnectorId)
    $registry = Get-AcmeConnectorRegistry
    $normalized = $ConnectorId.Trim().ToLowerInvariant()
    if (-not $registry.ContainsKey($normalized)) { throw "Unsupported connector id '$ConnectorId'." }
    return $registry[$normalized]
}

function Get-AcmeConnectorScriptFileName {
    param([Parameter(Mandatory)][string]$ConnectorId)
    return [string](Get-AcmeConnectorRegistryEntry -ConnectorId $ConnectorId).ScriptFileName
}
