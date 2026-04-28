param(
    [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/core/Env-Loader.psm1" -Force
Import-Module "$PSScriptRoot/core/Simple-Acme-Reconciler.psm1" -Force

$transcriptStarted = $false
$showDiagnostics = ([Environment]::GetEnvironmentVariable('CERTIFICATE_VERBOSE_DIAGNOSTICS') -eq '1')
try {
    if ([Environment]::GetEnvironmentVariable('CERTIFICATE_TRANSCRIPT_LOGGING') -eq '1') {
        $logDir = [Environment]::GetEnvironmentVariable('CERTIFICATE_LOG_DIR')
        if (-not [string]::IsNullOrWhiteSpace($logDir)) {
            if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            $transcriptPath = Join-Path $logDir ("reconcile-transcript-{0}.log" -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
            Start-Transcript -Path $transcriptPath -Force | Out-Null
            $transcriptStarted = $true
        }
    }
    $envFilePath = Resolve-BootstrapEnvPath -ProjectRoot $PSScriptRoot
    $envValues = Import-EnvFile -Path $envFilePath -Force
    $preflight = Assert-ReconcilePreflight -EnvValues $envValues
    Write-Output "preflight ok: wacs=$($preflight.WacsPath) domains=$($preflight.DomainCount) script=$($preflight.ScriptPath)"
    if ($showDiagnostics) {
        Show-ReconcileDiagnostics -Context 'simple-acme diagnostics'
    }
    if ($PreflightOnly) {
        Write-Output 'preflight only mode: reconcile skipped.'
        exit 0
    }
    $action = Invoke-SimpleAcmeReconcile -EnvValues $envValues
    Write-Output "simple-acme reconcile complete: $action"
    if ($showDiagnostics) {
        Show-ReconcileDiagnostics -Context 'simple-acme diagnostics'
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host ("ACME reconcile failed: " + $_.Exception.Message) -ForegroundColor Red
    Show-ReconcileDiagnostics -Context 'simple-acme diagnostics'
    Write-Error $_
    exit 1
} finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
