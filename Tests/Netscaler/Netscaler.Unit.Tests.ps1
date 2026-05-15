Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-TestNetscalerUnit {
    param([scriptblock]$Assert)

    $repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')
    $modulePath = Join-Path $repoRoot 'Scripts/Modules/SimpleAcme.Netscaler/SimpleAcme.Netscaler.psd1'
    $moduleFile = Join-Path $repoRoot 'Scripts/Modules/SimpleAcme.Netscaler/NetscalerNitro.psm1'
    $scriptPath = Join-Path $repoRoot 'Scripts/cert2netscaler.ps1'
    $sourceMapPath = Join-Path $repoRoot 'Docs/connectors/netscaler-source-map.json'

    & $Assert 'NetScaler module exports required functions' {
        Import-Module $modulePath -Force
        foreach ($name in @('New-NetscalerNitroBaseUri','Connect-NetscalerNitroSession','Invoke-NetscalerNitroRequest','Assert-NetscalerPrimary','Set-NetscalerSslVServerCertBinding','Sync-NetscalerHA')) {
            if (-not (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) {
                throw "Missing exported function $name."
            }
        }
    }

    & $Assert 'Parameter validation rejects missing certificate files before API interaction' {
        Import-Module $modulePath -Force
        try {
            Test-NetscalerLocalCertificateFiles -CertPath (Join-Path $PSScriptRoot 'missing.crt') -KeyPath (Join-Path $PSScriptRoot 'missing.key') | Out-Null
            throw 'Validation unexpectedly succeeded.'
        } catch {
            if ($_.Exception.Message -notmatch 'CertPath') { throw }
        }
    }

    & $Assert 'NetScalerHost and NitroBaseUrl validation are explicit' {
        Import-Module $modulePath -Force
        $null = New-NetscalerNitroBaseUri -HostName 'adc01.example.local'
        $null = New-NetscalerNitroBaseUri -HostName 'adc01.example.local' -UseHttp
        try {
            New-NetscalerNitroBaseUri -HostName 'https://adc01.example.local' | Out-Null
            throw 'Host URL unexpectedly succeeded.'
        } catch {
            if ($_.Exception.Message -notmatch 'NitroBaseUrl') { throw }
        }
        try {
            New-NetscalerNitroBaseUri -HostName 'adc01' -NitroBaseUrl 'https://adc01.example.local/not-nitro' | Out-Null
            throw 'Bad NitroBaseUrl unexpectedly succeeded.'
        } catch {
            if ($_.Exception.Message -notmatch '/nitro/v1') { throw }
        }
    }

    & $Assert 'HA not configured does not require PRIMARY' {
        Import-Module $modulePath -Force
        $ha = [pscustomobject]@{ HAConfigured = $false; HAMasterState = 'UNKNOWN'; Raw = @() }
        Assert-NetscalerPrimary -HAState $ha -RequirePrimary $true
    }

    & $Assert 'HA configured PRIMARY is allowed' {
        Import-Module $modulePath -Force
        $ha = [pscustomobject]@{ HAConfigured = $true; HAMasterState = 'PRIMARY'; Raw = @() }
        Assert-NetscalerPrimary -HAState $ha -RequirePrimary $true
    }

    & $Assert 'HA configured SECONDARY aborts by default' {
        Import-Module $modulePath -Force
        $ha = [pscustomobject]@{ HAConfigured = $true; HAMasterState = 'SECONDARY'; Raw = @() }
        try {
            Assert-NetscalerPrimary -HAState $ha -RequirePrimary $true
            throw 'HA enforcement unexpectedly succeeded.'
        } catch {
            if ($_.Exception.Message -notmatch 'not PRIMARY') { throw }
        }
    }

    & $Assert 'RequirePrimary behavior can be explicitly disabled' {
        Import-Module $modulePath -Force
        $ha = [pscustomobject]@{ HAConfigured = $true; HAMasterState = 'SECONDARY'; Raw = @() }
        Assert-NetscalerPrimary -HAState $ha -RequirePrimary $false
    }

    & $Assert 'No secret logging patterns are present' {
        $text = Get-Content -LiteralPath $moduleFile -Raw
        foreach ($bad in @('Write-Host $Password','Write-Verbose $Password','Write-Debug $Password','Write-Host $passwordText','Write-Verbose $passwordText','Write-Debug $passwordText')) {
            if ($text -match [regex]::Escape($bad)) { throw "Found unsafe secret logging pattern: $bad" }
        }
    }

    & $Assert 'WhatIf and ShouldProcess are wired for mutating operations' {
        $scriptText = Get-Content -LiteralPath $scriptPath -Raw
        $moduleText = Get-Content -LiteralPath $moduleFile -Raw
        if ($scriptText -notmatch 'SupportsShouldProcess\s*=\s*\$true') { throw 'Script does not enable SupportsShouldProcess.' }
        foreach ($fn in @('Send-NetscalerSslFile','Set-NetscalerSslCertKey','Set-NetscalerSslVServerCertBinding','Save-NetscalerConfig','Sync-NetscalerHA')) {
            if ($moduleText -notmatch "function\s+$fn[\s\S]*?SupportsShouldProcess\s*=\s*\$true") { throw "$fn does not enable SupportsShouldProcess." }
        }
    }

    & $Assert 'systemfile upload validates local file and uses documented override path' {
        $text = Get-Content -LiteralPath $moduleFile -Raw
        if ($text -notmatch 'Test-Path -LiteralPath \$Path -PathType Leaf') { throw 'Upload function does not validate local file.' }
        if ($text -notmatch '/config/systemfile\?override=yes') { throw 'Upload function does not use systemfile override endpoint.' }
        if ($text -notmatch 'fileencoding = ''BASE64''') { throw 'Upload function does not declare BASE64 encoding.' }
    }

    & $Assert 'sslcertkey missing creates and existing changes certificate material' {
        $text = Get-Content -LiteralPath $moduleFile -Raw
        if ($text -notmatch 'Get-NetscalerSslCertKey -CertKeyName \$CertKeyName') { throw 'Certkey existence is not queried.' }
        if ($text -notmatch "-Path '/config/sslcertkey'") { throw 'Missing sslcertkey add path.' }
        if ($text -notmatch "/config/sslcertkey\?action=update") { throw 'Missing sslcertkey change path.' }
    }

    & $Assert 'Binding logic avoids duplicates and preserves CA plus SNI bindings' {
        $text = Get-Content -LiteralPath $moduleFile -Raw
        if ($text -notmatch '\$alreadyBound\.Count\s*-eq\s*0') { throw 'Binding logic does not check for existing certkey binding.' }
        if ($text -notmatch 'Test-NetscalerServerCertificateBinding') { throw 'Binding replacement helper is missing.' }
        if ($text -notmatch 'snicert') { throw 'Binding replacement logic does not account for SNI bindings.' }
        if ($text -notmatch '\.ca') { throw 'Binding replacement logic does not account for CA bindings.' }
    }

    & $Assert 'hasync defaults save YES and force NO unless SyncHAForce is set' {
        $text = Get-Content -LiteralPath $moduleFile -Raw
        if ($text -notmatch "/config/hasync\?action=Force") { throw 'hasync Force action endpoint is missing.' }
        if ($text -notmatch "save = 'YES'") { throw 'hasync save=YES default is missing.' }
        if ($text -notmatch "if \(\$Force\) \{ 'YES' \} else \{ 'NO' \}") { throw 'hasync force default logic is not NO.' }
    }

    & $Assert 'Script saves and syncs only after deployment verification' {
        $text = Get-Content -LiteralPath $scriptPath -Raw
        $verifyIndex = $text.IndexOf('Test-NetscalerDeploymentVerification')
        $saveIndex = $text.IndexOf('Save-NetscalerConfig')
        $syncIndex = $text.IndexOf('Sync-NetscalerHA')
        if ($verifyIndex -lt 0 -or $saveIndex -lt $verifyIndex -or $syncIndex -lt $verifyIndex) {
            throw 'Save/sync ordering is not after verification.'
        }
    }

    & $Assert 'Verification status uses required vocabulary' {
        $text = Get-Content -LiteralPath $moduleFile -Raw
        foreach ($status in @('Passed','Failed','Partial')) {
            if ($text -notmatch "return '$status'|\n\s*'$status'") { throw "Missing status $status." }
        }
        if ((Get-Content -LiteralPath $scriptPath -Raw) -notmatch "\$verificationStatus = 'NotRun'") { throw 'Script does not initialize NotRun.' }
    }

    & $Assert 'Source map covers every implemented NITRO resource' {
        $map = Get-Content -LiteralPath $sourceMapPath -Raw | ConvertFrom-Json
        $resources = @($map.endpoint_or_resource)
        foreach ($required in @('login','logout','systemfile','sslcertkey','sslvserver_sslcertkey_binding','hanode','nsconfig','hasync')) {
            if (-not @($resources | Where-Object { $_ -match [regex]::Escape($required) })) {
                throw "Source map does not cover $required."
            }
        }
    }
}
