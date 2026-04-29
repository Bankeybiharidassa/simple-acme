Set-StrictMode -Version Latest

Describe 'README/code alignment' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $readme = Get-Content -Raw -Path (Join-Path $repoRoot 'README.md')

    It 'does not require PATH for wacs' {
        $readme | Should -Not -Match 'available on\s+`?PATH`?'
    }

    It 'does not claim automatic RSA fallback by default' {
        $readme | Should -Not -Match 'automatic RSA fallback'
    }

    It 'does not require CERTIFICATE_CONFIG_DIR for phase 1' {
        $readme | Should -Not -Match 'CERTIFICATE_CONFIG_DIR\s*\|\s*Yes'
    }

    It 'does not require pre-existing valid env for setup' {
        $readme | Should -Not -Match 'requires a valid env file before running setup'
    }

    It 'does not present nested tools/simple-acme as default' {
        $readme | Should -Not -Match 'default.*tools\\simple-acme'
    }
}

Describe 'Runtime layout check' {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    It 'expects install-root wacs and Scripts layout' {
        (Join-Path $repoRoot 'wacs.exe') | Should -Match 'wacs\.exe$'
        (Join-Path $repoRoot 'Scripts') | Should -Match 'Scripts$'
    }
}

Describe 'Updater dry run' {
    It 'prints selected release, target root, update/preserve summary and does not write files' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $manifest = Join-Path $repoRoot 'simple-acme-release-manifest.json'
        if (Test-Path $manifest) { Remove-Item $manifest -Force }
        $output = & (Join-Path $repoRoot 'certificate-update-simple-acme.ps1') -DryRun 2>&1 | Out-String
        $output | Should -Match 'Selected release asset:'
        $output | Should -Match 'Target root:'
        $output | Should -Match 'Files that would be updated:'
        $output | Should -Match 'Custom files that will be preserved:'
        (Test-Path $manifest) | Should -BeFalse
    }
}
