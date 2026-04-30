param(
    [Parameter(Position=0, Mandatory=$true)][string]$NewCertThumbprint,
    [Parameter(Position=1, Mandatory=$true)][string]$PfxPath,
    [Parameter(Position=2, Mandatory=$true)][System.Security.SecureString]$PfxPassword
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'core\connector-core.psm1') -Force
$normalizedThumbprint = Assert-CertThumbprint -Thumbprint $NewCertThumbprint
$cert = Get-CertificateByThumbprint -Thumbprint $normalizedThumbprint -PrimaryStorePath 'Cert:\LocalMachine\My'
if ($null -eq $cert) {
    if (-not (Test-Path -LiteralPath $PfxPath)) { Write-Error 'PFX file not found.'; exit 1 }
    Import-PfxCertificate -FilePath $PfxPath -Password $PfxPassword -CertStoreLocation 'Cert:\LocalMachine\My' -Exportable | Out-Null
    $cert = Get-CertificateByThumbprint -Thumbprint $normalizedThumbprint -PrimaryStorePath 'Cert:\LocalMachine\My'
    if ($null -eq $cert) { Write-Error 'Certificate not found after import.'; exit 1 }
}
$bound=$false
try { $rdpSettings = Get-WmiObject -Class 'Win32_TSGeneralSetting' -Namespace 'root\cimv2\terminalservices' -Filter "TerminalName='RDP-Tcp'"; if($rdpSettings){ $rdpSettings.SSLCertificateSHA1Hash=$normalizedThumbprint; $rdpSettings.Put()|Out-Null; $bound=$true } } catch {}
if (Get-Command -Name Set-RDCertificate -ErrorAction SilentlyContinue) { try { Set-RDCertificate -Role RDRedirector -Thumbprint $normalizedThumbprint -Force -ErrorAction Stop; $bound=$true } catch {} }
if (-not $bound) { Write-Error 'No applicable RDS binding succeeded.'; exit 1 }
exit 0
