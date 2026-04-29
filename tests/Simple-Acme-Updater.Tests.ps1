Set-StrictMode -Version Latest

Describe 'Updater install-root extraction' {
    It 'extracts official files to root and preserves custom script unless forced' {
        $root = Join-Path $TestDrive 'root'
        New-Item -ItemType Directory -Path $root | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'Scripts') | Out-Null
        Set-Content -Path (Join-Path $root 'Scripts/cert2rds.ps1') -Value 'custom'

        $fixture = Join-Path $TestDrive 'fixture'
        New-Item -ItemType Directory -Path (Join-Path $fixture 'Scripts') -Force | Out-Null
        Set-Content -Path (Join-Path $fixture 'wacs.exe') -Value 'official-wacs'
        Set-Content -Path (Join-Path $fixture 'settings_default.json') -Value '{}'
        Set-Content -Path (Join-Path $fixture 'Scripts/Example.ps1') -Value 'official-script'

        $zip = Join-Path $TestDrive 'official.zip'
        Compress-Archive -Path (Join-Path $fixture '*') -DestinationPath $zip -Force

        Mock Read-Host { 'n' }
        & (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'certificate-update-simple-acme.ps1') -RootPath $root -ReleaseZipPath $zip | Out-Null

        (Test-Path (Join-Path $root 'wacs.exe')) | Should -BeTrue
        (Test-Path (Join-Path $root 'settings_default.json')) | Should -BeTrue
        (Get-Content -Raw -Path (Join-Path $root 'Scripts/Example.ps1')) | Should -Match 'official-script'
        (Get-Content -Raw -Path (Join-Path $root 'Scripts/cert2rds.ps1')) | Should -Match 'custom'

        $manifest = Get-Content -Raw -Path (Join-Path $root 'simple-acme-release-manifest.json') | ConvertFrom-Json
        $manifest.source | Should -Be 'official-release'
        $manifest.officialChecksumVerified | Should -BeFalse
        $manifest.warning | Should -Match 'Official checksum was not available'
        $envFile = Get-Content -Raw -Path (Join-Path $root 'certificate.env')
        $envFile | Should -Match 'ACME_WACS_PATH='
        $envFile | Should -Match 'ACME_WACS_SOURCE=official-release'
        $envFile | Should -Match 'ACME_WACS_VERSION=local-fixture'
    }
}


Describe 'Updater transactional behavior' {
    It 'does not mutate files during DryRun' {
        $root = Join-Path $TestDrive 'dryrun-root'
        New-Item -ItemType Directory -Path $root | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'Scripts') | Out-Null
        Set-Content -Path (Join-Path $root 'Scripts/cert2rds.ps1') -Value 'custom-before'

        $fixture = Join-Path $TestDrive 'dryrun-fixture'
        New-Item -ItemType Directory -Path (Join-Path $fixture 'Scripts') -Force | Out-Null
        Set-Content -Path (Join-Path $fixture 'wacs.exe') -Value 'official-wacs'
        Set-Content -Path (Join-Path $fixture 'Scripts/Example.ps1') -Value 'official-script'
        $zip = Join-Path $TestDrive 'dryrun-official.zip'
        Compress-Archive -Path (Join-Path $fixture '*') -DestinationPath $zip -Force

        & (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'certificate-update-simple-acme.ps1') -RootPath $root -ReleaseZipPath $zip -DryRun | Out-Null

        (Test-Path (Join-Path $root 'wacs.exe')) | Should -BeFalse
        (Get-Content -Raw -Path (Join-Path $root 'Scripts/cert2rds.ps1')) | Should -Be 'custom-before'
        (Test-Path (Join-Path $root 'simple-acme-release-manifest.json')) | Should -BeFalse
    }

    It 'rolls back overwritten files if metadata persist fails' {
        $root = Join-Path $TestDrive 'rollback-root'
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-Content -Path (Join-Path $root 'wacs.exe') -Value 'old-wacs'

        $fixture = Join-Path $TestDrive 'rollback-fixture'
        New-Item -ItemType Directory -Path $fixture -Force | Out-Null
        Set-Content -Path (Join-Path $fixture 'wacs.exe') -Value 'new-wacs'
        Set-Content -Path (Join-Path $fixture 'settings_default.json') -Value '{"from":"fixture"}'
        $zip = Join-Path $TestDrive 'rollback-official.zip'
        Compress-Archive -Path (Join-Path $fixture '*') -DestinationPath $zip -Force

        Mock -CommandName Set-Content -ParameterFilter { $LiteralPath -like '*simple-acme-release-manifest.json' } -MockWith { throw 'forced manifest persist failure' }
        { & (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'certificate-update-simple-acme.ps1') -RootPath $root -ReleaseZipPath $zip } | Should -Throw

        (Get-Content -Raw -Path (Join-Path $root 'wacs.exe')) | Should -Be 'old-wacs'
        (Test-Path (Join-Path $root 'settings_default.json')) | Should -BeFalse
    }
}
