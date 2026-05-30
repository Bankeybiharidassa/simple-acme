Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')
    $script:modulePath = Join-Path $script:repoRoot 'Scripts/Modules/SimpleAcme.Sophos/SimpleAcme.Sophos.psd1'
    $script:moduleFile = Join-Path $script:repoRoot 'Scripts/Modules/SimpleAcme.Sophos/SophosFirewallXml.psm1'
    $script:scriptPath = Join-Path $script:repoRoot 'Scripts/deploy-sophos.ps1'
    $script:runnerPath = Join-Path $script:repoRoot 'setup/Sophos-Runner.psm1'
}

Describe 'Sophos connector static validation' {
    It 'module imports successfully' {
        { Import-Module $script:modulePath -Force -ErrorAction Stop } | Should -Not -Throw
        Get-Command -Module SimpleAcme.Sophos | Where-Object Name -eq 'Invoke-SophosXmlRequest' | Should -Not -BeNullOrEmpty
    }

    It 'script, module, manifest, and runner parse successfully' {
        foreach ($file in @($script:scriptPath, $script:moduleFile, $script:modulePath, $script:runnerPath)) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
            $errors | Should -BeNullOrEmpty
        }
    }

    It 'redacts sensitive XML and password text' {
        Import-Module $script:modulePath -Force
        $safe = Protect-SophosLogText '<Password>abc</Password><CertificateFile>cert</CertificateFile><PrivateKeyFile>key</PrivateKeyFile> password=abc'
        $safe | Should -Not -Match 'abc|cert|key'
        $safe | Should -Match '<Password>\*\*\*</Password>'
    }

    It 'builds XML request with escaped credentials' {
        Import-Module $script:modulePath -Force
        $xml = New-SophosRequestXml -Username 'admin&ops' -Password 'p<q' -InnerXml '<Get><AdminSettings></AdminSettings></Get>'
        $xml | Should -Match 'admin&amp;ops'
        $xml | Should -Match 'p&lt;q'
        { [xml]$xml } | Should -Not -Throw
    }

    It 'constructs API endpoint safely' {
        Import-Module $script:modulePath -Force
        New-SophosApiEndpoint -Firewall '192.0.2.10' -Port 4444 | Should -Be 'https://192.0.2.10:4444/webconsole/APIController'
        { New-SophosApiEndpoint -Firewall 'https://192.0.2.10' } | Should -Throw '*host name or IP*'
    }

    It 'SSH argument construction supports password and key auth with host key pinning' {
        Import-Module $script:modulePath -Force
        $key = Join-Path $TestDrive 'sophos.ppk'
        Set-Content -LiteralPath $key -Value 'dummy'
        $passwordArgs = New-SophosSshCommandArguments -Executable 'plink.exe' -HostName 'fw' -Username 'admin' -HostKeyFingerprint 'SHA256:test' -Password 'pw'
        $passwordArgs | Should -Contain '-pw'
        $keyArgs = New-SophosSshCommandArguments -Executable 'pscp.exe' -HostName 'fw' -Username 'admin' -HostKeyFingerprint 'SHA256:test' -PrivateKeyPath $key -RemotePath '/var/API-test.tar' -LocalPath (Join-Path $TestDrive 'out.tar')
        $keyArgs | Should -Contain '-i'
        { New-SophosSshCommandArguments -Executable 'plink.exe' -HostName 'fw' -Username 'admin' -Password 'pw' } | Should -Throw '*host key*'
    }
}

Describe 'Sophos XML parsing behavior' {
    BeforeEach {
        Import-Module $script:modulePath -Force
        Mock -ModuleName SimpleAcme.Sophos Invoke-WebRequest {
            [pscustomobject]@{
                StatusCode = 200
                Headers = @{ 'Content-Type' = 'text/xml' }
                Content = $script:SophosMockContent
            }
        }
    }

    It 'Get-SophosCertificate marks zero-byte export response' {
        $script:SophosMockContent = ''
        $null = Connect-SophosFirewallApi -Firewall 'fw' -Username 'admin' -Password 'pw' -TimeoutSeconds 1
        $result = Get-SophosCertificate
        $result.IsEmptyExportResponse | Should -BeTrue
        @($result.Certificates).Count | Should -Be 0
    }

    It 'Get-SophosCertificate parses certificate metadata when returned' {
        $script:SophosMockContent = @'
<Response>
  <Login><status>Authentication Successful</status></Login>
  <Certificate><Name>wildcard</Name><Action>UploadCertificate</Action><CertificateFormat>pem</CertificateFormat><CertificateFile>wildcard.pem</CertificateFile><PrivateKeyFile>wildcard.key</PrivateKeyFile></Certificate>
</Response>
'@
        $null = Connect-SophosFirewallApi -Firewall 'fw' -Username 'admin' -Password 'pw' -TimeoutSeconds 1
        $result = Get-SophosCertificate
        $result.IsEmptyExportResponse | Should -BeFalse
        $result.Certificates[0].Name | Should -Be 'wildcard'
    }

    It 'Get-SophosWafRules extracts HTTPBased rules and HTTPSCertificate' {
        $script:SophosMockContent = @'
<Response>
  <Login><status>Authentication Successful</status></Login>
  <FirewallRule>
    <Name>rdgw</Name>
    <Status>Enable</Status>
    <PolicyType>HTTPBased</PolicyType>
    <HTTPBasedPolicy>
      <HostedAddress>#PortB</HostedAddress>
      <HTTPSCertificate>wildcard</HTTPSCertificate>
      <ListenPort>443</ListenPort>
      <Domains><Domain>remote.example.test</Domain></Domains>
    </HTTPBasedPolicy>
  </FirewallRule>
  <FirewallRule><Name>lan-out</Name><PolicyType>Network</PolicyType></FirewallRule>
</Response>
'@
        $null = Connect-SophosFirewallApi -Firewall 'fw' -Username 'admin' -Password 'pw' -TimeoutSeconds 1
        $rules = @(Get-SophosWafRules)
        $rules.Count | Should -Be 1
        $rules[0].Name | Should -Be 'rdgw'
        $rules[0].HttpsCertificate | Should -Be 'wildcard'
    }
}

Describe 'Sophos TUI wiring' {
    It 'runner reports expected wiring files and keys' {
        Import-Module $script:runnerPath -Force
        $wiring = Test-SophosTuiWiring -ProjectRoot $script:repoRoot
        $wiring.ScriptExists | Should -BeTrue
        $wiring.ModuleManifestExists | Should -BeTrue
        $wiring.RunnerExists | Should -BeTrue
        @($wiring.MissingSchemaFields).Count | Should -Be 0
        @($wiring.MenuKeysPresent | Where-Object { -not $_.Present }).Count | Should -Be 0
        @($wiring.SetupDispatchPresent | Where-Object { -not $_.Present }).Count | Should -Be 0
        $wiring.ReleaseManifestIncludesRuntime | Should -BeTrue
    }
}
