@{
    RootModule        = 'NetscalerNitro.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'fb22b98b-16fa-4ec5-bbf0-c1e4c8414ed3'
    Author            = 'simple-acme contributors'
    CompanyName       = 'simple-acme'
    Copyright         = '(c) simple-acme contributors. All rights reserved.'
    Description       = 'NetScaler (Citrix ADC) NITRO deployment connector helpers for simple-acme certificate deployment.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'ConvertFrom-NetscalerSecureString',
        'Resolve-NetscalerPassword',
        'New-NetscalerNitroBaseUri',
        'Connect-NetscalerNitroSession',
        'Disconnect-NetscalerNitroSession',
        'Invoke-NetscalerNitroRequest',
        'Test-NetscalerLocalCertificateFiles',
        'Get-NetscalerHAState',
        'Assert-NetscalerPrimary',
        'Send-NetscalerSslFile',
        'Get-NetscalerSslCertKey',
        'Set-NetscalerSslCertKey',
        'Get-NetscalerSslVServerCertBindings',
        'Test-NetscalerServerCertificateBinding',
        'Set-NetscalerSslVServerCertBinding',
        'Save-NetscalerConfig',
        'Sync-NetscalerHA',
        'Test-NetscalerDeploymentVerification'
    )
    CmdletsToExport   = @()
    VariablesToExport = '*'
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('simple-acme', 'netscaler', 'citrix-adc', 'nitro', 'certificate')
            ProjectUri = 'https://github.com/Bankeybiharidassa/simple-acme'
        }
    }
}
