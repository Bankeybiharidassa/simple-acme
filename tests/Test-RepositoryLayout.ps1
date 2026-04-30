Set-StrictMode -Version Latest

function Invoke-TestRepositoryLayout {
    param([scriptblock]$Assert)

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    & $Assert 'Repository layout does not allow loose deployment scripts in root' {
        $forbiddenRootScripts = @(
            'cert2rds.ps1',
            'deploy-rds-farm.ps1',
            'deploy-rds-sessionhost.ps1',
            'deploy-paloalto.ps1',
            'deploy-sophos.ps1'
        )

        $forbidden = @($forbiddenRootScripts | Where-Object {
            Test-Path -LiteralPath (Join-Path $repoRoot $_) -PathType Leaf
        })

        if ($forbidden.Count -gt 0) {
            throw ('Forbidden root deployment scripts found: {0}' -f ($forbidden -join ', '))
        }
    }


    & $Assert 'Repository root contains required top-level directories' {
        $requiredDirs = @('core', 'setup', 'tests', 'docs', 'build', 'dist', 'connectors', 'Scripts')
        $missingDirs = @($requiredDirs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot $_) -PathType Container) })
        if ($missingDirs.Count -gt 0) {
            throw ('Missing required top-level directories: {0}' -f ($missingDirs -join ', '))
        }
    }

    & $Assert 'Deployment scripts exist under Scripts directory' {
        $required = @(
            (Join-Path $repoRoot 'Scripts/cert2rds.ps1'),
            (Join-Path $repoRoot 'Scripts/deploy-rds-farm.ps1'),
            (Join-Path $repoRoot 'Scripts/deploy-rds-sessionhost.ps1'),
            (Join-Path $repoRoot 'Scripts/deploy-paloalto.ps1'),
            (Join-Path $repoRoot 'Scripts/deploy-sophos.ps1')
        )

        $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
        if ($missing.Count -gt 0) {
            throw ('Missing deployment scripts under Scripts/: {0}' -f ($missing -join ', '))
        }
    }
}
