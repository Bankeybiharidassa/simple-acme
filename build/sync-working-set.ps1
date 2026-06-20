#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('DevToTestAndDist','DevToTest','DevToDist','TestToDev','Check')]
    [string]$Mode = 'DevToTestAndDist',

    [string]$ProjectRoot = '',
    [string]$TestRoot = '',
    [string]$DistRoot = '',
    [string]$ManifestPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-SyncFullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Assert-SyncPathInside {
    param(
        [Parameter(Mandatory)][string]$ChildPath,
        [Parameter(Mandatory)][string]$ParentPath,
        [Parameter(Mandatory)][string]$Name
    )

    $child = Resolve-SyncFullPath -Path $ChildPath
    $parent = Resolve-SyncFullPath -Path $ParentPath
    if (-not $parent.EndsWith([IO.Path]::DirectorySeparatorChar)) {
        $parent = $parent + [IO.Path]::DirectorySeparatorChar
    }
    if (-not $child.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name path '$child' is outside expected parent '$parent'."
    }
}

function Get-SyncManifestFiles {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Release manifest not found: $Path"
    }
    return @(Get-Content -LiteralPath $Path | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-SyncTrackedFiles {
    param([Parameter(Mandatory)][string]$Root)

    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) { throw 'git.exe is required to enumerate the dev working set.' }
    $output = & git -C $Root ls-files
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed while enumerating the dev working set.' }
    return @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        $_ -notmatch '^(?i)test/' -and
        $_ -notmatch '^(?i)\.git/'
    })
}

function Copy-SyncFile {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $source = Join-Path $SourceRoot $RelativePath
    $target = Join-Path $TargetRoot $RelativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Source file missing: $RelativePath"
    }
    $targetDir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $source -Destination $target -Force
}

function Test-SyncFileSet {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][string]$Name
    )

    $missing = New-Object System.Collections.Generic.List[string]
    $stale = New-Object System.Collections.Generic.List[string]
    foreach ($relativePath in @($Files)) {
        $source = Join-Path $SourceRoot $relativePath
        $target = Join-Path $TargetRoot $relativePath
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $missing.Add($relativePath) | Out-Null
            continue
        }
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
            $stale.Add($relativePath) | Out-Null
        }
    }

    [pscustomobject]@{
        Name = $Name
        MissingCount = $missing.Count
        StaleCount = $stale.Count
        Missing = @($missing.ToArray())
        Stale = @($stale.ToArray())
    }
}

function Invoke-SyncCopySet {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string[]]$Files,
        [Parameter(Mandatory)][string]$Name
    )

    foreach ($relativePath in @($Files)) {
        Copy-SyncFile -SourceRoot $SourceRoot -TargetRoot $TargetRoot -RelativePath $relativePath
    }
    Write-Host ("{0}: copied {1} file(s)." -f $Name, $Files.Count)
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path $PSScriptRoot -Parent }
$ProjectRoot = Resolve-SyncFullPath -Path $ProjectRoot
if ([string]::IsNullOrWhiteSpace($TestRoot)) { $TestRoot = Join-Path $ProjectRoot 'test\certificaat' }
if ([string]::IsNullOrWhiteSpace($DistRoot)) { $DistRoot = Join-Path $ProjectRoot 'dist' }
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $ProjectRoot 'build\release-file-list.txt' }
$TestRoot = Resolve-SyncFullPath -Path $TestRoot
$DistRoot = Resolve-SyncFullPath -Path $DistRoot
$ManifestPath = Resolve-SyncFullPath -Path $ManifestPath

Assert-SyncPathInside -ChildPath $TestRoot -ParentPath (Join-Path $ProjectRoot 'test') -Name 'Test root'
Assert-SyncPathInside -ChildPath $DistRoot -ParentPath $ProjectRoot -Name 'Dist root'

$manifestFiles = Get-SyncManifestFiles -Path $ManifestPath
$trackedFiles = Get-SyncTrackedFiles -Root $ProjectRoot

switch ($Mode) {
    'DevToTestAndDist' {
        Invoke-SyncCopySet -SourceRoot $ProjectRoot -TargetRoot $DistRoot -Files $manifestFiles -Name 'dev -> dist'
        Invoke-SyncCopySet -SourceRoot $ProjectRoot -TargetRoot $TestRoot -Files $trackedFiles -Name 'dev -> test\certificaat'
    }
    'DevToTest' {
        Invoke-SyncCopySet -SourceRoot $ProjectRoot -TargetRoot $TestRoot -Files $trackedFiles -Name 'dev -> test\certificaat'
    }
    'DevToDist' {
        Invoke-SyncCopySet -SourceRoot $ProjectRoot -TargetRoot $DistRoot -Files $manifestFiles -Name 'dev -> dist'
    }
    'TestToDev' {
        Invoke-SyncCopySet -SourceRoot $TestRoot -TargetRoot $ProjectRoot -Files $trackedFiles -Name 'test\certificaat -> dev'
    }
    'Check' {
        $test = Test-SyncFileSet -SourceRoot $ProjectRoot -TargetRoot $TestRoot -Files $trackedFiles -Name 'dev vs test\certificaat'
        $dist = Test-SyncFileSet -SourceRoot $ProjectRoot -TargetRoot $DistRoot -Files $manifestFiles -Name 'dev vs dist'
        $test
        $dist
        if ($test.MissingCount -gt 0 -or $test.StaleCount -gt 0 -or $dist.MissingCount -gt 0 -or $dist.StaleCount -gt 0) {
            throw 'Working-set sync check failed.'
        }
    }
}
