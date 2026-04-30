#Requires -Version 5.1
param(
    [Parameter(Position=0, Mandatory=$true)][ValidateNotNullOrEmpty()][string]$NewCertThumbprint,
    [Parameter(Position=1, Mandatory=$true)][string]$PfxPath,
    [Parameter(Position=2, Mandatory=$true)][System.Security.SecureString]$PfxPassword
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'core\connector-core.psm1') -Force
$normalized = Assert-CertThumbprint -CertThumbprint $NewCertThumbprint
$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $normalized } | Select-Object -First 1
if ($null -eq $cert) {
    if (-not (Test-Path -LiteralPath $PfxPath)) { Write-Error "PFX not found: $PfxPath"; exit 1 }
    Import-PfxCertificate -FilePath $PfxPath -Password $PfxPassword -CertStoreLocation 'Cert:\LocalMachine\My' -Exportable | Out-Null
    $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $normalized } | Select-Object -First 1
    if ($null -eq $cert) { Write-Error 'Certificate not found after import.'; exit 1 }
}
$filter = "TerminalName='RDP-Tcp'"
$bound = $false
try { $rdp = Get-CimInstance -ClassName Win32_TSGeneralSetting -Namespace root\cimv2\terminalservices -Filter $filter -ErrorAction Stop; Set-CimInstance -InputObject $rdp -Property @{ SSLCertificateSHA1Hash = $normalized } -ErrorAction Stop; $bound=$true } catch {}
if (-not $bound) {
    $rdp = Get-WmiObject -Class Win32_TSGeneralSetting -Namespace root\cimv2\terminalservices -Filter $filter -ErrorAction SilentlyContinue
    if ($null -ne $rdp) { $rdp.SSLCertificateSHA1Hash = $normalized; $rdp.Put() | Out-Null; $bound=$true }
}
if (-not $bound) { Write-Error 'Could not bind certificate to RDP listener.'; exit 1 }
Write-Host "OK: certificate $normalized bound to RDP listener on $env:COMPUTERNAME"
exit 0
