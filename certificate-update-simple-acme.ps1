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
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent'='simple-acme-helper' }
    $asset = $release.assets | Where-Object { $_.name -match '\.zip$' -and $_.prerelease -ne $true } | Select-Object -First 1
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
    if (Test-Path $EnvPath) {
        foreach ($line in (Get-Content -Path $EnvPath)) {
            if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
            $parts = $line.Split('=',2)
            $existing[$parts[0].Trim()] = $parts[1]
        }
    }
    foreach ($k in $Values.Keys) { $existing[$k] = [string]$Values[$k] }
    $out = foreach ($k in ($existing.Keys | Sort-Object)) { '{0}={1}' -f $k, $existing[$k] }
    Set-Content -Path $EnvPath -Value $out -Encoding UTF8
}

$root = [System.IO.Path]::GetFullPath($RootPath)
$envPath = Join-Path $root 'certificate.env'
$manifestPath = Join-Path $root 'simple-acme-release-manifest.json'

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

if (-not (Test-Path $zipPath) -and -not $DryRun) { throw "ZIP not found: $zipPath" }

$checksum = if ($DryRun) { 'DRYRUN' } else { (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLowerInvariant() }
if (-not $SkipChecksumVerification) { Write-Warning 'Official checksum was not available. Local SHA256 was calculated and stored, but authenticity could not be independently verified.' }

$staging = Join-Path $env:TEMP ('simple-acme-stage-' + [guid]::NewGuid().ToString('N'))
if (-not $DryRun) {
    New-Item -ItemType Directory -Path $staging | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $staging -Force
}

$officialFiles = @('wacs.exe','settings_default.json','Scripts')
Write-Host 'Files that would be updated:'
$officialFiles | ForEach-Object { Write-Host " - $_" }
Write-Host 'Custom files that will be preserved:'
Write-Host ' - certificate-setup.ps1'
Write-Host ' - certificate-simple-acme-reconcile.ps1'
Write-Host ' - certificate-backup.ps1'
Write-Host ' - certificate-restore.ps1'
Write-Host ' - core\, setup\, logs\, certificate.env, custom scripts'

if ($DryRun) { return }

# conflict detection for Scripts
$stageScripts = Join-Path $staging 'Scripts'
$targetScripts = Join-Path $root 'Scripts'
if (Test-Path $stageScripts) {
    Get-ChildItem -Path $stageScripts -File -Recurse | ForEach-Object {
        $relPath = $_.FullName.Substring($stageScripts.Length).TrimStart('\\','/')
        $dest = Join-Path $targetScripts $relPath
        if (Test-Path $dest) {
            $srcHash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash
            $dstHash = (Get-FileHash -Path $dest -Algorithm SHA256).Hash
            if ($srcHash -ne $dstHash -and -not $ForceOfficialUpdate) {
                $answer = Read-Host "Conflict for Scripts\\$relPath. Overwrite? (y/N)"
                if ($answer -notin @('y','Y','yes','YES')) { return }
            }
        }
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($dest)) -Force | Out-Null
        Copy-Item -Path $_.FullName -Destination $dest -Force
    }
}

Get-ChildItem -Path $staging -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $root $_.Name) -Force
}

$manifest = [ordered]@{
    source = 'official-release'
    releaseUrl = $rel.ReleaseUrl
    assetUrl = $rel.AssetUrl
    version = $rel.Version
    sha256 = $checksum
    installedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    wacsPath = (Join-Path $root 'wacs.exe')
}
$manifest | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8

Update-CertificateEnv -EnvPath $envPath -Values @{
    ACME_WACS_PATH = (Join-Path $root 'wacs.exe')
    ACME_WACS_SOURCE = 'official-release'
    ACME_WACS_VERSION = $rel.Version
    ACME_WACS_AUTO_UPDATE = '0'
    ACME_WACS_RELEASE_ZIP = $rel.AssetUrl
    ACME_WACS_RELEASE_SHA256 = $checksum
}

Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'Update complete.'
