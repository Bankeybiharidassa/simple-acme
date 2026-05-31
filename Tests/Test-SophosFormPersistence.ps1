Set-StrictMode -Version Latest

function Invoke-TestSophosFormPersistence {
    param([scriptblock]$Assert)

    & $Assert 'Sophos deployment form loads and saves persisted current values' {
        $path = Join-Path $PSScriptRoot '..\setup\Sophos-Runner.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        foreach ($text in @(
            'function Resolve-SophosTuiConfigDir',
            'function Get-SophosDeploymentCurrentValues',
            'function Save-SophosDeploymentCurrentValues',
            'function Add-SophosFieldDefaults',
            'function Invoke-SophosProfileForm',
            'function Get-SophosCertificateDeploymentContext',
            'Show-TuiForm -Fields ([hashtable[]]$schema.Fields) -CurrentValues $currentValues',
            'Save-SophosDeploymentCurrentValues -ConfigDir $configDir -Values $values'
        )) {
            if ($raw -notmatch [regex]::Escape($text)) {
                throw "Missing Sophos form persistence wiring: $text"
            }
        }
    }

    & $Assert 'Sophos deployment form persists into device config store' {
        $path = Join-Path $PSScriptRoot '..\setup\Sophos-Runner.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        if ($raw -notmatch "connector_type\s*=\s*'sophos'") {
            throw 'Sophos deployment values are not saved as a sophos device config.'
        }
        if ($raw -notmatch 'device_id\s*=\s*\$deviceId') {
            throw 'Sophos deployment values do not use a stable device id.'
        }
        if ($raw -notmatch 'Save-DeviceConfig -Device \$device -ConfigDir \$ConfigDir') {
            throw 'Sophos deployment values are not saved through Config-Store.'
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
            "Save-DeviceConfig -Device `$device -ConfigDir `$ConfigDir -SecretFields @('password')",
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

    & $Assert 'Sophos deployment form strips placeholder examples before validation and persistence' {
        $path = Join-Path $PSScriptRoot '..\setup\Sophos-Runner.psm1'
        $raw = Get-Content -LiteralPath $path -Raw
        if ($raw -notmatch 'function\s+Remove-SophosPlaceholderValues') {
            throw 'Sophos placeholder cleanup helper is missing.'
        }
        if ($raw -notmatch 'Remove-SophosPlaceholderValues -Values \(Get-SophosDeploymentCurrentValues') {
            throw 'Persisted Sophos values are not cleaned before reopening the form.'
        }
        if ($raw -notmatch 'Remove-SophosPlaceholderValues -Values \$values') {
            throw 'Submitted Sophos values are not cleaned before validation/persistence.'
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
}
