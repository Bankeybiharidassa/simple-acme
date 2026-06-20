Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/../core/Tui-Engine.psm1" -Force -Global
Import-Module "$PSScriptRoot/../core/Env-Loader.psm1" -Force -Global
Import-Module "$PSScriptRoot/Device-Profile-Runner.psm1" -Force -Global

$script:KempModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts/Modules/SimpleAcme.Kemp/SimpleAcme.Kemp.psd1'

function ConvertTo-KempTuiBoolean {
    param([object]$Value, [bool]$Default = $false)
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

function ConvertTo-KempCertificateObjectName {
    param([string]$Domains = '')

    $first = @($Domains -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ($first.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$first[0])) { return 'simple_acme_certificate' }
    $name = ([string]$first[0]).Trim().ToLowerInvariant()
    $name = $name -replace '^\*\.', 'wildcard_'
    $name = $name -replace '[^a-z0-9_-]+', '_'
    $name = $name.Trim('_')
    if ([string]::IsNullOrWhiteSpace($name)) { return 'simple_acme_certificate' }
    return $name
}

function Get-KempDefaultCertificateName {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    try {
        $envPath = Resolve-BootstrapEnvPath -ProjectRoot $ProjectRoot
        if (Test-Path -LiteralPath $envPath -PathType Leaf) {
            $envValues = Import-EnvFile -Path $envPath -Force
            if ($envValues.ContainsKey('DOMAINS')) { return ConvertTo-KempCertificateObjectName -Domains ([string]$envValues['DOMAINS']) }
        }
    } catch {
    }
    return 'simple_acme_certificate'
}

function Get-KempProfileFields {
    @(
        @{ Name='host'; Label='LoadMaster address'; Type='string'; Required=$true; Placeholder='192.168.45.150'; HelpText='Kemp LoadMaster management IP or DNS name.' },
        @{ Name='port'; Label='Management/API port'; Type='string'; Required=$true; Default='443'; Placeholder='443'; HelpText='HTTPS management/API port. Default is 443.' },
        @{ Name='username'; Label='Admin username'; Type='string'; Required=$false; Default='bal'; Placeholder='bal'; HelpText='Optional API username. API key is preferred when available.' },
        @{ Name='password'; Label='Admin password'; Type='secret'; Required=$false; Placeholder=''; HelpText='Optional API password. Leave empty when using API key only.' },
        @{ Name='api_key'; Label='API key'; Type='secret'; Required=$false; Placeholder=''; HelpText='Kemp API key. Preferred for scheduled renewal hooks.' },
        @{ Name='skip_certificate_check'; Label='Ignore LoadMaster TLS warning'; Type='choice'; Required=$true; Choices=@('false','true'); Default='true'; Placeholder='true'; HelpText='Set true for lab/self-signed LoadMaster management certificates.' }
    )
}

function Get-KempProfileValues {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$DeviceId = ''
    )

    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $fields = Get-KempProfileFields
    Add-DeviceProfileDefaults -Values (Get-DeviceProfileCurrentValues -ConfigDir $configDir -ConnectorType 'kemp' -DeviceId $DeviceId) -Fields $fields
}

function Resolve-KempProfilePasswordForTui {
    param([Parameter(Mandatory)][hashtable]$Values)

    if ($Values.ContainsKey('password') -and -not [string]::IsNullOrWhiteSpace([string]$Values['password'])) {
        return [string]$Values['password']
    }
    return ''
}

function Invoke-KempProfileCommunicationTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $null = $ProjectRoot
    Import-Module $script:KempModulePath -Force
    $hostName = [string]$Values['host']
    $port = if ($Values.ContainsKey('port') -and -not [string]::IsNullOrWhiteSpace([string]$Values['port'])) { [int]$Values['port'] } else { 443 }
    $username = if ($Values.ContainsKey('username')) { [string]$Values['username'] } else { 'bal' }
    $password = Resolve-KempProfilePasswordForTui -Values $Values
    $apiKey = if ($Values.ContainsKey('api_key')) { [string]$Values['api_key'] } else { '' }
    $skipCertificateCheck = ConvertTo-KempTuiBoolean -Value $(if ($Values.ContainsKey('skip_certificate_check')) { $Values['skip_certificate_check'] } else { $true }) -Default $true
    $endpoint = New-KempApiEndpoint -HostName $hostName -Port $port
    $started = Get-Date

    $null = Connect-KempLoadMaster -HostName $hostName -Port $port -ApiKey $apiKey -Username $username -Password $password -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 60
    $services = @(Get-KempVirtualServices -HostName $hostName -Port $port -ApiKey $apiKey -Username $username -Password $password -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 60)
    [pscustomobject]@{
        Status = 'Succeeded'
        Message = "Kemp APIv2 connected and returned $($services.Count) virtual service(s)."
        Endpoint = $endpoint
        Host = $hostName
        Port = $port
        VirtualServiceCount = $services.Count
        ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
        VirtualServices = @($services | Select-Object Id,Address,Port,Protocol,NickName,CurrentCertificate)
    }
}

function Invoke-KempTargetSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][hashtable]$Values
    )

    Import-Module $script:KempModulePath -Force
    $hostName = [string]$Values['host']
    $port = if ($Values.ContainsKey('port') -and -not [string]::IsNullOrWhiteSpace([string]$Values['port'])) { [int]$Values['port'] } else { 443 }
    $username = if ($Values.ContainsKey('username')) { [string]$Values['username'] } else { 'bal' }
    $password = Resolve-KempProfilePasswordForTui -Values $Values
    $apiKey = if ($Values.ContainsKey('api_key')) { [string]$Values['api_key'] } else { '' }
    $skipCertificateCheck = ConvertTo-KempTuiBoolean -Value $(if ($Values.ContainsKey('skip_certificate_check')) { $Values['skip_certificate_check'] } else { $true }) -Default $true
    $services = @(Get-KempVirtualServices -HostName $hostName -Port $port -ApiKey $apiKey -Username $username -Password $password -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 60)
    if ($services.Count -lt 1) {
        Write-Host 'Kemp API returned no virtual services.' -ForegroundColor Yellow
        Wait-DeviceProfileOperatorKey
        return $Values
    }

    Write-Host ''
    Write-Host 'Kemp virtual service target selection'
    Write-Host '-------------------------------------'
    Write-Host "Endpoint: $(New-KempApiEndpoint -HostName $hostName -Port $port)"
    Write-Host ''
    for ($i = 0; $i -lt $services.Count; $i++) {
        $service = $services[$i]
        $label = if ([string]::IsNullOrWhiteSpace([string]$service.NickName)) { '' } else { " name=$($service.NickName)" }
        Write-Host ("[{0}] id={1} vip={2}:{3}/{4}{5} current-cert={6}" -f ($i + 1), $service.Id, $service.Address, $service.Port, $service.Protocol, $label, $(if ([string]::IsNullOrWhiteSpace([string]$service.CurrentCertificate)) { '<empty>' } else { $service.CurrentCertificate }))
    }
    Write-Host ''
    Write-Host 'Enter comma-separated numbers only. Example: 1 or 1,2'
    $default = if ($services.Count -eq 1) { '1' } else { '' }
    while ($true) {
        $answer = Read-DeviceProfileConsoleLine -Prompt 'Select virtual services' -Default $default
        if ($null -eq $answer) { return $Values }
        $tokens = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($tokens.Count -lt 1) { Write-Host 'Select at least one number.' -ForegroundColor Yellow; continue }
        $selectedIds = @()
        $bad = @()
        foreach ($token in $tokens) {
            $number = 0
            if (-not [int]::TryParse($token, [ref]$number) -or $number -lt 1 -or $number -gt $services.Count) {
                $bad += $token
                continue
            }
            $id = [string]$services[$number - 1].Id
            if ([string]::IsNullOrWhiteSpace($id)) { $id = [string]$number }
            $selectedIds += $id
        }
        if ($bad.Count -gt 0) { Write-Host ("Invalid selection: {0}" -f ($bad -join ', ')) -ForegroundColor Yellow; continue }
        $Values['virtual_service_ids'] = ($selectedIds | Sort-Object -Unique) -join ','
        break
    }

    $certDefault = if ($Values.ContainsKey('certificate_name') -and -not [string]::IsNullOrWhiteSpace([string]$Values['certificate_name'])) { [string]$Values['certificate_name'] } else { Get-KempDefaultCertificateName -ProjectRoot $ProjectRoot }
    $certName = Read-DeviceProfileConsoleLine -Prompt 'Name in Kemp certificate store' -Default $certDefault
    if ($null -ne $certName -and -not [string]::IsNullOrWhiteSpace($certName)) { $Values['certificate_name'] = $certName.Trim() }
    return $Values
}

function Invoke-KempProfileForm {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    Invoke-DeviceProfileConnectorWizard -ProjectRoot $ProjectRoot -ConnectorType 'kemp'
}

function Invoke-KempDiagnostics {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $values = Get-KempProfileValues -ProjectRoot $ProjectRoot
    try {
        $result = Invoke-KempProfileCommunicationTest -ProjectRoot $ProjectRoot -Values $values
        Write-Host 'Kemp diagnostics'
        Write-Host '----------------'
        Write-Host ("Status: {0}" -f $result.Status)
        Write-Host ("Message: {0}" -f $result.Message)
        foreach ($service in @($result.VirtualServices)) {
            Write-Host ("VS id={0} vip={1}:{2}/{3} current-cert={4}" -f $service.Id, $service.Address, $service.Port, $service.Protocol, $(if ([string]::IsNullOrWhiteSpace([string]$service.CurrentCertificate)) { '<empty>' } else { $service.CurrentCertificate }))
        }
    } catch {
        Write-Host 'Kemp diagnostics failed' -ForegroundColor Red
        Write-Host $_.Exception.Message
    }
    Wait-DeviceProfileOperatorKey
}

function Invoke-KempDeploymentForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$WhatIfMode
    )

    $scriptPath = Join-Path $ProjectRoot 'Scripts/connectors/cert2kemp.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Kemp deployment script not found: $scriptPath" }
    $args = @('-ConfigDir', (Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot))
    if ($WhatIfMode) {
        & $scriptPath @args -WhatIf
        Wait-DeviceProfileOperatorKey
        return
    }
    Write-Host 'Kemp deployment needs a PFX cache file or PEM bundle path for manual post-issuance execution.'
    $pfxPath = Read-DeviceProfileConsoleLine -Prompt 'PFX path'
    if ($null -eq $pfxPath -or [string]::IsNullOrWhiteSpace($pfxPath)) { return }
    & $scriptPath @args -PfxPath $pfxPath
    Wait-DeviceProfileOperatorKey
}

function ConvertTo-KempSingleQuotedArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "''" }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Invoke-KempCertificateRequestSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $profileResult = Invoke-DeviceProfileConnectorWizard -ProjectRoot $ProjectRoot -ConnectorType 'kemp'
    if ($null -eq $profileResult -or [string]$profileResult.Status -ne 'Saved') { return $null }
    $deviceId = [string]$profileResult.DeviceId
    if ([string]::IsNullOrWhiteSpace($deviceId)) { throw 'Kemp device profile was saved without a device id.' }
    $profileValues = Get-KempProfileValues -ProjectRoot $ProjectRoot -DeviceId $deviceId

    try {
        $profileValues = Invoke-KempTargetSelection -ProjectRoot $ProjectRoot -Values $profileValues
    } catch {
        Write-Host ''
        Write-Host ('Unable to read Kemp virtual services: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host 'The profile was saved. Re-run Kemp profile setup after enabling LoadMaster API access.'
        Wait-DeviceProfileOperatorKey
        return $null
    }
    if (-not $profileValues.ContainsKey('virtual_service_ids') -or [string]::IsNullOrWhiteSpace([string]$profileValues['virtual_service_ids'])) { return $null }
    if (-not $profileValues.ContainsKey('certificate_name') -or [string]::IsNullOrWhiteSpace([string]$profileValues['certificate_name'])) {
        $profileValues['certificate_name'] = Get-KempDefaultCertificateName -ProjectRoot $ProjectRoot
    }

    Save-DeviceProfile -ConfigDir $configDir -ConnectorType 'kemp' -Label 'Kemp LoadMaster' -Values $profileValues -SecretFields @('password','api_key') -DeviceId $deviceId | Out-Null
    $Values['ACME_TARGET_SYSTEM'] = 'waf'
    $Values['ACME_TARGET_DEVICE_TYPE'] = 'kemp'
    $Values['ACME_TARGET_DEVICE_LABEL'] = 'Kemp LoadMaster'
    $Values['ACME_TARGET_DEVICE_ID'] = $deviceId
    $Values['ACME_INSTALLATION_PLUGINS'] = 'script'
    $Values['ACME_STORE_PLUGIN'] = 'pfxfile,certificatestore'
    $Values['ACME_SCRIPT_PATH'] = Join-Path $ProjectRoot 'Scripts\cert2kemp.ps1'
    $Values['ACME_SCRIPT_PARAMETERS'] = "-PfxPath '{CacheFile}' -CachePassword '{CachePassword}' -ConfigDir $(ConvertTo-KempSingleQuotedArgument -Value $configDir) -DeviceId $(ConvertTo-KempSingleQuotedArgument -Value $deviceId)"
    return $Values
}

Export-ModuleMember -Function Invoke-KempProfileForm,Invoke-KempDiagnostics,Invoke-KempDeploymentForm,Invoke-KempTargetSelection,Invoke-KempProfileCommunicationTest,Invoke-KempCertificateRequestSetup
