[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateNotNullOrEmpty()]
    [string]$CertThumbprint,
    [string]$ConfigDir = $env:CERTIFICATE_CONFIG_DIR,
    [string]$RenewalId = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'core/connector-core.psm1') -Force

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'RDS certificate binding must run elevated as Administrator or as the scheduled task SYSTEM account.'
    }
}

function Import-RdsManagementModule {
    try {
        Import-Module RemoteDesktop -ErrorAction Stop
    }
    catch {
        throw "Could not import the RemoteDesktop PowerShell module. Install the RDS management tools or run this on the RDS management/gateway server. Details: $($_.Exception.Message)"
    }

    if (-not (Get-Command -Name Set-RDCertificate -ErrorAction SilentlyContinue)) {
        throw 'Set-RDCertificate was not found after importing RemoteDesktop. Install the RDS management tools or run on an RDS server.'
    }
}

try {
    Assert-Administrator
    Import-RdsManagementModule

    $normalizedThumbprint = Assert-CertThumbprint -CertThumbprint $CertThumbprint
    $found = Get-CertificateByThumbprint -Thumbprint $normalizedThumbprint
    $normalized = Ensure-CertificateInMyStore -Certificate $found.Certificate -StorePath $found.StorePath
    if (-not $normalized.Certificate.HasPrivateKey) {
        throw "Certificate '$($normalized.Certificate.Thumbprint)' exists in $($normalized.StorePath) but has no private key."
    }

    Write-Host "RDS certificate binding using certificate '$($normalized.Certificate.Subject)' thumbprint $($normalized.Certificate.Thumbprint) from $($normalized.StorePath)"

    foreach ($role in @('RDGateway','RDWebAccess','RDPublishing','RDRedirector')) {
        try {
            Write-Host "Binding RDS role $role to thumbprint $($normalized.Certificate.Thumbprint)"
            Set-RDCertificate -Role $role -Thumbprint $normalized.Certificate.Thumbprint -Force -ErrorAction Stop
            Write-Host "Bound RDS role $role"
        }
        catch {
            throw "RDS role binding failed for '$role' with thumbprint '$($normalized.Certificate.Thumbprint)'. Details: $($_.Exception.Message)"
        }
    }

    Write-Host "RDS certificate binding updated for thumbprint $($normalized.Certificate.Thumbprint)"
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
