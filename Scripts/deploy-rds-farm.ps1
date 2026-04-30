param(
    [Parameter(Position=0, Mandatory=$true)]
    [string]$NewCertThumbprint
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'core\connector-core.psm1') -Force

$root = Split-Path -Parent $PSScriptRoot
$targetsPath = Join-Path $root 'deployment-targets.json'
if (-not (Test-Path -LiteralPath $targetsPath)) { Write-Error 'deployment-targets.json missing.'; exit 1 }
$targets = Get-Content -LiteralPath $targetsPath -Raw -Encoding UTF8 | ConvertFrom-Json

$normalizedThumbprint = Assert-CertThumbprint -Thumbprint $NewCertThumbprint
$cert = Get-CertificateByThumbprint -Thumbprint $normalizedThumbprint -PrimaryStorePath 'Cert:\LocalMachine\My'
if ($null -eq $cert) { Write-Error 'Certificate not found in Cert:\LocalMachine\My.'; exit 1 }
if (-not $cert.HasPrivateKey) { Write-Error 'Certificate private key is missing.'; exit 1 }

try {
    [void]$cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'export-test')
} catch {
    Write-Error 'Certificate private key is not exportable.'
    exit 1
}

& (Join-Path $PSScriptRoot 'cert2rds.ps1') $normalizedThumbprint
if ($LASTEXITCODE -ne 0) { Write-Error 'Local gateway deployment failed (cert2rds.ps1).'; exit $LASTEXITCODE }

$runtimeDir = Join-Path $root 'runtime'
if (-not (Test-Path -LiteralPath $runtimeDir)) { New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null }

$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$rights = [System.Security.AccessControl.FileSystemRights]::FullControl
$allow = [System.Security.AccessControl.AccessControlType]::Allow
$inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
$prop = [System.Security.AccessControl.PropagationFlags]::None
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators', $rights, $inherit, $prop, $allow)))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM', $rights, $inherit, $prop, $allow)))
[System.IO.Directory]::SetAccessControl($runtimeDir, $acl)

Add-Type -AssemblyName System.Web
$plainPassword = [System.Web.Security.Membership]::GeneratePassword(32, 8)
$securePassword = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
$plainPassword = $null

$pfxPath = Join-Path $runtimeDir ('rdsfarm-' + $normalizedThumbprint + '.pfx')
$pfxBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $securePassword)
[System.IO.File]::WriteAllBytes($pfxPath, $pfxBytes)

$results = @()
foreach ($host in @($targets.sessionHosts)) {
    if ($null -eq $host -or -not [bool]$host.enabled) { continue }
    $computerName = [string]$host.computerName
    if ([string]::IsNullOrWhiteSpace($computerName)) { $results += [pscustomobject]@{name='(unknown)';ok=$false;reason='missing computerName'}; continue }

    $session = $null
    $cred = $null
    try { $session = New-PSSession -ComputerName $computerName -Authentication Negotiate -ErrorAction Stop } catch {}
    if ($null -eq $session -and -not [string]::IsNullOrWhiteSpace([string]$host.username)) {
        try {
            $cred = Get-Credential -UserName ([string]$host.username) -Message "Enter password for $computerName"
            if ($null -ne $cred) { $session = New-PSSession -ComputerName $computerName -Credential $cred -Authentication Negotiate -ErrorAction Stop }
        } catch {}
    }
    if ($null -eq $session) { $results += [pscustomobject]@{name=$computerName;ok=$false;reason='unable to establish remoting session'}; continue }

    try {
        $remoteTempDir = [string]$targets.pfxDistribution.remoteTempDirectory
        if ([string]::IsNullOrWhiteSpace($remoteTempDir)) { $remoteTempDir = 'C:\Windows\Temp\simple-acme-helper' }
        Invoke-Command -Session $session -ScriptBlock { param($d) if(-not(Test-Path -LiteralPath $d)){New-Item -ItemType Directory -Path $d -Force|Out-Null} } -ArgumentList $remoteTempDir
        $remotePfxPath = Join-Path $remoteTempDir ([System.IO.Path]::GetFileName($pfxPath))
        try {
            Copy-Item -LiteralPath $pfxPath -Destination $remotePfxPath -ToSession $session -Force -ErrorAction Stop
        } catch {
            $bytes = [System.IO.File]::ReadAllBytes($pfxPath)
            Invoke-Command -Session $session -ScriptBlock { param($d,$b) [System.IO.File]::WriteAllBytes($d,$b) } -ArgumentList $remotePfxPath,$bytes
        }
        Invoke-Command -Session $session -ScriptBlock {
            param($thumb,$remotePath,$pwd)
            & 'C:\certificaat\Scripts\deploy-rds-sessionhost.ps1' -NewCertThumbprint $thumb -PfxPath $remotePath -PfxPassword $pwd
        } -ArgumentList $normalizedThumbprint,$remotePfxPath,$securePassword

        if ($targets.pfxDistribution.deleteRemotePfxAfterImport -ne $false) {
            try { Invoke-Command -Session $session -ScriptBlock { param($p) if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force} } -ArgumentList $remotePfxPath } catch { Write-Warning "Remote cleanup failed on $computerName" }
        }
        $results += [pscustomobject]@{name=$computerName;ok=$true;reason=''}
    } catch {
        $results += [pscustomobject]@{name=$computerName;ok=$false;reason=$_.Exception.Message}
    } finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

if ($targets.pfxDistribution.deleteLocalPfxAfterImport -ne $false) {
    try { if (Test-Path -LiteralPath $pfxPath) { Remove-Item -LiteralPath $pfxPath -Force } } catch { Write-Warning 'Local PFX cleanup failed.' }
}

foreach ($r in $results) {
    if ($r.ok) { Write-Host ("OK: " + $r.name) } else { Write-Host ("FAILED: " + $r.name + " - " + $r.reason) }
}
if (@($results | Where-Object { -not $_.ok }).Count -gt 0) { exit 1 }
exit 0
