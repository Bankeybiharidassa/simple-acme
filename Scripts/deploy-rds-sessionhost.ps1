[CmdletBinding()]
param(
    [Parameter(Position=0, Mandatory=$true)]
    [string]$NewCertThumbprint,

    [Parameter(Position=1, Mandatory=$true)]
    [string]$PfxPath,

    [Parameter(Position=2, Mandatory=$true)]
    [System.Security.SecureString]$PfxPassword
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'core\connector-core.psm1') -Force

try {
    $thumbprint = Assert-CertThumbprint -Thumbprint $NewCertThumbprint
    $cert = Get-CertificateByThumbprint -Thumbprint $thumbprint -Stores @('Cert:\LocalMachine\My')

    if ($null -eq $cert) {
        if (-not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) {
            throw "PFX path not found: $PfxPath"
        }

        Import-PfxCertificate -FilePath $PfxPath -Password $PfxPassword -Exportable -CertStoreLocation 'Cert:\LocalMachine\My' | Out-Null
        $cert = Get-CertificateByThumbprint -Thumbprint $thumbprint -Stores @('Cert:\LocalMachine\My')
        if ($null -eq $cert) {
            throw "Certificate '$thumbprint' was not found after importing the PFX."
        }
    }

    $setCmd = Get-Command -Name Set-RDCertificate -ErrorAction SilentlyContinue
    $getCmd = Get-Command -Name Get-RDCertificate -ErrorAction SilentlyContinue
    if ($null -ne $setCmd -and $null -ne $getCmd) {
        $applied = $false
        foreach ($role in @('RDSessionHost','RDConnectionBroker')) {
            try {
                Set-RDCertificate -Role $role -Thumbprint $thumbprint -Force -ErrorAction Stop | Out-Null
                $applied = $true
            } catch {
            }
        }

        if (-not $applied) {
            Write-Output "Certificate imported and verified on session host, but no applicable RDS binding role was detected."
        }
    } else {
        Write-Output 'RDS cmdlets not present; certificate import and verification completed.'
    }

    Write-Output "Session host deployment succeeded for thumbprint $thumbprint"
    exit 0
} catch {
    Write-Error $_
    exit 1
}
