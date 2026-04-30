#Requires -Version 5.1
param([Parameter(Position=0, Mandatory=$true)][ValidateNotNullOrEmpty()][string]$NewCertThumbprint)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'core\connector-core.psm1') -Force
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
$securePassword = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force; $plainPassword=$null
$pfxBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $securePassword)
$pfxName = 'farm-{0}-{1}.pfx' -f $normalized.Substring(0,8),([System.IO.Path]::GetRandomFileName().Replace('.',''))
$localPfxPath = Join-Path $runtimeDir $pfxName; [System.IO.File]::WriteAllBytes($localPfxPath,$pfxBytes); $pfxBytes=$null
$failed=$false
foreach($host in @($targets.sessionHosts | Where-Object { $_.enabled -eq $true })){
  $session=$null; $reason=''
  try { $session=New-PSSession -ComputerName $host.computerName -Authentication Negotiate -ErrorAction Stop } catch { $session=$null }
  if ($null -eq $session -and -not [string]::IsNullOrWhiteSpace([string]$host.username)) { try { $cred=Get-Credential -UserName $host.username -Message "Password for $($host.computerName)"; if($null -eq $cred){$reason='credential prompt cancelled'} else { $session=New-PSSession -ComputerName $host.computerName -Credential $cred -ErrorAction Stop } } catch { $reason=$_.Exception.Message } }
  if ($null -eq $session) { if([string]::IsNullOrWhiteSpace($reason)){$reason='cannot connect'}; Write-Host "FAILED: $($host.computerName) — $reason"; $failed=$true; continue }
  try {
    Invoke-Command -Session $session -ScriptBlock { param($p) New-Item -ItemType Directory -Path $p -Force | Out-Null } -ArgumentList $targets.pfxDistribution.remoteTempDirectory
    $remotePfxPath = Join-Path $targets.pfxDistribution.remoteTempDirectory $pfxName
    try { Copy-Item -Path $localPfxPath -ToSession $session -Destination $remotePfxPath -Force } catch { $bytes=[System.IO.File]::ReadAllBytes($localPfxPath); Invoke-Command -Session $session -ScriptBlock { param($b,$p) [System.IO.File]::WriteAllBytes($p,$b)} -ArgumentList $bytes,$remotePfxPath; $bytes=$null }
    Invoke-Command -Session $session -FilePath (Join-Path $PSScriptRoot 'deploy-rds-sessionhost.ps1') -ArgumentList $normalized,$remotePfxPath,$securePassword
    if ($targets.pfxDistribution.deleteRemotePfxAfterImport) { try { Invoke-Command -Session $session -ScriptBlock { param($p) Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } -ArgumentList $remotePfxPath } catch { Write-Warning "Remote PFX cleanup failed on $($host.computerName)" } }
    Write-Host "OK: $($host.computerName)"
  } catch { Write-Host "FAILED: $($host.computerName) — $($_.Exception.Message)"; $failed=$true } finally { Remove-PSSession $session }
}
if ($targets.pfxDistribution.deleteLocalPfxAfterImport) { try { Remove-Item -LiteralPath $localPfxPath -Force -ErrorAction SilentlyContinue } catch { Write-Warning "Local PFX cleanup failed: $localPfxPath" } }
if ($failed) { exit 1 } else { exit 0 }
