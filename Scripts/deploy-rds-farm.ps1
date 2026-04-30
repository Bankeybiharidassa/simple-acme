param(
    [Parameter(Position=0, Mandatory=$true)]
    [string]$NewCertThumbprint
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$targetsPath = Join-Path $root 'deployment-targets.json'
if (-not (Test-Path -LiteralPath $targetsPath)) { Write-Error 'deployment-targets.json missing.'; exit 1 }
$targets = Get-Content -LiteralPath $targetsPath -Raw -Encoding UTF8 | ConvertFrom-Json

$thumb = ($NewCertThumbprint -replace '\s','').ToUpperInvariant()
$cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $thumb } | Select-Object -First 1
if ($null -eq $cert) { Write-Error 'Certificate not found in Cert:\LocalMachine\My.'; exit 1 }
if (-not $cert.HasPrivateKey) { Write-Error 'Certificate has no private key.'; exit 1 }

$cert2rds = Join-Path $PSScriptRoot 'cert2rds.ps1'
& $cert2rds $thumb
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$runtimeDir = Join-Path $root 'runtime'
if (-not (Test-Path -LiteralPath $runtimeDir)) { New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null }

$pwChars = 1..48 | ForEach-Object { [char](Get-Random -Minimum 33 -Maximum 126) }
$plainPassword = -join $pwChars
$securePassword = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force
$plainPassword = $null

$pfxPath = Join-Path $runtimeDir ('rdsfarm-' + $thumb + '.pfx')
Export-PfxCertificate -Cert $cert.PSPath -FilePath $pfxPath -Password $securePassword | Out-Null

$failed = 0
foreach ($host in @($targets.sessionHosts)) {
    if ($null -eq $host -or -not $host.enabled) { continue }
    $computerName = [string]$host.computerName
    if ([string]::IsNullOrWhiteSpace($computerName)) { $failed++; continue }
    $session = $null
    try {
        $session = New-PSSession -ComputerName $computerName -ErrorAction Stop
    } catch {
        if (-not [string]::IsNullOrWhiteSpace([string]$host.username)) {
            $cred = Get-Credential -UserName ([string]$host.username) -Message "Enter password for $computerName"
            try { $session = New-PSSession -ComputerName $computerName -Credential $cred -ErrorAction Stop } catch { $session = $null }
        }
    }
    if ($null -eq $session) { Write-Warning "Failed to create remoting session for $computerName"; $failed++; continue }

    try {
        $remoteTempDir = if ($targets.pfxDistribution.remoteTempDirectory) { [string]$targets.pfxDistribution.remoteTempDirectory } else { 'C:\Windows\Temp\simple-acme-helper' }
        Invoke-Command -Session $session -ScriptBlock { param($dir) if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } -ArgumentList $remoteTempDir -ErrorAction Stop
        $remotePfxPath = Join-Path $remoteTempDir ([IO.Path]::GetFileName($pfxPath))
        Copy-Item -LiteralPath $pfxPath -Destination $remotePfxPath -ToSession $session -Force
        Invoke-Command -Session $session -ScriptBlock {
            param($scriptPath,$thumbprint,$remotePath,$password)
            & $scriptPath $thumbprint $remotePath $password
        } -ArgumentList 'C:\certificaat\Scripts\deploy-rds-sessionhost.ps1',$thumb,$remotePfxPath,$securePassword -ErrorAction Stop
        if ($targets.pfxDistribution.deleteRemotePfxAfterImport -ne $false) {
            Invoke-Command -Session $session -ScriptBlock { param($path) if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } } -ArgumentList $remotePfxPath -ErrorAction SilentlyContinue
        }
    } catch {
        $failed++
        Write-Warning "Failed on $computerName: $($_.Exception.Message)"
    } finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

if ($targets.pfxDistribution.deleteLocalPfxAfterImport -ne $false) {
    Remove-Item -LiteralPath $pfxPath -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { exit 1 }
exit 0
