function Invoke-TestDistHasNoCaseOnlyDuplicatePaths {
    param([scriptblock]$Assert)

    & $Assert "dist contains no case-only duplicate paths" {
        $distPath = Join-Path $PSScriptRoot '..\dist'
        $files = Get-ChildItem -Path $distPath -File -Recurse
        $groups = @($files | Group-Object { $_.FullName.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
        if ($groups.Count -gt 0) {
            $dupes = $groups | ForEach-Object { $_.Group.FullName -join ', ' } | Out-String
            throw "Found case-only duplicate path(s) in dist: $dupes"
        }
    }

    & $Assert "dist contains current content for every release manifest file" {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $distPath = Join-Path $repoRoot 'dist'
        $manifestPath = Join-Path $repoRoot 'build\release-file-list.txt'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            throw "Release manifest not found: $manifestPath"
        }

        $missing = @()
        $stale = @()
        foreach ($relativePath in @(Get-Content -LiteralPath $manifestPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $source = Join-Path $repoRoot $relativePath
            $candidate = Join-Path $distPath $relativePath
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $missing += $relativePath
                continue
            }
            $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            $distHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
            if ($sourceHash -ne $distHash) {
                $stale += $relativePath
            }
        }

        if ($missing.Count -gt 0) {
            throw "dist is missing release manifest file(s): $($missing -join ', ')"
        }
        if ($stale.Count -gt 0) {
            throw "dist has stale release manifest file(s): $($stale -join ', ')"
        }
    }
}
