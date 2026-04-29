[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateNotNullOrEmpty()]
    [string]$CertThumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'core/connector-core.psm1') -Force

try {
    $normalizedThumbprint = Assert-CertThumbprint -CertThumbprint $CertThumbprint
    $found = Get-CertificateByThumbprint -Thumbprint $normalizedThumbprint
    $normalized = Ensure-CertificateInMyStore -Certificate $found.Certificate -StorePath $found.StorePath

    foreach ($role in @('RDGateway','RDWebAccess','RDPublishing','RDRedirector')) {
        Set-RDCertificate -Role $role -Thumbprint $normalized.Certificate.Thumbprint -Force -ErrorAction Stop
    }

    Write-Host "RDS certificate binding updated for thumbprint $($normalized.Certificate.Thumbprint)"
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
