Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/../core/Tui-Engine.psm1" -Force -Global

function Get-NetScalerTuiLogRoot {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $configuredRoot = if (-not [string]::IsNullOrWhiteSpace($env:CERTIFICATE_LOG_DIR)) { [string]$env:CERTIFICATE_LOG_DIR } else { Join-Path $ProjectRoot 'logs' }
    $logRoot = [System.IO.Path]::GetFullPath($configuredRoot)
    if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    }
    $logRoot
}

function ConvertTo-NetScalerTuiBoolean {
    param(
        [object]$Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
    switch ($text.ToLowerInvariant()) {
        { $_ -in @('1','true','yes','y','on') } { return $true }
        { $_ -in @('0','false','no','n','off') } { return $false }
        default { throw "Invalid boolean value '$Value'. Use true or false." }
    }
}

function ConvertTo-NetScalerSafeValue {
    param(
        [string]$Name,
        [object]$Value
    )

    if ($Name -match '(?i)password|passplain|secret|key_path') {
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
        if ($Name -eq 'key_path') { return [System.IO.Path]::GetFileName([string]$Value) }
        return '<redacted>'
    }
    if ($Name -match '(?i)cert_path|chain_path') {
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
        return [System.IO.Path]::GetFileName([string]$Value)
    }
    $Value
}

function Write-NetScalerTuiJsonLog {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][object]$Data
    )

    $logRoot = Get-NetScalerTuiLogRoot -ProjectRoot $ProjectRoot
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $path = Join-Path $logRoot ("{0}-{1}.json" -f $Prefix, $stamp)
    $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

function Convert-NetScalerFormValuesToArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$FormValues
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    $map = [ordered]@{
        host = '-NetScalerHost'
        username = '-Username'
        password_secret_name = '-PasswordSecretName'
        certkey_name = '-CertKeyName'
        cert_path = '-CertPath'
        key_path = '-KeyPath'
    }

    foreach ($key in $map.Keys) {
        $value = if ($FormValues.ContainsKey($key)) { [string]$FormValues[$key] } else { '' }
        if ([string]::IsNullOrWhiteSpace($value)) { throw "Required NetScaler field '$key' is missing." }
        $arguments.Add($map[$key]) | Out-Null
        $arguments.Add($value) | Out-Null
    }

    if ($FormValues.ContainsKey('chain_path') -and -not [string]::IsNullOrWhiteSpace([string]$FormValues['chain_path'])) {
        $arguments.Add('-ChainPath') | Out-Null
        $arguments.Add([string]$FormValues['chain_path']) | Out-Null
    }

    $vServerName = if ($FormValues.ContainsKey('vserver_name')) { [string]$FormValues['vserver_name'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($vServerName)) { throw "Required NetScaler field 'vserver_name' is missing." }
    $arguments.Add('-VServerName') | Out-Null
    $arguments.Add($vServerName) | Out-Null

    if (-not (ConvertTo-NetScalerTuiBoolean -Value $(if ($FormValues.ContainsKey('require_primary')) { $FormValues['require_primary'] } else { $true }) -Default $true)) {
        $arguments.Add('-RequirePrimary:$false') | Out-Null
    }
    if (-not (ConvertTo-NetScalerTuiBoolean -Value $(if ($FormValues.ContainsKey('sync_ha')) { $FormValues['sync_ha'] } else { $true }) -Default $true)) {
        $arguments.Add('-NoSyncHA') | Out-Null
    }
    if (-not (ConvertTo-NetScalerTuiBoolean -Value $(if ($FormValues.ContainsKey('save_config')) { $FormValues['save_config'] } else { $true }) -Default $true)) {
        $arguments.Add('-NoSaveConfig') | Out-Null
    }
    if (ConvertTo-NetScalerTuiBoolean -Value $(if ($FormValues.ContainsKey('replace_existing_server_certificate')) { $FormValues['replace_existing_server_certificate'] } else { $false }) -Default $false) {
        $arguments.Add('-ReplaceExistingServerCertificate') | Out-Null
    }
    if (ConvertTo-NetScalerTuiBoolean -Value $(if ($FormValues.ContainsKey('skip_certificate_check')) { $FormValues['skip_certificate_check'] } else { $false }) -Default $false) {
        $arguments.Add('-SkipCertificateCheck') | Out-Null
    }

    @($arguments)
}

function Invoke-NetScalerConnectorScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$WhatIfMode
    )

    $invokeArgs = @($Arguments)
    if ($WhatIfMode) { $invokeArgs += '-WhatIf' }
    & $ScriptPath @invokeArgs
}

function New-NetScalerDeploymentLogRecord {
    param(
        [Parameter(Mandatory)][hashtable]$FormValues,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Status,
        [object]$PreviewResult,
        [object]$DeploymentResult,
        [string]$Message
    )

    $safeValues = [ordered]@{}
    foreach ($key in $FormValues.Keys) {
        $safeValues[$key] = ConvertTo-NetScalerSafeValue -Name ([string]$key) -Value $FormValues[$key]
    }

    [pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Status = $Status
        Message = $Message
        ScriptPath = $ScriptPath
        SafeFormValues = $safeValues
        ArgumentNames = @($Arguments | Where-Object { $_ -like '-*' })
        PreviewResult = $PreviewResult
        DeploymentResult = $DeploymentResult
    }
}

function Invoke-NetScalerDeploymentForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$WhatIfMode
    )

    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw "Device schema file not found: $schemaPath" }
    . $schemaPath
    if (-not $DeviceSchemas.ContainsKey('netscaler')) { throw "Device schema 'netscaler' was not found in $schemaPath" }

    $schema = $DeviceSchemas['netscaler']
    $values = Show-TuiForm -Fields ([hashtable[]]$schema.Fields) -Title 'NetScaler / Citrix ADC deployment'
    if ($null -eq $values) { return [pscustomobject]@{ Status = 'Canceled'; LogPath = $null } }

    $missing = @()
    foreach ($field in @($schema.Fields)) {
        if ($field.Required -and [string]::IsNullOrWhiteSpace([string]$values[$field.Name])) { $missing += [string]$field.Name }
    }
    if ($missing.Count -gt 0) { throw "Required NetScaler fields missing: $($missing -join ', ')" }

    $scriptPath = Join-Path $ProjectRoot 'Scripts/cert2netscaler.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "NetScaler deployment script not found: $scriptPath" }
    $arguments = @(Convert-NetScalerFormValuesToArguments -FormValues $values)

    $previewResult = $null
    $deploymentResult = $null
    $status = 'PreviewFailed'
    $message = ''
    try {
        Write-Host 'Running NetScaler WhatIf preview first. No appliance mutations should occur during this step.'
        $previewResult = Invoke-NetScalerConnectorScript -ScriptPath $scriptPath -Arguments $arguments -WhatIfMode
        if ($WhatIfMode) {
            $status = 'PreviewCompleted'
            $message = 'WhatIf preview completed. Real deployment was not requested.'
        } else {
            Write-Host ''
            Write-Host 'WhatIf preview completed. Type DEPLOY to execute the real NetScaler deployment.'
            $confirmation = [string](Read-Host 'Confirmation')
            if ($confirmation -cne 'DEPLOY') {
                $status = 'CanceledAfterPreview'
                $message = 'Operator did not type DEPLOY after preview. Real deployment was not executed.'
            } else {
                $deploymentResult = Invoke-NetScalerConnectorScript -ScriptPath $scriptPath -Arguments $arguments
                $status = 'DeploymentCompleted'
                $message = 'Real NetScaler deployment completed after explicit confirmation.'
            }
        }
    } catch {
        $message = $_.Exception.Message
        throw
    } finally {
        $record = New-NetScalerDeploymentLogRecord -FormValues $values -Arguments $arguments -ScriptPath $scriptPath -Status $status -PreviewResult $previewResult -DeploymentResult $deploymentResult -Message $message
        $jsonPath = Write-NetScalerTuiJsonLog -ProjectRoot $ProjectRoot -Prefix 'netscaler-tui-deploy' -Data $record
        $textPath = [System.IO.Path]::ChangeExtension($jsonPath, '.log')
        @(
            "TimestampUtc=$($record.TimestampUtc)"
            "Status=$status"
            "Message=$message"
            "ScriptPath=$scriptPath"
            "Host=$($record.SafeFormValues.host)"
            "Username=$($record.SafeFormValues.username)"
            "CertKeyName=$($record.SafeFormValues.certkey_name)"
            "VServerName=$($record.SafeFormValues.vserver_name)"
            "ArgumentNames=$($record.ArgumentNames -join ',')"
        ) | Set-Content -LiteralPath $textPath -Encoding UTF8
    }

    [pscustomobject]@{
        Status = $status
        Message = $message
        PreviewResult = $previewResult
        DeploymentResult = $deploymentResult
        JsonLogPath = $jsonPath
        TextLogPath = $textPath
    }
}

function Test-NetScalerTuiWiring {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $menuPath = Join-Path $ProjectRoot 'setup/Menu-Tree.ps1'
    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    $setupPath = Join-Path $ProjectRoot 'certificate-setup.ps1'
    $releasePath = Join-Path $ProjectRoot 'build/release-file-list.txt'
    $runnerPath = Join-Path $ProjectRoot 'setup/NetScaler-Runner.psm1'
    $scriptPath = Join-Path $ProjectRoot 'Scripts/cert2netscaler.ps1'
    $manifestPath = Join-Path $ProjectRoot 'Scripts/Modules/SimpleAcme.Netscaler/SimpleAcme.Netscaler.psd1'
    $sourceMapPath = Join-Path $ProjectRoot 'Docs/connectors/netscaler-source-map.json'

    $requiredFields = @('host','username','password_secret_name','certkey_name','cert_path','key_path','chain_path','vserver_name','require_primary','sync_ha','save_config','replace_existing_server_certificate','skip_certificate_check')
    . $schemaPath
    $schemaFields = if ($DeviceSchemas.ContainsKey('netscaler')) { @($DeviceSchemas['netscaler'].Fields | ForEach-Object { [string]$_.Name }) } else { @() }
    $menuText = if (Test-Path -LiteralPath $menuPath) { Get-Content -LiteralPath $menuPath -Raw } else { '' }
    $setupText = if (Test-Path -LiteralPath $setupPath) { Get-Content -LiteralPath $setupPath -Raw } else { '' }
    $releaseText = if (Test-Path -LiteralPath $releasePath) { Get-Content -LiteralPath $releasePath -Raw } else { '' }

    [pscustomobject]@{
        ScriptExists = Test-Path -LiteralPath $scriptPath -PathType Leaf
        ModuleManifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
        SourceMapExists = Test-Path -LiteralPath $sourceMapPath -PathType Leaf
        MenuKeysPresent = @('netscaler-deploy','netscaler-whatif','netscaler-diagnostics') | ForEach-Object { [pscustomobject]@{ Key = $_; Present = ($menuText -match [regex]::Escape($_)) } }
        SchemaPresent = $DeviceSchemas.ContainsKey('netscaler')
        MissingSchemaFields = @($requiredFields | Where-Object { $_ -notin $schemaFields })
        SetupDispatchPresent = @('netscaler-deploy','netscaler-whatif','netscaler-diagnostics') | ForEach-Object { [pscustomobject]@{ Key = $_; Present = ($setupText -match [regex]::Escape($_)) } }
        RunnerExists = Test-Path -LiteralPath $runnerPath -PathType Leaf
        ReleaseManifestIncludesRunner = $releaseText -match 'setup/NetScaler-Runner\.psm1'
    }
}

function Invoke-NetScalerDiagnostics {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $scriptPath = Join-Path $ProjectRoot 'Scripts/cert2netscaler.ps1'
    $manifestPath = Join-Path $ProjectRoot 'Scripts/Modules/SimpleAcme.Netscaler/SimpleAcme.Netscaler.psd1'
    $sourceMapPath = Join-Path $ProjectRoot 'Docs/connectors/netscaler-source-map.json'
    $requiredExports = @('Resolve-NetscalerPassword','Connect-NetscalerNitroSession','Get-NetscalerHAState','Assert-NetscalerPrimary','Send-NetscalerSslFile','Set-NetscalerSslCertKey','Set-NetscalerSslVServerCertBinding','Save-NetscalerConfig','Sync-NetscalerHA','Test-NetscalerDeploymentVerification')
    $checks = New-Object System.Collections.Generic.List[object]

    function Add-Check { param([string]$Name,[bool]$Passed,[string]$Detail = '') $checks.Add([pscustomobject]@{ Name=$Name; Passed=$Passed; Detail=$Detail }) | Out-Null }

    Add-Check -Name 'cert2netscaler.ps1 exists' -Passed (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Detail $scriptPath
    Add-Check -Name 'NetScaler module manifest exists' -Passed (Test-Path -LiteralPath $manifestPath -PathType Leaf) -Detail $manifestPath

    $module = $null
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $module = Import-Module $manifestPath -Force -PassThru
            Add-Check -Name 'NetScaler module imports' -Passed ($null -ne $module) -Detail $manifestPath
        } catch {
            Add-Check -Name 'NetScaler module imports' -Passed $false -Detail $_.Exception.Message
        }
    } else {
        Add-Check -Name 'NetScaler module imports' -Passed $false -Detail 'Manifest missing.'
    }

    foreach ($export in $requiredExports) {
        $present = $null -ne $module -and $module.ExportedCommands.ContainsKey($export)
        Add-Check -Name "Export exists: $export" -Passed $present
    }

    if (Test-Path -LiteralPath $sourceMapPath -PathType Leaf) {
        try { $null = Get-Content -LiteralPath $sourceMapPath -Raw | ConvertFrom-Json; Add-Check -Name 'NetScaler source map parses' -Passed $true -Detail $sourceMapPath }
        catch { Add-Check -Name 'NetScaler source map parses' -Passed $false -Detail $_.Exception.Message }
    } else {
        Add-Check -Name 'NetScaler source map exists' -Passed $false -Detail $sourceMapPath
    }

    $wiring = Test-NetScalerTuiWiring -ProjectRoot $ProjectRoot
    Add-Check -Name 'Release manifest includes NetScaler runtime files' -Passed ([bool]$wiring.ReleaseManifestIncludesRunner) -Detail 'setup/NetScaler-Runner.psm1'
    foreach ($menu in @($wiring.MenuKeysPresent)) { Add-Check -Name "Menu key present: $($menu.Key)" -Passed ([bool]$menu.Present) }
    Add-Check -Name 'NetScaler schema present' -Passed ([bool]$wiring.SchemaPresent)
    Add-Check -Name 'NetScaler schema has required fields' -Passed (@($wiring.MissingSchemaFields).Count -eq 0) -Detail (@($wiring.MissingSchemaFields) -join ',')
    foreach ($dispatch in @($wiring.SetupDispatchPresent)) { Add-Check -Name "Setup dispatch present: $($dispatch.Key)" -Passed ([bool]$dispatch.Present) }

    $pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
    Add-Check -Name 'PowerShell version' -Passed ($PSVersionTable.PSVersion.Major -ge 5) -Detail ($PSVersionTable.PSVersion.ToString())
    $pesterVersion = $null
    if ($null -ne $pester) { $pesterVersion = [string]$pester.Version }
    $pesterDetail = 'Not installed'
    if ($null -ne $pesterVersion) { $pesterDetail = $pesterVersion }
    Add-Check -Name 'Pester availability' -Passed ($null -ne $pester) -Detail $pesterDetail

    $checkArray = @()
    foreach ($check in $checks) { $checkArray += $check }
    $failedChecks = @($checkArray | Where-Object { -not $_.Passed })
    $result = [pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        PesterVersion = $pesterVersion
        Checks = $checkArray
        Passed = ($failedChecks.Count -eq 0)
    }
    $logPath = Write-NetScalerTuiJsonLog -ProjectRoot $ProjectRoot -Prefix 'netscaler-tui-diagnostic' -Data $result
    $result | Add-Member -NotePropertyName LogPath -NotePropertyValue $logPath -Force

    Write-Host 'NetScaler TUI diagnostic summary:'
    foreach ($check in $checkArray) {
        $prefix = '[FAIL]'
        if ($check.Passed) { $prefix = '[PASS]' }
        Write-Host ("{0} {1} {2}" -f $prefix, $check.Name, $check.Detail)
    }
    Write-Host "Diagnostic JSON: $logPath"
    $result
}

Export-ModuleMember -Function Invoke-NetScalerDeploymentForm,Invoke-NetScalerDiagnostics,Convert-NetScalerFormValuesToArguments,Test-NetScalerTuiWiring
