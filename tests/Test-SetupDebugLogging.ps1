function Invoke-TestSetupDebugLogging {
    param([scriptblock]$Assert)

    $setupPath = Join-Path $PSScriptRoot '..\certificate-setup.ps1'
    $content = Get-Content -Raw -LiteralPath $setupPath

    & $Assert 'adds explicit EnableDebugFileLog switch parameter' {
        if ($content -notmatch '(?s)param\(\s*\[switch\]\$EnableDebugFileLog\s*\)') {
            throw 'Expected [switch]$EnableDebugFileLog parameter in certificate-setup.ps1'
        }
    }

    & $Assert 'debug resolution prefers CERTIFICATE_LOG_DIR with script-root fallback' {
        if ($content -notmatch "\$env:CERTIFICATE_LOG_DIR") { throw 'Expected CERTIFICATE_LOG_DIR usage.' }
        if ($content -notmatch "Join-Path \$PSScriptRoot 'logs'") { throw 'Expected script-root logs fallback.' }
    }

    & $Assert 'creates certificate-setup-debug timestamp file naming pattern' {
        if ($content -notmatch 'certificate-setup-debug-\{0\}\.log') {
            throw 'Expected certificate-setup-debug-<timestamp>.log naming pattern.'
        }
    }

    & $Assert 'prints resolved absolute debug log path to console' {
        if ($content -notmatch 'Setup debug file log:') {
            throw 'Expected startup console message containing resolved debug file path.'
        }
    }

    & $Assert 'includes actionable directory and write permission errors' {
        if ($content -notmatch 'Unable to create debug log directory') { throw 'Expected create-directory error message.' }
        if ($content -notmatch 'has write permission') { throw 'Expected permission hint for directory creation failure.' }
        if ($content -notmatch 'Unable to write setup debug log') { throw 'Expected write-log-file error message.' }
    }
}
