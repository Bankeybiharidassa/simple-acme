[CmdletBinding()]
param(
    [switch]$EnableDebugFileLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:tuiModule = $null
$script:SetupLogEnabled = $false
$script:SetupLogPath = $null
$script:SetupTranscriptPath = $null
$script:SetupTranscriptEnabled = $false

function Initialize-SetupDebugLogging {
    $debugRequested = $EnableDebugFileLog -or $PSBoundParameters.ContainsKey('Debug') -or $DebugPreference -ne [System.Management.Automation.ActionPreference]::SilentlyContinue
    if (-not $debugRequested) { return }

    $configuredRoot = if (-not [string]::IsNullOrWhiteSpace($env:CERTIFICATE_LOG_DIR)) { [string]$env:CERTIFICATE_LOG_DIR } else { Join-Path $PSScriptRoot 'logs' }
    try {
        $logRoot = [System.IO.Path]::GetFullPath($configuredRoot)
    } catch {
        throw "Unable to resolve debug log directory path '$configuredRoot'. $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $logRoot)) {
        try {
            New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        } catch {
            throw "Unable to create debug log directory '$logRoot'. Verify the path and ensure the current user has write permission. $($_.Exception.Message)"
        }
    }

    $script:SetupLogPath = Join-Path $logRoot ("certificate-setup-debug-{0}.log" -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
    try {
        "[$((Get-Date).ToUniversalTime().ToString('o'))] Setup debug logging started." | Set-Content -LiteralPath $script:SetupLogPath -Encoding UTF8
    } catch {
        throw "Unable to write setup debug log '$script:SetupLogPath'. Verify write permissions for '$logRoot'. $($_.Exception.Message)"
    }

    $script:SetupLogEnabled = $true
    $script:SetupTranscriptPath = Join-Path $logRoot ("certificate-setup-transcript-{0}.log" -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
    try {
        Start-Transcript -LiteralPath $script:SetupTranscriptPath -Append -ErrorAction Stop | Out-Null
        $script:SetupTranscriptEnabled = $true
    } catch {
        $script:SetupTranscriptEnabled = $false
        Add-Content -LiteralPath $script:SetupLogPath -Value ("[{0}] Warning: unable to start transcript. {1}" -f (Get-Date).ToUniversalTime().ToString('o'), $_.Exception.Message) -Encoding UTF8
    }
    if (-not [string]::IsNullOrWhiteSpace([string]([Environment]::GetEnvironmentVariable('CERTIFICATE_VERBOSE_DIAGNOSTICS')))) {
        # preserve explicit operator value
    } else {
        [Environment]::SetEnvironmentVariable('CERTIFICATE_VERBOSE_DIAGNOSTICS', '1', 'Process')
    }
    [Console]::WriteLine(('Setup debug file log: {0}' -f $script:SetupLogPath))
    if ($script:SetupTranscriptEnabled) {
        [Console]::WriteLine(('Setup transcript log: {0}' -f $script:SetupTranscriptPath))
    }
}

function Stop-SetupDebugLogging {
    if ($script:SetupTranscriptEnabled) {
        try { Stop-Transcript | Out-Null } catch {}
        $script:SetupTranscriptEnabled = $false
    }
}

function Write-SetupDebugLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $script:SetupLogEnabled) { return }
    $line = "[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString('o'), $Message
    try {
        Add-Content -LiteralPath $script:SetupLogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch [System.IO.IOException] {
        $fallbackPath = [string]$script:SetupLogPath + '.fallback'
        try {
            Add-Content -LiteralPath $fallbackPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            # Debug logging must never terminate setup execution.
        }
    } catch {
        # Debug logging must never terminate setup execution.
    }
}

Initialize-SetupDebugLogging
Write-SetupDebugLog -Message "certificate-setup.ps1 started. ScriptRoot='$PSScriptRoot'"

$tuiEngineModulePath = Join-Path $PSScriptRoot 'core/Tui-Engine.psm1'
$formRunnerModulePath = Join-Path $PSScriptRoot 'setup/Form-Runner.psm1'
$netScalerRunnerModulePath = Join-Path $PSScriptRoot 'setup/NetScaler-Runner.psm1'
$sophosRunnerModulePath = Join-Path $PSScriptRoot 'setup/Sophos-Runner.psm1'
$schedulerModulePath = Join-Path $PSScriptRoot 'core/Scheduler.psm1'
$envLoaderModulePath = Join-Path $PSScriptRoot 'core/Env-Loader.psm1'

function Assert-SetupCommandAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedModulePath,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSModuleInfo]$ModuleInfo
    )

    $moduleCommand = $ModuleInfo.ExportedCommands[$CommandName]
    if ($null -eq $moduleCommand) {
        throw @"
Required setup command '$CommandName' was not exported by module '$($ModuleInfo.Name)'.
Expected module path: $ExpectedModulePath
Resolved module path: $($ModuleInfo.Path)
Current script root: $PSScriptRoot
Re-deploy the setup modules and ensure you are running certificate-setup.ps1 from the correct repository root.
"@
    }

    $resolved = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($null -eq $resolved -or [string]::IsNullOrWhiteSpace([string]$resolved.Source) -or $resolved.Source -ne $ModuleInfo.Name) {
        throw @"
Required setup command '$CommandName' is unavailable after module import.
Expected module path: $ExpectedModulePath
Resolved module path: $($ModuleInfo.Path)
Current script root: $PSScriptRoot
This usually indicates a path mismatch, stale deployment, or incomplete copy.
Run this script from a full repository checkout and confirm the module file exists at the expected path.
"@
    }
}

$tuiModule = Import-Module $tuiEngineModulePath -Force -Global -PassThru
Write-SetupDebugLog -Message "Imported module: $tuiEngineModulePath"
if ($null -eq $tuiModule) {
    throw "Unable to import required TUI module from path: $tuiEngineModulePath"
}
Assert-SetupCommandAvailable -CommandName 'Show-TuiMenu' -ExpectedModulePath $tuiEngineModulePath -ModuleInfo $tuiModule
Assert-SetupCommandAvailable -CommandName 'Show-TuiStatus' -ExpectedModulePath $tuiEngineModulePath -ModuleInfo $tuiModule

$formRunnerModule = Import-Module $formRunnerModulePath -Force -Global -PassThru
Write-SetupDebugLog -Message "Imported module: $formRunnerModulePath"
if ($null -eq $formRunnerModule) {
    throw "Unable to import required setup module from path: $formRunnerModulePath"
}
Assert-SetupCommandAvailable -CommandName 'Invoke-FirstRunWizard' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Invoke-AcmeForm' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Invoke-AcmeSettingsMenu' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Invoke-PolicyEditor' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Invoke-PolicyViewer' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Invoke-DeviceForm' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Invoke-ManageCertificatesMenu' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Invoke-ViewLogsDiagnostics' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Invoke-AcmeTuiDiagnostics' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Show-SimpleAcmeDiagnosticSummary' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Wait-ForOperatorReturn' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Assert-ProviderDirectoryConsistency' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule

$netScalerRunnerModule = Import-Module $netScalerRunnerModulePath -Force -Global -PassThru
Write-SetupDebugLog -Message "Imported module: $netScalerRunnerModulePath"
if ($null -eq $netScalerRunnerModule) {
    throw "Unable to import required NetScaler setup module from path: $netScalerRunnerModulePath"
}
Assert-SetupCommandAvailable -CommandName 'Invoke-NetScalerDeploymentForm' -ExpectedModulePath $netScalerRunnerModulePath -ModuleInfo $netScalerRunnerModule
Assert-SetupCommandAvailable -CommandName 'Invoke-NetScalerDiagnostics' -ExpectedModulePath $netScalerRunnerModulePath -ModuleInfo $netScalerRunnerModule
Assert-SetupCommandAvailable -CommandName 'Convert-NetScalerFormValuesToArguments' -ExpectedModulePath $netScalerRunnerModulePath -ModuleInfo $netScalerRunnerModule
Assert-SetupCommandAvailable -CommandName 'Test-NetScalerTuiWiring' -ExpectedModulePath $netScalerRunnerModulePath -ModuleInfo $netScalerRunnerModule
$sophosRunnerModule = Import-Module $sophosRunnerModulePath -Force -Global -PassThru
Write-SetupDebugLog -Message "Imported module: $sophosRunnerModulePath"
if ($null -eq $sophosRunnerModule) {
    throw "Unable to import required Sophos setup module from path: $sophosRunnerModulePath"
}
Assert-SetupCommandAvailable -CommandName 'Invoke-SophosDeploymentForm' -ExpectedModulePath $sophosRunnerModulePath -ModuleInfo $sophosRunnerModule
Assert-SetupCommandAvailable -CommandName 'Invoke-SophosDiagnostics' -ExpectedModulePath $sophosRunnerModulePath -ModuleInfo $sophosRunnerModule
Assert-SetupCommandAvailable -CommandName 'Invoke-SophosCertificateExportRecovery' -ExpectedModulePath $sophosRunnerModulePath -ModuleInfo $sophosRunnerModule
Assert-SetupCommandAvailable -CommandName 'Convert-SophosFormValuesToArguments' -ExpectedModulePath $sophosRunnerModulePath -ModuleInfo $sophosRunnerModule
Assert-SetupCommandAvailable -CommandName 'Test-SophosTuiWiring' -ExpectedModulePath $sophosRunnerModulePath -ModuleInfo $sophosRunnerModule
$schedulerModule = Import-Module $schedulerModulePath -Force -Global -PassThru
Write-SetupDebugLog -Message "Imported module: $schedulerModulePath"
if ($null -eq $schedulerModule) {
    throw "Unable to import required scheduler module from path: $schedulerModulePath"
}
Assert-SetupCommandAvailable -CommandName 'Ensure-OrchestratorScheduledTask' -ExpectedModulePath $schedulerModulePath -ModuleInfo $schedulerModule
Import-Module $envLoaderModulePath -Force -Global | Out-Null
Write-SetupDebugLog -Message "Imported module: $envLoaderModulePath"
. "$PSScriptRoot/setup/Menu-Tree.ps1"
Write-SetupDebugLog -Message "Loaded menu tree."

function Test-CurrentProcessElevated {
    if (-not ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)) { return $true }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-SingleQuotedLiteral {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "''" }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Start-ElevatedSetupRelaunch {
    param([Parameter(Mandatory)][string]$Reason)

    $scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
    $envAssignments = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('CERTIFICATE_ENV_FILE','CERTIFICATE_LOG_DIR','CERTIFICATE_CONFIG_DIR','CERTIFICATE_VERBOSE_DIAGNOSTICS','CERTIFICATE_TRANSCRIPT_LOGGING')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $envAssignments.Add(('$env:{0} = {1}' -f $name, (ConvertTo-SingleQuotedLiteral -Value $value)))
        }
    }

    $commandLines = @($envAssignments)
    $commandLines += ('$DebugPreference = {0}' -f (ConvertTo-SingleQuotedLiteral -Value ([string]$DebugPreference)))
    $commandLines += ('Set-Location -LiteralPath {0}' -f (ConvertTo-SingleQuotedLiteral -Value $PSScriptRoot))
    $commandLines += ('& {0} -EnableDebugFileLog' -f (ConvertTo-SingleQuotedLiteral -Value $scriptPath))
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes(($commandLines -join "`r`n")))

    Write-SetupDebugLog -Message ("Requesting elevated relaunch. reason='{0}' script='{1}'" -f $Reason, $scriptPath)
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-EncodedCommand',$encodedCommand) | Out-Null
    [Console]::WriteLine('')
    [Console]::WriteLine('An elevated PowerShell window was requested. Continue there to perform the privileged action.')
    [Console]::WriteLine('This non-elevated setup window will stay open; return here only if you choose not to use elevation.')
}

function Request-ElevationForPrivilegedAction {
    param([Parameter(Mandatory)][string]$Reason)

    if (Test-CurrentProcessElevated) { return $true }

    [Console]::WriteLine('')
    [Console]::WriteLine('Administrator rights may be required.')
    [Console]::WriteLine($Reason)
    [Console]::WriteLine('')
    $answer = [string](Read-Host 'Open an elevated PowerShell setup window now? [Y/N]')
    if ($answer.Trim().ToLowerInvariant() -in @('y','yes')) {
        Start-ElevatedSetupRelaunch -Reason $Reason
        Wait-ForOperatorReturn
        return $false
    }

    [Console]::WriteLine('')
    $continueAnswer = [string](Read-Host 'Continue in this non-elevated window anyway? [Y/N]')
    $continue = $continueAnswer.Trim().ToLowerInvariant() -in @('y','yes')
    Write-SetupDebugLog -Message ("Elevation prompt declined. continue_without_elevation='{0}' reason='{1}'" -f $continue, $Reason)
    return $continue
}

function Test-SetupFileReadable {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $stream.Dispose()
        return $true
    } catch [System.IO.FileNotFoundException] {
        return $true
    } catch [System.IO.DirectoryNotFoundException] {
        return $true
    } catch {
        return $false
    }
}

function Repair-SetupFileAcl {
    param([Parameter(Mandatory)][string]$Path)

    if (-not ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)) { return $true }

    try {
        Set-EnvFileAcl -Path $Path
        if (Test-SetupFileReadable -Path $Path) { return $true }
    } catch {
        Write-SetupDebugLog -Message ("Set-EnvFileAcl repair failed for '{0}': {1}" -f $Path, $_.Exception.Message)
    }

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $account = $identity.Name
        if ([string]::IsNullOrWhiteSpace($account)) { return $false }
        $grant = ('{0}:(F)' -f $account)
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) { $icacls = 'icacls.exe' }
        $process = Start-Process -FilePath $icacls -ArgumentList @($Path, '/grant', $grant) -Wait -PassThru -WindowStyle Hidden
        Write-SetupDebugLog -Message ("icacls repair for '{0}' exited with code {1}." -f $Path, $process.ExitCode)
        return ($process.ExitCode -eq 0 -and (Test-SetupFileReadable -Path $Path))
    } catch {
        Write-SetupDebugLog -Message ("icacls repair failed for '{0}': {1}" -f $Path, $_.Exception.Message)
        return $false
    }
}

function Ensure-SetupEnvFileReadable {
    param([Parameter(Mandatory)][string]$EnvFilePath)

    if (Test-SetupFileReadable -Path $EnvFilePath) { return $true }

    Write-SetupDebugLog -Message ("Env file is not readable by current process: {0}" -f $EnvFilePath)
    [Console]::WriteLine('')
    [Console]::WriteLine('The configured certificate.env exists, but this PowerShell cannot read it.')
    [Console]::WriteLine($EnvFilePath)
    [Console]::WriteLine('This usually means the file ACL was hardened by an earlier elevated or SYSTEM run.')

    if (Repair-SetupFileAcl -Path $EnvFilePath) {
        [Console]::WriteLine('Repaired certificate.env permissions for the current operator.')
        return $true
    }

    if (-not (Test-CurrentProcessElevated)) {
        [Console]::WriteLine('')
        $answer = [string](Read-Host 'Open an elevated PowerShell setup window to repair/read this file? [Y/N]')
        if ($answer.Trim().ToLowerInvariant() -in @('y','yes')) {
            Start-ElevatedSetupRelaunch -Reason "certificate.env is not readable by the current non-elevated process: $EnvFilePath"
            Wait-ForOperatorReturn
            return $false
        }

        [Console]::WriteLine('')
        $continueAnswer = [string](Read-Host 'Continue in this non-elevated window anyway? [Y/N]')
        return ($continueAnswer.Trim().ToLowerInvariant() -in @('y','yes'))
    }

    [Console]::WriteLine('Permission repair failed even though this process is elevated. Check file ownership/ACL manually.')
    Wait-ForOperatorReturn
    return $false
}

function Test-ReconcileLikelyRequiresElevation {
    param([Parameter(Mandatory)][hashtable]$EnvValues)

    $storePlugin = if ($EnvValues.ContainsKey('ACME_STORE_PLUGIN')) { [string]$EnvValues['ACME_STORE_PLUGIN'] } else { '' }
    $installationPlugin = if ($EnvValues.ContainsKey('ACME_INSTALLATION_PLUGINS')) { [string]$EnvValues['ACME_INSTALLATION_PLUGINS'] } else { '' }
    $targetSystem = if ($EnvValues.ContainsKey('ACME_TARGET_SYSTEM')) { [string]$EnvValues['ACME_TARGET_SYSTEM'] } elseif ($EnvValues.ContainsKey('TARGET_SYSTEM')) { [string]$EnvValues['TARGET_SYSTEM'] } else { '' }
    $scriptPath = if ($EnvValues.ContainsKey('ACME_SCRIPT_PATH')) { [string]$EnvValues['ACME_SCRIPT_PATH'] } else { '' }

    if ($storePlugin -match '(?i)(^|[,;\s])certificatestore($|[,;\s])') { return $true }
    if ($installationPlugin -match '(?i)(^|[,;\s])iis($|[,;\s])') { return $true }
    if ($targetSystem -match '(?i)^(iis|rds|rds-farm)$') { return $true }
    if ($scriptPath -match '(?i)(cert2rds|deploy-rds-farm|cert2iis)\.ps1$') { return $true }
    return $false
}

function Invoke-InitialAcmeReconcilePrompt {
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][string]$EnvFilePath
    )

    Write-SetupDebugLog -Message "Initial reconcile prompt started. env_file='$EnvFilePath'"
    $envValues = Import-EnvFile -Path $EnvFilePath -Force
    if ($envValues.ContainsKey('__ENV_IMPORT_SUMMARY')) {
        $summary = $envValues['__ENV_IMPORT_SUMMARY']
        Write-SetupDebugLog -Message ("Env import summary for initial reconcile: applied={0}; skipped={1}" -f $summary.AppliedCount, $summary.SkippedCount)
    }

    try {
        Assert-ProviderDirectoryConsistency -Values $envValues
    } catch {
        Write-SetupDebugLog -Message ("Provider directory consistency check failed: " + $_.Exception.Message)
        [Console]::WriteLine('')
        [Console]::WriteLine($_.Exception.Message)
        Wait-ForOperatorReturn
        return
    }

    [Console]::WriteLine('')
    [Console]::WriteLine('Issuance ACME directory:')
    [Console]::WriteLine([string]$envValues['ACME_DIRECTORY'])
    [Console]::WriteLine('')
    [Console]::WriteLine('Effective wacs command preview:')
    try {
        Import-Module (Join-Path $RootDir 'core/Simple-Acme-Reconciler.psm1') -Force | Out-Null
        $csrAlgo = if ($envValues.ContainsKey('ACME_CSR_ALGORITHM')) { [string]$envValues['ACME_CSR_ALGORITHM'] } else { 'ec' }
        $previewLine = Get-MaskedWacsIssueCommandPreview -EnvValues $envValues -CsrAlgorithm $csrAlgo
        [Console]::WriteLine($previewLine)
    } catch {
        [Console]::WriteLine(('Cannot build WACS command preview: ' + $_.Exception.Message))
        Wait-ForOperatorReturn
        return
    }
    [Console]::WriteLine('')

    Write-SetupDebugLog -Message "Initial reconcile prompt displayed to operator."
    [Console]::WriteLine('')
    $answer = [string](Read-Host 'Run initial ACME reconcile now? [Y/N]')
    $normalizedAnswer = $answer.Trim().ToLowerInvariant()
    $willProceed = $normalizedAnswer -in @('y','yes')
    Write-SetupDebugLog -Message ("Initial reconcile prompt response captured. raw='{0}' normalized='{1}' decision='{2}'" -f $answer, $normalizedAnswer, $(if ($willProceed) { 'proceed' } else { 'skip' }))
    if (-not $willProceed) {
        Write-SetupDebugLog -Message 'Initial reconcile skipped by operator choice.'
        [Console]::WriteLine('')
        [Console]::WriteLine('Skipped ACME reconcile. Run certificate-simple-acme-reconcile.ps1 later to bootstrap issuance.')
        Wait-ForOperatorReturn
        return
    }

    if (Test-ReconcileLikelyRequiresElevation -EnvValues $envValues) {
        $elevationReason = 'The certificate request/install preview includes local machine certificate store or Windows binding work. This commonly needs Administrator rights.'
        if (-not (Request-ElevationForPrivilegedAction -Reason $elevationReason)) {
            Write-SetupDebugLog -Message 'Initial reconcile deferred after elevation prompt.'
            return
        }
    }

    $logDir = [string][Environment]::GetEnvironmentVariable('CERTIFICATE_LOG_DIR')
    if ([string]::IsNullOrWhiteSpace($logDir)) {
        $logDir = [System.IO.Path]::GetFullPath((Join-Path $RootDir 'logs'))
    }
    $transcriptEnabled = ([Environment]::GetEnvironmentVariable('CERTIFICATE_TRANSCRIPT_LOGGING') -eq '1')
    Write-SetupDebugLog -Message ("Initial reconcile log directory resolved: '{0}'" -f $logDir)
    Write-SetupDebugLog -Message "Reconcile log pattern: reconcile-YYYYMMDD.log"
    if ($transcriptEnabled) {
        Write-SetupDebugLog -Message "Reconcile transcript logging is enabled. Pattern: reconcile-transcript-YYYYMMDD-HHMMSS.log"
    } else {
        Write-SetupDebugLog -Message 'Reconcile transcript logging is disabled. To enable set CERTIFICATE_TRANSCRIPT_LOGGING=1.'
    }

    try {
        Import-Module (Join-Path $RootDir 'core/Simple-Acme-Reconciler.psm1') -Force | Out-Null
        Write-SetupDebugLog -Message ("Starting initial reconcile. domains='{0}' acme_directory='{1}' script_path='{2}'" -f [string]$envValues['DOMAINS'], [string]$envValues['ACME_DIRECTORY'], [string]$envValues['ACME_SCRIPT_PATH'])
        $action = Invoke-SimpleAcmeReconcile -EnvValues $envValues
        Write-SetupDebugLog -Message ("Initial reconcile completed successfully. action='{0}' completed_utc='{1}'" -f [string]$action, (Get-Date).ToUniversalTime().ToString('o'))
        [Console]::WriteLine('')
        [Console]::WriteLine("ACME reconcile completed successfully (action=$action).")
        if ([Environment]::GetEnvironmentVariable('CERTIFICATE_VERBOSE_DIAGNOSTICS') -eq '1') {
            Write-ReconcileDiagnostics -Context 'simple-acme diagnostics'
        }
        Invoke-PostSetupValidation -RootDir $RootDir -EnvValues $envValues
    } catch {
        Write-SetupDebugLog -Message ("Initial reconcile failed: " + $_.Exception.Message)
        if ($_.InvocationInfo) {
            Write-SetupDebugLog -Message ("Failure invocation context: script='{0}' line='{1}' command='{2}'" -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line)
        } else {
            Write-SetupDebugLog -Message 'Failure invocation context unavailable.'
        }
        if ($_.ScriptStackTrace) {
            Write-SetupDebugLog -Message ('Failure stack trace: ' + $_.ScriptStackTrace)
        } else {
            Write-SetupDebugLog -Message 'Failure stack trace unavailable.'
        }

        $failurePhase = 'initial reconcile'
        [Console]::WriteLine('')
        [Console]::WriteLine(('ACME reconcile failed during {0}: ' -f $failurePhase) + $_.Exception.Message)
        if ($_.InvocationInfo) {
            [Console]::WriteLine('Script: ' + $_.InvocationInfo.ScriptName)
            [Console]::WriteLine('Line: ' + $_.InvocationInfo.ScriptLineNumber)
            [Console]::WriteLine('Command: ' + $_.InvocationInfo.Line)
        }
        if ($_.ScriptStackTrace) {
            [Console]::WriteLine('Stack trace:')
            [Console]::WriteLine($_.ScriptStackTrace)
        }
        [Console]::WriteLine('See wrapper log:')
        [Console]::WriteLine('See reconcile-*.log in the logs\ directory next to this script.')
        Write-ReconcileDiagnostics -Context 'simple-acme diagnostics'
        Wait-ForOperatorReturn
    } finally {
        $latestReconcileLog = $null
        if (Test-Path -LiteralPath $logDir) {
            $latestReconcileLog = Get-ChildItem -LiteralPath $logDir -Filter 'reconcile-*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
        }
        $latestPath = if ($null -eq $latestReconcileLog) { '(not found)' } else { [string]$latestReconcileLog.FullName }
        Write-SetupDebugLog -Message ("Latest reconcile log discovered: {0}" -f $latestPath)
        Write-SetupDebugLog -Message ("Reconcile transcript status: {0}" -f $(if ($transcriptEnabled) { 'enabled' } else { 'disabled (set CERTIFICATE_TRANSCRIPT_LOGGING=1 to enable)' }))
    }
}

function Invoke-PostSetupValidation {
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][hashtable]$EnvValues
    )

    $statusRow = [Math]::Max(0, [Console]::WindowHeight - 2)
    try {
        Import-Module (Join-Path $RootDir 'core/Simple-Acme-Reconciler.psm1') -Force | Out-Null
        $domains = Get-NormalizedDomains -Domains ([string]$EnvValues['DOMAINS'])
        $renewals = @()
        foreach ($file in Get-RenewalFiles) {
            $summary = Get-RenewalSummary -File $file
            if (Test-ExactDomainSetMatch -Requested $domains -Actual $summary.Hosts) { $renewals += ,$summary }
        }
        if ($renewals.Count -lt 1) { throw 'No renewal JSON found for configured domains.' }
        $compare = Compare-RenewalWithEnv -RenewalSummary $renewals[0] -EnvValues $EnvValues
        if (-not $compare.Matches) { throw "Renewal JSON plugin mismatch: $($compare.Mismatches -join ', ')" }

        Show-TuiStatus -Message 'Post-setup validation passed (renewal JSON, plugins, and script wiring).' -Type Success -Row $statusRow
    } catch {
        Show-TuiStatus -Message "Post-setup validation warning: $($_.Exception.Message)" -Type Warning -Row $statusRow
        Wait-ForOperatorReturn
    }
}

function Invoke-OrchestratorTaskRegistration {
    param([Parameter(Mandatory)][string]$RootDir)

    $statusRow = [Math]::Max(0, [Console]::WindowHeight - 2)
    if (-not (Request-ElevationForPrivilegedAction -Reason 'Registering or repairing the orchestrator scheduled task can require Administrator rights, especially when using SYSTEM as the task user.')) {
        Show-TuiStatus -Message 'Scheduled task registration deferred. Continue in the elevated setup window to register it.' -Type Warning -Row $statusRow
        Start-Sleep -Milliseconds 2200
        return
    }

    try {
        $envValues = Import-EnvFile -Path (Resolve-BootstrapEnvPath -ProjectRoot $RootDir) -Force
        $taskName = if (-not [string]::IsNullOrWhiteSpace([string]$envValues['CERTIFICATE_TASK_NAME'])) { [string]$envValues['CERTIFICATE_TASK_NAME'] } else { 'Certificate-Orchestrator' }
        $interval = 5
        if (-not [string]::IsNullOrWhiteSpace([string]$envValues['CERTIFICATE_TASK_INTERVAL_MINUTES'])) {
            if (-not [int]::TryParse([string]$envValues['CERTIFICATE_TASK_INTERVAL_MINUTES'], [ref]$interval)) {
                throw "CERTIFICATE_TASK_INTERVAL_MINUTES must be an integer. Value: '$($envValues['CERTIFICATE_TASK_INTERVAL_MINUTES'])'"
            }
        }
        $taskUser = if (-not [string]::IsNullOrWhiteSpace([string]$envValues['CERTIFICATE_TASK_USER'])) { [string]$envValues['CERTIFICATE_TASK_USER'] } else { 'SYSTEM' }
        $psExe = if (-not [string]::IsNullOrWhiteSpace([string]$envValues['CERTIFICATE_TASK_POWERSHELL'])) { [string]$envValues['CERTIFICATE_TASK_POWERSHELL'] } else { 'powershell.exe' }
        $scriptPath = Join-Path $RootDir 'certificate-orchestrator.ps1'
        $result = Ensure-OrchestratorScheduledTask -TaskName $taskName -ScriptPath $scriptPath -EveryMinutes $interval -TaskUser $taskUser -PowerShellExe $psExe
        Show-TuiStatus -Message "Scheduled task $($result.Action): $($result.TaskName) every $($result.EveryMinutes) minutes as $($result.TaskUser)." -Type Success -Row $statusRow
    } catch {
        Show-TuiStatus -Message "Scheduled task registration failed: $($_.Exception.Message)" -Type Error -Row $statusRow
    }
    Start-Sleep -Milliseconds 2200
}

$envPath = Resolve-BootstrapEnvPath -ProjectRoot $PSScriptRoot
Write-SetupDebugLog -Message "Resolved env path: $envPath"
[Console]::WriteLine('Active bootstrap env:')
[Console]::WriteLine($envPath)
if ($env:CERTIFICATE_ENV_FILE) {
    [Console]::WriteLine('Source: CERTIFICATE_ENV_FILE override')
}
if (-not (Ensure-SetupEnvFileReadable -EnvFilePath $envPath)) {
    Stop-SetupDebugLogging
    return
}

. "$PSScriptRoot/config.ps1"
Initialize-CertificateConfig -AllowIncomplete | Out-Null
Write-SetupDebugLog -Message "Certificate config initialized."

$configDir = if ($env:CERTIFICATE_CONFIG_DIR) { $env:CERTIFICATE_CONFIG_DIR } else { Join-Path $PSScriptRoot 'config' }
if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

$menuStack = @($CertificateMenuTree)
while ($menuStack.Count -gt 0) {
    Write-SetupDebugLog -Message "Rendering menu: $($menuStack[$menuStack.Count - 1].Title)"
    $currentMenu = $menuStack[$menuStack.Count - 1]
    $selected = Show-TuiMenu -Menu $currentMenu -DisableSubmenuRecursion

    if ($null -eq $selected -or $selected -eq 'exit') {
        if ($menuStack.Count -eq 1) { break }
        $menuStack = @($menuStack[0..($menuStack.Count - 2)])
        continue
    }

    $menuItem = $currentMenu.Items | Where-Object { $_.Key -eq $selected } | Select-Object -First 1
    if ($null -eq $menuItem) { continue }

    if ($menuItem.Type -eq 'submenu') {
        Write-SetupDebugLog -Message "Opening submenu: $selected"
        if ($selected -eq 'advanced') {
            [Console]::WriteLine('')
            [Console]::WriteLine('These features are experimental phase-2 deployment/orchestrator functions.')
            [Console]::WriteLine('They are not required for normal local simple-acme certificate setup.')
            $phase2Confirm = [string](Read-Host 'Continue? [Y/N]')
            if ($phase2Confirm.Trim().ToLowerInvariant() -notin @('y','yes')) {
                continue
            }
        }
        $menuStack += ,@{ Title = $menuItem.Label; Items = @($menuItem.Items) }
        continue
    }

    Clear-TuiScreen
    switch ($selected) {
        'setup-new'      {
            Write-SetupDebugLog -Message "Executing action: setup-new"
            if (-not (Ensure-SetupEnvFileReadable -EnvFilePath $envPath)) {
                Write-SetupDebugLog -Message 'setup-new deferred because certificate.env is not readable.'
                continue
            }
            $result = Invoke-AcmeForm -EnvFilePath $envPath
            if ($null -eq $result) {
                Write-SetupDebugLog -Message 'setup-new outcome: canceled-before-save (Invoke-AcmeForm returned null).'
            } elseif ([string]$result.Status -eq 'saved') {
                Write-SetupDebugLog -Message ("setup-new outcome: saved (target='{0}' domains='{1}'). Reconcile prompt will be shown." -f [string]$result.TargetSystem, [string]$result.Domains)
                Invoke-InitialAcmeReconcilePrompt -RootDir $PSScriptRoot -EnvFilePath $envPath
            } else {
                Write-SetupDebugLog -Message ("setup-new outcome: unexpected-result-status='{0}'. Reconcile prompt will be skipped." -f [string]$result.Status)
            }
        }
        'manage-certs'   { Invoke-ManageCertificatesMenu -ConfigDir $configDir }
        'acme'           {
            Write-SetupDebugLog -Message "Executing action: acme"
            if (-not (Ensure-SetupEnvFileReadable -EnvFilePath $envPath)) {
                Write-SetupDebugLog -Message 'acme settings deferred because certificate.env is not readable.'
                continue
            }
            Invoke-AcmeSettingsMenu -EnvFilePath $envPath
        }
        'logs-diagnostics' { Write-SetupDebugLog -Message "Executing action: logs-diagnostics"; Invoke-ViewLogsDiagnostics -ProjectRoot $PSScriptRoot }
        'acme-tui-diagnostics' { Write-SetupDebugLog -Message "Executing action: acme-tui-diagnostics"; Invoke-AcmeTuiDiagnostics -ProjectRoot $PSScriptRoot }
        'netscaler-deploy'      { Write-SetupDebugLog -Message "Executing action: netscaler-deploy"; Invoke-NetScalerDeploymentForm -ProjectRoot $PSScriptRoot -WhatIfMode:$false }
        'netscaler-whatif'      { Write-SetupDebugLog -Message "Executing action: netscaler-whatif"; Invoke-NetScalerDeploymentForm -ProjectRoot $PSScriptRoot -WhatIfMode:$true }
        'netscaler-diagnostics' { Write-SetupDebugLog -Message "Executing action: netscaler-diagnostics"; Invoke-NetScalerDiagnostics -ProjectRoot $PSScriptRoot }
        'sophos-deploy'         { Write-SetupDebugLog -Message "Executing action: sophos-deploy"; Invoke-SophosDeploymentForm -ProjectRoot $PSScriptRoot -WhatIfMode:$false }
        'sophos-whatif'         { Write-SetupDebugLog -Message "Executing action: sophos-whatif"; Invoke-SophosDeploymentForm -ProjectRoot $PSScriptRoot -WhatIfMode:$true }
        'sophos-diagnostics'    { Write-SetupDebugLog -Message "Executing action: sophos-diagnostics"; Invoke-SophosDiagnostics -ProjectRoot $PSScriptRoot }
        'sophos-export-recovery' { Write-SetupDebugLog -Message "Executing action: sophos-export-recovery"; Invoke-SophosCertificateExportRecovery -ProjectRoot $PSScriptRoot }
        'task-register'  { Write-SetupDebugLog -Message "Executing action: task-register"; Invoke-OrchestratorTaskRegistration -RootDir $PSScriptRoot }
        'policies'       { Write-SetupDebugLog -Message "Executing action: policies"; Invoke-PolicyEditor -ConfigDir $configDir | Out-Null }
        'policies-view'  { Write-SetupDebugLog -Message "Executing action: policies-view"; Invoke-PolicyViewer -ConfigDir $configDir | Out-Null }
        'backup-create'  { Write-SetupDebugLog -Message "Executing action: backup-create"; & "$PSScriptRoot/certificate-backup.ps1" -OutputPath (Join-Path $PSScriptRoot ("certificate-{0}.certbak" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) }
        'backup-restore' {
            $path = Read-Host 'Backup path'
            if ($path) { & "$PSScriptRoot/certificate-restore.ps1" -BackupPath $path }
        }
        'backup-verify'  {
            $path = Read-Host 'Backup path'
            if ($path) { & "$PSScriptRoot/certificate-restore.ps1" -BackupPath $path -DryRun }
        }
        'java_keystore_info'             {
            Show-TuiStatus -Message 'Java KeyStore connector is disabled: requires JDK/keytool.exe.' -Type Warning -Row ([Console]::WindowHeight-2)
            Start-Sleep -Milliseconds 1800
        }
        'vbr_cloud_gateway_info'         {
            Show-TuiStatus -Message 'Veeam VBR connector is disabled: requires VBR PowerShell module.' -Type Warning -Row ([Console]::WindowHeight-2)
            Start-Sleep -Milliseconds 1800
        }
        'azure_application_gateway_info' {
            Show-TuiStatus -Message 'Azure Application Gateway connector is disabled: requires AzureRM module.' -Type Warning -Row ([Console]::WindowHeight-2)
            Start-Sleep -Milliseconds 1800
        }
        'azure_ad_app_proxy_info'        {
            Show-TuiStatus -Message 'Azure AD App Proxy connector is disabled: requires AzureAD module.' -Type Warning -Row ([Console]::WindowHeight-2)
            Start-Sleep -Milliseconds 1800
        }
        default          {
            Show-TuiStatus -Message "No action implemented for '$selected'." -Type Warning -Row ([Console]::WindowHeight-2)
            Start-Sleep -Milliseconds 1200
        }
    }
    Clear-TuiScreen
}

Stop-SetupDebugLogging
