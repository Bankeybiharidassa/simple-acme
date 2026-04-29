Set-StrictMode -Version Latest

Describe 'Connector thumbprint contract and script signature drift' {
    It 'rejects invalid thumbprint format using shared validator' {
        Import-Module (Join-Path $PSScriptRoot '../Scripts/core/connector-core.psm1') -Force
        { Assert-CertThumbprint -CertThumbprint 'not-a-thumbprint' } | Should -Throw '*[CERT_THUMBPRINT_INVALID]*'
    }

    It 'accepts valid thumbprint and normalizes case/whitespace' {
        Import-Module (Join-Path $PSScriptRoot '../Scripts/core/connector-core.psm1') -Force
        $value = Assert-CertThumbprint -CertThumbprint ' aa bb cc dd ee ff 00 11 22 33 44 55 66 77 88 99 aa bb cc dd '
        $value | Should -Be 'AABBCCDDEEFF00112233445566778899AABBCCDD'
    }

    It 'keeps CertThumbprint param signature aligned between duplicate cert2rds scripts' {
        $rootScript = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../Scripts/cert2rds.ps1')
        $connectorScript = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../Scripts/connectors/cert2rds.ps1')

        ($rootScript -match '\[string\]\$CertThumbprint') | Should -BeTrue
        ($connectorScript -match '\[string\]\$CertThumbprint') | Should -BeTrue
        ($rootScript -match '\[Parameter\(Mandatory=\$true') | Should -BeTrue
        ($connectorScript -match '\[Parameter\(Mandatory') | Should -BeTrue
    }
}
