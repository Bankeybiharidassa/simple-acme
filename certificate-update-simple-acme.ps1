[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$RootPath = $PSScriptRoot,
    [string]$ReleaseZipPath,
    [switch]$DryRun,
    [switch]$ForceOfficialUpdate,
    [switch]$SkipChecksumVerification
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LatestSimpleAcmeRelease {
    $api = 'https://api.github.com/repos/simple-acme/simple-acme/releases/latest'
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'simple-acme-helper' }
    $asset = @($release.assets | Where-Object { $_.name -match '\.zip$' }) | Select-Object -First 1
    if (-not $asset) { throw 'No ZIP asset found in latest simple-acme release.' }
    [pscustomobject]@{
        Version = [string]$release.tag_name
        ReleaseUrl = [string]$release.html_url
        AssetUrl = [string]$asset.browser_download_url
        AssetName = [string]$asset.name
    }
}

function Update-CertificateEnv {
    param([string]$EnvPath,[hashtable]$Values)
    $existing = @{}
    if (Test-Path -LiteralPath $EnvPath) {
        foreach ($line in (Get-Content -LiteralPath $EnvPath)) {
            if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
            $parts = $line.Split('=',2)
            $existing[$parts[0].Trim()] = $parts[1]
        }
    }
    foreach ($k in $Values.Keys) { $existing[$k] = [string]$Values[$k] }
    $out = foreach ($k in ($existing.Keys | Sort-Object)) { '{0}={1}' -f $k, $existing[$k] }
    Set-Content -LiteralPath $EnvPath -Value $out -Encoding UTF8
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

$root = [System.IO.Path]::GetFullPath($RootPath)
$envPath = Join-Path $root 'certificate.env'
$manifestPath = Join-Path $root 'simple-acme-release-manifest.json'
$logsDir = Join-Path $root 'logs'
if (-not $DryRun) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$updateLog = Join-Path $logsDir ("simple-acme-update-$ts.log")

if (-not $ReleaseZipPath) {
    $rel = Get-LatestSimpleAcmeRelease
    $zipPath = Join-Path $env:TEMP $rel.AssetName
    Write-Host "Selected release asset: $($rel.AssetUrl)"
    if (-not $DryRun) { Invoke-WebRequest -Uri $rel.AssetUrl -OutFile $zipPath -UseBasicParsing }
} else {
    $zipPath = $ReleaseZipPath
    $rel = [pscustomobject]@{ Version='local-fixture'; ReleaseUrl='local'; AssetUrl=$zipPath; AssetName=[IO.Path]::GetFileName($zipPath) }
    Write-Host "Selected release asset: $zipPath"
}
Write-Host "Target root: $root"

if (-not (Test-Path -LiteralPath $zipPath) -and -not $DryRun) { throw "ZIP not found: $zipPath" }

$checksum = if ($DryRun) { 'DRYRUN' } else { Get-FileSha256 -Path $zipPath }
$officialChecksumVerified = $false
$checksumWarning = $null
if (-not $SkipChecksumVerification) {
    $checksumWarning = 'Official checksum was not available. Local SHA256 was calculated and stored but authenticity was not independently verified.'
    Write-Warning $checksumWarning
}

Write-Host 'Files that would be updated:'
@('wacs.exe','settings_default.json','Scripts\*','*.dll') | ForEach-Object { Write-Host " - $_" }
Write-Host 'Custom files that will be preserved:'
@('certificate-setup.ps1','certificate-simple-acme-reconcile.ps1','certificate-backup.ps1','certificate-restore.ps1','certificate-update-simple-acme.ps1','core\','setup\','logs\','certificate.env','simple-acme-release-manifest.json','simple-acme-helper-renewals.json','Scripts\cert2rds.ps1') | ForEach-Object { Write-Host " - $_" }

if ($DryRun) { return }

$staging = Join-Path $env:TEMP ('simple-acme-stage-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging -Force | Out-Null
Expand-Archive -Path $zipPath -DestinationPath $staging -Force

$backupRoot = Join-Path $root ("backup-update-$ts")
$backups = New-Object System.Collections.Generic.List[string]
$logLines = New-Object System.Collections.Generic.List[string]

$knownOfficialPatterns = @('wacs.exe','settings_default.json','*.dll','Scripts/*')
$stageFiles = @(Get-ChildItem -Path $staging -Recurse -File)
foreach ($file in $stageFiles) {
    $relPath = $file.FullName.Substring($staging.Length).TrimStart('\\','/')
    $dest = Join-Path $root $relPath
    $overwrite = $true
    if (Test-Path -LiteralPath $dest) {
        $srcHash = Get-FileSha256 -Path $file.FullName
        $dstHash = Get-FileSha256 -Path $dest
        if ($srcHash -eq $dstHash) {
            $overwrite = $true
            $logLines.Add("UNCHANGED $relPath") | Out-Null
        } else {
            $isKnownOfficial = $false
            foreach ($pattern in $knownOfficialPatterns) {
                if ($relPath -like $pattern) { $isKnownOfficial = $true; break }
            }
            if (-not $isKnownOfficial -and -not $ForceOfficialUpdate) {
                $answer = Read-Host "Conflict for $relPath (custom/unknown). Overwrite? (y/N)"
                if ($answer -notin @('y','Y','yes','YES')) { $overwrite = $false }
            }
            if ($overwrite) {
                $backupPath = Join-Path $backupRoot $relPath
                New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($backupPath)) -Force | Out-Null
                Copy-Item -LiteralPath $dest -Destination $backupPath -Force
                $backups.Add($backupPath) | Out-Null
                $logLines.Add("BACKUP $relPath -> $backupPath") | Out-Null
            }
        }
    }

    if ($overwrite) {
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($dest)) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
        $logLines.Add("UPDATED $relPath") | Out-Null
    } else {
        $logLines.Add("SKIPPED $relPath") | Out-Null
    }
}

$manifest = [ordered]@{
    source = 'official-release'
    releaseUrl = $rel.ReleaseUrl
    assetUrl = $rel.AssetUrl
    version = $rel.Version
    sha256 = $checksum
    officialChecksumVerified = $officialChecksumVerified
    installedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    wacsPath = (Join-Path $root 'wacs.exe')
    warning = $checksumWarning
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Update-CertificateEnv -EnvPath $envPath -Values @{
    ACME_WACS_PATH = (Join-Path $root 'wacs.exe')
    ACME_WACS_SOURCE = 'official-release'
    ACME_WACS_VERSION = $rel.Version
    ACME_WACS_AUTO_UPDATE = '0'
    ACME_WACS_RELEASE_ZIP = $rel.AssetUrl
    ACME_WACS_RELEASE_SHA256 = $checksum
}

@(
    "timestamp=$((Get-Date).ToUniversalTime().ToString('o'))",
    "root=$root",
    "release=$($rel.Version)",
    "asset=$($rel.AssetUrl)",
    "sha256=$checksum",
    "officialChecksumVerified=$officialChecksumVerified",
    "backupRoot=$backupRoot"
) + $logLines | Set-Content -LiteralPath $updateLog -Encoding UTF8

Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Update complete."
Write-Host "Update log: $updateLog"
