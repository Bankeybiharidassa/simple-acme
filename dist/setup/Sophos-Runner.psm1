Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/../core/Tui-Engine.psm1" -Force -Global
Import-Module "$PSScriptRoot/../core/Config-Store.psm1" -Force -Global
Import-Module "$PSScriptRoot/../core/Env-Loader.psm1" -Force -Global
Import-Module "$PSScriptRoot/Device-Profile-Runner.psm1" -Force -Global
Import-Module "$PSScriptRoot/../core/Crypto.psm1" -Force -Global

$script:SophosModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts/Modules/SimpleAcme.Sophos/SimpleAcme.Sophos.psd1'

function ConvertTo-SophosTuiBoolean {
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

function ConvertTo-SophosSafeValue {
    param([string]$Name, [object]$Value)
    if ($Name -match '(?i)password|secret|private_key|key_path') {
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
        if ($Name -match 'key_path') { return [IO.Path]::GetFileName([string]$Value) }
        return '<redacted>'
    }
    if ($Name -match '(?i)pfx_path|cert_path|chain_path|ssh_private_key_path') {
        if ([string]::IsNullOrWhiteSpace([string]$Value)) { return '' }
        return [IO.Path]::GetFileName([string]$Value)
    }
    $Value
}

function Get-SophosTuiLogRoot {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $configuredRoot = if (-not [string]::IsNullOrWhiteSpace($env:CERTIFICATE_LOG_DIR)) { [string]$env:CERTIFICATE_LOG_DIR } else { Join-Path $ProjectRoot 'logs' }
    $logRoot = [IO.Path]::GetFullPath($configuredRoot)
    if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) { New-Item -ItemType Directory -Path $logRoot -Force | Out-Null }
    $logRoot
}

function Write-SophosTuiJsonLog {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][object]$Data
    )
    $logRoot = Get-SophosTuiLogRoot -ProjectRoot $ProjectRoot
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $path = Join-Path $logRoot ("{0}-{1}.json" -f $Prefix, $stamp)
    $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

function Write-SophosTuiSecureValueFile {
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Plaintext
    )

    $secretDir = Join-Path $ConfigDir 'secrets'
    if (-not (Test-Path -LiteralPath $secretDir -PathType Container)) {
        New-Item -ItemType Directory -Path $secretDir -Force | Out-Null
    }
    $cipher = Protect-DpapiValue -Plaintext $Plaintext -Scope LocalMachine
    $payload = [ordered]@{
        scope = 'LocalMachine'
        ciphertext = $cipher
        created_by = 'certificate-setup sophos tui'
        updated_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
    $path = Join-Path $secretDir ("{0}.json" -f $Name)
    $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
    return [string]$path
}

function Resolve-SophosProfilePassword {
    param(
        [Parameter(Mandatory)][hashtable]$Values
    )

    if ($Values.ContainsKey('password') -and -not [string]::IsNullOrWhiteSpace([string]$Values['password'])) {
        return [string]$Values['password']
    }

    Import-Module $script:SophosModulePath -Force
    if ($Values.ContainsKey('password_secret_name') -and -not [string]::IsNullOrWhiteSpace([string]$Values['password_secret_name'])) {
        return Resolve-SophosPassword -PasswordSecretName ([string]$Values['password_secret_name'])
    }

    if ($Values.ContainsKey('password_secure_file') -and -not [string]::IsNullOrWhiteSpace([string]$Values['password_secure_file'])) {
        $path = [string]$Values['password_secure_file']
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Sophos admin password file was not found: $path" }
        $raw = (Get-Content -LiteralPath $path -Raw).Trim()
        if ($raw.StartsWith('{')) {
            $payload = $raw | ConvertFrom-Json
            if (-not $payload.ciphertext) { throw "Sophos admin password file '$path' does not contain a ciphertext value." }
            return Unprotect-DpapiValue -CiphertextBase64 ([string]$payload.ciphertext)
        }
        $secure = $raw | ConvertTo-SecureString
        return ConvertFrom-SophosSecureString -SecureString $secure
    }

    throw 'Sophos admin password is missing. Enter Admin password, Admin password secret, or Admin password file in the device profile.'
}

function Invoke-SophosProfileCommunicationTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][string]$ConnectorType,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)]$Schema
    )

    $null = $ProjectRoot
    $null = $ConfigDir
    $null = $ConnectorType
    $null = $Label
    $null = $Schema

    Import-Module $script:SophosModulePath -Force
    $firewall = if ($Values.ContainsKey('host')) { [string]$Values['host'] } else { '' }
    $port = if ($Values.ContainsKey('port') -and -not [string]::IsNullOrWhiteSpace([string]$Values['port'])) { [int]$Values['port'] } else { 4444 }
    $username = if ($Values.ContainsKey('username')) { [string]$Values['username'] } else { 'admin' }
    $skipCertificateCheck = ConvertTo-SophosTuiBoolean -Value $(if ($Values.ContainsKey('skip_certificate_check')) { $Values['skip_certificate_check'] } else { $false })
    $endpoint = New-SophosApiEndpoint -Firewall $firewall -Port $port
    $password = Resolve-SophosProfilePassword -Values $Values

    $started = Get-Date
    $usedSkipCertificateCheck = $skipCertificateCheck
    $warning = ''
    try {
        $session = Connect-SophosFirewallApi -Firewall $firewall -Port $port -Username $username -Password $password -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds 120
    } catch {
        $message = [string]$_.Exception.Message
        if (-not $skipCertificateCheck -and $message -match '(?i)trust relationship|certificate|ssl/tls') {
            $warning = 'TLS certificate validation failed; retried with Ignore Sophos TLS warning enabled for this test.'
            $usedSkipCertificateCheck = $true
            try {
                $session = Connect-SophosFirewallApi -Firewall $firewall -Port $port -Username $username -Password $password -SkipCertificateCheck -TimeoutSeconds 120
            } catch {
                $retryMessage = [string]$_.Exception.Message
                if ($retryMessage -match '(?i)timed out|timeout|unexpected error occurred on a receive') {
                    throw "Sophos XML API did not answer the authenticated request at $endpoint. The admin page is reachable, but Sophos API access is commonly disabled by default or restricted to allowed source IP addresses. In Sophos, enable Backup and firmware > API > API configuration and add this operator machine's source IP address."
                }
                throw
            }
        } elseif ($message -match '(?i)timed out|timeout|unexpected error occurred on a receive') {
            throw "Sophos XML API did not answer the authenticated request at $endpoint. The admin page is reachable, but Sophos API access is commonly disabled by default or restricted to allowed source IP addresses. In Sophos, enable Backup and firmware > API > API configuration and add this operator machine's source IP address."
        } else {
            throw
        }
    }
    $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
    [pscustomobject]@{
        Status = 'Succeeded'
        Message = 'Sophos XML API login and AdminSettings read succeeded.'
        Warning = $warning
        Endpoint = $endpoint
        Firewall = $firewall
        Port = $port
        Username = $username
        SkipCertificateCheck = $usedSkipCertificateCheck
        ElapsedMilliseconds = $elapsed
        SessionEndpoint = $session.Endpoint
    }
}

function Connect-SophosProfileForTui {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [int]$TimeoutSeconds = 120
    )

    Import-Module $script:SophosModulePath -Force
    $firewall = if ($Values.ContainsKey('host')) { [string]$Values['host'] } else { '' }
    $port = if ($Values.ContainsKey('port') -and -not [string]::IsNullOrWhiteSpace([string]$Values['port'])) { [int]$Values['port'] } else { 4444 }
    $username = if ($Values.ContainsKey('username') -and -not [string]::IsNullOrWhiteSpace([string]$Values['username'])) { [string]$Values['username'] } else { 'admin' }
    $skipCertificateCheck = ConvertTo-SophosTuiBoolean -Value $(if ($Values.ContainsKey('skip_certificate_check')) { $Values['skip_certificate_check'] } else { $false })
    $password = Resolve-SophosProfilePassword -Values $Values
    $endpoint = New-SophosApiEndpoint -Firewall $firewall -Port $port

    try {
        $session = Connect-SophosFirewallApi -Firewall $firewall -Port $port -Username $username -Password $password -SkipCertificateCheck:$skipCertificateCheck -TimeoutSeconds $TimeoutSeconds
        return [pscustomobject]@{ Session = $session; Endpoint = $endpoint; UsedSkipCertificateCheck = $skipCertificateCheck; Warning = '' }
    } catch {
        $message = [string]$_.Exception.Message
        if (-not $skipCertificateCheck -and $message -match '(?i)trust relationship|certificate|ssl/tls') {
            $session = Connect-SophosFirewallApi -Firewall $firewall -Port $port -Username $username -Password $password -SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
            return [pscustomobject]@{
                Session = $session
                Endpoint = $endpoint
                UsedSkipCertificateCheck = $true
                Warning = 'TLS certificate validation failed; retried with Ignore Sophos TLS warning enabled for this discovery.'
            }
        }
        if ($message -match '(?i)timed out|timeout|unexpected error occurred on a receive') {
            throw "Sophos XML API did not answer the authenticated request at $endpoint. The admin page is reachable, but Sophos API access may be disabled or restricted to allowed source IP addresses. In Sophos, enable Backup and firmware > API > API configuration and add this operator machine's source IP address."
        }
        throw
    }
}

function Get-SophosLiveCertificateTargets {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Values)

    $connection = Connect-SophosProfileForTui -Values $Values -TimeoutSeconds 120
    $adminSettings = Get-SophosAdminWebSettings
    $wafRules = @(Get-SophosWafRules)

    [pscustomobject]@{
        Endpoint = $connection.Endpoint
        Warning = $connection.Warning
        UsedSkipCertificateCheck = $connection.UsedSkipCertificateCheck
        AdminSettings = $adminSettings
        WafRules = @($wafRules)
    }
}

function Format-SophosTargetValue {
    param([object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '<empty>' }
    [string]$Value
}

function ConvertTo-SophosTargetDefaultToken {
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][object]$Discovery
    )

    $tokens = New-Object System.Collections.Generic.List[string]
    if (ConvertTo-SophosTuiBoolean -Value $(if ($Values.ContainsKey('bind_admin_portal')) { $Values['bind_admin_portal'] } else { $false })) { $tokens.Add('1') | Out-Null }
    if (ConvertTo-SophosTuiBoolean -Value $(if ($Values.ContainsKey('bind_vpn_portal')) { $Values['bind_vpn_portal'] } else { $false })) { $tokens.Add('2') | Out-Null }
    if (ConvertTo-SophosTuiBoolean -Value $(if ($Values.ContainsKey('bind_user_portal')) { $Values['bind_user_portal'] } else { $false })) { $tokens.Add('3') | Out-Null }
    if (ConvertTo-SophosTuiBoolean -Value $(if ($Values.ContainsKey('bind_waf')) { $Values['bind_waf'] } else { $false })) {
        $rules = @($Discovery.WafRules)
        $wafNames = if ($Values.ContainsKey('waf_rule_names')) { [string]$Values['waf_rule_names'] } else { '' }
        foreach ($name in @($wafNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            for ($i = 0; $i -lt $rules.Count; $i++) {
                if ([string]$rules[$i].Name -eq $name) {
                    $tokens.Add([string]($i + 4)) | Out-Null
                    break
                }
            }
        }
    }
    ($tokens.ToArray() -join ',')
}

function Read-SophosTargetSelectionInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Discovery,
        [string]$DefaultSelection = ''
    )

    $rules = @($Discovery.WafRules)
    while ($true) {
        $prompt = if ([string]::IsNullOrWhiteSpace($DefaultSelection)) {
            'Select targets'
        } else {
            "Select targets [$DefaultSelection]"
        }
        $inputResult = Read-SophosConsoleLine -Prompt $prompt
        if ($inputResult.Canceled) { return '__CANCEL__' }
        $raw = [string]$inputResult.Value
        if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $DefaultSelection }
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Host 'Select at least one portal or WAF rule.' -ForegroundColor Yellow
            continue
        }

        $bindAdmin = $false
        $bindVpn = $false
        $bindUser = $false
        $selectedRules = New-Object System.Collections.Generic.List[string]
        $invalid = New-Object System.Collections.Generic.List[string]

        foreach ($part in @($raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            if ($part -notmatch '^\d+$') {
                $invalid.Add($part) | Out-Null
                continue
            }

            $index = [int]$part
            switch ($index) {
                1 { $bindAdmin = $true; continue }
                2 { $bindVpn = $true; continue }
                3 { $bindUser = $true; continue }
                default {
                    if ($index -ge 4 -and $index -lt (4 + $rules.Count)) {
                        $rule = $rules[$index - 4]
                        if (-not [string]::IsNullOrWhiteSpace([string]$rule.Name) -and -not $selectedRules.Contains([string]$rule.Name)) {
                            $selectedRules.Add([string]$rule.Name) | Out-Null
                        }
                    } else {
                        $invalid.Add($part) | Out-Null
                    }
                }
            }
        }

        if ($invalid.Count -gt 0) {
            Write-Host ("Invalid target selection: {0}. Use numbers only, separated by commas." -f ($invalid.ToArray() -join ', ')) -ForegroundColor Yellow
            continue
        }
        if (-not ($bindAdmin -or $bindVpn -or $bindUser -or $selectedRules.Count -gt 0)) {
            Write-Host 'Select at least one portal or WAF rule.' -ForegroundColor Yellow
            continue
        }

        return [pscustomobject]@{
            BindAdminPortal = $bindAdmin
            BindVpnPortal = $bindVpn
            BindUserPortal = $bindUser
            WafRuleNames = @($selectedRules.ToArray())
        }
    }
}

function Invoke-SophosCertificateTargetSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][hashtable]$Values
    )

    Write-Host ''
    Write-Host 'Reading Sophos portals and WAF rules from the firewall...'
    $discovery = Get-SophosLiveCertificateTargets -Values $Values

    Write-Host ''
    Write-Host 'Sophos certificate target selection'
    Write-Host '-----------------------------------'
    Write-Host ("Endpoint: {0}" -f $discovery.Endpoint)
    if (-not [string]::IsNullOrWhiteSpace([string]$discovery.Warning)) {
        Write-Host ("Warning: {0}" -f $discovery.Warning) -ForegroundColor Yellow
    }
    Write-Host 'Sophos exposes admin, VPN, and user portal certificate binding through one shared WebAdminSettings certificate field.'
    Write-Host ''

    $settings = $discovery.AdminSettings
    Write-Host ("[1] Admin portal  port={0}  current-cert={1}" -f (Format-SophosTargetValue $settings.HTTPSport), (Format-SophosTargetValue $settings.Certificate))
    Write-Host ("[2] VPN portal    port={0}  current-cert={1}" -f (Format-SophosTargetValue $settings.VPNPortalHTTPSPort), (Format-SophosTargetValue $settings.Certificate))
    Write-Host ("[3] User portal   port={0}  current-cert={1}" -f (Format-SophosTargetValue $settings.UserPortalHTTPSPort), (Format-SophosTargetValue $settings.Certificate))

    $rules = @($discovery.WafRules)
    if ($rules.Count -gt 0) {
        Write-Host ''
        Write-Host 'WAF / web server rules'
        for ($i = 0; $i -lt $rules.Count; $i++) {
            $rule = $rules[$i]
            $number = $i + 4
            $domains = @($rule.Domains) -join ','
            Write-Host ("[{0}] WAF {1}  status={2}  port={3}  domains={4}  current-cert={5}" -f $number, (Format-SophosTargetValue $rule.Name), (Format-SophosTargetValue $rule.Status), (Format-SophosTargetValue $rule.ListenPort), (Format-SophosTargetValue $domains), (Format-SophosTargetValue $rule.HttpsCertificate))
        }
    } else {
        Write-Host ''
        Write-Host 'No Sophos WAF / web server rules were returned by the API.'
    }

    Write-Host ''
    Write-Host 'Enter comma-separated numbers only. Example: 1,2,3 or 1,4'
    $defaultSelection = ConvertTo-SophosTargetDefaultToken -Values $Values -Discovery $discovery
    $selection = Read-SophosTargetSelectionInput -Discovery $discovery -DefaultSelection $defaultSelection
    if ($selection -eq '__CANCEL__') { return $null }

    $Values['bind_admin_portal'] = if ($selection.BindAdminPortal) { 'true' } else { 'false' }
    $Values['bind_vpn_portal'] = if ($selection.BindVpnPortal) { 'true' } else { 'false' }
    $Values['bind_user_portal'] = if ($selection.BindUserPortal) { 'true' } else { 'false' }
    $Values['bind_waf'] = if (@($selection.WafRuleNames).Count -gt 0) { 'true' } else { 'false' }
    $Values['waf_rule_names'] = (@($selection.WafRuleNames) -join ',')

    Write-Host ''
    Write-Host 'Selected Sophos targets'
    Write-Host '-----------------------'
    Write-Host ("Admin portal: {0}" -f $Values['bind_admin_portal'])
    Write-Host ("VPN portal: {0}" -f $Values['bind_vpn_portal'])
    Write-Host ("User portal: {0}" -f $Values['bind_user_portal'])
    Write-Host ("WAF rules: {0}" -f $(if ([string]::IsNullOrWhiteSpace([string]$Values['waf_rule_names'])) { '<none>' } else { [string]$Values['waf_rule_names'] }))

    Write-SophosTuiJsonLog -ProjectRoot $ProjectRoot -Prefix 'sophos-target-selection' -Data ([pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Endpoint = $discovery.Endpoint
        Selected = $selection
        AdminSettings = $discovery.AdminSettings
        WafRules = @($discovery.WafRules | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Status = $_.Status
                PolicyType = $_.PolicyType
                HttpsCertificate = $_.HttpsCertificate
                ListenPort = $_.ListenPort
                HostedAddress = $_.HostedAddress
                Domains = @($_.Domains)
            }
        })
    }) | Out-Null

    $Values
}

function ConvertTo-SophosSingleQuotedArgument {
    param([string]$Value)
    "'{0}'" -f ([string]$Value).Replace("'", "''")
}

function Save-SophosDeploymentSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigDir,
        [Parameter(Mandatory)][hashtable]$Values,
        [string]$DeviceId = 'sophos-firewall'
    )

    $settings = @{}
    foreach ($key in $Values.Keys) { $settings[[string]$key] = [string]$Values[$key] }
    $device = @{
        device_id = $DeviceId
        connector_type = 'sophos'
        label = 'Sophos firewall'
        created_at = (Get-Date).ToUniversalTime().ToString('o')
        updated_at = (Get-Date).ToUniversalTime().ToString('o')
        settings = $settings
    }
    Save-DeviceConfig -Device $device -ConfigDir $ConfigDir -SecretFields @('password') | Out-Null
    return [pscustomobject]@{ Status = 'Saved'; DeviceId = $DeviceId; ConfigDir = $ConfigDir }
}

function Invoke-SophosCertificateRequestSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][hashtable]$Values
    )

    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    . $schemaPath
    if (-not $DeviceSchemas.ContainsKey('sophos')) { throw "Device schema 'sophos' was not found in $schemaPath" }

    $configDir = if ($Values.ContainsKey('CERTIFICATE_CONFIG_DIR') -and -not [string]::IsNullOrWhiteSpace([string]$Values['CERTIFICATE_CONFIG_DIR'])) {
        [IO.Path]::GetFullPath([string]$Values['CERTIFICATE_CONFIG_DIR'])
    } else {
        Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    }
    $Values['CERTIFICATE_CONFIG_DIR'] = $configDir

    $schema = $DeviceSchemas['sophos']
    $deviceId = 'sophos-firewall'
    $profileValues = Add-DeviceProfileDefaults -Values (Get-DeviceProfileCurrentValues -ConfigDir $configDir -ConnectorType 'sophos' -CertificateRuntimeKeys @('pfx_path','pfx_password','cert_path','key_path','chain_path','enable_ssh_export_recovery','ssh_username','ssh_port','ssh_password_secret_name','ssh_private_key_path','ssh_host_key_fingerprint','export_recovery_path') -PlaintextSecretNameFields @{ password_secret_name = 'password' }) -Fields @($schema.Fields)
    if ($profileValues.Count -eq 0 -or -not $profileValues.ContainsKey('host') -or [string]::IsNullOrWhiteSpace([string]$profileValues['host'])) {
        Write-Host ''
        Write-Host 'No Sophos device profile exists yet. Create the firewall connection profile first.' -ForegroundColor Yellow
        $profileResult = Invoke-SophosProfileForm -ProjectRoot $ProjectRoot
        if ($null -eq $profileResult -or [string]$profileResult.Status -ne 'Saved') { return $null }
        if ($profileResult.PSObject.Properties.Name -contains 'DeviceId' -and -not [string]::IsNullOrWhiteSpace([string]$profileResult.DeviceId)) { $deviceId = [string]$profileResult.DeviceId }
        $profileValues = Add-DeviceProfileDefaults -Values (Get-DeviceProfileCurrentValues -ConfigDir $configDir -ConnectorType 'sophos' -CertificateRuntimeKeys @('pfx_path','pfx_password','cert_path','key_path','chain_path','enable_ssh_export_recovery','ssh_username','ssh_port','ssh_password_secret_name','ssh_private_key_path','ssh_host_key_fingerprint','export_recovery_path') -PlaintextSecretNameFields @{ password_secret_name = 'password' }) -Fields @($schema.Fields)
    }

    $domains = if ($Values.ContainsKey('DOMAINS')) { [string]$Values['DOMAINS'] } else { '' }
    $profileValues['certificate_name'] = ConvertTo-SophosCertificateObjectName -Domains $domains -PfxPath ''
    if ($Values.ContainsKey('ACME_PFX_PASSWORD') -and -not [string]::IsNullOrWhiteSpace([string]$Values['ACME_PFX_PASSWORD'])) {
        $profileValues['pfx_password_secure_file'] = Write-SophosTuiSecureValueFile -ConfigDir $configDir -Name 'sophos-pfx-password' -Plaintext ([string]$Values['ACME_PFX_PASSWORD'])
    }

    $profileValues = Invoke-SophosCertificateTargetSelection -ProjectRoot $ProjectRoot -Values $profileValues
    if ($null -eq $profileValues) { return $null }
    Save-SophosDeploymentSelection -ConfigDir $configDir -Values $profileValues -DeviceId $deviceId | Out-Null
    Write-Host 'The WACS scheduled renewal hook will reuse this saved Sophos target selection automatically.'

    $scriptPath = Join-Path $ProjectRoot 'Scripts/deploy-sophos.ps1'
    $Values['ACME_TARGET_SYSTEM'] = 'sophos'
    $Values['TARGET_SYSTEM'] = 'sophos'
    $Values['ACME_TARGET_DEVICE_TYPE'] = 'sophos'
    $Values['ACME_TARGET_DEVICE_LABEL'] = 'Sophos firewall'
    $Values['ACME_TARGET_DEVICE_ID'] = $deviceId
    $Values['ACME_SCRIPT_PATH'] = $scriptPath
    $Values['ACME_SCRIPT_PARAMETERS'] = "-PfxPath '{CacheFile}' -ConfigDir $(ConvertTo-SophosSingleQuotedArgument -Value $configDir) -DeviceId $(ConvertTo-SophosSingleQuotedArgument -Value $deviceId)"
    $Values
}

function Resolve-SophosDefaultPfxPath {
    $defaultDir = 'C:\certs'
    if (-not (Test-Path -LiteralPath $defaultDir -PathType Container)) { return '' }
    $latest = Get-ChildItem -LiteralPath $defaultDir -Filter '*.pfx' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latest) { return '' }
    return [string]$latest.FullName
}

function ConvertTo-SophosCertificateObjectName {
    param(
        [string]$Domains = '',
        [string]$PfxPath = ''
    )

    $source = ''
    if (-not [string]::IsNullOrWhiteSpace($Domains)) {
        $source = @($Domains -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })[0]
    }
    if ([string]::IsNullOrWhiteSpace($source) -and -not [string]::IsNullOrWhiteSpace($PfxPath)) {
        $source = [IO.Path]::GetFileNameWithoutExtension($PfxPath)
    }
    if ([string]::IsNullOrWhiteSpace($source)) { $source = 'simple-acme-certificate' }
    $source = $source.Replace('*.', 'wildcard-').Replace('*', 'wildcard').Replace('_', '-')
    $safe = ($source -replace '[^A-Za-z0-9.-]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'simple-acme-certificate' }
    return $safe
}

function Get-SophosCertificateDeploymentContext {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigDir
    )

    $envValues = @{}
    try {
        $envPath = Resolve-BootstrapEnvPath -ProjectRoot $ProjectRoot
        if (Test-Path -LiteralPath $envPath -PathType Leaf) {
            $envValues = Read-EffectiveEnvFile -Path $envPath -AllowIncomplete
        }
    } catch {
        Write-Verbose "Could not read certificate.env for Sophos deployment defaults: $($_.Exception.Message)"
    }

    $pfxPath = ''
    if ($envValues.ContainsKey('ACME_PFX_FILE_PATH') -and -not [string]::IsNullOrWhiteSpace([string]$envValues['ACME_PFX_FILE_PATH'])) {
        $configuredPfx = [string]$envValues['ACME_PFX_FILE_PATH']
        if (Test-Path -LiteralPath $configuredPfx -PathType Leaf) { $pfxPath = $configuredPfx }
        elseif (Test-Path -LiteralPath $configuredPfx -PathType Container) {
            $latest = Get-ChildItem -LiteralPath $configuredPfx -Filter '*.pfx' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($null -ne $latest) { $pfxPath = [string]$latest.FullName }
        }
    }
    if ([string]::IsNullOrWhiteSpace($pfxPath)) { $pfxPath = Resolve-SophosDefaultPfxPath }

    $domains = if ($envValues.ContainsKey('DOMAINS')) { [string]$envValues['DOMAINS'] } else { '' }
    $pfxPassword = if ($envValues.ContainsKey('ACME_PFX_PASSWORD')) { [string]$envValues['ACME_PFX_PASSWORD'] } else { '' }

    return @{
        pfx_path = $pfxPath
        certificate_name = ConvertTo-SophosCertificateObjectName -Domains $domains -PfxPath $pfxPath
        pfx_password = $pfxPassword
    }
}

function Convert-SophosFormValuesToArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$FormValues,
        [string]$ConfigDir = ''
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    $required = @('host','username')
    foreach ($key in $required) {
        if (-not $FormValues.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$FormValues[$key])) {
            throw "Required Sophos field '$key' is missing."
        }
    }
    $password = if ($FormValues.ContainsKey('password')) { [string]$FormValues['password'] } else { '' }
    $passwordSecretName = if ($FormValues.ContainsKey('password_secret_name')) { [string]$FormValues['password_secret_name'] } else { '' }
    $passwordSecureFile = if ($FormValues.ContainsKey('password_secure_file')) { [string]$FormValues['password_secure_file'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($password) -and [string]::IsNullOrWhiteSpace($passwordSecretName) -and [string]::IsNullOrWhiteSpace($passwordSecureFile)) {
        throw "Sophos admin password is missing. Open Sophos Firewall - Create or edit device profile and enter the firewall admin password."
    }
    if (-not [string]::IsNullOrWhiteSpace($password) -and [string]::IsNullOrWhiteSpace($ConfigDir)) {
        throw "Sophos API password needs a config directory so it can be passed as an encrypted DPAPI secure file."
    }

    $pfxPath = if ($FormValues.ContainsKey('pfx_path')) { [string]$FormValues['pfx_path'] } else { '' }
    $certPath = if ($FormValues.ContainsKey('cert_path')) { [string]$FormValues['cert_path'] } else { '' }
    $keyPath = if ($FormValues.ContainsKey('key_path')) { [string]$FormValues['key_path'] } else { '' }
    $pfxPassword = if ($FormValues.ContainsKey('pfx_password')) { [string]$FormValues['pfx_password'] } else { '' }
    $pfxPasswordSecureFile = if ($FormValues.ContainsKey('pfx_password_secure_file')) { [string]$FormValues['pfx_password_secure_file'] } else { '' }
    $hasPfx = -not [string]::IsNullOrWhiteSpace($pfxPath)
    $hasPemPair = (-not [string]::IsNullOrWhiteSpace($certPath)) -or (-not [string]::IsNullOrWhiteSpace($keyPath))

    if ($hasPfx -and $hasPemPair) {
        throw "Provide either 'pfx_path' or the PEM 'cert_path'/'key_path' pair, not both."
    }
    if (-not $hasPfx -and ([string]::IsNullOrWhiteSpace($certPath) -or [string]::IsNullOrWhiteSpace($keyPath))) {
        throw "No issued certificate file was found for Sophos deployment. Request the certificate first, or make sure the PFX exists under the configured PFX folder or C:\certs."
    }
    if ($hasPfx -and -not [string]::IsNullOrWhiteSpace($pfxPassword) -and [string]::IsNullOrWhiteSpace($ConfigDir)) {
        throw "Sophos PFX password needs a config directory so it can be passed as an encrypted DPAPI secure file."
    }

    $bindAdminPortal = ConvertTo-SophosTuiBoolean -Value $(if ($FormValues.ContainsKey('bind_admin_portal')) { $FormValues['bind_admin_portal'] } else { $false })
    $bindVpnPortal = ConvertTo-SophosTuiBoolean -Value $(if ($FormValues.ContainsKey('bind_vpn_portal')) { $FormValues['bind_vpn_portal'] } else { $false })
    $bindUserPortal = ConvertTo-SophosTuiBoolean -Value $(if ($FormValues.ContainsKey('bind_user_portal')) { $FormValues['bind_user_portal'] } else { $false })
    $bindWaf = ConvertTo-SophosTuiBoolean -Value $(if ($FormValues.ContainsKey('bind_waf')) { $FormValues['bind_waf'] } else { $false })
    $wafRuleNames = if ($FormValues.ContainsKey('waf_rule_names')) { [string]$FormValues['waf_rule_names'] } else { '' }
    if (-not ($bindAdminPortal -or $bindVpnPortal -or $bindUserPortal -or $bindWaf)) {
        throw "Select at least one Sophos certificate target: admin portal, VPN portal, user portal, or WAF."
    }
    if ($bindWaf -and [string]::IsNullOrWhiteSpace($wafRuleNames)) {
        throw "Sophos WAF binding requires 'waf_rule_names'."
    }

    $enableSshRecovery = ConvertTo-SophosTuiBoolean -Value $(if ($FormValues.ContainsKey('enable_ssh_export_recovery')) { $FormValues['enable_ssh_export_recovery'] } else { $false })
    if ($enableSshRecovery) {
        $sshHostKey = if ($FormValues.ContainsKey('ssh_host_key_fingerprint')) { [string]$FormValues['ssh_host_key_fingerprint'] } else { '' }
        $exportPath = if ($FormValues.ContainsKey('export_recovery_path')) { [string]$FormValues['export_recovery_path'] } else { '' }
        $sshPasswordSecret = if ($FormValues.ContainsKey('ssh_password_secret_name')) { [string]$FormValues['ssh_password_secret_name'] } else { '' }
        $sshPrivateKey = if ($FormValues.ContainsKey('ssh_private_key_path')) { [string]$FormValues['ssh_private_key_path'] } else { '' }
        if ([string]::IsNullOrWhiteSpace($sshHostKey)) { throw "Sophos SSH export recovery requires 'ssh_host_key_fingerprint'." }
        if ([string]::IsNullOrWhiteSpace($exportPath)) { throw "Sophos SSH export recovery requires 'export_recovery_path'." }
        if ([string]::IsNullOrWhiteSpace($sshPasswordSecret) -and [string]::IsNullOrWhiteSpace($sshPrivateKey)) {
            throw "Sophos SSH export recovery requires 'ssh_password_secret_name' or 'ssh_private_key_path'."
        }
    }

    $map = [ordered]@{
        host = '-Firewall'
        port = '-Port'
        username = '-Username'
        certificate_name = '-CertificateName'
        pfx_path = '-PfxPath'
        pfx_password_secret_name = '-PfxPasswordSecretName'
        cert_path = '-CertPath'
        key_path = '-KeyPath'
        chain_path = '-ChainPath'
        ssh_username = '-SshUsername'
        ssh_port = '-SshPort'
        ssh_password_secret_name = '-SshPasswordSecretName'
        ssh_private_key_path = '-SshPrivateKeyPath'
        ssh_host_key_fingerprint = '-SshHostKeyFingerprint'
        export_recovery_path = '-ExportRecoveryPath'
    }

    foreach ($key in $map.Keys) {
        if ($FormValues.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$FormValues[$key])) {
            $arguments.Add($map[$key]) | Out-Null
            $arguments.Add([string]$FormValues[$key]) | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($password)) {
        $arguments.Add('-PasswordSecureFile') | Out-Null
        $arguments.Add((Write-SophosTuiSecureValueFile -ConfigDir $ConfigDir -Name 'sophos-api-password' -Plaintext $password)) | Out-Null
    } elseif (-not [string]::IsNullOrWhiteSpace($passwordSecureFile)) {
        $arguments.Add('-PasswordSecureFile') | Out-Null
        $arguments.Add($passwordSecureFile) | Out-Null
    } else {
        $arguments.Add('-PasswordSecretName') | Out-Null
        $arguments.Add($passwordSecretName) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($pfxPassword)) {
        $arguments.Add('-PfxPasswordSecureFile') | Out-Null
        $arguments.Add((Write-SophosTuiSecureValueFile -ConfigDir $ConfigDir -Name 'sophos-pfx-password' -Plaintext $pfxPassword)) | Out-Null
    } elseif (-not [string]::IsNullOrWhiteSpace($pfxPasswordSecureFile)) {
        $arguments.Add('-PfxPasswordSecureFile') | Out-Null
        $arguments.Add($pfxPasswordSecureFile) | Out-Null
    }

    if ($bindAdminPortal) { $arguments.Add('-BindAdminPortal') | Out-Null }
    if ($bindVpnPortal) { $arguments.Add('-BindVpnPortal') | Out-Null }
    if ($bindUserPortal) { $arguments.Add('-BindUserPortal') | Out-Null }
    if (ConvertTo-SophosTuiBoolean -Value $(if ($FormValues.ContainsKey('skip_certificate_check')) { $FormValues['skip_certificate_check'] } else { $false })) { $arguments.Add('-SkipCertificateCheck') | Out-Null }
    if ($enableSshRecovery) { $arguments.Add('-EnableSshExportRecovery') | Out-Null }

    if ($bindWaf -and $FormValues.ContainsKey('waf_rule_names') -and -not [string]::IsNullOrWhiteSpace([string]$FormValues['waf_rule_names'])) {
        $arguments.Add('-WafRuleNames') | Out-Null
        $arguments.Add([string]$FormValues['waf_rule_names']) | Out-Null
    }

    @($arguments)
}

function Invoke-SophosConnectorScript {
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

function Read-SophosGuidedText {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [switch]$Required
    )

    while ($true) {
        $suffix = if ([string]::IsNullOrWhiteSpace($Default)) { '' } else { " [$Default]" }
        $inputResult = Read-SophosConsoleLine -Prompt "$Prompt$suffix"
        if ($inputResult.Canceled) { return '__CANCEL__' }
        $value = [string]$inputResult.Value
        if ($value -match '^[Qq]$') { return '__CANCEL__' }
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        $value = $value.Trim()
        if (-not $Required -or -not [string]::IsNullOrWhiteSpace($value)) { return $value }
        Write-Host 'This value is required.' -ForegroundColor Yellow
    }
}

function Read-SophosGuidedYesNo {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $false
    )

    $suffix = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $inputResult = Read-SophosConsoleLine -Prompt ("{0} ({1})" -f $Prompt, $suffix)
        if ($inputResult.Canceled) { return $null }
        $answer = [string]$inputResult.Value
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch ($answer.Trim().ToLowerInvariant()) {
            { $_ -in @('y','yes','j','ja') } { return $true }
            { $_ -in @('n','no','nee') } { return $false }
            { $_ -eq 'q' } { return $false }
            default { Write-Host 'Please answer y or n.' -ForegroundColor Yellow }
        }
    }
}

function Read-SophosGuidedPassword {
    param(
        [bool]$HasExistingPassword = $false
    )

    while ($true) {
        $prompt = if ($HasExistingPassword) { 'Admin password (press Enter to keep saved password)' } else { 'Admin password' }
        $inputResult = Read-SophosConsoleLine -Prompt $prompt -MaskInput
        if ($inputResult.Canceled) { return '__CANCEL__' }
        $plain = [string]$inputResult.Value
        if ($HasExistingPassword -and [string]::IsNullOrEmpty($plain)) { return $null }
        if (-not [string]::IsNullOrEmpty($plain)) { return $plain }
        Write-Host 'Admin password is required for the Sophos API.' -ForegroundColor Yellow
    }
}

function Read-SophosConsoleLine {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$MaskInput
    )

    [Console]::Write("${Prompt}: ")
    $buffer = New-Object System.Text.StringBuilder
    while ($true) {
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            ([ConsoleKey]::Enter) {
                [Console]::WriteLine()
                return [pscustomobject]@{ Canceled = $false; Value = $buffer.ToString() }
            }
            ([ConsoleKey]::Escape) {
                [Console]::WriteLine()
                return [pscustomobject]@{ Canceled = $true; Value = '' }
            }
            ([ConsoleKey]::Backspace) {
                if ($buffer.Length -gt 0) {
                    $buffer.Length = $buffer.Length - 1
                    [Console]::Write("`b `b")
                }
            }
            default {
                if (-not [char]::IsControl($key.KeyChar)) {
                    [void]$buffer.Append($key.KeyChar)
                    if ($MaskInput) { [Console]::Write('*') } else { [Console]::Write($key.KeyChar) }
                }
            }
        }
    }
}

function Wait-SophosGuidedOperator {
    param([string]$Message = 'Press any key to continue.')

    Write-Host ''
    Write-Host $Message
    [Console]::ReadKey($true) | Out-Null
}

function Get-SophosGuidedProfileFields {
    @(
        @{ Name='host'; Label='Firewall address'; Type='string'; Required=$true },
        @{ Name='port'; Label='Admin/API port'; Type='string'; Required=$true },
        @{ Name='username'; Label='Admin username'; Type='string'; Required=$true },
        @{ Name='password'; Label='Admin password'; Type='secret'; Required=$false },
        @{ Name='skip_certificate_check'; Label='Ignore Sophos TLS warning'; Type='choice'; Required=$true }
    )
}

function Invoke-SophosProfileForm {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $currentValues = Get-DeviceProfileCurrentValues -ConfigDir $configDir -ConnectorType 'sophos' -PlaintextSecretNameFields @{ password_secret_name = 'password' }
    $values = @{}
    foreach ($key in $currentValues.Keys) { $values[[string]$key] = [string]$currentValues[$key] }

    Write-Host ''
    Write-Host 'Sophos XGS connection profile'
    Write-Host '-----------------------------'
    Write-Host 'This stores how simple-acme talks to the firewall. Certificate portals and WAF rules are selected later after the API is tested.'
    Write-Host 'Type Q at a text prompt to cancel.'
    Write-Host ''

    $hostDefault = if ($values.ContainsKey('host')) { [string]$values['host'] } else { '' }
    $hostValue = Read-SophosGuidedText -Prompt 'Firewall address or DNS name' -Default $hostDefault -Required
    if ($hostValue -eq '__CANCEL__') { return [pscustomobject]@{ Status = 'Canceled' } }
    $values['host'] = $hostValue

    $portDefault = if ($values.ContainsKey('port') -and -not [string]::IsNullOrWhiteSpace([string]$values['port'])) { [string]$values['port'] } else { '4444' }
    while ($true) {
        $portValue = Read-SophosGuidedText -Prompt 'Admin/API HTTPS port' -Default $portDefault -Required
        if ($portValue -eq '__CANCEL__') { return [pscustomobject]@{ Status = 'Canceled' } }
        $parsedPort = 0
        if ([int]::TryParse($portValue, [ref]$parsedPort) -and $parsedPort -ge 1 -and $parsedPort -le 65535) {
            $values['port'] = [string]$parsedPort
            break
        }
        Write-Host 'Enter a TCP port between 1 and 65535. Sophos default is 4444.' -ForegroundColor Yellow
    }

    $userDefault = if ($values.ContainsKey('username') -and -not [string]::IsNullOrWhiteSpace([string]$values['username'])) { [string]$values['username'] } else { 'admin' }
    $usernameValue = Read-SophosGuidedText -Prompt 'Admin username' -Default $userDefault -Required
    if ($usernameValue -eq '__CANCEL__') { return [pscustomobject]@{ Status = 'Canceled' } }
    $values['username'] = $usernameValue

    $hasExistingPassword = $values.ContainsKey('password') -and -not [string]::IsNullOrWhiteSpace([string]$values['password'])
    $passwordValue = Read-SophosGuidedPassword -HasExistingPassword:$hasExistingPassword
    if ($passwordValue -eq '__CANCEL__') { return [pscustomobject]@{ Status = 'Canceled' } }
    if ($null -ne $passwordValue) {
        $values['password'] = $passwordValue
        $values['password_secret_name'] = ''
        $values['password_secure_file'] = ''
    }

    $skipDefault = ConvertTo-SophosTuiBoolean -Value $(if ($values.ContainsKey('skip_certificate_check')) { $values['skip_certificate_check'] } else { $false })
    $skipValue = Read-SophosGuidedYesNo -Prompt 'Ignore Sophos TLS warning for API calls? Use yes only for self-signed/untrusted admin certificates.' -Default $skipDefault
    if ($null -eq $skipValue) { return [pscustomobject]@{ Status = 'Canceled' } }
    $values['skip_certificate_check'] = if ($skipValue) { 'true' } else { 'false' }

    $saveResult = Save-DeviceProfile -ConfigDir $configDir -ConnectorType 'sophos' -Label 'Sophos firewall' -Values $values -SecretFields @('password') -DefaultDeviceId 'sophos-firewall'

    Show-DeviceProfileSummary -Title 'Saved Sophos connection profile' -Values $values -Fields (Get-SophosGuidedProfileFields)

    $testResult = $null
    $testLogPath = $null
    $shouldTestCommunication = Read-SophosGuidedYesNo -Prompt 'Test Sophos API communication now?' -Default $true
    if ($null -eq $shouldTestCommunication) { return [pscustomobject]@{ Status = 'Canceled' } }
    if ($shouldTestCommunication) {
        Write-Host ''
        Write-Host 'Testing Sophos API communication...'
        try {
            $testResult = Invoke-SophosProfileCommunicationTest -ProjectRoot $ProjectRoot -ConfigDir $configDir -ConnectorType 'sophos' -Label 'Sophos firewall' -Values $values -Schema @{ Label='Sophos firewall' }
        } catch {
            $testResult = [pscustomobject]@{
                Status = 'Failed'
                Message = $_.Exception.Message
                ErrorType = $_.Exception.GetType().FullName
            }
        }
        $testLogPath = Write-DeviceProfileJsonLog -ProjectRoot $ProjectRoot -ConnectorType 'sophos' -Data $testResult
        Write-Host ''
        Write-Host 'Communication test summary'
        Write-Host '--------------------------'
        $statusText = [string]$testResult.Status
        if ($statusText -eq 'Succeeded') {
            Write-Host ("Status: {0}" -f $statusText) -ForegroundColor Green
        } else {
            Write-Host ("Status: {0}" -f $statusText) -ForegroundColor Red
        }
        if ($testResult.PSObject.Properties.Name -contains 'Message') { Write-Host ("Message: {0}" -f $testResult.Message) }
        if ($testResult.PSObject.Properties.Name -contains 'Warning' -and -not [string]::IsNullOrWhiteSpace([string]$testResult.Warning)) { Write-Host ("Warning: {0}" -f $testResult.Warning) -ForegroundColor Yellow }
        if ($testResult.PSObject.Properties.Name -contains 'Endpoint') { Write-Host ("Endpoint: {0}" -f $testResult.Endpoint) }
        Write-Host ("Log: {0}" -f $testLogPath)
        Wait-SophosGuidedOperator -Message 'Press any key to continue.'
    } else {
        Write-Host ''
        Write-Host 'Communication test skipped by operator.'
        Wait-SophosGuidedOperator -Message 'Press any key to continue.'
    }

    return [pscustomobject]@{ Status = 'Saved'; ConfigDir = $configDir; DeviceId = [string]$saveResult.DeviceId; CommunicationTest = $testResult; CommunicationTestLog = $testLogPath }
}

function Invoke-SophosDeploymentForm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [switch]$WhatIfMode
    )

    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    . $schemaPath
    if (-not $DeviceSchemas.ContainsKey('sophos')) { throw "Device schema 'sophos' was not found in $schemaPath" }

    $schema = $DeviceSchemas['sophos']
    $configDir = Resolve-DeviceProfileConfigDir -ProjectRoot $ProjectRoot
    $values = Add-DeviceProfileDefaults -Values (Get-DeviceProfileCurrentValues -ConfigDir $configDir -ConnectorType 'sophos' -CertificateRuntimeKeys @('certificate_name','pfx_path','pfx_password','pfx_password_secret_name','pfx_password_secure_file','cert_path','key_path','chain_path','enable_ssh_export_recovery','ssh_username','ssh_port','ssh_password_secret_name','ssh_private_key_path','ssh_host_key_fingerprint','export_recovery_path') -PlaintextSecretNameFields @{ password_secret_name = 'password' }) -Fields @($schema.Fields)
    if ($values.Count -eq 0 -or -not $values.ContainsKey('host') -or [string]::IsNullOrWhiteSpace([string]$values['host'])) {
        Write-Host 'No Sophos device profile exists yet. Create the profile first.' -ForegroundColor Yellow
        $profileResult = Invoke-SophosProfileForm -ProjectRoot $ProjectRoot
        if ($null -eq $profileResult -or [string]$profileResult.Status -ne 'Saved') { return [pscustomobject]@{ Status = 'Canceled'; LogPath = $null } }
        $values = Add-DeviceProfileDefaults -Values (Get-DeviceProfileCurrentValues -ConfigDir $configDir -ConnectorType 'sophos' -CertificateRuntimeKeys @('certificate_name','pfx_path','pfx_password','pfx_password_secret_name','pfx_password_secure_file','cert_path','key_path','chain_path','enable_ssh_export_recovery','ssh_username','ssh_port','ssh_password_secret_name','ssh_private_key_path','ssh_host_key_fingerprint','export_recovery_path') -PlaintextSecretNameFields @{ password_secret_name = 'password' }) -Fields @($schema.Fields)
    }
    $certificateContext = Get-SophosCertificateDeploymentContext -ProjectRoot $ProjectRoot -ConfigDir $configDir
    foreach ($key in $certificateContext.Keys) {
        if (-not [string]::IsNullOrWhiteSpace([string]$certificateContext[$key])) { $values[[string]$key] = [string]$certificateContext[$key] }
    }
    $values = Invoke-SophosCertificateTargetSelection -ProjectRoot $ProjectRoot -Values $values
    if ($null -eq $values) { return [pscustomobject]@{ Status = 'Canceled'; LogPath = $null } }
    Save-SophosDeploymentSelection -ConfigDir $configDir -Values $values

    $scriptPath = Join-Path $ProjectRoot 'Scripts/deploy-sophos.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Sophos deployment script not found: $scriptPath" }

    $safeValues = [ordered]@{}
    foreach ($key in $values.Keys) { $safeValues[$key] = ConvertTo-SophosSafeValue -Name ([string]$key) -Value $values[$key] }

    $status = 'PreviewFailed'
    $message = ''
    $previewResult = $null
    $deploymentResult = $null
    $arguments = @()
    $jsonPath = $null
    $textPath = $null
    try {
        $arguments = @(Convert-SophosFormValuesToArguments -FormValues $values -ConfigDir $configDir)
        Write-Host 'Running Sophos WhatIf preview first. No firewall mutations should occur during this step.'
        $previewResult = Invoke-SophosConnectorScript -ScriptPath $scriptPath -Arguments $arguments -WhatIfMode
        if ($WhatIfMode) {
            $status = 'PreviewCompleted'
            $message = 'WhatIf preview completed. Real deployment was not requested.'
        } else {
            Write-Host ''
            Write-Host 'WhatIf preview completed. Type DEPLOY to execute the real Sophos deployment, or press Esc to cancel.'
            $confirmationResult = Read-SophosConsoleLine -Prompt 'Confirmation'
            if ($confirmationResult.Canceled -or [string]$confirmationResult.Value -cne 'DEPLOY') {
                $status = 'CanceledAfterPreview'
                $message = 'Operator did not type DEPLOY after preview. Real deployment was not executed.'
            } else {
                $deploymentResult = Invoke-SophosConnectorScript -ScriptPath $scriptPath -Arguments $arguments
                $status = 'DeploymentCompleted'
                $message = 'Real Sophos deployment completed after explicit confirmation.'
            }
        }
    } catch {
        $message = $_.Exception.Message
        Write-Host "Sophos deployment validation/execution failed: $message" -ForegroundColor Red
        throw
    } finally {
        $record = [pscustomobject]@{
            TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            Status = $status
            Message = $message
            ScriptPath = $scriptPath
            SafeFormValues = $safeValues
            ArgumentNames = @($arguments | Where-Object { $_ -like '-*' })
            PreviewResult = $previewResult
            DeploymentResult = $deploymentResult
        }
        $jsonPath = Write-SophosTuiJsonLog -ProjectRoot $ProjectRoot -Prefix 'sophos-tui-deploy' -Data $record
        $textPath = [IO.Path]::ChangeExtension($jsonPath, '.log')
        @(
            "TimestampUtc=$($record.TimestampUtc)"
            "Status=$status"
            "Message=$message"
            "ScriptPath=$scriptPath"
            "Host=$($record.SafeFormValues.host)"
            "Username=$($record.SafeFormValues.username)"
            "CertificateName=$($record.SafeFormValues.certificate_name)"
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

function Test-SophosTuiWiring {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $menuPath = Join-Path $ProjectRoot 'setup/Menu-Tree.ps1'
    $schemaPath = Join-Path $ProjectRoot 'setup/Device-Schemas.ps1'
    $setupPath = Join-Path $ProjectRoot 'certificate-setup.ps1'
    $runnerPath = Join-Path $ProjectRoot 'setup/Sophos-Runner.psm1'
    $scriptPath = Join-Path $ProjectRoot 'Scripts/deploy-sophos.ps1'
    $manifestPath = Join-Path $ProjectRoot 'Scripts/Modules/SimpleAcme.Sophos/SimpleAcme.Sophos.psd1'
    $releasePath = Join-Path $ProjectRoot 'build/release-file-list.txt'
    . $schemaPath

    $schemaFields = if ($DeviceSchemas.ContainsKey('sophos')) { @($DeviceSchemas['sophos'].Fields | ForEach-Object { [string]$_.Name }) } else { @() }
    $menuText = if (Test-Path -LiteralPath $menuPath) { Get-Content -LiteralPath $menuPath -Raw } else { '' }
    $setupText = if (Test-Path -LiteralPath $setupPath) { Get-Content -LiteralPath $setupPath -Raw } else { '' }
    $releaseText = if (Test-Path -LiteralPath $releasePath) { Get-Content -LiteralPath $releasePath -Raw } else { '' }
    $requiredFields = @('host','port','username','password','skip_certificate_check')

    [pscustomobject]@{
        ScriptExists = Test-Path -LiteralPath $scriptPath -PathType Leaf
        ModuleManifestExists = Test-Path -LiteralPath $manifestPath -PathType Leaf
        RunnerExists = Test-Path -LiteralPath $runnerPath -PathType Leaf
        SchemaPresent = $DeviceSchemas.ContainsKey('sophos')
        MissingSchemaFields = @($requiredFields | Where-Object { $_ -notin $schemaFields })
        MenuKeysPresent = @('sophos-profile','sophos-deploy','sophos-whatif','sophos-diagnostics','sophos-export-recovery') | ForEach-Object { [pscustomobject]@{ Key = $_; Present = ($menuText -match [regex]::Escape($_)) } }
        SetupDispatchPresent = @('sophos-profile','sophos-deploy','sophos-whatif','sophos-diagnostics','sophos-export-recovery') | ForEach-Object { [pscustomobject]@{ Key = $_; Present = ($setupText -match [regex]::Escape($_)) } }
        ReleaseManifestIncludesRuntime = ($releaseText -match 'setup/Device-Profile-Runner\.psm1' -and $releaseText -match 'setup/Sophos-Runner\.psm1' -and $releaseText -match 'scripts/modules/SimpleAcme\.Sophos/SimpleAcme\.Sophos\.psd1')
    }
}

function Invoke-SophosDiagnostics {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check { param([string]$Name,[bool]$Passed,[string]$Detail = '') $checks.Add([pscustomobject]@{ Name=$Name; Passed=$Passed; Detail=$Detail }) | Out-Null }

    $wiring = Test-SophosTuiWiring -ProjectRoot $ProjectRoot
    Add-Check -Name 'Sophos script exists' -Passed ([bool]$wiring.ScriptExists)
    Add-Check -Name 'Sophos module manifest exists' -Passed ([bool]$wiring.ModuleManifestExists)
    Add-Check -Name 'Sophos runner exists' -Passed ([bool]$wiring.RunnerExists)
    Add-Check -Name 'Sophos schema present' -Passed ([bool]$wiring.SchemaPresent)
    Add-Check -Name 'Sophos schema has required fields' -Passed (@($wiring.MissingSchemaFields).Count -eq 0) -Detail (@($wiring.MissingSchemaFields) -join ',')
    foreach ($menu in @($wiring.MenuKeysPresent)) { Add-Check -Name "Menu key present: $($menu.Key)" -Passed ([bool]$menu.Present) }
    foreach ($dispatch in @($wiring.SetupDispatchPresent)) { Add-Check -Name "Setup dispatch present: $($dispatch.Key)" -Passed ([bool]$dispatch.Present) }
    Add-Check -Name 'Release manifest includes Sophos runtime files' -Passed ([bool]$wiring.ReleaseManifestIncludesRuntime)

    $manifestPath = Join-Path $ProjectRoot 'Scripts/Modules/SimpleAcme.Sophos/SimpleAcme.Sophos.psd1'
    try {
        $module = Import-Module $manifestPath -Force -PassThru
        Add-Check -Name 'Sophos module imports' -Passed ($null -ne $module)
    } catch {
        Add-Check -Name 'Sophos module imports' -Passed $false -Detail $_.Exception.Message
    }

    $checkArray = @($checks.ToArray())
    $result = [pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Checks = $checkArray
        Passed = (@($checkArray | Where-Object { -not $_.Passed }).Count -eq 0)
    }
    $logPath = Write-SophosTuiJsonLog -ProjectRoot $ProjectRoot -Prefix 'sophos-tui-diagnostic' -Data $result
    $result | Add-Member -NotePropertyName LogPath -NotePropertyValue $logPath -Force

    Write-Host 'Sophos TUI diagnostic summary:'
    foreach ($check in $checkArray) {
        $prefix = '[FAIL]'
        if ($check.Passed) { $prefix = '[PASS]' }
        Write-Host ("{0} {1} {2}" -f $prefix, $check.Name, $check.Detail)
    }
    Write-Host "Diagnostic JSON: $logPath"
    $result
}

function Invoke-SophosCertificateExportRecovery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    Write-Host 'Sophos SSH export recovery is diagnostics-only.'
    Write-Host 'Advanced Shell may affect vendor support and certificate exports contain private keys.'
    Invoke-SophosDeploymentForm -ProjectRoot $ProjectRoot -WhatIfMode
}

Export-ModuleMember -Function Invoke-SophosProfileForm,Invoke-SophosDeploymentForm,Invoke-SophosDiagnostics,Invoke-SophosCertificateExportRecovery,Invoke-SophosCertificateRequestSetup,Convert-SophosFormValuesToArguments,Test-SophosTuiWiring
