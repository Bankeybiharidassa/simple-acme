#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position=0,Mandatory=$true)][Alias('NewCertThumbprint')][ValidateNotNullOrEmpty()][string]$CertThumbprint,
    [string]$CachePassword = '',
    [string]$CacheFile = '',
    [string]$PfxStorePath = '',
    [string]$PfxPassword = '',
    [string]$SessionHosts = '',
    [string]$RemoteTempDirectory = 'C:\Windows\Temp\simple-acme-rds',
    [switch]$SkipLocalRdsBinding,
    [switch]$SkipSessionHosts
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'core\connector-core.psm1') -Force
function Write-DeployLog { param([string]$Action,[string]$Target,[string]$Result,[hashtable]$Details=@{}) Write-ConnectorLog -Component 'deploy-rds-farm' -Action $Action -Target $Target -Result $Result -Details $Details -EmitConsole }
function Normalize-Thumbprint { param([string]$Thumbprint) (($Thumbprint -replace '\s','').ToUpperInvariant()) }
function Resolve-HostsFromTargets {
  $installRoot = Split-Path $PSScriptRoot -Parent
  $targetsPath = Join-Path $installRoot 'deployment-targets.json'
  if (-not (Test-Path -LiteralPath $targetsPath)) { return @() }
  $targets = Get-Content -LiteralPath $targetsPath -Raw | ConvertFrom-Json
  return @($targets.sessionHosts | Where-Object { $_.enabled -eq $true } | ForEach-Object { [string]$_.computerName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
$normalized = Normalize-Thumbprint $CertThumbprint
if (-not $SkipLocalRdsBinding) {
  & (Join-Path $PSScriptRoot 'cert2rds.ps1') $normalized
  if ($LASTEXITCODE -ne 0) { throw "Local RDS gateway deployment failed (exit $LASTEXITCODE)." }
}
if ($SkipSessionHosts) { exit 0 }
$hosts = @()
if (-not [string]::IsNullOrWhiteSpace($SessionHosts)) { $hosts = @($SessionHosts.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) }
if ($hosts.Count -eq 0) { $hosts = Resolve-HostsFromTargets }
if ($hosts.Count -eq 0) { throw 'No session hosts provided. Pass -SessionHosts or configure deployment-targets.json.' }
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
if ([string]::IsNullOrWhiteSpace($plainPassword)) { throw 'No PFX password available. Provide -CachePassword or -PfxPassword.' }
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
