#Requires -Version 5.1
param(
  [Parameter(Position=0, Mandatory=$true)][ValidateNotNullOrEmpty()][string]$NewCertThumbprint,
  [Parameter(Mandatory=$false)][System.Management.Automation.PSCredential]$SessionCredential,
  [Parameter(Mandatory=$false)][string]$SessionCredentialFile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'core\connector-core.psm1') -Force
function Write-DeployLog {
  param([string]$Action,[string]$Target,[string]$Result,[hashtable]$Details=@{})
  Write-ConnectorLog -Component 'deploy-rds-farm' -Action $Action -Target $Target -Result $Result -Details $Details -EmitConsole
}
if ($null -eq $SessionCredential -and -not [string]::IsNullOrWhiteSpace($SessionCredentialFile)) {
  if (-not (Test-Path -LiteralPath $SessionCredentialFile)) { Write-Error "SessionCredentialFile not found: $SessionCredentialFile"; exit 1 }
  $SessionCredential = Import-Clixml -LiteralPath $SessionCredentialFile
}
$installRoot = Split-Path $PSScriptRoot -Parent
$targetsPath = Join-Path $installRoot 'deployment-targets.json'
if (-not (Test-Path -LiteralPath $targetsPath)) { Write-Error "deployment-targets.json not found: $targetsPath"; exit 1 }
$targets = Get-Content -LiteralPath $targetsPath -Raw | ConvertFrom-Json
$normalized = Assert-CertThumbprint -CertThumbprint $NewCertThumbprint
$found = Get-CertificateByThumbprint -Thumbprint $normalized
if ($null -eq $found -or $null -eq $found.Certificate) { Write-Error "Certificate $normalized not found in store."; exit 1 }
$cert = $found.Certificate
if ($null -eq $cert.PrivateKey) { Write-Error 'Certificate has no private key.'; exit 1 }
try { $null = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx) } catch { Write-Error "Private key is not exportable: $($_.Exception.Message)"; exit 1 }
& (Join-Path $PSScriptRoot 'cert2rds.ps1') $normalized; if ($LASTEXITCODE -ne 0) { Write-Error "Local RDS gateway deployment failed (exit $LASTEXITCODE)."; exit 1 }
$runtimeDir = Join-Path $installRoot 'runtime'; if (-not (Test-Path -LiteralPath $runtimeDir)) { New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null }
Add-Type -AssemblyName System.Web
$plainPassword = [System.Web.Security.Membership]::GeneratePassword(32,8)
$securePassword = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
$pfxBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $securePassword)
$pfxName = 'farm-{0}-{1}.pfx' -f $normalized.Substring(0,8),([System.IO.Path]::GetRandomFileName().Replace('.',''))
$localPfxPath = Join-Path $runtimeDir $pfxName; [System.IO.File]::WriteAllBytes($localPfxPath,$pfxBytes); $pfxBytes=$null
$failed=$false
if ($null -eq $SessionCredential) {
  Write-Error 'SessionCredential or SessionCredentialFile is required for unattended operation.'
  exit 1
}
foreach($host in @($targets.sessionHosts | Where-Object { $_.enabled -eq $true })){
  $session=$null; $reason=''
  try { $session=New-PSSession -ComputerName $host.computerName -Credential $SessionCredential -Authentication Negotiate -ErrorAction Stop } catch { $session=$null; $reason=$_.Exception.Message }
  if ($null -eq $session) { if([string]::IsNullOrWhiteSpace($reason)){$reason='cannot connect'}; Write-DeployLog -Action 'session-connect' -Target $host.computerName -Result 'fail' -Details @{ reason = $reason }; $failed=$true; continue }
  try {
    Invoke-Command -Session $session -ScriptBlock { param($p) New-Item -ItemType Directory -Path $p -Force | Out-Null } -ArgumentList $targets.pfxDistribution.remoteTempDirectory
    $remotePfxPath = Join-Path $targets.pfxDistribution.remoteTempDirectory $pfxName
    try { Copy-Item -Path $localPfxPath -ToSession $session -Destination $remotePfxPath -Force } catch { $bytes=[System.IO.File]::ReadAllBytes($localPfxPath); Invoke-Command -Session $session -ScriptBlock { param($b,$p) [System.IO.File]::WriteAllBytes($p,$b)} -ArgumentList $bytes,$remotePfxPath; $bytes=$null }
    Invoke-Command -Session $session -FilePath (Join-Path $PSScriptRoot 'deploy-rds-sessionhost.ps1') -ArgumentList $normalized,$remotePfxPath,$plainPassword
    if ($targets.pfxDistribution.deleteRemotePfxAfterImport) { try { Invoke-Command -Session $session -ScriptBlock { param($p) Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } -ArgumentList $remotePfxPath } catch { Write-Warning "Remote PFX cleanup failed on $($host.computerName)" } }
    Write-DeployLog -Action 'deploy' -Target $host.computerName -Result 'success' -Details @{ thumbprint = $normalized }
  } catch { Write-DeployLog -Action 'deploy' -Target $host.computerName -Result 'fail' -Details @{ error = $_.Exception.Message }; $failed=$true } finally { Remove-PSSession $session }
}
$plainPassword = $null
if ($targets.pfxDistribution.deleteLocalPfxAfterImport) { try { Remove-Item -LiteralPath $localPfxPath -Force -ErrorAction SilentlyContinue } catch { Write-Warning "Local PFX cleanup failed: $localPfxPath" } }
if ($failed) { exit 1 } else { exit 0 }
