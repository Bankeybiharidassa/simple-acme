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
    }
}
