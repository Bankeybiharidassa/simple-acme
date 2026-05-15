Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
$script:repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')
    $script:modulePath = Join-Path $script:repoRoot 'Scripts/Modules/SimpleAcme.Netscaler/SimpleAcme.Netscaler.psd1'
    $script:moduleFile = Join-Path $script:repoRoot 'Scripts/Modules/SimpleAcme.Netscaler/NetscalerNitro.psm1'
    $script:manifestPath = Join-Path $script:repoRoot 'Scripts/Modules/SimpleAcme.Netscaler/SimpleAcme.Netscaler.psd1'
    $script:scriptPath = Join-Path $script:repoRoot 'Scripts/cert2netscaler.ps1'
    $script:sourceMapPath = Join-Path $script:repoRoot 'Docs/connectors/netscaler-source-map.json'
}

Describe 'NetScaler connector static validation' {
    It 'module imports successfully' {
        { Import-Module $script:modulePath -Force -ErrorAction Stop } | Should -Not -Throw
        Get-Command -Module SimpleAcme.Netscaler | Where-Object Name -eq 'Invoke-NetscalerNitroRequest' | Should -Not -BeNullOrEmpty
    }

    It 'script and module parse successfully' {
        foreach ($file in @($script:scriptPath, $script:moduleFile, $script:manifestPath)) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
            $errors | Should -BeNullOrEmpty
        }
    }

    It 'source-map JSON parses successfully' {
        { Get-Content -LiteralPath $script:sourceMapPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'every NITRO endpoint used in code exists in source-map' {
        $map = @(Get-Content -LiteralPath $script:sourceMapPath -Raw | ConvertFrom-Json)
        $resources = @($map.endpoint_or_resource)
        $code = Get-Content -LiteralPath $script:moduleFile -Raw
        $paths = [regex]::Matches($code, "-Path\s+('([^']+)'|\(\""([^\""{]+))") | ForEach-Object {
            if ($_.Groups[2].Success) { $_.Groups[2].Value } else { $_.Groups[3].Value }
        } | Where-Object { $_ -like '/config/*' -or $_ -like '/stat/*' } | Sort-Object -Unique
        foreach ($path in $paths) {
            $resourceName = (($path -replace '^/(config|stat)/','') -replace '\?.*$','' -replace '/.*$','')
            @($resources | Where-Object { $_ -match [regex]::Escape($resourceName) }).Count | Should -BeGreaterThan 0 -Because "$path must be sourced"
        }
    }

    It 'no source-map entry points to a missing implementation function' {
        Import-Module $script:modulePath -Force
        $map = @(Get-Content -LiteralPath $script:sourceMapPath -Raw | ConvertFrom-Json)
        foreach ($entry in $map) {
            if ($entry.PSObject.Properties.Name -contains 'implementation_function' -and $entry.implementation_function) {
                Get-Command -Name $entry.implementation_function -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'script has no outer ShouldProcess gate around the whole deployment' {
        $text = Get-Content -LiteralPath $script:scriptPath -Raw
        $text | Should -Not -Match "ShouldProcess\(\$NetScalerHost, 'Open NITRO session and deploy certificate'"
    }
}

Describe 'NetScaler helper validation' {
    BeforeEach { Import-Module $script:modulePath -Force }

    It 'New-NetscalerNitroBaseUri rejects bad inputs' {
        New-NetscalerNitroBaseUri -HostName 'adc01.example.local' | Should -Be 'https://adc01.example.local/nitro/v1'
        New-NetscalerNitroBaseUri -HostName 'adc01.example.local' -UseHttp | Should -Be 'http://adc01.example.local/nitro/v1'
        { New-NetscalerNitroBaseUri -HostName 'https://adc01.example.local' } | Should -Throw '*NitroBaseUrl*'
        { New-NetscalerNitroBaseUri -HostName 'adc01' -NitroBaseUrl 'ftp://adc01/nitro/v1' } | Should -Throw '*http:// or https://*'
        { New-NetscalerNitroBaseUri -HostName 'adc01' -NitroBaseUrl 'https://adc01/not-nitro' } | Should -Throw '*/nitro/v1*'
    }

    It 'local file validation fails before any connection or mutation' {
        { Test-NetscalerLocalCertificateFiles -CertPath (Join-Path $TestDrive 'missing.crt') -KeyPath (Join-Path $TestDrive 'missing.key') } | Should -Throw '*CertPath*'
    }

    It 'Resolve-NetscalerPassword does not write secrets' {
        $secure = ConvertTo-SecureString 's3cret-value' -AsPlainText -Force
        $text = Get-Content -LiteralPath $script:moduleFile -Raw
        $text | Should -Not -Match 'Write-(Host|Verbose|Debug|Information).*Password'
        Resolve-NetscalerPassword -Password $secure | Should -Be 's3cret-value'
    }

    It 'NITRO errorcode not zero throws without secret leakage' {
        { Assert-NetscalerNitroResponse -Response ([pscustomobject]@{ errorcode = 123; message = 'password=supersecret failed' }) -Method POST -Path '/config/login' } | Should -Throw '*password=***'
    }

    It 'HA not configured continues' {
        Assert-NetscalerPrimary -HAState ([pscustomobject]@{ HAConfigured = $false; HAMasterState = 'UNKNOWN'; Ambiguous = $false }) -RequirePrimary $true
    }

    It 'HA configured PRIMARY continues' {
        Assert-NetscalerPrimary -HAState ([pscustomobject]@{ HAConfigured = $true; HAMasterState = 'PRIMARY'; Ambiguous = $false }) -RequirePrimary $true
    }

    It 'HA configured SECONDARY aborts' {
        { Assert-NetscalerPrimary -HAState ([pscustomobject]@{ HAConfigured = $true; HAMasterState = 'SECONDARY'; Ambiguous = $false }) -RequirePrimary $true } | Should -Throw '*not safely PRIMARY*'
    }

    It 'HA ambiguous plus RequirePrimary fails safe' {
        { Assert-NetscalerPrimary -HAState ([pscustomobject]@{ HAConfigured = $true; HAMasterState = 'UNKNOWN'; Ambiguous = $true }) -RequirePrimary $true } | Should -Throw '*ambiguous=True*'
    }

    It 'CA binding detection preserves CA' -TestCases @(
        @{ Value = $true }, @{ Value = 'True' }, @{ Value = 'TRUE' }, @{ Value = 'YES' }, @{ Value = 'Yes' }, @{ Value = 'yes' }
    ) {
        param($Value)
        Test-NetscalerServerCertificateBinding -Binding ([pscustomobject]@{ certkeyname = 'ca'; ca = $Value; snicert = 'NO' }) | Should -BeFalse
    }

    It 'SNI binding detection preserves SNI' -TestCases @(
        @{ Value = $true }, @{ Value = 'True' }, @{ Value = 'TRUE' }, @{ Value = 'YES' }, @{ Value = 'Yes' }, @{ Value = 'yes' }
    ) {
        param($Value)
        Test-NetscalerServerCertificateBinding -Binding ([pscustomobject]@{ certkeyname = 'sni'; ca = 'NO'; snicert = $Value }) | Should -BeFalse
    }

    It 'missing metadata is treated conservatively for replacement' {
        Test-NetscalerServerCertificateBinding -Binding ([pscustomobject]@{ certkeyname = 'unknown' }) | Should -BeFalse
    }

    It 'explicit false metadata identifies server certificate bindings' -TestCases @(
        @{ Ca = $false; Sni = $false }, @{ Ca = 'false'; Sni = 'NO' }, @{ Ca = 'False'; Sni = 'no' }
    ) {
        param($Ca, $Sni)
        Test-NetscalerServerCertificateBinding -Binding ([pscustomobject]@{ certkeyname = 'server'; ca = $Ca; snicert = $Sni }) | Should -BeTrue
    }
}

Describe 'NetScaler request behavior' {
    BeforeEach {
        Import-Module $script:modulePath -Force
        $global:NetscalerRequests = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName SimpleAcme.Netscaler Invoke-RestMethod {
            $global:NetscalerRequests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = (Get-Variable -Name Body -ValueOnly -ErrorAction SilentlyContinue); ContentType = $ContentType }) | Out-Null
            [pscustomobject]@{ errorcode = 0; message = 'Done' }
        }
        Connect-NetscalerNitroSession -HostName 'adc01.example.local' -Username 'nsroot' -Password 'pw' -RetryCount 0
        $global:NetscalerRequests.Clear()
    }

    AfterEach { Disconnect-NetscalerNitroSession }

    It 'systemfile payload uses BASE64 and /nsconfig/ssl/' {
        $file = Join-Path $TestDrive 'wildcard_example_com.crt'
        Set-Content -LiteralPath $file -Value 'certificate'
        Send-NetscalerSslFile -Path $file -FileName 'wildcard_example_com.crt' | Should -BeTrue
        $req = $global:NetscalerRequests[-1]
        $req.Method | Should -Be 'POST'
        $req.Uri | Should -Match '/config/systemfile\?override=yes$'
        $body = $req.Body | ConvertFrom-Json
        $body.systemfile.fileencoding | Should -Be 'BASE64'
        $body.systemfile.filelocation | Should -Be '/nsconfig/ssl/'
    }

    It 'sslcertkey add payload is correct' {
        Mock -ModuleName SimpleAcme.Netscaler Invoke-RestMethod {
            $global:NetscalerRequests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = (Get-Variable -Name Body -ValueOnly -ErrorAction SilentlyContinue) }) | Out-Null
            if ($Uri -match '/config/sslcertkey/cert-key-01$') { return [pscustomobject]@{ errorcode = 0; sslcertkey = @() } }
            [pscustomobject]@{ errorcode = 0; message = 'Done' }
        }
        Set-NetscalerSslCertKey -CertKeyName 'cert-key-01' -CertFileName 'cert.crt' -KeyFileName 'cert.key' -ChainFileName 'chain.crt' | Should -BeTrue
        $req = @($global:NetscalerRequests | Where-Object Uri -match '/config/sslcertkey$')[-1]
        $body = $req.Body | ConvertFrom-Json
        $body.sslcertkey.certkey | Should -Be 'cert-key-01'
        $body.sslcertkey.cert | Should -Be 'cert.crt'
        $body.sslcertkey.key | Should -Be 'cert.key'
        $body.sslcertkey.inform | Should -Be 'PEM'
        $body.sslcertkey.cacert | Should -Be 'chain.crt'
    }

    It 'sslcertkey update payload is correct' {
        Mock -ModuleName SimpleAcme.Netscaler Invoke-RestMethod {
            $global:NetscalerRequests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = (Get-Variable -Name Body -ValueOnly -ErrorAction SilentlyContinue) }) | Out-Null
            if ($Uri -match '/config/sslcertkey/cert\.key\.name$') { return [pscustomobject]@{ errorcode = 0; sslcertkey = @([pscustomobject]@{ certkey = 'cert.key.name' }) } }
            [pscustomobject]@{ errorcode = 0; message = 'Done' }
        }
        Set-NetscalerSslCertKey -CertKeyName 'cert.key.name' -CertFileName 'new.crt' -KeyFileName 'new.key' | Should -BeTrue
        $req = @($global:NetscalerRequests | Where-Object Uri -match '/config/sslcertkey\?action=update$')[-1]
        $body = $req.Body | ConvertFrom-Json
        $body.sslcertkey.certkey | Should -Be 'cert.key.name'
        $body.sslcertkey.cert | Should -Be 'new.crt'
    }

    It 'KeyPassword passplain removed from local payload after request path' {
        $captured = $null
        Mock -ModuleName SimpleAcme.Netscaler Invoke-RestMethod {
            $global:NetscalerRequests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = (Get-Variable -Name Body -ValueOnly -ErrorAction SilentlyContinue) }) | Out-Null
            if ($Uri -match '/config/sslcertkey/keypass$') { return [pscustomobject]@{ errorcode = 0; sslcertkey = @() } }
            $script:captured = $Body | ConvertFrom-Json
            [pscustomobject]@{ errorcode = 0; message = 'Done' }
        }
        $secure = ConvertTo-SecureString 'key-pass' -AsPlainText -Force
        Set-NetscalerSslCertKey -CertKeyName 'keypass' -CertFileName 'cert.crt' -KeyFileName 'cert.key' -KeyPassword $secure | Should -BeTrue
        $script:captured.sslcertkey.passplain | Should -Be 'key-pass'
        (Get-Content -LiteralPath $script:moduleFile -Raw) | Should -Match ([regex]::Escape("`$payload['passplain'] = `$null"))
    }

    It 'hasync payload defaults save YES and force NO' {
        Sync-NetscalerHA | Should -BeTrue
        $body = ($global:NetscalerRequests[-1].Body | ConvertFrom-Json)
        $global:NetscalerRequests[-1].Uri | Should -Match '/config/hasync\?action=Force$'
        $body.hasync.save | Should -Be 'YES'
        $body.hasync.force | Should -Be 'NO'
    }

    It 'SyncHAForce sets force YES only when requested' {
        Sync-NetscalerHA -Force | Should -BeTrue
        ($global:NetscalerRequests[-1].Body | ConvertFrom-Json).hasync.force | Should -Be 'YES'
    }

    It 'SaveConfig calls nsconfig action save' {
        Save-NetscalerConfig | Should -BeTrue
        $global:NetscalerRequests[-1].Method | Should -Be 'POST'
        $global:NetscalerRequests[-1].Uri | Should -Match '/config/nsconfig\?action=save$'
    }

    It 'DELETE args are correctly URL encoded' -TestCases @(
        @{ Name = 'wildcard_example_com'; Expected = 'wildcard_example_com' },
        @{ Name = 'cert-key-01'; Expected = 'cert-key-01' },
        @{ Name = 'cert.key.name'; Expected = 'cert.key.name' }
    ) {
        param($Name, $Expected)
        Mock -ModuleName SimpleAcme.Netscaler Invoke-RestMethod {
            $global:NetscalerRequests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = (Get-Variable -Name Body -ValueOnly -ErrorAction SilentlyContinue) }) | Out-Null
            if ($Uri -match '/config/sslvserver_sslcertkey_binding/vsrv$') {
                return [pscustomobject]@{ errorcode = 0; sslvserver_sslcertkey_binding = @([pscustomobject]@{ certkeyname = $Name; ca = 'NO'; snicert = 'NO' }) }
            }
            [pscustomobject]@{ errorcode = 0; message = 'Done' }
        }
        Set-NetscalerSslVServerCertBinding -VServerName 'vsrv' -CertKeyName 'newcert' -ReplaceExistingServerCertificate | Should -BeTrue
        $delete = @($global:NetscalerRequests | Where-Object Method -eq 'DELETE')[-1]
        $delete.Uri | Should -Match "args=certkeyname:$([regex]::Escape($Expected))$"
    }

    It 'existing binding does not duplicate' {
        Mock -ModuleName SimpleAcme.Netscaler Invoke-RestMethod {
            $global:NetscalerRequests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = (Get-Variable -Name Body -ValueOnly -ErrorAction SilentlyContinue) }) | Out-Null
            if ($Uri -match '/config/sslvserver_sslcertkey_binding/vsrv$') {
                return [pscustomobject]@{ errorcode = 0; sslvserver_sslcertkey_binding = @([pscustomobject]@{ certkeyname = 'cert-key-01'; ca = 'NO'; snicert = 'NO' }) }
            }
            [pscustomobject]@{ errorcode = 0; message = 'Done' }
        }
        Set-NetscalerSslVServerCertBinding -VServerName 'vsrv' -CertKeyName 'cert-key-01' | Should -BeFalse
        @($global:NetscalerRequests | Where-Object Method -eq 'PUT').Count | Should -Be 0
    }

    It 'missing binding binds once' {
        Mock -ModuleName SimpleAcme.Netscaler Invoke-RestMethod {
            $global:NetscalerRequests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = (Get-Variable -Name Body -ValueOnly -ErrorAction SilentlyContinue) }) | Out-Null
            if ($Uri -match '/config/sslvserver_sslcertkey_binding/vsrv$' -and $Method -eq 'GET') {
                return [pscustomobject]@{ errorcode = 0; sslvserver_sslcertkey_binding = @() }
            }
            [pscustomobject]@{ errorcode = 0; message = 'Done' }
        }
        Set-NetscalerSslVServerCertBinding -VServerName 'vsrv' -CertKeyName 'newcert' | Should -BeTrue
        @($global:NetscalerRequests | Where-Object Method -eq 'PUT').Count | Should -Be 1
    }

    It 'ReplaceExistingServerCertificate removes only safe server cert bindings' {
        Mock -ModuleName SimpleAcme.Netscaler Invoke-RestMethod {
            $global:NetscalerRequests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = (Get-Variable -Name Body -ValueOnly -ErrorAction SilentlyContinue) }) | Out-Null
            if ($Uri -match '/config/sslvserver_sslcertkey_binding/vsrv$' -and $Method -eq 'GET') {
                return [pscustomobject]@{ errorcode = 0; sslvserver_sslcertkey_binding = @(
                    [pscustomobject]@{ certkeyname = 'old-server'; ca = 'NO'; snicert = 'NO' },
                    [pscustomobject]@{ certkeyname = 'ca-cert'; ca = 'YES'; snicert = 'NO' },
                    [pscustomobject]@{ certkeyname = 'sni-cert'; ca = 'NO'; snicert = 'YES' },
                    [pscustomobject]@{ certkeyname = 'unknown' }
                ) }
            }
            [pscustomobject]@{ errorcode = 0; message = 'Done' }
        }
        Set-NetscalerSslVServerCertBinding -VServerName 'vsrv' -CertKeyName 'newcert' -ReplaceExistingServerCertificate | Should -BeTrue
        $deletes = @($global:NetscalerRequests | Where-Object Method -eq 'DELETE')
        $deletes.Count | Should -Be 1
        $deletes[0].Uri | Should -Match 'old-server$'
    }

    It 'SkipCertificateCheck restores previous callback after success' {
        $previous = [Net.ServicePointManager]::ServerCertificateValidationCallback
        Connect-NetscalerNitroSession -HostName 'adc01.example.local' -Username 'nsroot' -Password 'pw' -SkipCertificateCheck -RetryCount 0
        [Net.ServicePointManager]::ServerCertificateValidationCallback | Should -Be $previous
    }

    It 'SkipCertificateCheck restores previous callback after failure' {
        Mock -ModuleName SimpleAcme.Netscaler Invoke-RestMethod { throw 'boom' }
        $previous = [Net.ServicePointManager]::ServerCertificateValidationCallback
        { Connect-NetscalerNitroSession -HostName 'adc01.example.local' -Username 'nsroot' -Password 'pw' -SkipCertificateCheck -RetryCount 0 } | Should -Throw
        [Net.ServicePointManager]::ServerCertificateValidationCallback | Should -Be $previous
    }
}

Describe 'NetScaler retry behavior' {
    BeforeEach {
        Import-Module $script:modulePath -Force
        Mock -ModuleName SimpleAcme.Netscaler Start-Sleep {}
    }

    function New-TestWebException([int]$StatusCode) {
        $ex = [Exception]::new('test')
        $resp = [pscustomobject]@{ StatusCode = $StatusCode }
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue $resp -Force
        $ex
    }

    It 'retries 408 429 and 5xx' -TestCases @(@{ Code = 408 }, @{ Code = 429 }, @{ Code = 500 }) {
        param($Code)
        $script:count = 0
        Mock -ModuleName SimpleAcme.Netscaler Invoke-RestMethod {
            $script:count++
            if ($script:count -eq 1) { throw (New-TestWebException $Code) }
            [pscustomobject]@{ errorcode = 0 }
        }
        Connect-NetscalerNitroSession -HostName 'adc01.example.local' -Username 'u' -Password 'p' -RetryCount 1 -RetryDelaySeconds 0
        $script:count | Should -Be 2
    }

    It 'does not retry normal 4xx' {
        $text = Get-Content -LiteralPath $script:moduleFile -Raw
        $text | Should -Match '\$statusCode -eq 408 -or \$statusCode -eq 429 -or \$statusCode -ge 500'
        $text | Should -Not -Match '\$statusCode -ge 400'
    }
}

Describe 'NetScaler script orchestration' {
    BeforeEach {
        Import-Module $script:modulePath -Force
        Set-Content -LiteralPath (Join-Path $TestDrive 'cert.crt') -Value 'cert'
        Set-Content -LiteralPath (Join-Path $TestDrive 'cert.key') -Value 'key'
        $global:NetscalerRequests = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName SimpleAcme.Netscaler Invoke-RestMethod {
            $path = ([uri]$Uri).PathAndQuery -replace '^/nitro/v1',''
            $global:NetscalerRequests.Add([pscustomobject]@{ Method = $Method; Path = $path; Body = (Get-Variable -Name Body -ValueOnly -ErrorAction SilentlyContinue) }) | Out-Null
            switch -Regex ($path) {
                '^/config/login$' { return [pscustomobject]@{ errorcode = 0 } }
                '^/config/logout$' { return [pscustomobject]@{ errorcode = 0 } }
                '^/stat/hanode$' { return [pscustomobject]@{ errorcode = 0; hanode = @([pscustomobject]@{ hacurstatus = 'NO'; hacurmasterstate = 'UNKNOWN' }) } }
                '^/config/sslcertkey/cert-key-01$' { return [pscustomobject]@{ errorcode = 0; sslcertkey = @() } }
                '^/config/sslvserver_sslcertkey_binding/vsrv$' { return [pscustomobject]@{ errorcode = 0; sslvserver_sslcertkey_binding = @() } }
                default { return [pscustomobject]@{ errorcode = 0; message = 'Done' } }
            }
        }
    }

    It '-WhatIf produces planned actions and no mutating API requests' {
        $secure = ConvertTo-SecureString 'pw' -AsPlainText -Force
        $result = & $script:scriptPath -NetScalerHost 'adc01.example.local' -Username 'u' -Password $secure -CertKeyName 'cert-key-01' -CertPath (Join-Path $TestDrive 'cert.crt') -KeyPath (Join-Path $TestDrive 'cert.key') -VServerName 'vsrv' -RetryCount 0 -WhatIf 6>$null
        $result.Mode | Should -Be 'WhatIfConnected'
        $result.VerificationStatus | Should -Be 'Planned'
        $result.PlannedActions.Count | Should -BeGreaterThan 0
        @($global:NetscalerRequests | Where-Object { $_.Method -in @('POST','PUT','DELETE') -and $_.Path -notin @('/config/login','/config/logout') }).Count | Should -Be 0
        @($global:NetscalerRequests | Where-Object Path -eq '/config/login').Count | Should -Be 1
    }

    It 'normal execution invokes operations in correct order using mocked NITRO' {
        $secure = ConvertTo-SecureString 'pw' -AsPlainText -Force
        Mock -ModuleName SimpleAcme.Netscaler Invoke-RestMethod {
            $path = ([uri]$Uri).PathAndQuery -replace '^/nitro/v1',''
            $global:NetscalerRequests.Add([pscustomobject]@{ Method = $Method; Path = $path; Body = (Get-Variable -Name Body -ValueOnly -ErrorAction SilentlyContinue) }) | Out-Null
            switch -Regex ($path) {
                '^/config/login$' { return [pscustomobject]@{ errorcode = 0 } }
                '^/config/logout$' { return [pscustomobject]@{ errorcode = 0 } }
                '^/stat/hanode$' { return [pscustomobject]@{ errorcode = 0; hanode = @([pscustomobject]@{ hacurstatus = 'NO'; hacurmasterstate = 'UNKNOWN' }) } }
                '^/config/sslcertkey/cert-key-01$' {
                    if (@($global:NetscalerRequests | Where-Object Path -eq '/config/sslcertkey').Count -gt 0) { return [pscustomobject]@{ errorcode = 0; sslcertkey = @([pscustomobject]@{ certkey = 'cert-key-01' }) } }
                    return [pscustomobject]@{ errorcode = 0; sslcertkey = @() }
                }
                '^/config/sslvserver_sslcertkey_binding/vsrv$' {
                    if (@($global:NetscalerRequests | Where-Object Method -eq 'PUT').Count -gt 0) { return [pscustomobject]@{ errorcode = 0; sslvserver_sslcertkey_binding = @([pscustomobject]@{ certkeyname = 'cert-key-01'; ca = 'NO'; snicert = 'NO' }) } }
                    return [pscustomobject]@{ errorcode = 0; sslvserver_sslcertkey_binding = @() }
                }
                default { return [pscustomobject]@{ errorcode = 0; message = 'Done' } }
            }
        }
        $result = & $script:scriptPath -NetScalerHost 'adc01.example.local' -Username 'u' -Password $secure -CertKeyName 'cert-key-01' -CertPath (Join-Path $TestDrive 'cert.crt') -KeyPath (Join-Path $TestDrive 'cert.key') -VServerName 'vsrv' -RetryCount 0
        $result.VerificationStatus | Should -Be 'Passed'
        $records = @($global:NetscalerRequests)
        $loginIndex = [array]::IndexOf(@($records.Path), '/config/login')
        $haIndex = [array]::IndexOf(@($records.Path), '/stat/hanode')
        $uploadIndex = [array]::IndexOf(@($records.Path), '/config/systemfile?override=yes')
        $certAddIndex = [array]::IndexOf(@($records.Path), '/config/sslcertkey')
        $bindIndex = [array]::IndexOf(@($records | ForEach-Object { if ($_.Method -eq 'PUT') { $_.Path } else { '' } }), '/config/sslvserver_sslcertkey_binding/vsrv')
        $saveIndex = [array]::IndexOf(@($records.Path), '/config/nsconfig?action=save')
        $loginIndex | Should -BeLessThan $haIndex
        $haIndex | Should -BeLessThan $uploadIndex
        $uploadIndex | Should -BeLessThan $certAddIndex
        $certAddIndex | Should -BeLessThan $bindIndex
        $bindIndex | Should -BeLessThan $saveIndex
    }
}