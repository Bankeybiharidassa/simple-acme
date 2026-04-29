[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'release-file-list.txt'),
    [string]$ReleaseRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'out/release')
)

$repoRoot = Split-Path $PSScriptRoot -Parent

if (-not (Test-Path $ManifestPath)) {
    throw "Release manifest not found: $ManifestPath"
}

$files = Get-Content -Path $ManifestPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
if ($files.Count -eq 0) {
    throw "Release manifest is empty: $ManifestPath"
}

if (Test-Path $ReleaseRoot) {
    Remove-Item -Path $ReleaseRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $ReleaseRoot -Force | Out-Null

$copied = 0
foreach ($relativePath in $files) {
    $source = Join-Path $repoRoot $relativePath
    if (-not (Test-Path $source)) {
        throw "Source file from manifest is missing: $relativePath"
    }

    $destination = Join-Path $ReleaseRoot $relativePath
    $destinationDir = Split-Path $destination -Parent
    if (-not (Test-Path $destinationDir)) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }

    Copy-Item -Path $source -Destination $destination -Force
    $copied++
}

Write-Host "Recreated release state at '$ReleaseRoot' with $copied files from '$ManifestPath'."
