$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:EventSource = 'Certificate'
$script:EventLogName = 'Application'

function Ensure-EventSource {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($script:EventSource)) {
            New-EventLog -LogName $script:EventLogName -Source $script:EventSource
        }
    } catch {
        Write-Warning "Event Log: $($_.Exception.Message)"
    }
}

function Write-CertificateLog {
    param(
        [string]$Level,
        [string]$Message,
        [string]$JobId = '',
        [string]$Domain = '',
        [string]$Step = ''
    )

    $levelText = ''
    if ($null -ne $Level) {
        $levelText = [string]$Level
    }

    $normalizedLevel = switch -Regex ($levelText.Trim().ToUpperInvariant()) {
        '^INFO(RMATION)?$' { 'INFO'; break }
        '^WARN(ING)?$' { 'WARN'; break }
        '^ERR(OR)?$' { 'ERROR'; break }
        default { 'INFO' }
    }

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $line = '{0} [{1,-5}] [job:{2}] [domain:{3}] [step:{4}] {5}' -f $timestamp, $normalizedLevel, $JobId, $Domain, $Step, $Message

    $entryType = switch ($normalizedLevel) {
        'INFO' { 'Information' }
        'WARN' { 'Warning' }
        'ERROR' { 'Error' }
    }

    Ensure-EventSource
    try {
        Write-EventLog -LogName $script:EventLogName -Source $script:EventSource -EventId 1000 -EntryType $entryType -Message $line
    } catch {
        Write-Warning "Event Log: $($_.Exception.Message)"
    }

    $logDir = $env:CERTIFICATE_LOG_DIR
    if ([string]::IsNullOrWhiteSpace($logDir)) {
        $logDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' 'logs'))
    }
    if (-not (Test-Path -LiteralPath $logDir)) {
        try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch { Write-Warning "Cannot create log directory '$logDir': $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $logDir) {
        $datestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd')
        $path = Join-Path $logDir "orchestrator-$datestamp.log"
        try { Add-Content -LiteralPath $path -Value $line -Encoding UTF8 } catch { Write-Warning "Log file write failed: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function Write-CertificateLog
