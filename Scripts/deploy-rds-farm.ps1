#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position=0,Mandatory=$true)][Alias('NewCertThumbprint')][ValidateNotNullOrEmpty()][string]$CertThumbprint,
    [string]$CachePassword = '',
    [string]$CacheFile = '',
    [string]$PfxStorePath = '',
    [string]$PfxPassword = '',
    [string]$SessionHosts = '',
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
$normalized = Normalize-Thumbprint $CertThumbprint
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
$failed=$false
foreach($hostName in $hosts){
  $session=$null
  try { $session=New-PSSession -ComputerName $hostName -Authentication Negotiate -ErrorAction Stop } catch { Write-DeployLog -Action 'session-connect' -Target $hostName -Result 'fail' -Details @{ reason = $_.Exception.Message }; $failed=$true; continue }
  try {
    Invoke-Command -Session $session -ScriptBlock { param($p) New-Item -ItemType Directory -Path $p -Force | Out-Null } -ArgumentList $RemoteTempDirectory
    $remotePfxPath = Join-Path $RemoteTempDirectory ([System.IO.Path]::GetFileName($pfxPath))
    Copy-Item -LiteralPath $pfxPath -ToSession $session -Destination $remotePfxPath -Force
    Invoke-Command -Session $session -FilePath (Join-Path $PSScriptRoot 'deploy-rds-sessionhost.ps1') -ArgumentList $normalized,$remotePfxPath,$plainPassword
    Write-DeployLog -Action 'deploy' -Target $hostName -Result 'success' -Details @{ thumbprint = $normalized }
  } catch { Write-DeployLog -Action 'deploy' -Target $hostName -Result 'fail' -Details @{ error = $_.Exception.Message }; $failed=$true } finally { if ($session) { Remove-PSSession $session } }
}
if ($failed) { exit 1 } else { exit 0 }
