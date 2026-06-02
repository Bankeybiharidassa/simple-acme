@{
    RootModule = 'KempLoadMaster.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'd31348f7-0a15-49f2-95f0-f3cf04c49e80'
    Author = 'simple-acme'
    CompanyName = 'simple-acme'
    Copyright = '(c) simple-acme contributors. All rights reserved.'
    Description = 'Kemp LoadMaster APIv2 helpers for simple-acme certificate deployment.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Invoke-KempApiV2',
        'Invoke-KempClassicApi',
        'Invoke-KempApi',
        'Test-KempManagementUi',
        'Connect-KempLoadMaster',
        'Get-KempVirtualServices',
        'Import-KempCertificate',
        'Set-KempVirtualServiceCertificate',
        'Test-KempVirtualServiceCertificate',
        'Convert-KempPfxToPemBundle',
        'Resolve-KempPassword',
        'New-KempApiEndpoint'
    )
    CmdletsToExport = @()
    VariablesToExport = '*'
    AliasesToExport = @()
}
