[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateNotNullOrEmpty()]
    [string]$CertThumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'core/connector-core.psm1') -Force

function Normalize-Thumbprint([string]$Value) {
    return (($Value -replace '\s','').ToUpperInvariant())
}

function Find-CertificateByThumbprint {
    param([string]$Thumbprint)
    $normalized = Normalize-Thumbprint $Thumbprint
    foreach ($store in @('Cert:\LocalMachine\My','Cert:\LocalMachine\WebHosting')) {
        $cert = Get-ChildItem -Path $store -ErrorAction SilentlyContinue | Where-Object {
            (Normalize-Thumbprint $_.Thumbprint) -eq $normalized
        } | Select-Object -First 1
        if ($null -ne $cert) {
            return [pscustomobject]@{ Cert = $cert; Store = $store }
        }
    }
    return $null
}

try {
    $found = Find-CertificateByThumbprint -Thumbprint $CertThumbprint
    if ($null -eq $found) {
        throw "Certificate with thumbprint '$CertThumbprint' not found in LocalMachine\\My or LocalMachine\\WebHosting."
    }

    $normalized = Assert-CertThumbprint -CertThumbprint $CertThumbprint
    if ($found.Store -eq 'Cert:\LocalMachine\WebHosting') {
        Write-Host "Certificate found in WebHosting store, copying to LocalMachine\\My."
        $dest = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue | Where-Object {
            (Normalize-Thumbprint $_.Thumbprint) -eq $normalized
        } | Select-Object -First 1

        if ($null -eq $dest) {
            $raw = $found.Cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            $tmp = Join-Path $env:TEMP ("cert2rds-{0}.cer" -f [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllBytes($tmp, $raw)
            try {
                Import-Certificate -FilePath $tmp -CertStoreLocation 'Cert:\LocalMachine\My' -ErrorAction Stop | Out-Null
            }
            finally {
                Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            }
        }
    }

    foreach ($role in @('RDGateway','RDWebAccess','RDPublishing','RDRedirector')) {
        Set-RDCertificate -Role $role -Thumbprint $normalized -Force -ErrorAction Stop
    }

    Write-Host "RDS certificate binding updated for thumbprint $normalized"
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
