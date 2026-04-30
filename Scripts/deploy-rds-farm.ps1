[CmdletBinding()]
param(
    [Parameter(Position=0, Mandatory=$true)]
    [string]$NewCertThumbprint
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'core\connector-core.psm1') -Force

$root = Split-Path $PSScriptRoot -Parent
$targetsPath = Join-Path $root 'deployment-targets.json'
if (-not (Test-Path -LiteralPath $targetsPath -PathType Leaf)) { throw "Missing deployment-targets.json at $targetsPath" }

$results = @()
$localPfxPath = $null
$thumbprint = Assert-CertThumbprint -Thumbprint $NewCertThumbprint

try {
    $config = Get-Content -Raw -LiteralPath $targetsPath -Encoding UTF8 | ConvertFrom-Json
    $cert = Get-CertificateByThumbprint -Thumbprint $thumbprint -Stores @('Cert:\LocalMachine\My')
    if ($null -eq $cert) { throw "Certificate '$thumbprint' not found in Cert:\LocalMachine\My." }
    if (-not $cert.HasPrivateKey) { throw "Certificate '$thumbprint' has no private key." }

    & (Join-Path $PSScriptRoot 'cert2rds.ps1') $thumbprint
    if ($LASTEXITCODE -ne 0) { throw 'Local RD Gateway deployment failed.' }
    $results += [pscustomobject]@{ server='localhost'; success=$true; message='Gateway deployment successful' }

    $runtimeDir = Join-Path $root 'runtime'
    if (-not (Test-Path -LiteralPath $runtimeDir)) { New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null }
    try {
        $acl = Get-Acl -LiteralPath $runtimeDir
        $acl.SetAccessRuleProtection($true,$false)
        foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        $prop = [System.Security.AccessControl.PropagationFlags]::None
        $allow = [System.Security.AccessControl.AccessControlType]::Allow
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators','FullControl',$inherit,$prop,$allow)))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl',$inherit,$prop,$allow)))
        Set-Acl -LiteralPath $runtimeDir -AclObject $acl
    } catch { Write-Warning "Unable to harden ACL on runtime directory: $runtimeDir" }

    Add-Type -AssemblyName System.Web
    $plainPassword = [System.Web.Security.Membership]::GeneratePassword(32, 8)
    $pfxPassword = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
    $plainPassword = $null

    $localPfxPath = Join-Path $runtimeDir ("rds-farm-{0}.pfx" -f [Guid]::NewGuid().ToString('N'))
    Export-PfxCertificate -Cert $cert -FilePath $localPfxPath -Password $pfxPassword -Force | Out-Null

    foreach ($host in @($config.sessionHosts | Where-Object { $_.enabled -eq $true })) {
        $cn = [string]$host.computerName
        $session = $null
        $remotePfxPath = Join-Path ([string]$config.pfxDistribution.remoteTempDirectory) ([IO.Path]::GetFileName($localPfxPath))
        try {
            try { $session = New-PSSession -ComputerName $cn -ErrorAction Stop } catch {
                if (-not [string]::IsNullOrWhiteSpace([string]$host.username)) {
                    $cred = Get-Credential -UserName ([string]$host.username) -Message "Enter password for $cn"
                    $session = New-PSSession -ComputerName $cn -Credential $cred -ErrorAction Stop
                } else { throw }
            }

            Invoke-Command -Session $session -ScriptBlock { param($dir) if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } -ArgumentList ([string]$config.pfxDistribution.remoteTempDirectory)
            try {
                Copy-Item -LiteralPath $localPfxPath -Destination $remotePfxPath -ToSession $session -Force -ErrorAction Stop
            } catch {
                $bytes = [IO.File]::ReadAllBytes($localPfxPath)
                Invoke-Command -Session $session -ScriptBlock { param($path,$payload) [IO.File]::WriteAllBytes($path,$payload) } -ArgumentList $remotePfxPath,$bytes
            }

            Invoke-Command -Session $session -FilePath (Join-Path $PSScriptRoot 'deploy-rds-sessionhost.ps1') -ArgumentList $thumbprint,$remotePfxPath,$pfxPassword

            if ($config.pfxDistribution.deleteRemotePfxAfterImport -eq $true) {
                Invoke-Command -Session $session -ScriptBlock { param($path) if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } } -ArgumentList $remotePfxPath
            }

            $results += [pscustomobject]@{ server=$cn; success=$true; message='Session host deployment successful' }
        } catch {
            $results += [pscustomobject]@{ server=$cn; success=$false; message=$_.Exception.Message }
        } finally {
            if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
        }
    }
} catch {
    Write-Error $_
    $results += [pscustomobject]@{ server='localhost'; success=$false; message=$_.Exception.Message }
} finally {
    if ($localPfxPath -and (Test-Path -LiteralPath $localPfxPath)) {
        if ($config.pfxDistribution.deleteLocalPfxAfterImport -eq $true) {
            try { Remove-Item -LiteralPath $localPfxPath -Force } catch { Write-Warning "Failed to delete local PFX: $localPfxPath" }
        } else {
            Write-Warning "Local PFX retained by configuration: $localPfxPath"
        }
    }
}

$results | ForEach-Object { Write-Output ("[{0}] success={1} message={2}" -f $_.server,$_.success,$_.message) }
if (@($results | Where-Object { -not $_.success }).Count -gt 0) { exit 1 }
exit 0
