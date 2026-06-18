Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/../core/Tui-Engine.psm1" -Force -Global
Import-Module "$PSScriptRoot/../core/Config-Store.psm1" -Force -Global

function Resolve-DeviceProfileConfigDir {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $configured = [Environment]::GetEnvironmentVariable('CERTIFICATE_CONFIG_DIR')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        return [IO.Path]::GetFullPath($configured)
    }

    return [IO.Path]::GetFullPath((Join-Path $ProjectRoot 'config'))
}

function Test-DeviceProfileLikelyPlaintextSecret {
    param([object]$Value)

    if ($null -eq $Value) { return $false }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($text -match '[^A-Za-z0-9_.-]') { return $true }
    return $false
}

function ConvertTo-DeviceProfileDisplayValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '<empty>' }
    if ($Name -match '(?i)password|secret|private_key|api_key|token') { return '<hidden>' }
    return [string]$Value
}

function Show-DeviceProfileSummary {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][object[]]$Fields
    )

    Write-Host ''
    Write-Host $Title
    Write-Host ('-' * $Title.Length)
    foreach ($field in @($Fields)) {
        if (-not ($field -is [System.Collections.IDictionary]) -or -not $field.ContainsKey('Name')) { continue }
        $name = [string]$field['Name']
        $label = if ($field.ContainsKey('Label') -and -not [string]::IsNullOrWhiteSpace([string]$field['Label'])) { [string]$field['Label'] } else { $name }
        $value = if ($Values.ContainsKey($name)) { $Values[$name] } else { $null }
        Write-Host ('{0}: {1}' -f $label, (ConvertTo-DeviceProfileDisplayValue -Name $name -Value $value))
    }
}

function Write-DeviceProfileJsonLog {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConnectorType,
        [Parameter(Mandatory)][object]$Data
    )

    $configuredRoot = if (-not [string]::IsNullOrWhiteSpace($env:CERTIFICATE_LOG_DIR)) { [string]$env:CERTIFICATE_LOG_DIR } else { Join-Path $ProjectRoot 'logs' }
    $logRoot = [IO.Path]::GetFullPath($configuredRoot)
    if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $path = Join-Path $logRoot ("device-profile-{0}-{1}.json" -f $ConnectorType, $stamp)
    $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    return [string]$path
}

function Read-DeviceProfileYesNo {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = [string](Read-Host ("{0} ({1})" -f $Prompt, $suffix))
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch ($answer.Trim().ToLowerInvariant()) {
            { $_ -in @('y','yes','j','ja') } { return $true }
            { $_ -in @('n','no','nee') } { return $false }
            default { Write-Host 'Please answer y or n.' -ForegroundColor Yellow }
        }
    }
}

function Wait-DeviceProfileOperatorKey {
    param([string]$Message = 'Press any key to continue.')

    Write-Host ''
    Write-Host $Message
    [Console]::ReadKey($true) | Out-Null
}

function Read-DeviceProfileConsoleLine {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [switch]$Secret
    )

    $suffix = ''
    if (-not [string]::IsNullOrWhiteSpace($Default)) {
        $displayDefault = if ($Secret) { '<hidden>' } else { $Default }
        $suffix = " [$displayDefault]"
    }
    Write-Host -NoNewline ("{0}{1}: " -f $Prompt, $suffix)
    $buffer = New-Object System.Text.StringBuilder
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Escape) {
            Write-Host ''
            return $null
        }
        if ($key.Key -eq [ConsoleKey]::Enter) {
            Write-Host ''
            $text = $buffer.ToString()
            if ([string]::IsNullOrWhiteSpace($text) -and -not [string]::IsNullOrWhiteSpace($Default)) { return $Default }
            return $text
        }
        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($buffer.Length -gt 0) {
                $buffer.Length = $buffer.Length - 1
                Write-Host -NoNewline "`b `b"
            }
            continue
        }
        if ($key.KeyChar -eq [char]0) { continue }
        [void]$buffer.Append($key.KeyChar)
        if ($Secret) {
            Write-Host -NoNewline '*'
        } else {
            Write-Host -NoNewline $key.KeyChar
        }
    }
}

function Read-DeviceProfileGuidedYesNo {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = Read-DeviceProfileConsoleLine -Prompt ("{0} ({1})" -f $Prompt, $suffix)
        if ($null -eq $answer) { return $null }
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch ($answer.Trim().ToLowerInvariant()) {
            { $_ -in @('y','yes','j','ja') } { return $true }
            { $_ -in @('n','no','nee') } { return $false }
            default { Write-Host 'Please answer y or n, or press Esc to cancel.' -ForegroundColor Yellow }
        }
    }
}

function Select-DeviceProfileNumberedItem {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$LabelSelector
    )

    while ($true) {
        Clear-Host
        Write-Host $Title
        Write-Host ('-' * $Title.Length)
        for ($i = 0; $i -lt $Items.Count; $i++) {
            Write-Host ("[{0}] {1}" -f ($i + 1), (& $LabelSelector $Items[$i]))
        }
        Write-Host '[0] Back'
        Write-Host ''
        $answer = Read-DeviceProfileConsoleLine -Prompt 'Select number'
        if ($null -eq $answer) { return $null }
        $number = 0
        if (-not [int]::TryParse($answer, [ref]$number)) {
            Write-Host 'Enter a number from the list.' -ForegroundColor Yellow
            Start-Sleep -Milliseconds 900
            continue
        }
        if ($number -eq 0) { return $null }
        if ($number -ge 1 -and $number -le $Items.Count) { return $Items[$number - 1] }
        Write-Host 'That number is not in the list.' -ForegroundColor Yellow
        Start-Sleep -Milliseconds 900
    }
}

function ConvertTo-DeviceProfileIdPart {
    param([string]$Value)

    $text = if ([string]::IsNullOrWhiteSpace($Value)) { 'device' } else { $Value.Trim().ToLowerInvariant() }
    $text = [regex]::Replace($text, '[^a-z0-9]+', '-')
    $text = $text.Trim('-')
    if ([string]::IsNullOrWhiteSpace($text)) { return 'device' }
    return $text
}

function Get-DeviceProfileById {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$DeviceId
    )

    if ([string]::IsNullOrWhiteSpace($DeviceId)) { return $null }
    try {
        return Get-DeviceConfig -ConfigDir $ConfigDir -DeviceId $DeviceId
    } catch {
        return $null
    }
}

function New-DeviceProfileId {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$ConnectorType,
        [Parameter(Mandatory)][string]$FriendlyName
    )

    $connectorPart = ConvertTo-DeviceProfileIdPart -Value $ConnectorType
    $namePart = ConvertTo-DeviceProfileIdPart -Value $FriendlyName
    $baseId = "$connectorPart-$namePart"
    $candidate = $baseId
    $suffix = 2
    while ($null -ne (Get-DeviceProfileById -ConfigDir $ConfigDir -DeviceId $candidate)) {
        $candidate = "{0}-{1}" -f $baseId, $suffix
        $suffix++
    }
    return $candidate
}

function Get-DeviceProfileEndpointSummary {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Device)

    $settings = if ($Device.ContainsKey('settings') -and $Device['settings'] -is [System.Collections.IDictionary]) { $Device['settings'] } else { @{} }
    $host = ''
    foreach ($key in @('host','hostname','address','management_host','firewall_address','endpoint')) {
        if ($settings.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$settings[$key])) {
            $host = [string]$settings[$key]
            break
        }
    }
    $port = ''
    foreach ($key in @('port','api_port','admin_port','management_port')) {
        if ($settings.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$settings[$key])) {
            $port = [string]$settings[$key]
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($host) -and [string]::IsNullOrWhiteSpace($port)) { return '<not set>' }
    if ([string]::IsNullOrWhiteSpace($port)) { return $host }
    if ([string]::IsNullOrWhiteSpace($host)) { return "port $port" }
    return "{0}:{1}" -f $host, $port
}

function Get-DeviceProfileTargetSummary {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Device)

    $settings = if ($Device.ContainsKey('settings') -and $Device['settings'] -is [System.Collections.IDictionary]) { $Device['settings'] } else { @{} }
    $parts = @()
    foreach ($key in @('virtual_service_ids','waf_rule_names','bind_admin_portal','bind_vpn_portal','bind_user_portal','bind_waf_rules','target_names','bind_target_ids','bind_target_names')) {
        if ($settings.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$settings[$key])) {
            $parts += ("{0}={1}" -f $key, (ConvertTo-DeviceProfileDisplayValue -Name $key -Value $settings[$key]))
        }
    }
    if ($parts.Count -lt 1) { return '<not set>' }
    return ($parts -join '; ')
}

function Get-DeviceProfileCurrentValues {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$ConnectorType,
        [string]$DeviceId = '',
        [string[]]$CertificateRuntimeKeys = @(),
        [hashtable]$PlaintextSecretNameFields = @{}
    )

    if (-not [string]::IsNullOrWhiteSpace($DeviceId)) {
        $existingDevice = Get-DeviceProfileById -ConfigDir $ConfigDir -DeviceId $DeviceId
        $existing = @($existingDevice)
    } else {
        $existing = @(Get-AllDeviceConfigs -ConfigDir $ConfigDir -SkipIntegrityFailures | Where-Object {
            $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]($_['connector_type']) -eq $ConnectorType
        } | Select-Object -First 1)
    }
    if ($existing.Count -lt 1 -or $null -eq $existing[0]) { return @{} }
    if (-not ($existing[0] -is [System.Collections.IDictionary]) -or -not $existing[0].ContainsKey('settings')) { return @{} }
    $settings = $existing[0]['settings']
    if (-not ($settings -is [System.Collections.IDictionary])) { return @{} }

    $current = @{}
    foreach ($key in $settings.Keys) { $current[[string]$key] = [string]$settings[$key] }

    foreach ($secretNameField in $PlaintextSecretNameFields.Keys) {
        $secretField = [string]$PlaintextSecretNameFields[$secretNameField]
        if ([string]::IsNullOrWhiteSpace($secretField)) { continue }
        if (-not $current.ContainsKey($secretField) -and $current.ContainsKey($secretNameField) -and (Test-DeviceProfileLikelyPlaintextSecret -Value $current[$secretNameField])) {
            $current[$secretField] = [string]$current[$secretNameField]
            $current[$secretNameField] = ''
        }
    }

    foreach ($certificateKey in @($CertificateRuntimeKeys)) {
        if ($current.ContainsKey($certificateKey)) { $current.Remove($certificateKey) }
    }
    return $current
}

function Add-DeviceProfileDefaults {
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][object[]]$Fields
    )

    $withDefaults = @{}
    foreach ($key in $Values.Keys) { $withDefaults[[string]$key] = [string]$Values[$key] }
    foreach ($field in @($Fields)) {
        if (-not ($field -is [System.Collections.IDictionary])) { continue }
        if (-not $field.ContainsKey('Name') -or -not $field.ContainsKey('Default')) { continue }
        $name = [string]$field['Name']
        $defaultValue = [string]$field['Default']
        if (-not $withDefaults.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string]$withDefaults[$name])) {
            $withDefaults[$name] = $defaultValue
        }
    }
    return $withDefaults
}

function Remove-DeviceProfilePlaceholderValues {
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][object[]]$Fields
    )

    $clean = @{}
    foreach ($key in $Values.Keys) { $clean[[string]$key] = [string]$Values[$key] }
    foreach ($field in @($Fields)) {
        if (-not ($field -is [System.Collections.IDictionary])) { continue }
        if (-not $field.ContainsKey('Name') -or -not $field.ContainsKey('Placeholder')) { continue }
        if ($field.ContainsKey('Default')) { continue }
        if ($field.ContainsKey('Required') -and [bool]$field['Required']) { continue }
        $name = [string]$field['Name']
        if (-not $clean.ContainsKey($name)) { continue }
        $placeholder = [string]$field['Placeholder']
        $value = [string]$clean[$name]
        if (-not [string]::IsNullOrWhiteSpace($placeholder) -and $value -eq $placeholder) {
            $clean[$name] = ''
        }
    }
    return $clean
}

function Get-DeviceProfileFieldDefault {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Field,
        [Parameter(Mandatory)][hashtable]$CurrentValues
    )

    $name = [string]$Field['Name']
    if ($CurrentValues.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace([string]$CurrentValues[$name])) {
        return [string]$CurrentValues[$name]
    }
    if ($Field.ContainsKey('Default')) { return [string]$Field['Default'] }
    if ($Field.ContainsKey('Placeholder')) { return [string]$Field['Placeholder'] }
    return ''
}

function Test-DeviceProfileFieldAppliesToMethod {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Field,
        [string]$ConnectionMethod = ''
    )

    if (-not $Field.ContainsKey('Methods')) { return $true }
    if ([string]::IsNullOrWhiteSpace($ConnectionMethod)) { return $true }
    return @($Field['Methods']) -contains $ConnectionMethod
}

function Invoke-DeviceProfileTcpTest {
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$Label
    )

    $hostValue = if ($Values.ContainsKey('host')) { [string]$Values['host'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($hostValue)) {
        return [pscustomobject]@{ Status = 'Skipped'; Message = 'No host field is stored for this profile.' }
    }

    $port = 0
    if ($Values.ContainsKey('port')) { [void][int]::TryParse([string]$Values['port'], [ref]$port) }
    if ($port -lt 1) {
        $method = if ($Values.ContainsKey('connection_method')) { [string]$Values['connection_method'] } else { '' }
        if ($method -match '^ssh') { $port = 22 } elseif ($method -match '^api|https') { $port = 443 }
    }
    if ($port -lt 1) {
        return [pscustomobject]@{ Status = 'Skipped'; Message = 'No TCP port is stored for this profile.'; Host = $hostValue }
    }

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($hostValue, $port, $null, $null)
        $connected = $async.AsyncWaitHandle.WaitOne(4000, $false)
        if (-not $connected) {
            return [pscustomobject]@{ Status = 'Failed'; Message = 'TCP connection timed out.'; Host = $hostValue; Port = $port; Label = $Label }
        }
        $client.EndConnect($async)
        return [pscustomobject]@{ Status = 'Success'; Message = 'TCP connection opened successfully. Protocol authentication was not attempted by the generic profile test.'; Host = $hostValue; Port = $port; Label = $Label }
    } catch {
        return [pscustomobject]@{ Status = 'Failed'; Message = $_.Exception.Message; Host = $hostValue; Port = $port; Label = $Label }
    } finally {
        $client.Close()
    }
}

function ConvertTo-DeviceProfileBoolean {
    param([object]$Value, [bool]$Default = $false)

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
    switch ($text.ToLowerInvariant()) {
        { $_ -in @('1','true','yes','y','on') } { return $true }
        { $_ -in @('0','false','no','n','off') } { return $false }
        default { return $Default }
    }
}

function Invoke-KempDeviceProfileApiTest {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$Label
    )

    $modulePath = Join-Path $ProjectRoot 'Scripts/Modules/SimpleAcme.Kemp/SimpleAcme.Kemp.psd1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        return [pscustomobject]@{ Status = 'Failed'; Message = "Kemp module was not found: $modulePath"; Label = $Label }
    }

    Import-Module $modulePath -Force
    $hostName = if ($Values.ContainsKey('host')) { [string]$Values['host'] } else { '' }
    $port = 443
    if ($Values.ContainsKey('port') -and -not [string]::IsNullOrWhiteSpace([string]$Values['port'])) { [void][int]::TryParse([string]$Values['port'], [ref]$port) }
    $username = if ($Values.ContainsKey('username')) { [string]$Values['username'] } else { '' }
    $password = if ($Values.ContainsKey('password')) { [string]$Values['password'] } else { '' }
    $apiKey = if ($Values.ContainsKey('api_key')) { [string]$Values['api_key'] } else { '' }
    $skipCertificateCheck = ConvertTo-DeviceProfileBoolean -Value $(if ($Values.ContainsKey('skip_certificate_check')) { $Values['skip_certificate_check'] } else { $true }) -Default $true
    $endpoint = New-KempApiEndpoint -HostName $hostName -Port $port
    $started = Get-Date
    $managementUi = Test-KempManagementUi -HostName $hostName -Port $port -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 20

    try {
        $null = Connect-KempLoadMaster -HostName $hostName -Port $port -ApiKey $apiKey -Username $username -Password $password -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 60
        $services = @(Get-KempVirtualServices -HostName $hostName -Port $port -ApiKey $apiKey -Username $username -Password $password -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 60)
        return [pscustomobject]@{
            Status = 'Succeeded'
            Message = "Kemp API connected and returned $($services.Count) virtual service(s)."
            Endpoint = $endpoint
            Host = $hostName
            Port = $port
            Label = $Label
            ManagementUi = $managementUi
            VirtualServiceCount = $services.Count
            ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
            VirtualServices = @($services | Select-Object Id,Address,Port,Protocol,NickName,CurrentCertificate)
        }
    } catch {
        $prefix = if ($managementUi.Status -eq 'Succeeded') {
            "Kemp management UI is reachable at $($managementUi.Endpoint), but REST certificate API failed. "
        } else {
            "Kemp management UI probe failed at $($managementUi.Endpoint). "
        }
        return [pscustomobject]@{
            Status = 'Failed'
            Message = $prefix + $_.Exception.Message
            Endpoint = $endpoint
            Host = $hostName
            Port = $port
            Label = $Label
            ManagementUi = $managementUi
            ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
        }
    }
}

function Invoke-ClavisterDeviceProfileSshTest {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$Label
    )

    $modulePath = Join-Path $ProjectRoot 'Scripts/Modules/SimpleAcme.Clavister/SimpleAcme.Clavister.psd1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        return [pscustomobject]@{ Status = 'Failed'; Message = "Clavister module was not found: $modulePath"; Label = $Label }
    }

    Import-Module $modulePath -Force
    $hostName = if ($Values.ContainsKey('host')) { [string]$Values['host'] } else { '' }
    $port = 22
    if ($Values.ContainsKey('port') -and -not [string]::IsNullOrWhiteSpace([string]$Values['port'])) { [void][int]::TryParse([string]$Values['port'], [ref]$port) }
    $username = if ($Values.ContainsKey('username')) { [string]$Values['username'] } else { 'admin' }
    $password = if ($Values.ContainsKey('password')) { [string]$Values['password'] } else { '' }
    $privateKeyPath = if ($Values.ContainsKey('private_key_path')) { [string]$Values['private_key_path'] } else { '' }
    $fingerprint = if ($Values.ContainsKey('ssh_host_key_fingerprint')) { [string]$Values['ssh_host_key_fingerprint'] } else { '' }

    $started = Get-Date
    $tcp = Invoke-DeviceProfileTcpTest -Values $Values -Label $Label
    if ([string]$tcp.Status -ne 'Success') {
        return [pscustomobject]@{
            Status = 'Failed'
            Message = "TCP connection failed before SSH authentication: $($tcp.Message)"
            Host = $hostName
            Port = $port
            Label = $Label
            Tcp = $tcp
            ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
        }
    }

    $ssh = Test-ClavisterSshConnection -HostName $hostName -Port $port -Username $username -Password $password -PrivateKeyPath $privateKeyPath -HostKeyFingerprint $fingerprint -TimeoutSeconds 30
    return [pscustomobject]@{
        Status = $ssh.Status
        Message = $ssh.Message
        Host = $hostName
        Port = $port
        Label = $Label
        Tcp = $tcp
        ToolFamily = if ($ssh.PSObject.Properties.Name -contains 'ToolFamily') { $ssh.ToolFamily } else { '' }
        ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
    }
}

function Invoke-OPNsenseDeviceProfileApiTest {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$Label
    )

    $modulePath = Join-Path $ProjectRoot 'Scripts/Modules/SimpleAcme.OPNsense/SimpleAcme.OPNsense.psd1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        return [pscustomobject]@{ Status = 'Failed'; Message = "OPNsense module was not found: $modulePath"; Label = $Label }
    }

    Import-Module $modulePath -Force
    $hostName = if ($Values.ContainsKey('host')) { [string]$Values['host'] } else { '' }
    $port = 443
    if ($Values.ContainsKey('port') -and -not [string]::IsNullOrWhiteSpace([string]$Values['port'])) { [void][int]::TryParse([string]$Values['port'], [ref]$port) }
    $apiKey = if ($Values.ContainsKey('api_key')) { [string]$Values['api_key'] } else { '' }
    $apiSecret = if ($Values.ContainsKey('api_secret')) { [string]$Values['api_secret'] } else { '' }
    $skipCertificateCheck = ConvertTo-DeviceProfileBoolean -Value $(if ($Values.ContainsKey('skip_certificate_check')) { $Values['skip_certificate_check'] } else { $true }) -Default $true
    $started = Get-Date

    try {
        $connection = Test-OPNsenseApiConnection -HostName $hostName -Port $port -ApiKey $apiKey -ApiSecret $apiSecret -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 60
        $targets = @(Get-OPNsenseCertificateServiceInventory -HostName $hostName -Port $port -ApiKey $apiKey -ApiSecret $apiSecret -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 20)
        return [pscustomobject]@{
            Status = 'Succeeded'
            Message = "OPNsense API connected. Inventory returned $($targets.Count) certificate service surface(s)."
            Endpoint = $connection.Endpoint
            Host = $hostName
            Port = $port
            Label = $Label
            Product = $connection.Product
            Version = $connection.Version
            TargetCount = $targets.Count
            Targets = @($targets | Select-Object Id,Name,BindingStatus,Endpoint)
            ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
        }
    } catch {
        return [pscustomobject]@{
            Status = 'Failed'
            Message = $_.Exception.Message
            Host = $hostName
            Port = $port
            Label = $Label
            ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
        }
    }
}

function Invoke-PaloAltoDeviceProfileWebRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers = @{},
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 20
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $supportsSkipCertificateCheck = (Get-Command -Name Invoke-WebRequest).Parameters.ContainsKey('SkipCertificateCheck')
    $previous = [Net.ServicePointManager]::ServerCertificateValidationCallback
    if ($SkipCertificateCheck -and -not $supportsSkipCertificateCheck) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { param($sender,$certificate,$chain,$sslPolicyErrors) return $true }
    }

    try {
        $parameters = @{
            Uri = $Uri
            Method = 'Get'
            TimeoutSec = $TimeoutSeconds
            UseBasicParsing = $true
        }
        if ($Headers.Count -gt 0) { $parameters['Headers'] = $Headers }
        if ($SkipCertificateCheck -and $supportsSkipCertificateCheck) { $parameters['SkipCertificateCheck'] = $true }
        return Invoke-WebRequest @parameters
    } finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $previous
    }
}

function Invoke-PaloAltoDeviceProfileApiTest {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$Label
    )

    $null = $ProjectRoot
    $hostName = if ($Values.ContainsKey('host')) { [string]$Values['host'] } else { '' }
    $port = 443
    if ($Values.ContainsKey('port') -and -not [string]::IsNullOrWhiteSpace([string]$Values['port'])) { [void][int]::TryParse([string]$Values['port'], [ref]$port) }
    $apiKey = if ($Values.ContainsKey('api_key')) { [string]$Values['api_key'] } else { '' }
    $username = if ($Values.ContainsKey('username')) { [string]$Values['username'] } else { '' }
    $password = if ($Values.ContainsKey('password')) { [string]$Values['password'] } else { '' }
    $vsys = if ($Values.ContainsKey('vsys') -and -not [string]::IsNullOrWhiteSpace([string]$Values['vsys'])) { [string]$Values['vsys'] } else { 'vsys1' }
    $restLocation = if ($Values.ContainsKey('rest_location') -and -not [string]::IsNullOrWhiteSpace([string]$Values['rest_location'])) { [string]$Values['rest_location'] } else { 'vsys' }
    $skipCertificateCheck = ConvertTo-DeviceProfileBoolean -Value $(if ($Values.ContainsKey('skip_certificate_check')) { $Values['skip_certificate_check'] } else { $true }) -Default $true
    $base = if ($port -eq 443) { "https://$hostName" } else { "https://${hostName}:$port" }
    $started = Get-Date

    $tcp = Invoke-DeviceProfileTcpTest -Values $Values -Label $Label
    if ([string]$tcp.Status -ne 'Success') {
        return [pscustomobject]@{
            Status = 'Failed'
            Message = "TCP connection failed before Palo Alto API authentication: $($tcp.Message)"
            Host = $hostName
            Port = $port
            Label = $Label
            Tcp = $tcp
            ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
        }
    }

    try {
        if ([string]::IsNullOrWhiteSpace($apiKey)) {
            if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
                throw 'Palo Alto API key is missing, and username/password were not supplied for XML keygen.'
            }
            $keyUri = "{0}/api/?type=keygen&user={1}&password={2}" -f $base, [Uri]::EscapeDataString($username), [Uri]::EscapeDataString($password)
            $keyResponse = Invoke-PaloAltoDeviceProfileWebRequest -Uri $keyUri -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 20
            [xml]$keyXml = [string]$keyResponse.Content
            if ([string]$keyXml.response.status -ne 'success' -or [string]::IsNullOrWhiteSpace([string]$keyXml.response.result.key)) {
                throw "Palo Alto XML keygen failed: $($keyXml.response.msg.InnerText)"
            }
            $apiKey = [string]$keyXml.response.result.key
        }

        $systemCmd = '<show><system><info></info></system></show>'
        $systemUri = "{0}/api/?type=op&cmd={1}&key={2}" -f $base, [Uri]::EscapeDataString($systemCmd), [Uri]::EscapeDataString($apiKey)
        $systemResponse = Invoke-PaloAltoDeviceProfileWebRequest -Uri $systemUri -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 30
        [xml]$systemXml = [string]$systemResponse.Content
        if ([string]$systemXml.response.status -ne 'success') {
            throw "Palo Alto XML system info failed: $($systemXml.response.msg.InnerText)"
        }
        $system = $systemXml.response.result.system

        $apiKeyCertificateXPath = "/config/devices/entry[@name='localhost.localdomain']/deviceconfig/setting/management/api/key/certificate"
        $apiKeyCertificateStatus = 'NotConfigured'
        $apiKeyCertificateName = ''
        $apiKeyCertificateMessage = ''
        try {
            $apiKeyCertificateUri = "{0}/api/?type=config&action=show&xpath={1}&key={2}" -f $base, [Uri]::EscapeDataString($apiKeyCertificateXPath), [Uri]::EscapeDataString($apiKey)
            $apiKeyCertificateResponse = Invoke-PaloAltoDeviceProfileWebRequest -Uri $apiKeyCertificateUri -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 20
            [xml]$apiKeyCertificateXml = [string]$apiKeyCertificateResponse.Content
            if ([string]$apiKeyCertificateXml.response.status -eq 'success') {
                $apiKeyCertificateName = ([string]$apiKeyCertificateXml.response.result.InnerText).Trim()
                if ([string]::IsNullOrWhiteSpace($apiKeyCertificateName)) {
                    $apiKeyCertificateStatus = 'Configured'
                } else {
                    $apiKeyCertificateStatus = 'Configured'
                    $apiKeyCertificateMessage = "API key certificate '$apiKeyCertificateName' is configured."
                }
            } elseif ($apiKeyCertificateXml.response.msg.InnerText -match 'No such node') {
                $apiKeyCertificateMessage = 'API key certificate is not configured; PAN-OS may warn that KeyGen uses the deprecated algorithm.'
            } else {
                $apiKeyCertificateStatus = 'Unknown'
                $apiKeyCertificateMessage = $apiKeyCertificateXml.response.msg.InnerText
            }
        } catch {
            $apiKeyCertificateStatus = 'Unknown'
            $apiKeyCertificateMessage = $_.Exception.Message
        }

        $restQuery = if ($restLocation -eq 'vsys') { "location=vsys&vsys=$([Uri]::EscapeDataString($vsys))" } else { 'location=shared' }
        $restUri = "{0}/restapi/v12.1/Objects/Addresses?{1}" -f $base, $restQuery
        $restStatus = 'Skipped'
        $restMessage = ''
        try {
            $restResponse = Invoke-PaloAltoDeviceProfileWebRequest -Uri $restUri -Headers @{ 'X-PAN-KEY' = $apiKey; 'Accept' = 'application/json' } -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 20
            $restBody = [string]$restResponse.Content | ConvertFrom-Json
            $restStatus = if ([string]$restBody.'@status' -eq 'success') { 'Succeeded' } else { 'Failed' }
            $restMessage = "REST address inventory returned status $($restBody.'@status')."
        } catch {
            $restStatus = 'Failed'
            $restMessage = $_.Exception.Message
        }

        return [pscustomobject]@{
            Status = 'Succeeded'
            Message = "Palo Alto XML API connected to $($system.hostname) on PAN-OS $($system.'sw-version'). REST inventory: $restStatus."
            Endpoint = "$base/api/"
            Host = $hostName
            Port = $port
            Label = $Label
            Hostname = [string]$system.hostname
            Model = [string]$system.model
            SwVersion = [string]$system.'sw-version'
            Serial = [string]$system.serial
            Vsys = $vsys
            ApiKeyCertificate = [pscustomobject]@{ Status = $apiKeyCertificateStatus; Name = $apiKeyCertificateName; Message = $apiKeyCertificateMessage; XPath = $apiKeyCertificateXPath }
            RestInventory = [pscustomobject]@{ Status = $restStatus; Endpoint = $restUri; Message = $restMessage }
            Tcp = $tcp
            ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
        }
    } catch {
        return [pscustomobject]@{
            Status = 'Failed'
            Message = $_.Exception.Message
            Host = $hostName
            Port = $port
            Label = $Label
            Tcp = $tcp
            ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
        }
    }
}

function Invoke-DeviceProfileCommunicationTest {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConnectorType,
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$Label
    )

    switch ($ConnectorType) {
        'clavister' { return Invoke-ClavisterDeviceProfileSshTest -ProjectRoot $ProjectRoot -Values $Values -Label $Label }
        'kemp' { return Invoke-KempDeviceProfileApiTest -ProjectRoot $ProjectRoot -Values $Values -Label $Label }
        'opnsense' { return Invoke-OPNsenseDeviceProfileApiTest -ProjectRoot $ProjectRoot -Values $Values -Label $Label }
        'paloalto' { return Invoke-PaloAltoDeviceProfileApiTest -ProjectRoot $ProjectRoot -Values $Values -Label $Label }
        default { return Invoke-DeviceProfileTcpTest -Values $Values -Label $Label }
    }
}

function Save-DeviceProfile {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$ConnectorType,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][hashtable]$Values,
        [string[]]$SecretFields = @(),
        [string]$DefaultDeviceId = '',
        [string]$DeviceId = '',
        [string]$FriendlyName = ''
    )

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $effectiveLabel = if (-not [string]::IsNullOrWhiteSpace($FriendlyName)) { $FriendlyName.Trim() } else { $Label }
    if ([string]::IsNullOrWhiteSpace($DeviceId)) {
        if (-not [string]::IsNullOrWhiteSpace($DefaultDeviceId)) {
            $DeviceId = $DefaultDeviceId
        } else {
            $DeviceId = New-DeviceProfileId -ConfigDir $ConfigDir -ConnectorType $ConnectorType -FriendlyName $effectiveLabel
        }
    }

    $deviceId = $DeviceId.Trim()
    $createdAt = $now
    $existing = Get-DeviceProfileById -ConfigDir $ConfigDir -DeviceId $deviceId
    if ($null -ne $existing -and $existing -is [System.Collections.IDictionary]) {
        if ($existing.ContainsKey('created_at') -and -not [string]::IsNullOrWhiteSpace([string]$existing['created_at'])) {
            $createdAt = [string]$existing['created_at']
        }
    }

    $settings = @{}
    foreach ($key in $Values.Keys) { $settings[[string]$key] = [string]$Values[$key] }
    $device = @{
        device_id = $deviceId
        connector_type = $ConnectorType
        label = $effectiveLabel
        created_at = $createdAt
        updated_at = $now
        settings = $settings
    }
    Save-DeviceConfig -Device $device -ConfigDir $ConfigDir -SecretFields $SecretFields | Out-Null
}

function Invoke-GuidedDeviceProfileForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConnectorType,
        [string]$Title = '',
        [string]$DefaultDeviceId = '',
        [string]$DeviceId = '',
        [string]$FriendlyName = ''
    )

    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    . $schemaPath
    if (-not $DeviceSchemas.ContainsKey($ConnectorType)) { throw "Device schema '$ConnectorType' was not found in $schemaPath" }
    $schema = $DeviceSchemas[$ConnectorType]
    $profileLabel = if ($schema.ContainsKey('Label') -and -not [string]::IsNullOrWhiteSpace([string]$schema.Label)) { [string]$schema.Label } else { $ConnectorType }
    $displayLabel = if (-not [string]::IsNullOrWhiteSpace($FriendlyName)) { $FriendlyName.Trim() } else { $profileLabel }
    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $currentValues = Add-DeviceProfileDefaults -Values (Get-DeviceProfileCurrentValues -ConfigDir $configDir -ConnectorType $ConnectorType -DeviceId $DeviceId) -Fields @($schema.Fields)
    $values = @{}
    foreach ($key in $currentValues.Keys) { $values[[string]$key] = [string]$currentValues[$key] }

    $connectionMethod = ''
    if ($schema.ContainsKey('ConnectionMethods')) {
        $methods = @($schema.ConnectionMethods)
        if ($methods.Count -gt 0) {
            $selectedMethod = Select-DeviceProfileNumberedItem -Title ("{0}: connection method" -f $profileLabel) -Items $methods -LabelSelector {
                param($item)
                if ($item -is [System.Collections.IDictionary] -and $item.ContainsKey('Label')) { return [string]$item['Label'] }
                return [string]$item
            }
            if ($null -eq $selectedMethod) { return [pscustomobject]@{ Status = 'Canceled' } }
            $connectionMethod = if ($selectedMethod -is [System.Collections.IDictionary] -and $selectedMethod.ContainsKey('Key')) { [string]$selectedMethod['Key'] } else { [string]$selectedMethod }
            $values['connection_method'] = $connectionMethod
            if ($selectedMethod -is [System.Collections.IDictionary] -and $selectedMethod.ContainsKey('DefaultPort') -and (-not $values.ContainsKey('port') -or [string]::IsNullOrWhiteSpace([string]$values['port']))) {
                $values['port'] = [string]$selectedMethod['DefaultPort']
            }
        }
    }

    Clear-Host
    $formTitle = if (-not [string]::IsNullOrWhiteSpace($Title)) { $Title } else { "{0} guided device profile" -f $displayLabel }
    Write-Host $formTitle
    Write-Host ('-' * $formTitle.Length)
    Write-Host 'Press Esc at any question to cancel.'
    Write-Host ''

    foreach ($field in @($schema.Fields)) {
        if (-not ($field -is [System.Collections.IDictionary]) -or -not $field.ContainsKey('Name')) { continue }
        if (-not (Test-DeviceProfileFieldAppliesToMethod -Field $field -ConnectionMethod $connectionMethod)) { continue }
        $name = [string]$field['Name']
        if ($name -eq 'connection_method') { continue }
        $labelText = if ($field.ContainsKey('Label') -and -not [string]::IsNullOrWhiteSpace([string]$field['Label'])) { [string]$field['Label'] } else { $name }
        $required = ($field.ContainsKey('Required') -and [bool]$field['Required'])
        $prompt = if ($required) { "$labelText *" } else { $labelText }
        $default = Get-DeviceProfileFieldDefault -Field $field -CurrentValues $values
        $isSecret = ($field.ContainsKey('Type') -and [string]$field['Type'] -eq 'secret') -or ($name -match '(?i)password|secret|token|api_key')

        while ($true) {
            $answer = Read-DeviceProfileConsoleLine -Prompt $prompt -Default $default -Secret:$isSecret
            if ($null -eq $answer) { return [pscustomobject]@{ Status = 'Canceled' } }
            if ($required -and [string]::IsNullOrWhiteSpace($answer)) {
                Write-Host 'This value is required.' -ForegroundColor Yellow
                continue
            }
            $values[$name] = [string]$answer
            break
        }
    }

    $values = Remove-DeviceProfilePlaceholderValues -Values $values -Fields @($schema.Fields)
    $values = Add-DeviceProfileDefaults -Values $values -Fields @($schema.Fields)
    $secretFields = @()
    foreach ($field in @($schema.Fields)) {
        if (-not ($field -is [System.Collections.IDictionary]) -or -not $field.ContainsKey('Name')) { continue }
        $name = [string]$field['Name']
        if (($field.ContainsKey('Type') -and [string]$field['Type'] -eq 'secret') -or $name -match '(?i)password|token|api_key|secret') {
            $secretFields += $name
        }
    }
    $secretFields = @($secretFields | Sort-Object -Unique)

    Save-DeviceProfile -ConfigDir $configDir -ConnectorType $ConnectorType -Label $profileLabel -Values $values -SecretFields $secretFields -DefaultDeviceId $DefaultDeviceId -DeviceId $DeviceId -FriendlyName $displayLabel
    Show-DeviceProfileSummary -Title ("Saved {0} device profile" -f $displayLabel) -Values $values -Fields @($schema.Fields)

    $testResult = $null
    $testLogPath = $null
    $shouldTest = Read-DeviceProfileGuidedYesNo -Prompt ("Test communication with {0} now?" -f $displayLabel) -Default $true
    if ($null -eq $shouldTest) { return [pscustomobject]@{ Status = 'Saved'; ConfigDir = $configDir; CommunicationTest = $null } }
    if ($shouldTest) {
        Write-Host ''
        Write-Host ("Testing communication with {0}..." -f $displayLabel)
        $testResult = Invoke-DeviceProfileCommunicationTest -ProjectRoot $ProjectRoot -ConnectorType $ConnectorType -Values $values -Label $displayLabel
        $testLogPath = Write-DeviceProfileJsonLog -ProjectRoot $ProjectRoot -ConnectorType $ConnectorType -Data $testResult
        Write-Host ''
        Write-Host 'Communication test summary'
        Write-Host '--------------------------'
        Write-Host ("Status: {0}" -f $testResult.Status)
        Write-Host ("Message: {0}" -f $testResult.Message)
        if ($testResult.PSObject.Properties.Name -contains 'Host') { Write-Host ("Host: {0}" -f $testResult.Host) }
        if ($testResult.PSObject.Properties.Name -contains 'Port') { Write-Host ("Port: {0}" -f $testResult.Port) }
        if ($testResult.PSObject.Properties.Name -contains 'ManagementUi' -and $null -ne $testResult.ManagementUi) {
            Write-Host ("Management UI: {0} ({1})" -f $testResult.ManagementUi.Status, $testResult.ManagementUi.Endpoint)
        }
        Write-Host ("Log: {0}" -f $testLogPath)
        Wait-DeviceProfileOperatorKey
    } else {
        Write-Host ''
        Write-Host 'Communication test skipped by operator.'
        Wait-DeviceProfileOperatorKey
    }

    return [pscustomobject]@{ Status = 'Saved'; ConfigDir = $configDir; CommunicationTest = $testResult; CommunicationTestLog = $testLogPath }
}

function Invoke-DeviceProfileWizard {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    . $schemaPath
    $items = @(
        foreach ($key in @($DeviceSchemas.Keys | Sort-Object)) {
            $schema = $DeviceSchemas[$key]
            if ($schema.ContainsKey('Disabled') -and [bool]$schema.Disabled) { continue }
            [pscustomobject]@{
                ConnectorType = [string]$key
                Label = if ($schema.ContainsKey('Label')) { [string]$schema.Label } else { [string]$key }
                Category = if ($schema.ContainsKey('Category')) { [string]$schema.Category } else { 'other' }
                Guided = ($schema.ContainsKey('SetupMode') -and [string]$schema.SetupMode -eq 'guided')
            }
        }
    )

    $selected = Select-DeviceProfileNumberedItem -Title 'Create or edit device profile' -Items $items -LabelSelector {
        param($item)
        $mode = if ($item.Guided) { 'guided' } else { 'form' }
        return ("{0} ({1}, {2})" -f $item.Label, $item.Category, $mode)
    }
    if ($null -eq $selected) { return [pscustomobject]@{ Status = 'Canceled' } }
    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $existingProfiles = @(Get-AllDeviceConfigs -ConfigDir $configDir -SkipIntegrityFailures | Where-Object {
        $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]($_['connector_type']) -eq [string]$selected.ConnectorType
    } | Sort-Object @{ Expression = { if ($_ -is [System.Collections.IDictionary] -and $_.ContainsKey('label')) { [string]($_['label']) } else { '' } } })

    $selectedDeviceId = ''
    $friendlyName = ''
    if ($existingProfiles.Count -gt 0) {
        $profileChoices = @([pscustomobject]@{ Kind = 'new'; Device = $null; Label = ("Create new {0}" -f $selected.Label) })
        foreach ($profile in $existingProfiles) {
            $label = if ($profile.ContainsKey('label') -and -not [string]::IsNullOrWhiteSpace([string]$profile['label'])) { [string]$profile['label'] } else { [string]$profile['device_id'] }
            $profileChoices += [pscustomobject]@{ Kind = 'existing'; Device = $profile; Label = ("Edit {0} ({1})" -f $label, [string]$profile['device_id']) }
        }
        $profileChoice = Select-DeviceProfileNumberedItem -Title ("{0}: choose profile" -f $selected.Label) -Items $profileChoices -LabelSelector {
            param($item)
            return [string]$item.Label
        }
        if ($null -eq $profileChoice) { return [pscustomobject]@{ Status = 'Canceled' } }
        if ([string]$profileChoice.Kind -eq 'existing') {
            $selectedDeviceId = [string]$profileChoice.Device['device_id']
            $friendlyName = if ($profileChoice.Device.ContainsKey('label') -and -not [string]::IsNullOrWhiteSpace([string]$profileChoice.Device['label'])) { [string]$profileChoice.Device['label'] } else { $selected.Label }
        }
    }

    if ([string]::IsNullOrWhiteSpace($selectedDeviceId)) {
        Clear-Host
        Write-Host ("Create {0} profile" -f $selected.Label)
        Write-Host ('-' * ("Create {0} profile" -f $selected.Label).Length)
        Write-Host 'Give this device a short friendly name operators can recognize later.'
        Write-Host ''
        $friendlyName = Read-DeviceProfileConsoleLine -Prompt 'Friendly name' -Default ([string]$selected.Label)
        if ($null -eq $friendlyName) { return [pscustomobject]@{ Status = 'Canceled' } }
        if ([string]::IsNullOrWhiteSpace($friendlyName)) { $friendlyName = [string]$selected.Label }
        $selectedDeviceId = New-DeviceProfileId -ConfigDir $configDir -ConnectorType ([string]$selected.ConnectorType) -FriendlyName $friendlyName
    }

    if ($selected.Guided) {
        return Invoke-GuidedDeviceProfileForm -ProjectRoot $ProjectRoot -ConnectorType $selected.ConnectorType -DeviceId $selectedDeviceId -FriendlyName $friendlyName
    }
    return Invoke-DeviceProfileForm -ProjectRoot $ProjectRoot -ConnectorType $selected.ConnectorType -DeviceId $selectedDeviceId -FriendlyName $friendlyName
}

function Invoke-DeviceProfileConnectorWizard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConnectorType
    )

    $schemaChoices = @(Get-DeviceProfileSchemaChoices -ProjectRoot $ProjectRoot)
    $selected = @($schemaChoices | Where-Object { [string]$_.ConnectorType -eq $ConnectorType } | Select-Object -First 1)
    if ($selected.Count -lt 1 -or $null -eq $selected[0]) {
        throw "No setup schema is available for connector type '$ConnectorType'."
    }
    $selected = $selected[0]

    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $existingProfiles = @(Get-AllDeviceConfigs -ConfigDir $configDir -SkipIntegrityFailures | Where-Object {
        $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]($_['connector_type']) -eq [string]$selected.ConnectorType
    } | Sort-Object @{ Expression = { if ($_ -is [System.Collections.IDictionary] -and $_.ContainsKey('label')) { [string]($_['label']) } else { '' } } })

    $selectedDeviceId = ''
    $friendlyName = ''
    if ($existingProfiles.Count -gt 0) {
        $profileChoices = @([pscustomobject]@{ Kind = 'new'; Device = $null; Label = ("Create new {0}" -f $selected.Label) })
        foreach ($profile in $existingProfiles) {
            $label = if ($profile.ContainsKey('label') -and -not [string]::IsNullOrWhiteSpace([string]$profile['label'])) { [string]$profile['label'] } else { [string]$profile['device_id'] }
            $profileChoices += [pscustomobject]@{ Kind = 'existing'; Device = $profile; Label = ("Edit {0} ({1})" -f $label, [string]$profile['device_id']) }
        }
        $profileChoice = Select-DeviceProfileNumberedItem -Title ("{0}: choose profile" -f $selected.Label) -Items $profileChoices -LabelSelector {
            param($item)
            return [string]$item.Label
        }
        if ($null -eq $profileChoice) { return [pscustomobject]@{ Status = 'Canceled' } }
        if ([string]$profileChoice.Kind -eq 'existing') {
            $selectedDeviceId = [string]$profileChoice.Device['device_id']
            $friendlyName = if ($profileChoice.Device.ContainsKey('label') -and -not [string]::IsNullOrWhiteSpace([string]$profileChoice.Device['label'])) { [string]$profileChoice.Device['label'] } else { $selected.Label }
        }
    }

    if ([string]::IsNullOrWhiteSpace($selectedDeviceId)) {
        Clear-Host
        Write-Host ("Create {0} profile" -f $selected.Label)
        Write-Host ('-' * ("Create {0} profile" -f $selected.Label).Length)
        Write-Host 'Give this device a short friendly name operators can recognize later.'
        Write-Host ''
        $friendlyName = Read-DeviceProfileConsoleLine -Prompt 'Friendly name' -Default ([string]$selected.Label)
        if ($null -eq $friendlyName) { return [pscustomobject]@{ Status = 'Canceled' } }
        if ([string]::IsNullOrWhiteSpace($friendlyName)) { $friendlyName = [string]$selected.Label }
        $selectedDeviceId = New-DeviceProfileId -ConfigDir $configDir -ConnectorType ([string]$selected.ConnectorType) -FriendlyName $friendlyName
    }

    return Invoke-DeviceProfileEditorForChoice -ProjectRoot $ProjectRoot -Choice $selected -DeviceId $selectedDeviceId -FriendlyName $friendlyName
}

function Get-DeviceProfileSchemaChoices {
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    . $schemaPath
    return @(
        foreach ($key in @($DeviceSchemas.Keys | Sort-Object)) {
            $schema = $DeviceSchemas[$key]
            if ($schema.ContainsKey('Disabled') -and [bool]$schema.Disabled) { continue }
            [pscustomobject]@{
                ConnectorType = [string]$key
                Label = if ($schema.ContainsKey('Label')) { [string]$schema.Label } else { [string]$key }
                Category = if ($schema.ContainsKey('Category')) { [string]$schema.Category } else { 'other' }
                Guided = ($schema.ContainsKey('SetupMode') -and [string]$schema.SetupMode -eq 'guided')
            }
        }
    )
}

function Get-DeviceProfileList {
    param([Parameter(Mandatory)][string]$ConfigDir)

    return @(Get-AllDeviceConfigs -ConfigDir $ConfigDir -SkipIntegrityFailures | Where-Object {
        $_ -is [System.Collections.IDictionary]
    } | Sort-Object `
        @{ Expression = { if ($_.ContainsKey('connector_type')) { [string]($_['connector_type']) } else { '' } } }, `
        @{ Expression = { if ($_.ContainsKey('label')) { [string]($_['label']) } else { '' } } }, `
        @{ Expression = { if ($_.ContainsKey('device_id')) { [string]($_['device_id']) } else { '' } } })
}

function Select-DeviceProfileExistingDevice {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Devices
    )

    if ($Devices.Count -lt 1) {
        Clear-Host
        Write-Host $Title
        Write-Host ('-' * $Title.Length)
        Write-Host 'No device profiles are configured yet.'
        Wait-DeviceProfileOperatorKey
        return $null
    }

    return Select-DeviceProfileNumberedItem -Title $Title -Items $Devices -LabelSelector {
        param($device)
        $label = if ($device.ContainsKey('label') -and -not [string]::IsNullOrWhiteSpace([string]$device['label'])) { [string]$device['label'] } else { '<unnamed>' }
        $connector = if ($device.ContainsKey('connector_type')) { [string]$device['connector_type'] } else { '<missing>' }
        $deviceId = if ($device.ContainsKey('device_id')) { [string]$device['device_id'] } else { '<missing>' }
        $endpoint = Get-DeviceProfileEndpointSummary -Device $device
        return ("{0}  type={1}  endpoint={2}  id={3}" -f $label, $connector, $endpoint, $deviceId)
    }
}

function Invoke-DeviceProfileEditorForChoice {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)]$Choice,
        [Parameter(Mandatory)][string]$DeviceId,
        [Parameter(Mandatory)][string]$FriendlyName
    )

    if ($Choice.Guided) {
        return Invoke-GuidedDeviceProfileForm -ProjectRoot $ProjectRoot -ConnectorType $Choice.ConnectorType -DeviceId $DeviceId -FriendlyName $FriendlyName
    }
    return Invoke-DeviceProfileForm -ProjectRoot $ProjectRoot -ConnectorType $Choice.ConnectorType -DeviceId $DeviceId -FriendlyName $FriendlyName
}

function Invoke-DeviceProfileAdd {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $items = Get-DeviceProfileSchemaChoices -ProjectRoot $ProjectRoot
    $selected = Select-DeviceProfileNumberedItem -Title 'Add device profile' -Items $items -LabelSelector {
        param($item)
        $mode = if ($item.Guided) { 'guided' } else { 'form' }
        return ("{0} ({1}, {2})" -f $item.Label, $item.Category, $mode)
    }
    if ($null -eq $selected) { return [pscustomobject]@{ Status = 'Canceled' } }

    Clear-Host
    Write-Host ("Add {0} profile" -f $selected.Label)
    Write-Host ('-' * ("Add {0} profile" -f $selected.Label).Length)
    Write-Host 'Give this device a short friendly name operators can recognize later.'
    Write-Host ''
    $friendlyName = Read-DeviceProfileConsoleLine -Prompt 'Friendly name' -Default ([string]$selected.Label)
    if ($null -eq $friendlyName) { return [pscustomobject]@{ Status = 'Canceled' } }
    if ([string]::IsNullOrWhiteSpace($friendlyName)) { $friendlyName = [string]$selected.Label }

    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $deviceId = New-DeviceProfileId -ConfigDir $configDir -ConnectorType ([string]$selected.ConnectorType) -FriendlyName $friendlyName
    return Invoke-DeviceProfileEditorForChoice -ProjectRoot $ProjectRoot -Choice $selected -DeviceId $deviceId -FriendlyName $friendlyName
}

function Invoke-DeviceProfileEdit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $device = Select-DeviceProfileExistingDevice -Title 'Change existing device profile' -Devices (Get-DeviceProfileList -ConfigDir $configDir)
    if ($null -eq $device) { return [pscustomobject]@{ Status = 'Canceled' } }

    $schemaChoices = @(Get-DeviceProfileSchemaChoices -ProjectRoot $ProjectRoot)
    $connectorType = if ($device.ContainsKey('connector_type')) { [string]$device['connector_type'] } else { '' }
    $choice = @($schemaChoices | Where-Object { [string]$_.ConnectorType -eq $connectorType } | Select-Object -First 1)
    if ($choice.Count -lt 1 -or $null -eq $choice[0]) {
        Write-Host ''
        Write-Host ("No setup schema is available for connector type '{0}'." -f $connectorType) -ForegroundColor Yellow
        Wait-DeviceProfileOperatorKey
        return [pscustomobject]@{ Status = 'SchemaMissing'; ConnectorType = $connectorType }
    }

    $deviceId = if ($device.ContainsKey('device_id')) { [string]$device['device_id'] } else { '' }
    $friendlyName = if ($device.ContainsKey('label') -and -not [string]::IsNullOrWhiteSpace([string]$device['label'])) { [string]$device['label'] } else { $deviceId }
    return Invoke-DeviceProfileEditorForChoice -ProjectRoot $ProjectRoot -Choice $choice[0] -DeviceId $deviceId -FriendlyName $friendlyName
}

function Invoke-DeviceProfileDelete {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $device = Select-DeviceProfileExistingDevice -Title 'Delete device profile' -Devices (Get-DeviceProfileList -ConfigDir $configDir)
    if ($null -eq $device) { return [pscustomobject]@{ Status = 'Canceled' } }

    $deviceId = if ($device.ContainsKey('device_id')) { [string]$device['device_id'] } else { '' }
    $label = if ($device.ContainsKey('label') -and -not [string]::IsNullOrWhiteSpace([string]$device['label'])) { [string]$device['label'] } else { $deviceId }
    Clear-Host
    Write-Host 'Delete device profile'
    Write-Host '---------------------'
    Write-Host ("Friendly name: {0}" -f $label)
    Write-Host ("Device ID: {0}" -f $deviceId)
    $connectorLabel = if ($device.ContainsKey('connector_type')) { [string]$device['connector_type'] } else { '<missing>' }
    Write-Host ("Type: {0}" -f $connectorLabel)
    Write-Host ("Endpoint: {0}" -f (Get-DeviceProfileEndpointSummary -Device $device))
    Write-Host ''
    $confirm = Read-DeviceProfileGuidedYesNo -Prompt 'Delete this configured device profile?' -Default $false
    if ($null -eq $confirm -or -not $confirm) { return [pscustomobject]@{ Status = 'Canceled'; DeviceId = $deviceId } }
    Remove-DeviceConfig -ConfigDir $configDir -DeviceId $deviceId
    Write-Host ''
    Write-Host ("Deleted device profile: {0}" -f $label)
    Wait-DeviceProfileOperatorKey
    return [pscustomobject]@{ Status = 'Deleted'; DeviceId = $deviceId; ConfigDir = $configDir }
}

function Invoke-DeviceProfileManager {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    while ($true) {
        $choice = Select-DeviceProfileNumberedItem -Title 'Configured devices' -Items @(
            [pscustomobject]@{ Key = 'view'; Label = 'View configured devices' },
            [pscustomobject]@{ Key = 'add'; Label = 'Add new device' },
            [pscustomobject]@{ Key = 'edit'; Label = 'Change existing device' },
            [pscustomobject]@{ Key = 'delete'; Label = 'Delete existing device' }
        ) -LabelSelector {
            param($item)
            return [string]$item.Label
        }
        if ($null -eq $choice) { return [pscustomobject]@{ Status = 'Canceled' } }

        switch ([string]$choice.Key) {
            'view'   { Invoke-DeviceProfileInventory -ProjectRoot $ProjectRoot | Out-Null }
            'add'    { Invoke-DeviceProfileAdd -ProjectRoot $ProjectRoot | Out-Null }
            'edit'   { Invoke-DeviceProfileEdit -ProjectRoot $ProjectRoot | Out-Null }
            'delete' { Invoke-DeviceProfileDelete -ProjectRoot $ProjectRoot | Out-Null }
        }
    }
}

function Invoke-DeviceProfileForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConnectorType,
        [string]$Title = '',
        [string]$DefaultDeviceId = '',
        [string]$DeviceId = '',
        [string]$FriendlyName = '',
        [string[]]$CertificateRuntimeKeys = @(),
        [hashtable]$PlaintextSecretNameFields = @{},
        [string[]]$SecretFields = @(),
        [scriptblock]$CommunicationTest = $null
    )

    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    . $schemaPath
    if (-not $DeviceSchemas.ContainsKey($ConnectorType)) { throw "Device schema '$ConnectorType' was not found in $schemaPath" }

    $schema = $DeviceSchemas[$ConnectorType]
    $label = if ($schema.ContainsKey('Label') -and -not [string]::IsNullOrWhiteSpace([string]$schema.Label)) { [string]$schema.Label } else { $ConnectorType }
    $displayLabel = if (-not [string]::IsNullOrWhiteSpace($FriendlyName)) { $FriendlyName.Trim() } else { $label }
    $formTitle = if (-not [string]::IsNullOrWhiteSpace($Title)) { $Title } else { "{0} device profile" -f $displayLabel }
    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $currentValues = Remove-DeviceProfilePlaceholderValues -Values (Get-DeviceProfileCurrentValues -ConfigDir $configDir -ConnectorType $ConnectorType -DeviceId $DeviceId -CertificateRuntimeKeys $CertificateRuntimeKeys -PlaintextSecretNameFields $PlaintextSecretNameFields) -Fields @($schema.Fields)
    $currentValues = Add-DeviceProfileDefaults -Values $currentValues -Fields @($schema.Fields)
    $values = Show-TuiForm -Fields ([hashtable[]]$schema.Fields) -CurrentValues $currentValues -Title $formTitle
    if ($null -eq $values) { return [pscustomobject]@{ Status = 'Canceled' } }
    $values = Remove-DeviceProfilePlaceholderValues -Values $values -Fields @($schema.Fields)
    $values = Add-DeviceProfileDefaults -Values $values -Fields @($schema.Fields)
    Save-DeviceProfile -ConfigDir $configDir -ConnectorType $ConnectorType -Label $label -Values $values -SecretFields $SecretFields -DefaultDeviceId $DefaultDeviceId -DeviceId $DeviceId -FriendlyName $displayLabel
    Show-DeviceProfileSummary -Title ("Saved {0} device profile" -f $displayLabel) -Values $values -Fields @($schema.Fields)

    $testResult = $null
    $testLogPath = $null
    if ($null -ne $CommunicationTest) {
        $shouldTest = Read-DeviceProfileYesNo -Prompt ("Test communication with {0} now?" -f $displayLabel) -Default $true
        if ($shouldTest) {
            Write-Host ''
            Write-Host ("Testing communication with {0}..." -f $displayLabel)
            try {
                $testResult = & $CommunicationTest -ProjectRoot $ProjectRoot -ConfigDir $configDir -ConnectorType $ConnectorType -Label $displayLabel -Values $values -Schema $schema
            } catch {
                $testResult = [pscustomobject]@{
                    Status = 'Failed'
                    Message = $_.Exception.Message
                    ErrorType = $_.Exception.GetType().FullName
                }
            }
            $testLogPath = Write-DeviceProfileJsonLog -ProjectRoot $ProjectRoot -ConnectorType $ConnectorType -Data $testResult
            Write-Host ''
            Write-Host 'Communication test summary'
            Write-Host '--------------------------'
            Write-Host ("Status: {0}" -f $testResult.Status)
            if ($testResult.PSObject.Properties.Name -contains 'Message') { Write-Host ("Message: {0}" -f $testResult.Message) }
            if ($testResult.PSObject.Properties.Name -contains 'Endpoint') { Write-Host ("Endpoint: {0}" -f $testResult.Endpoint) }
            Write-Host ("Log: {0}" -f $testLogPath)
        } else {
            Write-Host ''
            Write-Host 'Communication test skipped by operator.'
        }
    }

    Show-TuiStatus -Message ("{0} device profile saved." -f $displayLabel) -Type Success -Row ([Math]::Max(0,[Console]::WindowHeight)-2)
    Start-Sleep -Milliseconds 1200
    return [pscustomobject]@{ Status = 'Saved'; ConfigDir = $configDir; CommunicationTest = $testResult; CommunicationTestLog = $testLogPath }
}

function Invoke-DeviceProfileInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $devices = @(Get-DeviceProfileList -ConfigDir $configDir)

    Clear-Host
    Write-Host 'Configured devices'
    Write-Host '------------------'
    Write-Host ("Config folder: {0}" -f $configDir)
    Write-Host ''
    if ($devices.Count -lt 1) {
        Write-Host 'No device profiles are configured yet.'
        Wait-DeviceProfileOperatorKey
        return [pscustomobject]@{ Status = 'Empty'; Count = 0; ConfigDir = $configDir }
    }

    for ($i = 0; $i -lt $devices.Count; $i++) {
        $device = $devices[$i]
        $label = if ($device.ContainsKey('label') -and -not [string]::IsNullOrWhiteSpace([string]$device['label'])) { [string]$device['label'] } else { '<unnamed>' }
        $deviceId = if ($device.ContainsKey('device_id')) { [string]$device['device_id'] } else { '<missing>' }
        $connector = if ($device.ContainsKey('connector_type')) { [string]$device['connector_type'] } else { '<missing>' }
        $updated = if ($device.ContainsKey('updated_at')) { [string]$device['updated_at'] } else { '<unknown>' }
        Write-Host ("[{0}] {1}" -f ($i + 1), $label)
        Write-Host ("    Type: {0}" -f $connector)
        Write-Host ("    Device ID: {0}" -f $deviceId)
        Write-Host ("    Endpoint: {0}" -f (Get-DeviceProfileEndpointSummary -Device $device))
        Write-Host ("    Targets: {0}" -f (Get-DeviceProfileTargetSummary -Device $device))
        Write-Host ("    Updated: {0}" -f $updated)
        Write-Host ''
    }

    Wait-DeviceProfileOperatorKey
    return [pscustomobject]@{ Status = 'Shown'; Count = $devices.Count; ConfigDir = $configDir }
}

Export-ModuleMember -Function Resolve-DeviceProfileConfigDir,Get-DeviceProfileCurrentValues,Add-DeviceProfileDefaults,Remove-DeviceProfilePlaceholderValues,Get-DeviceProfileFieldDefault,Save-DeviceProfile,Invoke-DeviceProfileForm,Invoke-GuidedDeviceProfileForm,Invoke-DeviceProfileWizard,Invoke-DeviceProfileConnectorWizard,Invoke-DeviceProfileManager,Invoke-DeviceProfileInventory,Invoke-DeviceProfileAdd,Invoke-DeviceProfileEdit,Invoke-DeviceProfileDelete,Invoke-DeviceProfileTcpTest,Test-DeviceProfileLikelyPlaintextSecret,Show-DeviceProfileSummary,ConvertTo-DeviceProfileDisplayValue,Write-DeviceProfileJsonLog,Read-DeviceProfileYesNo,Read-DeviceProfileConsoleLine,Read-DeviceProfileGuidedYesNo,Wait-DeviceProfileOperatorKey,New-DeviceProfileId
