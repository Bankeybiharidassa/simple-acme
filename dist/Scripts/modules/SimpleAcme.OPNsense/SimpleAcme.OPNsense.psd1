@{
    RootModule = 'OPNsenseApi.psm1'
    ModuleVersion = '0.1.0'
    GUID = '66a35b8d-8e5a-43b0-92f6-685640fdf2fd'
    Author = 'simple-acme'
    CompanyName = 'simple-acme'
    Copyright = '(c) simple-acme contributors'
    Description = 'OPNsense API helpers for simple-acme device profile testing and certificate deployment planning.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'New-OPNsenseApiBaseUri',
        'Invoke-OPNsenseApi',
        'Test-OPNsenseApiConnection',
        'Search-OPNsenseCertificates',
        'Get-OPNsenseCertificateServiceInventory',
        'New-OPNsenseCertificateImportPayload'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
