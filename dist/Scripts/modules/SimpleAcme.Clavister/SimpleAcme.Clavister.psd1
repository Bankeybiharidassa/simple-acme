@{
    RootModule = 'ClavisterSsh.psm1'
    ModuleVersion = '0.1.0'
    GUID = '5dfef0f8-d6f3-4a74-a2c5-5ad0d63c4f7a'
    Author = 'simple-acme'
    CompanyName = 'simple-acme'
    Copyright = '(c) simple-acme contributors. All rights reserved.'
    Description = 'Clavister cOS Core SSH/SCP helpers for simple-acme certificate deployment.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'ConvertFrom-ClavisterSecureString',
        'Convert-ClavisterPfxToPemFiles',
        'Invoke-ClavisterScpUpload',
        'Invoke-ClavisterSshCommand',
        'Get-ClavisterCertificateServiceInventory',
        'Set-ClavisterCertificateServiceBinding',
        'Test-ClavisterSshConnection'
    )
    CmdletsToExport = @()
    VariablesToExport = '*'
    AliasesToExport = @()
}
