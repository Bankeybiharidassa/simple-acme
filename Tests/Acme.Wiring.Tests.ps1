BeforeAll {
$script:repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $script:repoRoot 'core/Simple-Acme-Reconciler.psm1') -Force
Import-Module (Join-Path $script:repoRoot 'setup/Form-Runner.psm1') -Force

function New-TestEnv {
    param([hashtable]$Overrides = @{})
    $env = @{
        ACME_DIRECTORY = 'https://acme-v02.api.letsencrypt.org/directory'
        DOMAINS = 'example.com'
        ACME_SOURCE_PLUGIN = 'manual'
        ACME_ORDER_PLUGIN = 'single'
        ACME_VALIDATION_MODE = 'none'
        ACME_STORE_PLUGIN = 'certificatestore'
        ACME_CERT_STORE_LOCATION = 'My'
        ACME_INSTALLATION_PLUGINS = 'script'
        ACME_SCRIPT_PATH = 'C:\certificaat\Scripts\cert2rds.ps1'
        ACME_SCRIPT_PARAMETERS = '{CertThumbprint}'
        ACME_CSR_ALGORITHM = 'ec'
        ACME_ALLOW_CSR_FALLBACK = '0'
    }
    foreach ($key in $Overrides.Keys) { $env[$key] = $Overrides[$key] }
    return $env
}

function Assert-ArgValue {
    param([string[]]$ArgList,[string]$Name,[string]$Value)
    $idx = [array]::IndexOf($ArgList, $Name)
    $idx | Should -BeGreaterThan -1
    $ArgList[$idx + 1] | Should -Be $Value
}
function New-TestRenewalSummary {
    param([hashtable]$Overrides = @{})
    $summary = [ordered]@{
        Hosts = @('example.com')
        BaseUri = 'https://acme-v02.api.letsencrypt.org/directory'
        EabKid = ''
        SourcePlugin = 'manual'
        OrderPlugin = 'single'
        StorePlugins = @('certificatestore')
        AccountName = ''
        HasValidationNone = $true
        InstallationPlugins = @('script')
        ScriptPaths = @('C:\certificaat\Scripts\cert2rds.ps1')
        ScriptParameters = @('{CertThumbprint}')
    }
    foreach ($key in $Overrides.Keys) { $summary[$key] = $Overrides[$key] }
    return [pscustomobject]$summary
}
}

Describe 'ACME connector registry' {
    It 'contains all required connector ids and maps scripts' {
        $registry = Get-AcmeConnectorRegistry
        foreach ($id in @('iis','rds','rds-farm','mail','firewall','waf','kemp','netscaler','paloalto','sophos','custom')) {
            $registry.ContainsKey($id) | Should -BeTrue
            $registry[$id].Label | Should -Not -BeNullOrEmpty
            $registry[$id].NoobDescription | Should -Not -BeNullOrEmpty
        }
        Get-ConnectorScriptByIntent -TargetIntent 'rds-farm' | Should -Be 'deploy-rds-farm.ps1'
        { Get-GuidedPipelineTemplate -TargetSystem 'netscaler' -ValidationMode 'none' } | Should -Throw '*post-deployment only*'
    }

    It 'reports healthy ACME TUI wiring diagnostics without secrets' {
        $result = Test-AcmeTuiWiring -ProjectRoot $script:repoRoot
        $result.Passed | Should -BeTrue
        (($result.Checks | ConvertTo-Json -Depth 5) -join '') | Should -Not -Match 'secret|password123|SUPER_SECRET'
    }
}

Describe 'WACS issue argument arrays' {
    It 'builds IIS single system arguments' {
        $actualArgs = @(Get-WacsIssueArguments -EnvValues (New-TestEnv @{ ACME_SOURCE_PLUGIN='iis'; ACME_INSTALLATION_PLUGINS='iis'; ACME_SCRIPT_PATH=''; ACME_SCRIPT_PARAMETERS='' }) -CsrAlgorithm 'ec')
        $actualArgs | Should -Be @('--accepttos','--source','iis','--order','single','--baseuri','https://acme-v02.api.letsencrypt.org/directory','--validation','none','--host','example.com','--store','certificatestore','--certificatestore','My','--nocache','--installation','iis','--csr','ec')
    }

    It 'builds RDS Gateway single arguments' {
        $actualArgs = @(Get-WacsIssueArguments -EnvValues (New-TestEnv @{ ACME_SCRIPT_PATH='C:\certificaat\Scripts\cert2rds.ps1' }) -CsrAlgorithm 'ec')
        $actualArgs | Should -Be @('--accepttos','--source','manual','--order','single','--baseuri','https://acme-v02.api.letsencrypt.org/directory','--validation','none','--host','example.com','--store','certificatestore','--certificatestore','My','--nocache','--installation','script','--script','C:\certificaat\Scripts\cert2rds.ps1','--scriptparameters','{CertThumbprint}','--csr','ec')
    }

    It 'builds RDS farm with session host/PFX arguments' {
        $params = "-CertThumbprint '{CertThumbprint}' -CachePassword '{CachePassword}' -CacheFile '{CacheFile}' -ConfigFile C:\certificaat\runtime\deployment\rds-farm.env"
        $actualArgs = @(Get-WacsIssueArguments -EnvValues (New-TestEnv @{ ACME_TARGET_SYSTEM='rds-farm'; ACME_STORE_PLUGIN='pfxfile,certificatestore'; ACME_PFX_FILE_PATH='C:\certs'; ACME_PFX_PASSWORD='pfx-secret'; ACME_SCRIPT_PATH='C:\certificaat\Scripts\deploy-rds-farm.ps1'; ACME_SCRIPT_PARAMETERS=$params; ACME_PRIVATE_KEY_STRATEGY='pfx-distribution' }) -CsrAlgorithm 'rsa')
        $actualArgs | Should -Be @('--accepttos','--source','manual','--order','single','--baseuri','https://acme-v02.api.letsencrypt.org/directory','--validation','none','--host','example.com','--store','certificatestore,pfxfile','--pfxfilepath','C:\certs','--pfxpassword','pfx-secret','--certificatestore','My','--nocache','--installation','script','--script','C:\certificaat\Scripts\deploy-rds-farm.ps1','--scriptparameters',$params,'--csr','rsa')
    }

    It 'builds mail, firewall, and WAF arguments with mapped scripts' {
        foreach ($case in @(@('mail','cert2mail.ps1'),@('firewall','cert2fw.ps1'),@('waf','cert2waf.ps1'))) {
            $actualArgs = @(Get-WacsIssueArguments -EnvValues (New-TestEnv @{ ACME_SCRIPT_PATH="C:\certificaat\Scripts\$($case[1])" }) -CsrAlgorithm 'ec')
            Assert-ArgValue -ArgList $actualArgs -Name '--script' -Value "C:\certificaat\Scripts\$($case[1])"
            Assert-ArgValue -ArgList $actualArgs -Name '--scriptparameters' -Value '{CertThumbprint}'
            $actualArgs | Should -Contain '--installation'
        }
    }

    It 'builds pfxfile plus certificatestore arguments' {
        $actualArgs = @(Get-WacsIssueArguments -EnvValues (New-TestEnv @{ ACME_STORE_PLUGIN='pfxfile,certificatestore'; ACME_PFX_FILE_PATH='D:\pfx'; ACME_PFX_PASSWORD='pfx-secret' }) -CsrAlgorithm 'ec')
        Assert-ArgValue -ArgList $actualArgs -Name '--store' -Value 'certificatestore,pfxfile'
        Assert-ArgValue -ArgList $actualArgs -Name '--pfxfilepath' -Value 'D:\pfx'
        Assert-ArgValue -ArgList $actualArgs -Name '--pfxpassword' -Value 'pfx-secret'
        Assert-ArgValue -ArgList $actualArgs -Name '--certificatestore' -Value 'My'
    }

    It 'builds Networking4All DV with EAB' {
        $actualArgs = @(Get-WacsIssueArguments -EnvValues (New-TestEnv @{ ACME_DIRECTORY='https://acme.networking4all.com/dv'; ACME_REQUIRES_EAB='1'; ACME_KID='kid-123'; ACME_HMAC_SECRET='hmac-secret' }) -CsrAlgorithm 'ec')
        Assert-ArgValue -ArgList $actualArgs -Name '--baseuri' -Value 'https://acme.networking4all.com/dv'
        Assert-ArgValue -ArgList $actualArgs -Name '--eab-key-identifier' -Value 'kid-123'
        Assert-ArgValue -ArgList $actualArgs -Name '--eab-key' -Value 'hmac-secret'
    }

    It 'builds Networking4All wildcard product with wildcard domain' {
        $actualArgs = @(Get-WacsIssueArguments -EnvValues (New-TestEnv @{ ACME_DIRECTORY='https://acme.networking4all.com/wildcard'; DOMAINS='*.example.com'; ACME_REQUIRES_EAB='1'; ACME_KID='kid-123'; ACME_HMAC_SECRET='hmac-secret' }) -CsrAlgorithm 'ec')
        Assert-ArgValue -ArgList $actualArgs -Name '--baseuri' -Value 'https://acme.networking4all.com/wildcard'
        Assert-ArgValue -ArgList $actualArgs -Name '--host' -Value '*.example.com'
    }

    It 'builds Let''s Encrypt without EAB' {
        $actualArgs = @(Get-WacsIssueArguments -EnvValues (New-TestEnv) -CsrAlgorithm 'ec')
        $actualArgs | Should -Not -Contain '--eab-key-identifier'
        $actualArgs | Should -Not -Contain '--eab-key'
    }

    It 'builds custom ACME with EAB and custom script path' {
        $actualArgs = @(Get-WacsIssueArguments -EnvValues (New-TestEnv @{ ACME_DIRECTORY='https://acme.example.test/directory'; ACME_REQUIRES_EAB='1'; ACME_KID='custom-kid'; ACME_HMAC_SECRET='custom-secret'; ACME_SCRIPT_PATH='D:\hooks\deploy.ps1'; ACME_SCRIPT_PARAMETERS='-Thumb {CertThumbprint} -Mode Custom' }) -CsrAlgorithm 'rsa')
        Assert-ArgValue -ArgList $actualArgs -Name '--baseuri' -Value 'https://acme.example.test/directory'
        Assert-ArgValue -ArgList $actualArgs -Name '--script' -Value 'D:\hooks\deploy.ps1'
        Assert-ArgValue -ArgList $actualArgs -Name '--scriptparameters' -Value '-Thumb {CertThumbprint} -Mode Custom'
        Assert-ArgValue -ArgList $actualArgs -Name '--csr' -Value 'rsa'
    }

    It 'supports RSA and EC key command choices' {
        Assert-ArgValue -ArgList @(Get-WacsIssueArguments -EnvValues (New-TestEnv) -CsrAlgorithm 'rsa') -Name '--csr' -Value 'rsa'
        Assert-ArgValue -ArgList @(Get-WacsIssueArguments -EnvValues (New-TestEnv) -CsrAlgorithm 'ec') -Name '--csr' -Value 'ec'
    }

    It 'masks EAB key, PFX password, and EAB kid in previews' {
        $actualArgs = @(Get-WacsIssueArguments -EnvValues (New-TestEnv @{ ACME_STORE_PLUGIN='pfxfile,certificatestore'; ACME_PFX_FILE_PATH='D:\pfx'; ACME_PFX_PASSWORD='pfx-secret'; ACME_REQUIRES_EAB='1'; ACME_KID='kid-visible'; ACME_HMAC_SECRET='hmac-secret' }) -CsrAlgorithm 'ec')
        $preview = Get-MaskedWacsIssueCommandPreview -EnvValues (New-TestEnv @{ ACME_STORE_PLUGIN='pfxfile,certificatestore'; ACME_PFX_FILE_PATH='D:\pfx'; ACME_PFX_PASSWORD='pfx-secret'; ACME_REQUIRES_EAB='1'; ACME_KID='kid-visible'; ACME_HMAC_SECRET='hmac-secret' }) -CsrAlgorithm 'ec'
        $masked = @(Get-MaskedWacsArgumentsText -Args $actualArgs)
        $masked | Should -Contain '<hidden>'
        $masked | Should -Contain '<set>'
        $preview | Should -Not -Match 'pfx-secret|hmac-secret|kid-visible'
        $preview | Should -Match '--eab-key-identifier <set>'
    }

    It 'has enough non-interactive issue arguments for script installation and CSR' {
        $actualArgs = @(Get-WacsIssueArguments -EnvValues (New-TestEnv) -CsrAlgorithm 'ec')
        foreach ($required in @('--source','--order','--baseuri','--validation','--host','--store','--installation','--script','--scriptparameters','--csr','--accepttos','--nocache')) {
            $actualArgs | Should -Contain $required
        }
    }
    It 'rejects rds-farm preview generation without required PFX settings' {
        $farmTemplate = Get-GuidedPipelineTemplate -TargetSystem 'rds-farm' -ValidationMode 'none'
        $env = New-TestEnv @{
            ACME_TARGET_SYSTEM = 'rds-farm'
            ACME_STORE_PLUGIN = [string]$farmTemplate.ACME_STORE_PLUGIN
            ACME_SCRIPT_PATH = [string]$farmTemplate.ACME_SCRIPT_PATH
            ACME_SCRIPT_PARAMETERS = [string]$farmTemplate.ACME_SCRIPT_PARAMETERS
            ACME_PRIVATE_KEY_STRATEGY = 'pfx-distribution'
        }
        { Get-MaskedWacsIssueCommandPreview -EnvValues $env -CsrAlgorithm 'ec' } | Should -Throw '*ACME_PFX_FILE_PATH*'
    }

    It 'builds rds-farm masked preview with PFX path, hidden password, script, and full script parameters' {
        $params = "-CertThumbprint '{CertThumbprint}' -CachePassword '{CachePassword}' -CacheFile '{CacheFile}' -ConfigFile 'C:\certificaat\runtime\deployment\rds-farm.env'"
        $preview = Get-MaskedWacsIssueCommandPreview -EnvValues (New-TestEnv @{ ACME_TARGET_SYSTEM='rds-farm'; ACME_STORE_PLUGIN='pfxfile,certificatestore'; ACME_PFX_FILE_PATH='C:\certs'; ACME_PFX_PASSWORD='pfx-secret'; ACME_SCRIPT_PATH='C:\certificaat\Scripts\deploy-rds-farm.ps1'; ACME_SCRIPT_PARAMETERS=$params; ACME_PRIVATE_KEY_STRATEGY='pfx-distribution' }) -CsrAlgorithm 'rsa'
        $preview | Should -Match '--pfxfilepath C:\\certs'
        $preview | Should -Match '--pfxpassword <hidden>'
        $preview | Should -Match '--script C:\\certificaat\\Scripts\\deploy-rds-farm\.ps1'
        $preview | Should -Match ([regex]::Escape($params))
        $preview | Should -Not -Match 'pfx-secret'
    }
}

Describe 'Preflight and renewal script parameter validation' {
    It 'defaults empty script parameters to thumbprint only when empty' {
        $scriptFile = Join-Path $TestDrive 'hook.ps1'; 'param()' | Set-Content $scriptFile
        $wacsFile = Join-Path $TestDrive 'wacs.exe'; 'stub' | Set-Content $wacsFile
        $env = New-TestEnv @{ ACME_WACS_PATH=$wacsFile; ACME_WACS_VERSION='Software version 2.3.0.0'; ACME_SCRIPT_PATH=$scriptFile; ACME_SCRIPT_PARAMETERS='' }
        Test-ReconcilePreflight -EnvValues $env | Out-Null
        $env.ACME_SCRIPT_PARAMETERS | Should -Be '{CertThumbprint}'
    }

    It 'preserves rds-farm, custom, and NetScaler-style non-empty script parameters' {
        foreach ($paramText in @("-CertThumbprint '{CertThumbprint}' -CachePassword '{CachePassword}' -CacheFile '{CacheFile}'", '-Thumb {CertThumbprint} -Target custom', '-CertPath {CacheFile} -CertKeyName adc-cert -CertThumbprint {CertThumbprint}')) {
            $scriptFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ps1'); 'param()' | Set-Content $scriptFile
            $wacsFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.exe'); 'stub' | Set-Content $wacsFile
            $env = New-TestEnv @{ ACME_WACS_PATH=$wacsFile; ACME_WACS_VERSION='Software version 2.3.0.0'; ACME_SCRIPT_PATH=$scriptFile; ACME_SCRIPT_PARAMETERS=$paramText }
            Test-ReconcilePreflight -EnvValues $env | Out-Null
            $env.ACME_SCRIPT_PARAMETERS | Should -Be $paramText
        }
    }

    It 'compares renewal parameters against ACME_SCRIPT_PARAMETERS exactly after safe normalization' {
        $summary = New-TestRenewalSummary @{ ScriptPaths=@('C:\certificaat\Scripts\deploy-rds-farm.ps1'); ScriptParameters=@("-CertThumbprint   '{CertThumbprint}'   -CachePassword '{CachePassword}' -CacheFile '{CacheFile}'") }
        $env = New-TestEnv @{ ACME_SCRIPT_PATH='C:\certificaat\Scripts\deploy-rds-farm.ps1'; ACME_SCRIPT_PARAMETERS="-CertThumbprint '{CertThumbprint}' -CachePassword '{CachePassword}' -CacheFile '{CacheFile}'" }
        (Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $env).Matches | Should -BeTrue

        $summary.ScriptParameters = @('{CertThumbprint}')
        $env.ACME_SCRIPT_PARAMETERS = '{CertThumbprint}'
        (Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $env).Matches | Should -BeTrue

        $summary.ScriptParameters = @('-Wrong {CertThumbprint}')
        $bad = Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $env
        $bad.Matches | Should -BeFalse
        $bad.Mismatches | Should -Contain 'Script parameters'

        $summary.ScriptParameters = @()
        $missing = Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $env
        $missing.Matches | Should -BeFalse
        $missing.Mismatches | Should -Contain 'Script parameters'
    }
    It 'validates IIS renewal without script path or parameters' {
        $summary = New-TestRenewalSummary @{ SourcePlugin='iis'; InstallationPlugins=@('iis'); ScriptPaths=@(); ScriptParameters=@() }
        $env = New-TestEnv @{ ACME_SOURCE_PLUGIN='iis'; ACME_INSTALLATION_PLUGINS='iis'; ACME_SCRIPT_PATH=''; ACME_SCRIPT_PARAMETERS='' }
        (Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $env).Matches | Should -BeTrue
    }

    It 'fails IIS renewal when installer differs' {
        $summary = New-TestRenewalSummary @{ SourcePlugin='iis'; InstallationPlugins=@('script'); ScriptPaths=@(); ScriptParameters=@() }
        $env = New-TestEnv @{ ACME_SOURCE_PLUGIN='iis'; ACME_INSTALLATION_PLUGINS='iis'; ACME_SCRIPT_PATH=''; ACME_SCRIPT_PARAMETERS='' }
        $result = Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $env
        $result.Matches | Should -BeFalse
        $result.Mismatches | Should -Contain 'Installation plugins'
    }

    It 'still validates script renewals by exact script path and parameters' {
        $summary = New-TestRenewalSummary
        $env = New-TestEnv
        (Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $env).Matches | Should -BeTrue

        $summary.ScriptPaths = @('C:\wrong.ps1')
        $wrongPath = Compare-RenewalWithEnv -RenewalSummary $summary -EnvValues $env
        $wrongPath.Matches | Should -BeFalse
        $wrongPath.Mismatches | Should -Contain 'Script path'
    }
}

Describe 'Static guard for WACS preview source of truth' {
    It 'has no manual WACS preview builders in setup or core TUI code' {
        $formText = Get-Content -LiteralPath (Join-Path $script:repoRoot 'setup/Form-Runner.psm1') -Raw
        $formText | Should -Not -Match 'wacs\.exe --accepttos'
        $formText | Should -Not -Match ' --source manual --order single '
    }
    It 'diagnostics resolve lower-case release manifest script paths against upper-case Scripts directory' {
        $result = Test-AcmeTuiWiring -ProjectRoot $script:repoRoot
        $result.Passed | Should -BeTrue
        ($result.Checks | Where-Object { $_.Name -eq 'Release manifest file exists: scripts/cert2rds.ps1' }).Passed | Should -BeTrue
        ($result.Checks | Where-Object { $_.Name -eq 'Release output file exists: scripts/deploy-rds-farm.ps1' }).Passed | Should -BeTrue
        ($result.Checks | Where-Object { $_.Name -eq 'Release output file exists: scripts/modules/SimpleAcme.Sophos/SophosFirewallXml.psm1' }).Passed | Should -BeTrue
        ($result.Checks | Where-Object { $_.Name -eq 'Release output file exists: setup/Sophos-Runner.psm1' }).Passed | Should -BeTrue
    }
}
