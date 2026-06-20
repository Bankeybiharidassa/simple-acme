#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position=0,Mandatory=$true)][Alias('NewCertThumbprint')][ValidateNotNullOrEmpty()][string]$CertThumbprint,
    [string]$CachePassword = '',
    [string]$CacheFile = '',
    [string]$PfxStorePath = '',
    [string]$PfxPassword = '',
    [string]$SessionHosts = '',
    [pscredential]$SessionCredential = $null,
    [string]$RemoteTempDirectory = '',
    [string]$ConfigFile = '',
    [switch]$SkipLocalRdsBinding,
    [switch]$SkipSessionHosts
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'core\connector-core.psm1') -Force
function Write-DeployLog { param([string]$Action,[string]$Target,[string]$Result,[hashtable]$Details=@{}) Write-ConnectorLog -Component 'deploy-rds-farm' -Action $Action -Target $Target -Result $Result -Details $Details -EmitConsole }
function Normalize-Thumbprint { param([string]$Thumbprint) (($Thumbprint -replace '\s','').ToUpperInvariant()) }

function Assert-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run elevated as Administrator or as the scheduled task SYSTEM account.'
  }
}

function Assert-FileReadable {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "PFX/cache file not found: $Path" }
  $item = Get-Item -LiteralPath $Path
  if ($item.Length -lt 1024) { throw "PFX/cache file is unexpectedly small: $Path ($($item.Length) bytes)" }
}

function Resolve-DeploymentSecret {
  param([hashtable]$Config,[string]$PlainKey,[string]$ReferenceKey)
  $plainKeyName = $PlainKey.ToUpperInvariant()
  if ($Config.ContainsKey($plainKeyName) -and -not [string]::IsNullOrWhiteSpace([string]$Config[$plainKeyName])) { return [string]$Config[$plainKeyName] }
  $referenceKeyName = $ReferenceKey.ToUpperInvariant()
  if (-not $Config.ContainsKey($referenceKeyName) -or [string]::IsNullOrWhiteSpace([string]$Config[$referenceKeyName])) { return '' }
  $secretName = [string]$Config[$referenceKeyName]
  $configDir = Resolve-ConnectorConfigValue -Config $Config -Keys @('CERTIFICATE_CONFIG_DIR','CONFIG_DIR')
  if ([string]::IsNullOrWhiteSpace($configDir)) { throw "Deployment config references secret '$secretName' but CERTIFICATE_CONFIG_DIR is empty." }
  $credentialPath = Join-Path $configDir 'credentials.sec'
  if (-not (Test-Path -LiteralPath $credentialPath)) { throw "Deployment config references secret '$secretName' but credentials.sec was not found at '$credentialPath'. Re-run setup to save secure credentials." }
  Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'core\Crypto.psm1') -Force
  $credentialMap = Get-Content -LiteralPath $credentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $property = $credentialMap.PSObject.Properties[$secretName]
  if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { throw "Secret '$secretName' was not found in '$credentialPath'. Re-run setup or rotate the PFX password." }
  return (Unprotect-DpapiValue -CiphertextBase64 ([string]$property.Value) -Scope LocalMachine)
}
function ConvertTo-HostList {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
  $trimmed = $Value.Trim()
  if ($trimmed.StartsWith('[')) {
    try { return @($trimmed | ConvertFrom-Json | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique) }
    catch { throw "HOSTS in deployment config must be CSV or a JSON string array. $($_.Exception.Message)" }
  }
  return @($Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
}
function Resolve-HostsFromTargets {
  $installRoot = Split-Path $PSScriptRoot -Parent
  $targetsPath = Join-Path $installRoot 'deployment-targets.json'
  if (-not (Test-Path -LiteralPath $targetsPath)) { return @() }
  $targets = Get-Content -LiteralPath $targetsPath -Raw | ConvertFrom-Json
  return @($targets.sessionHosts | Where-Object { $_.enabled -eq $true } | ForEach-Object { [string]$_.computerName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
function Invoke-LocalRdsBinding {
  param([Parameter(Mandatory)][string]$Thumbprint)

  $scriptPath = Join-Path $PSScriptRoot 'cert2rds.ps1'
  if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Local RDS binding script not found: $scriptPath" }

  $stdoutPath = Join-Path $env:TEMP ("simple-acme-rds-local-{0}.out.log" -f ([guid]::NewGuid().ToString('N')))
  $stderrPath = Join-Path $env:TEMP ("simple-acme-rds-local-{0}.err.log" -f ([guid]::NewGuid().ToString('N')))
  try {
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-CertThumbprint',$Thumbprint) -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { @(Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue) } else { @() }
    $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { @(Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue) } else { @() }
    $details = @{ thumbprint = $Thumbprint; exitCode = $process.ExitCode; stdoutTail = @($stdout | Select-Object -Last 20); stderrTail = @($stderr | Select-Object -Last 20) }
    if ($process.ExitCode -ne 0) {
      Write-DeployLog -Action 'local-rds-binding' -Target 'localhost' -Result 'fail' -Details $details
      $summary = @($details.stderrTail + $details.stdoutTail) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 8
      if ($summary.Count -gt 0) {
        throw "Local RDS binding failed with exit code $($process.ExitCode). Last output: $($summary -join ' | ')"
      }
      throw "Local RDS binding failed with exit code $($process.ExitCode). No child output was captured."
    }
  }
  finally {
    Remove-Item -LiteralPath $stdoutPath,$stderrPath -Force -ErrorAction SilentlyContinue
  }
  Write-DeployLog -Action 'local-rds-binding' -Target 'localhost' -Result 'success' -Details @{ thumbprint = $Thumbprint }
}
$normalized = Normalize-Thumbprint $CertThumbprint
if (-not $SkipLocalRdsBinding) {
  Invoke-LocalRdsBinding -Thumbprint $normalized
}
if ($SkipSessionHosts) { exit 0 }
$config = Read-ConnectorDeploymentConfigFile -Path $ConfigFile
if (-not $PSBoundParameters.ContainsKey('SessionHosts')) { $SessionHosts = Resolve-ConnectorConfigValue -Config $config -Keys @('HOSTS','SESSION_HOSTS') -Fallback $SessionHosts }
if (-not $PSBoundParameters.ContainsKey('PfxStorePath')) { $PfxStorePath = Resolve-ConnectorConfigValue -Config $config -Keys @('PFX_STORE_PATH','PFXSTOREPATH') -Fallback $PfxStorePath }
if (-not $PSBoundParameters.ContainsKey('PfxPassword')) { $PfxPassword = Resolve-DeploymentSecret -Config $config -PlainKey 'PFX_PASSWORD' -ReferenceKey 'PFX_PASSWORD_REF' }
if (-not $PSBoundParameters.ContainsKey('RemoteTempDirectory')) { $RemoteTempDirectory = Resolve-ConnectorConfigValue -Config $config -Keys @('REMOTE_TEMP_DIRECTORY','REMOTE_TEMP_DIR') -Fallback $RemoteTempDirectory }
if ([string]::IsNullOrWhiteSpace($RemoteTempDirectory)) { $RemoteTempDirectory = 'C:\Windows\Temp\simple-acme-rds' }
$hosts = ConvertTo-HostList -Value $SessionHosts
if ($hosts.Count -eq 0) { $hosts = Resolve-HostsFromTargets }
if ($hosts.Count -eq 0) { throw 'No session hosts provided. Pass -SessionHosts, set HOSTS in -ConfigFile, or configure deployment-targets.json.' }
if (-not [string]::IsNullOrWhiteSpace($PfxStorePath) -and -not (Test-Path -LiteralPath $PfxStorePath)) { New-Item -ItemType Directory -Path $PfxStorePath -Force | Out-Null }
$pfxPath = $CacheFile
$plainPassword = $CachePassword
if ([string]::IsNullOrWhiteSpace($pfxPath) -or -not (Test-Path -LiteralPath $pfxPath)) {
  if ([string]::IsNullOrWhiteSpace($PfxStorePath)) { $PfxStorePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime' }
  $candidate = Get-ChildItem -LiteralPath $PfxStorePath -Filter '*.pfx' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  if ($null -eq $candidate) { throw 'No PFX available. Provide -CacheFile from wacs or ensure -PfxStorePath has a .pfx file.' }
  $pfxPath = $candidate.FullName
  if ([string]::IsNullOrWhiteSpace($plainPassword)) { $plainPassword = $PfxPassword }
}
if ([string]::IsNullOrWhiteSpace($plainPassword)) { throw 'No PFX password available. Provide -CachePassword, -PfxPassword, or PFX_PASSWORD in -ConfigFile.' }
Assert-Admin
Assert-FileReadable -Path $pfxPath
$failed=$false
foreach($hostName in $hosts){
  $session=$null
  try {
    $sessionArgs = @{ ComputerName = $hostName; Authentication = 'Negotiate'; ErrorAction = 'Stop' }
    if ($null -ne $SessionCredential) { $sessionArgs.Credential = $SessionCredential }
    $session=New-PSSession @sessionArgs
  } catch { Write-DeployLog -Action 'session-connect' -Target $hostName -Result 'fail' -Details @{ reason = $_.Exception.Message }; $failed=$true; continue }
  try {
    Invoke-Command -Session $session -ScriptBlock { param($p) New-Item -ItemType Directory -Path $p -Force | Out-Null } -ArgumentList $RemoteTempDirectory
    $remotePfxPath = Join-Path $RemoteTempDirectory ("rds-cert-{0}.pfx" -f ([guid]::NewGuid().ToString('N')))
    Copy-Item -LiteralPath $pfxPath -ToSession $session -Destination $remotePfxPath -Force
    Invoke-Command -Session $session -FilePath (Join-Path $PSScriptRoot 'deploy-rds-sessionhost.ps1') -ArgumentList $normalized,$remotePfxPath,$plainPassword
    Write-DeployLog -Action 'deploy' -Target $hostName -Result 'success' -Details @{ thumbprint = $normalized }
  } catch { Write-DeployLog -Action 'deploy' -Target $hostName -Result 'fail' -Details @{ error = $_.Exception.Message }; $failed=$true } finally { if ($session) { Remove-PSSession $session } }
}
if ($failed) { exit 1 } else { exit 0 }
