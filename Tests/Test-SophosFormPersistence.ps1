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

    & $Assert 'Sophos API password can be entered directly and is stored encrypted' {
        $runnerPath = Join-Path $PSScriptRoot '..\setup\Sophos-Runner.psm1'
        $schemaPath = Join-Path $PSScriptRoot '..\setup\Device-Schemas.ps1'
        $runner = Get-Content -LiteralPath $runnerPath -Raw
        $schema = Get-Content -LiteralPath $schemaPath -Raw
        foreach ($text in @(
            "Name='password'; Label='API password'; Type='secret'",
            "Name='password_secure_file'; Label='API password secure file'",
            "Name='pfx_password'; Label='PFX password'; Type='secret'"
        )) {
            if ($schema -notmatch [regex]::Escape($text)) {
                throw "Missing Sophos password schema wiring: $text"
            }
        }
        foreach ($text in @(
            'function Write-SophosTuiSecureValueFile',
            'function Resolve-SophosDefaultPfxPath',
            "Save-DeviceConfig -Device `$device -ConfigDir `$ConfigDir -SecretFields @('password','pfx_password')",
            "Sophos API authentication is missing. Enter 'password', 'password_secret_name', or 'password_secure_file'.",
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
    }
}
