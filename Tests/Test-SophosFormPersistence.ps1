Set-StrictMode -Version Latest

function Invoke-TestSophosFormPersistence {
    param([scriptblock]$Assert)

    & $Assert 'Device profile runner loads and saves persisted current values for any connector' {
        $path = Join-Path $PSScriptRoot '..\setup\Device-Profile-Runner.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        foreach ($text in @(
            'function Resolve-DeviceProfileConfigDir',
            'function Get-DeviceProfileCurrentValues',
            'function Save-DeviceProfile',
            'function Add-DeviceProfileDefaults',
            'function Invoke-DeviceProfileForm',
            '[Parameter(Mandatory)][string]$ConnectorType',
            '[string[]]$CertificateRuntimeKeys = @()',
            '[hashtable]$PlaintextSecretNameFields = @{}',
            '[scriptblock]$CommunicationTest = $null',
            'Show-TuiForm -Fields ([hashtable[]]$schema.Fields) -CurrentValues $currentValues',
            'Save-DeviceProfile -ConfigDir $configDir -ConnectorType $ConnectorType',
            'Test communication with {0} now?',
            'Communication test summary',
            'Show-DeviceProfileSummary'
        )) {
            if ($raw -notmatch [regex]::Escape($text)) {
                throw "Missing generic device profile wiring: $text"
            }
        }
    }

    & $Assert 'Sophos profile form uses the generic device profile runner' {
        $path = Join-Path $PSScriptRoot '..\setup\Sophos-Runner.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        foreach ($text in @(
            'Import-Module "$PSScriptRoot/Device-Profile-Runner.psm1"',
            'function Invoke-SophosProfileForm',
            'Invoke-DeviceProfileForm `',
            "-ConnectorType 'sophos'",
            "-DefaultDeviceId 'sophos-firewall'",
            "-SecretFields @('password')",
            '-CommunicationTest ${function:Invoke-SophosProfileCommunicationTest}',
            'function Invoke-SophosProfileCommunicationTest',
            'Connect-SophosFirewallApi',
            '-TimeoutSeconds 120',
            'Backup and firmware > API > API configuration',
            'function Get-SophosCertificateDeploymentContext'
        )) {
            if ($raw -notmatch [regex]::Escape($text)) {
                throw "Missing Sophos generic profile runner wiring: $text"
            }
        }
    }

    & $Assert 'Sophos admin password can be entered directly and is stored encrypted' {
        $runnerPath = Join-Path $PSScriptRoot '..\setup\Sophos-Runner.psm1'
        $schemaPath = Join-Path $PSScriptRoot '..\setup\Device-Schemas.ps1'
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $schema = Get-Content -LiteralPath $schemaPath -Raw
        foreach ($text in @(
            "Name='password'; Label='Admin password'; Type='secret'",
            "Name='password_secure_file'; Label='Admin password file'"
        )) {
            if ($schema -notmatch [regex]::Escape($text)) {
                throw "Missing Sophos password schema wiring: $text"
            }
        }
        foreach ($text in @(
            'function Write-SophosTuiSecureValueFile',
            'function Resolve-SophosDefaultPfxPath',
            "-SecretFields @('password')",
            'Sophos admin password is missing.',
            '-PasswordSecureFile'
        )) {
            if ($runner -notmatch [regex]::Escape($text)) {
                throw "Missing Sophos direct password wiring: $text"
            }
        }
    }

    & $Assert 'Sophos validation failures are written to deploy log' {
        $path = Join-Path $PSScriptRoot '..\setup\Sophos-Runner.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        foreach ($text in @(
            '$arguments = @()',
            "Sophos deployment validation/execution failed: `$message",
            "Write-SophosTuiJsonLog -ProjectRoot `$ProjectRoot -Prefix 'sophos-tui-deploy'"
        )) {
            if ($raw -notmatch [regex]::Escape($text)) {
                throw "Missing Sophos failure logging wiring: $text"
            }
        }
    }

    & $Assert 'config store JSON conversion is safe for single-property objects under strict mode' {
        $path = Join-Path $PSScriptRoot '..\core\Config-Store.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        if ($raw -notmatch '\$props\s*=\s*@\(\$InputObject \| Get-Member -MemberType NoteProperty\)') {
            throw 'Config-Store does not normalize NoteProperty results before checking Count.'
        }
    }

    & $Assert 'Device profile form strips placeholder examples before validation and persistence' {
        $path = Join-Path $PSScriptRoot '..\setup\Device-Profile-Runner.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        if ($raw -notmatch 'function\s+Remove-DeviceProfilePlaceholderValues') {
            throw 'Device profile placeholder cleanup helper is missing.'
        }
        if ($raw -notmatch 'Remove-DeviceProfilePlaceholderValues -Values \(Get-DeviceProfileCurrentValues') {
            throw 'Persisted device profile values are not cleaned before reopening the form.'
        }
        if ($raw -notmatch 'Remove-DeviceProfilePlaceholderValues -Values \$values') {
            throw 'Submitted device profile values are not cleaned before validation/persistence.'
        }
        if ($raw -notmatch 'if \(\$field\.ContainsKey\(''Default''\)\) \{ continue \}') {
            throw 'Sophos placeholder cleanup still strips explicit defaults.'
        }
        if ($raw -notmatch 'if \(\$field\.ContainsKey\(''Required''\) -and \[bool\]\$field\[''Required''\]\) \{ continue \}') {
            throw 'Sophos placeholder cleanup still strips required field values.'
        }
    }

    & $Assert 'Sophos schema separates accepted defaults from examples' {
        $schemaPath = Join-Path $PSScriptRoot '..\setup\Device-Schemas.ps1'
        $schema = Get-Content -LiteralPath $schemaPath -Raw
        foreach ($text in @(
            "Name='port'; Label='Admin/API port'; Type='string'; Required=`$true; Default='4444'",
            "Name='username'; Label='Admin username'; Type='string'; Required=`$true; Default='admin'",
            "Name='bind_admin_portal'; Label='Use for admin portal'; Type='choice'; Required=`$true; Choices=@('true','false'); Default='true'",
            "Name='skip_certificate_check'; Label='Ignore Sophos TLS warning'; Type='choice'; Required=`$true; Choices=@('false','true'); Default='false'"
        )) {
            if ($schema -notmatch [regex]::Escape($text)) {
                throw "Missing Sophos default/schema wording: $text"
            }
        }
    }

    & $Assert 'Sophos device profile does not ask for certificate artifacts' {
        $schemaPath = Join-Path $PSScriptRoot '..\setup\Device-Schemas.ps1'
        $schema = Get-Content -LiteralPath $schemaPath -Raw
        $match = [regex]::Match($schema, "sophos\s*=\s*@\{.*?custom\s*=\s*@\{", [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if (-not $match.Success) { throw 'Could not isolate Sophos schema block.' }
        $sophosSchema = $match.Value
        foreach ($text in @(
            "Name='certificate_name'",
            "Name='pfx_path'",
            "Name='pfx_password'",
            "Name='cert_path'",
            "Name='key_path'",
            "Name='enable_ssh_export_recovery'"
        )) {
            if ($sophosSchema -match [regex]::Escape($text)) {
                throw "Sophos device profile still asks for certificate/deploy-time field: $text"
            }
        }
    }

    & $Assert 'Sophos PowerShell 5.1 TLS skip uses a .NET certificate callback' {
        $modulePath = Join-Path $PSScriptRoot '..\Scripts\Modules\SimpleAcme.Sophos\SophosFirewallXml.psm1'
        $raw = Get-Content -LiteralPath $modulePath -Raw
        foreach ($text in @(
            'SimpleAcmeSophosCertificatePolicy',
            'RemoteCertificateValidationCallback',
            'CreateDelegate',
            'TrustAnyCertificate'
        )) {
            if ($raw -notmatch [regex]::Escape($text)) {
                throw "Missing Sophos PowerShell 5.1 certificate callback wiring: $text"
            }
        }
        if ($raw -match [regex]::Escape('ServerCertificateValidationCallback = { $true }')) {
            throw 'Sophos TLS skip still uses a PowerShell scriptblock callback, which fails on Windows PowerShell 5.1 worker threads.'
        }
    }
}
