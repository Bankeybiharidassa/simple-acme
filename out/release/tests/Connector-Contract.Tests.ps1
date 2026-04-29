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

    It 'keeps CertThumbprint parameter attributes aligned between duplicate cert2rds scripts' {
        $rootAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Scripts/cert2rds.ps1'), [ref]$null, [ref]$null)
        $connectorAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Scripts/connectors/cert2rds.ps1'), [ref]$null, [ref]$null)

        $rootParam = @($rootAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'CertThumbprint' })[0]
        $connectorParam = @($connectorAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'CertThumbprint' })[0]

        $rootParam.StaticType.Name | Should -Be 'String'
        $connectorParam.StaticType.Name | Should -Be 'String'

        $rootAttrs = @($rootParam.Attributes | ForEach-Object { $_.Extent.Text })
        $connectorAttrs = @($connectorParam.Attributes | ForEach-Object { $_.Extent.Text })

        ($rootAttrs -join ' ') | Should -Match 'Mandatory\s*=\s*\$true'
        ($connectorAttrs -join ' ') | Should -Match 'Mandatory\s*=\s*\$true'
        ($rootAttrs -join ' ') | Should -Match 'Position\s*=\s*0'
        ($connectorAttrs -join ' ') | Should -Match 'Position\s*=\s*0'
        ($rootAttrs -join ' ') | Should -Match 'ValidateNotNullOrEmpty'
        ($connectorAttrs -join ' ') | Should -Match 'ValidateNotNullOrEmpty'
    }

    It 'keeps duplicate cert2rds script parameter names aligned' {
        $rootAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Scripts/cert2rds.ps1'), [ref]$null, [ref]$null)
        $connectorAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Scripts/connectors/cert2rds.ps1'), [ref]$null, [ref]$null)

        $rootParams = @($rootAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $connectorParams = @($connectorAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $rootParams | Should -Be $connectorParams
    }
}
