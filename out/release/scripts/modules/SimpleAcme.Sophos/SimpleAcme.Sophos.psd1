@{
    RootModule = 'SophosFirewallXml.psm1'
    ModuleVersion = '0.1.0'
    GUID = '97b3a57c-14a9-4f4f-98e5-5ad8f742b938'
    Author = 'simple-acme'
    CompanyName = 'simple-acme'
    Copyright = '(c) simple-acme contributors. All rights reserved.'
    Description = 'Sophos Firewall XML API connector helpers for simple-acme certificate deployment.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'ConvertFrom-SophosSecureString',
        'Resolve-SophosPassword',
        'New-SophosApiEndpoint',
        'Protect-SophosLogText',
        'New-SophosRequestXml',
        'Connect-SophosFirewallApi',
        'Invoke-SophosXmlRequest',
        'Get-SophosCertificate',
        'Export-SophosCertificateArchive',
        'Import-SophosCertificate',
        'Remove-SophosCertificate',
        'Get-SophosAdminWebSettings',
        'Set-SophosAdminWebSettingsCertificate',
        'Get-SophosWafRules',
        'Set-SophosWafRuleCertificate',
        'Test-SophosDeploymentVerification',
        'New-SophosSshCommandArguments',
        'Invoke-SophosAdvancedShellCommand',
        'Get-SophosApiExportArtifact',
        'Copy-SophosApiExportArtifact'
    )
    CmdletsToExport = @()
    VariablesToExport = '*'
    AliasesToExport = @()
}
