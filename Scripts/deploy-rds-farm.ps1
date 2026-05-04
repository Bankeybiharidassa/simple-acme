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
if (-not $cert.HasPrivateKey) { Write-Error 'Certificate has no private key.'; exit 1 }
$keyIsExportable = $false
try { $null = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx); $keyIsExportable = $true } catch { }
& (Join-Path $PSScriptRoot 'cert2rds.ps1') $normalized; if ($LASTEXITCODE -ne 0) { Write-Error "Local RDS gateway deployment failed (exit $LASTEXITCODE)."; exit 1 }
$runtimeDir = Join-Path $installRoot 'runtime'; if (-not (Test-Path -LiteralPath $runtimeDir)) { New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null }
Add-Type -AssemblyName System.Web
$plainPassword = [System.Web.Security.Membership]::GeneratePassword(32,8)
$securePassword = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
$pfxName = 'farm-{0}-{1}.pfx' -f $normalized.Substring(0,8),([System.IO.Path]::GetRandomFileName().Replace('.',''))
$localPfxPath = Join-Path $runtimeDir $pfxName
if ($keyIsExportable) {
  $pfxBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $securePassword)
  [System.IO.File]::WriteAllBytes($localPfxPath, $pfxBytes); $pfxBytes = $null
} else {
  # WACS 2.3.6 may leave the cert store key non-exportable when replacing an existing cert
  # even when PrivateKeyExportable=true in settings.json. Fall back to the WACS-produced PFX
  # file (written by the pfxfile store step with no password).
  $pfxSearchRoots = @((Join-Path $env:ProgramData 'simple-acme'), (Join-Path $env:ProgramData 'win-acme'))
  $sourcePfx = $null
  foreach ($root in $pfxSearchRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $candidates = @(Get-ChildItem -Path $root -Filter '*.pfx' -Recurse -ErrorAction SilentlyContinue |
      Where-Object {
        try {
          $c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $_.FullName, '',
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
          $match = ($c.Thumbprint -eq $normalized); $c.Dispose(); $match
        } catch { $false }
      })
    if ($candidates.Count -gt 0) { $sourcePfx = $candidates[0].FullName; break }
  }
  if ($null -eq $sourcePfx) {
    Write-Error 'Private key is not exportable and no WACS-produced PFX file found for this thumbprint. Ensure ACME_PFX_FILE_PATH is set and the pfxfile store step ran successfully.'
    exit 1
  }
  Write-DeployLog -Action 'pfx-fallback' -Target $sourcePfx -Result 'info' -Details @{ reason = 'cert store key non-exportable; reading from WACS PFX' }
  $sourceCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
    $sourcePfx, '',
    ([System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
     [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet))
  $pfxBytes = $sourceCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $securePassword)
  $sourceCert.Dispose()
  [System.IO.File]::WriteAllBytes($localPfxPath, $pfxBytes); $pfxBytes = $null
}
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
