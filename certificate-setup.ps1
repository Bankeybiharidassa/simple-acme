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
    [Console]::WriteLine("Setup debug file log: $script:SetupLogPath")
    if ($script:SetupTranscriptEnabled) {
        [Console]::WriteLine("Setup transcript log: $script:SetupTranscriptPath")
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
    Add-Content -LiteralPath $script:SetupLogPath -Value $line -Encoding UTF8
}

Initialize-SetupDebugLogging
Write-SetupDebugLog -Message "certificate-setup.ps1 started. ScriptRoot='$PSScriptRoot'"

$tuiEngineModulePath = Join-Path $PSScriptRoot 'core/Tui-Engine.psm1'
$formRunnerModulePath = Join-Path $PSScriptRoot 'setup/Form-Runner.psm1'
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
Assert-SetupCommandAvailable -CommandName 'Show-SimpleAcmeDiagnosticSummary' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Wait-ForOperatorReturn' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
Assert-SetupCommandAvailable -CommandName 'Assert-ProviderDirectoryConsistency' -ExpectedModulePath $formRunnerModulePath -ModuleInfo $formRunnerModule
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

function Invoke-InitialAcmeReconcilePrompt {
    param(
        [Parameter(Mandatory)][string]$RootDir,
        [Parameter(Mandatory)][string]$EnvFilePath
    )

    $envValues = Import-EnvFile -Path $EnvFilePath -Force

    try {
        Assert-ProviderDirectoryConsistency -Values $envValues
    } catch {
        [Console]::WriteLine('')
        [Console]::WriteLine($_.Exception.Message)
        Wait-ForOperatorReturn
        return
    }

    [Console]::WriteLine('')
    [Console]::WriteLine('Issuance ACME directory:')
    [Console]::WriteLine([string]$envValues.ACME_DIRECTORY)
    [Console]::WriteLine('')
    [Console]::WriteLine('Effective wacs command preview:')
    $scriptParameters = if ($envValues.ContainsKey('ACME_SCRIPT_PARAMETERS')) { [string]$envValues.ACME_SCRIPT_PARAMETERS } else { '{CertThumbprint}' }
    $storePlugin = if ($envValues.ContainsKey('ACME_STORE_PLUGIN')) { [string]$envValues.ACME_STORE_PLUGIN } else { 'certificatestore' }
    $csrAlgo = if ($envValues.ContainsKey('ACME_CSR_ALGORITHM')) { [string]$envValues.ACME_CSR_ALGORITHM } else { 'ec' }
    $commandPreview = ('wacs.exe --accepttos --source manual --order single --baseuri {0} --validation none --globalvalidation none --host {1} --store {2} --installation script --script {3} --scriptparameters "{4}" --csr {5}' -f [string]$envValues.ACME_DIRECTORY, [string]$envValues.DOMAINS, $storePlugin, [string]$envValues.ACME_SCRIPT_PATH, $scriptParameters, $csrAlgo)
    [Console]::WriteLine($commandPreview)
    if (-not [string]::IsNullOrWhiteSpace([string]$envValues.ACME_KID)) { [Console]::WriteLine('--eab-key-identifier <set>') }
    if (-not [string]::IsNullOrWhiteSpace([string]$envValues.ACME_HMAC_SECRET)) { [Console]::WriteLine('--eab-key <hidden>') }
    [Console]::WriteLine('')

    [Console]::WriteLine('')
    $answer = [string](Read-Host 'Run initial ACME reconcile now? [Y/N]')
    if ($answer.Trim().ToLowerInvariant() -notin @('y','yes')) {
        [Console]::WriteLine('')
        [Console]::WriteLine('Skipped ACME reconcile. Run certificate-simple-acme-reconcile.ps1 later to bootstrap issuance.')
        Wait-ForOperatorReturn
        return
    }

    try {
        Import-Module (Join-Path $RootDir 'core/Simple-Acme-Reconciler.psm1') -Force | Out-Null
        $action = Invoke-SimpleAcmeReconcile -EnvValues $envValues
        [Console]::WriteLine('')
        [Console]::WriteLine("ACME reconcile completed successfully (action=$action).")
        if ([Environment]::GetEnvironmentVariable('CERTIFICATE_VERBOSE_DIAGNOSTICS') -eq '1') {
            Write-ReconcileDiagnostics -Context 'simple-acme diagnostics'
        }
        Invoke-PostSetupValidation -RootDir $RootDir -EnvValues $envValues
    } catch {
        [Console]::WriteLine('')
        [Console]::WriteLine('ACME reconcile failed: ' + $_.Exception.Message)
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
        $domains = Get-NormalizedDomains -Domains ([string]$EnvValues.DOMAINS)
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
    try {
        $envValues = Import-EnvFile -Path (Resolve-BootstrapEnvPath -ProjectRoot $RootDir) -Force
        $taskName = if (-not [string]::IsNullOrWhiteSpace([string]$envValues.CERTIFICATE_TASK_NAME)) { [string]$envValues.CERTIFICATE_TASK_NAME } else { 'Certificate-Orchestrator' }
        $interval = 5
        if (-not [string]::IsNullOrWhiteSpace([string]$envValues.CERTIFICATE_TASK_INTERVAL_MINUTES)) {
            if (-not [int]::TryParse([string]$envValues.CERTIFICATE_TASK_INTERVAL_MINUTES, [ref]$interval)) {
                throw "CERTIFICATE_TASK_INTERVAL_MINUTES must be an integer. Value: '$($envValues.CERTIFICATE_TASK_INTERVAL_MINUTES)'"
            }
        }
        $taskUser = if (-not [string]::IsNullOrWhiteSpace([string]$envValues.CERTIFICATE_TASK_USER)) { [string]$envValues.CERTIFICATE_TASK_USER } else { 'SYSTEM' }
        $psExe = if (-not [string]::IsNullOrWhiteSpace([string]$envValues.CERTIFICATE_TASK_POWERSHELL)) { [string]$envValues.CERTIFICATE_TASK_POWERSHELL } else { 'powershell.exe' }
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
            $result = Invoke-AcmeForm -EnvFilePath $envPath
            if ($null -ne $result) {
                Invoke-InitialAcmeReconcilePrompt -RootDir $PSScriptRoot -EnvFilePath $envPath
            }
        }
        'manage-certs'   { Invoke-ManageCertificatesMenu -ConfigDir $configDir }
        'acme'           {
            Write-SetupDebugLog -Message "Executing action: acme"
            Invoke-AcmeSettingsMenu -EnvFilePath $envPath
        }
        'logs-diagnostics' { Write-SetupDebugLog -Message "Executing action: logs-diagnostics"; Invoke-ViewLogsDiagnostics -ProjectRoot $PSScriptRoot }
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
