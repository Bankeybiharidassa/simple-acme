#Requires -Version 5.1
param(
    [Parameter(Position=0, Mandatory=$true)][ValidateNotNullOrEmpty()][string]$NewCertThumbprint,
    [Parameter(Position=1, Mandatory=$true)][string]$PfxPath,
    [Parameter(Position=2, Mandatory=$true)][ValidateNotNullOrEmpty()][string]$PfxPasswordToken
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'core\connector-core.psm1') -Force
function Write-DeployLog {
    param([string]$Action,[string]$Target,[string]$Result,[hashtable]$Details=@{})
    Write-ConnectorLog -Component 'deploy-rds-sessionhost' -Action $Action -Target $Target -Result $Result -Details $Details -EmitConsole
}
$normalized = Assert-CertThumbprint -CertThumbprint $NewCertThumbprint
$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $normalized } | Select-Object -First 1
if ($null -eq $cert) {
    if (-not (Test-Path -LiteralPath $PfxPath)) { Write-Error "PFX not found: $PfxPath"; exit 1 }
    $pfxPassword = ConvertTo-SecureString -String $PfxPasswordToken -AsPlainText -Force
    Import-PfxCertificate -FilePath $PfxPath -Password $pfxPassword -CertStoreLocation 'Cert:\LocalMachine\My' -Exportable | Out-Null
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
Write-DeployLog -Action 'bind-rdp' -Target $env:COMPUTERNAME -Result 'success' -Details @{ thumbprint = $normalized }
exit 0
