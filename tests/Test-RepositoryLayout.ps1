Set-StrictMode -Version Latest

function Invoke-TestRepositoryLayout {
    param([scriptblock]$Assert)

    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    & $Assert 'Repository layout does not allow loose deployment scripts in root' {
        $allowedRootScripts = @(
            'certificate-setup.ps1',
            'certificate-simple-acme-reconcile.ps1',
            'certificate-update-simple-acme.ps1',
            'certificate-backup.ps1',
            'certificate-restore.ps1',
            'certificate-orchestrator.ps1',
            'config.ps1'
        )

        $forbidden = @(Get-ChildItem -Path $repoRoot -File -Filter '*.ps1' | Where-Object {
            ($_.Name -like 'deploy-*.ps1' -or $_.Name -like '*-paloalto*.ps1' -or $_.Name -like '*-sophos*.ps1') -and
            ($allowedRootScripts -notcontains $_.Name)
        })

        if ($forbidden.Count -gt 0) {
            throw ('Forbidden root deployment scripts found: {0}' -f (($forbidden | Select-Object -ExpandProperty Name) -join ', '))
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
            (Join-Path $repoRoot 'Scripts/deploy-paloalto.ps1'),
            (Join-Path $repoRoot 'Scripts/deploy-sophos.ps1')
        )

        $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
        if ($missing.Count -gt 0) {
            throw ('Missing deployment scripts under Scripts/: {0}' -f ($missing -join ', '))
        }
    }
}
