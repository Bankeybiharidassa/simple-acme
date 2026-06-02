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

    $suffix = if ([string]::IsNullOrWhiteSpace($Default)) { '' } else { " [$Default]" }
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

function Get-DeviceProfileCurrentValues {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$ConnectorType,
        [string[]]$CertificateRuntimeKeys = @(),
        [hashtable]$PlaintextSecretNameFields = @{}
    )

    $existing = @(Get-AllDeviceConfigs -ConfigDir $ConfigDir -SkipIntegrityFailures | Where-Object {
        $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]($_['connector_type']) -eq $ConnectorType
    } | Select-Object -First 1)
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

function Save-DeviceProfile {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$ConnectorType,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][hashtable]$Values,
        [string[]]$SecretFields = @(),
        [string]$DefaultDeviceId = ''
    )

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $existing = @(Get-AllDeviceConfigs -ConfigDir $ConfigDir -SkipIntegrityFailures | Where-Object {
        $_ -is [System.Collections.IDictionary] -and $_.ContainsKey('connector_type') -and [string]($_['connector_type']) -eq $ConnectorType
    } | Select-Object -First 1)

    $deviceId = if (-not [string]::IsNullOrWhiteSpace($DefaultDeviceId)) { $DefaultDeviceId } else { "$ConnectorType-device" }
    $createdAt = $now
    if ($existing.Count -gt 0 -and $null -ne $existing[0] -and $existing[0] -is [System.Collections.IDictionary]) {
        if ($existing[0].ContainsKey('device_id') -and -not [string]::IsNullOrWhiteSpace([string]$existing[0]['device_id'])) {
            $deviceId = [string]$existing[0]['device_id']
        }
        if ($existing[0].ContainsKey('created_at') -and -not [string]::IsNullOrWhiteSpace([string]$existing[0]['created_at'])) {
            $createdAt = [string]$existing[0]['created_at']
        }
    }

    $settings = @{}
    foreach ($key in $Values.Keys) { $settings[[string]$key] = [string]$Values[$key] }
    $device = @{
        device_id = $deviceId
        connector_type = $ConnectorType
        label = $Label
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
        [string]$DefaultDeviceId = ''
    )

    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    . $schemaPath
    if (-not $DeviceSchemas.ContainsKey($ConnectorType)) { throw "Device schema '$ConnectorType' was not found in $schemaPath" }
    $schema = $DeviceSchemas[$ConnectorType]
    $profileLabel = if ($schema.ContainsKey('Label') -and -not [string]::IsNullOrWhiteSpace([string]$schema.Label)) { [string]$schema.Label } else { $ConnectorType }
    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $currentValues = Add-DeviceProfileDefaults -Values (Get-DeviceProfileCurrentValues -ConfigDir $configDir -ConnectorType $ConnectorType) -Fields @($schema.Fields)
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
    $formTitle = if (-not [string]::IsNullOrWhiteSpace($Title)) { $Title } else { "{0} guided device profile" -f $profileLabel }
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

    Save-DeviceProfile -ConfigDir $configDir -ConnectorType $ConnectorType -Label $profileLabel -Values $values -SecretFields $secretFields -DefaultDeviceId $DefaultDeviceId
    Show-DeviceProfileSummary -Title ("Saved {0} device profile" -f $profileLabel) -Values $values -Fields @($schema.Fields)

    $testResult = $null
    $testLogPath = $null
    $shouldTest = Read-DeviceProfileGuidedYesNo -Prompt ("Test communication with {0} now?" -f $profileLabel) -Default $true
    if ($null -eq $shouldTest) { return [pscustomobject]@{ Status = 'Saved'; ConfigDir = $configDir; CommunicationTest = $null } }
    if ($shouldTest) {
        Write-Host ''
        Write-Host ("Testing communication with {0}..." -f $profileLabel)
        $testResult = Invoke-DeviceProfileTcpTest -Values $values -Label $profileLabel
        $testLogPath = Write-DeviceProfileJsonLog -ProjectRoot $ProjectRoot -ConnectorType $ConnectorType -Data $testResult
        Write-Host ''
        Write-Host 'Communication test summary'
        Write-Host '--------------------------'
        Write-Host ("Status: {0}" -f $testResult.Status)
        Write-Host ("Message: {0}" -f $testResult.Message)
        if ($testResult.PSObject.Properties.Name -contains 'Host') { Write-Host ("Host: {0}" -f $testResult.Host) }
        if ($testResult.PSObject.Properties.Name -contains 'Port') { Write-Host ("Port: {0}" -f $testResult.Port) }
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
    if ($selected.Guided) {
        return Invoke-GuidedDeviceProfileForm -ProjectRoot $ProjectRoot -ConnectorType $selected.ConnectorType
    }
    return Invoke-DeviceProfileForm -ProjectRoot $ProjectRoot -ConnectorType $selected.ConnectorType
}

function Invoke-DeviceProfileForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConnectorType,
        [string]$Title = '',
        [string]$DefaultDeviceId = '',
        [string[]]$CertificateRuntimeKeys = @(),
        [hashtable]$PlaintextSecretNameFields = @{},
        [string[]]$SecretFields = @(),
        [scriptblock]$CommunicationTest = $null
    )

    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    . $schemaPath
    if (-not $DeviceSchemas.ContainsKey($ConnectorType)) { throw "Device schema '$ConnectorType' was not found in $schemaPath" }

    $schema = $DeviceSchemas[$ConnectorType]
    $formTitle = if (-not [string]::IsNullOrWhiteSpace($Title)) { $Title } else { "{0} device profile" -f [string]$schema.Label }
    $label = if ($schema.ContainsKey('Label') -and -not [string]::IsNullOrWhiteSpace([string]$schema.Label)) { [string]$schema.Label } else { $ConnectorType }
    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $currentValues = Remove-DeviceProfilePlaceholderValues -Values (Get-DeviceProfileCurrentValues -ConfigDir $configDir -ConnectorType $ConnectorType -CertificateRuntimeKeys $CertificateRuntimeKeys -PlaintextSecretNameFields $PlaintextSecretNameFields) -Fields @($schema.Fields)
    $currentValues = Add-DeviceProfileDefaults -Values $currentValues -Fields @($schema.Fields)
    $values = Show-TuiForm -Fields ([hashtable[]]$schema.Fields) -CurrentValues $currentValues -Title $formTitle
    if ($null -eq $values) { return [pscustomobject]@{ Status = 'Canceled' } }
    $values = Remove-DeviceProfilePlaceholderValues -Values $values -Fields @($schema.Fields)
    $values = Add-DeviceProfileDefaults -Values $values -Fields @($schema.Fields)
    Save-DeviceProfile -ConfigDir $configDir -ConnectorType $ConnectorType -Label $label -Values $values -SecretFields $SecretFields -DefaultDeviceId $DefaultDeviceId
    Show-DeviceProfileSummary -Title ("Saved {0} device profile" -f $label) -Values $values -Fields @($schema.Fields)

    $testResult = $null
    $testLogPath = $null
    if ($null -ne $CommunicationTest) {
        $shouldTest = Read-DeviceProfileYesNo -Prompt ("Test communication with {0} now?" -f $label) -Default $true
        if ($shouldTest) {
            Write-Host ''
            Write-Host ("Testing communication with {0}..." -f $label)
            try {
                $testResult = & $CommunicationTest -ProjectRoot $ProjectRoot -ConfigDir $configDir -ConnectorType $ConnectorType -Label $label -Values $values -Schema $schema
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

    Show-TuiStatus -Message ("{0} device profile saved." -f $label) -Type Success -Row ([Math]::Max(0,[Console]::WindowHeight)-2)
    Start-Sleep -Milliseconds 1200
    return [pscustomobject]@{ Status = 'Saved'; ConfigDir = $configDir; CommunicationTest = $testResult; CommunicationTestLog = $testLogPath }
}

Export-ModuleMember -Function Resolve-DeviceProfileConfigDir,Get-DeviceProfileCurrentValues,Add-DeviceProfileDefaults,Remove-DeviceProfilePlaceholderValues,Get-DeviceProfileFieldDefault,Save-DeviceProfile,Invoke-DeviceProfileForm,Invoke-GuidedDeviceProfileForm,Invoke-DeviceProfileWizard,Invoke-DeviceProfileTcpTest,Test-DeviceProfileLikelyPlaintextSecret,Show-DeviceProfileSummary,ConvertTo-DeviceProfileDisplayValue,Write-DeviceProfileJsonLog,Read-DeviceProfileYesNo,Read-DeviceProfileConsoleLine,Read-DeviceProfileGuidedYesNo,Wait-DeviceProfileOperatorKey
