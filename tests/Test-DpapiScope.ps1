Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-TestDpapiScope {
    param([Parameter(Mandatory)][scriptblock]$Assert)

    & $Assert 'runtime code disallows CurrentUser DPAPI scope' {
        $targets = @(
            (Join-Path $PSScriptRoot '..\core\Crypto.psm1'),
            (Join-Path $PSScriptRoot '..\Scripts\deploy-paloalto.ps1'),
            (Join-Path $PSScriptRoot '..\Scripts\deploy-sophos.ps1')
        )
        foreach ($path in $targets) {
            $raw = Get-Content -LiteralPath $path -Raw
            if ($raw -match "DataProtectionScope]::CurrentUser") {
                throw "CurrentUser DPAPI scope found in runtime file: $path"
            }
            if ($raw -match "ValidateSet\([^)]*CurrentUser") {
                throw "CurrentUser scope is permitted in runtime file: $path"
            }
        }
    }

    & $Assert 'runtime code uses LocalMachine DPAPI scope' {
        $cryptoPath = Join-Path $PSScriptRoot '..\core\Crypto.psm1'
        $raw = Get-Content -LiteralPath $cryptoPath -Raw
        if ($raw -notmatch "DataProtectionScope]::\$Scope") {
            throw 'Crypto module does not resolve DPAPI scope enum.'
        }
        if ($raw -notmatch "ValidateSet\('LocalMachine'\)\[string\]\$Scope = 'LocalMachine'") {
            throw 'Crypto module does not enforce LocalMachine-only scope.'
        }
    }


    & $Assert 'DPAPI type loader is available before runtime protection calls' {
        $targets = @(
            (Join-Path $PSScriptRoot '..\core\Crypto.psm1'),
            (Join-Path $PSScriptRoot '..\Scripts\deploy-paloalto.ps1'),
            (Join-Path $PSScriptRoot '..\Scripts\deploy-sophos.ps1')
        )
        foreach ($path in $targets) {
            $raw = Get-Content -LiteralPath $path -Raw
            if ($raw -notmatch 'function\s+Initialize-DpapiSupport') {
                throw "Initialize-DpapiSupport function was not found in runtime file: $path"
            }
            if ($raw -notmatch 'Add-Type\s+-AssemblyName\s+\$assembly') {
                throw "DPAPI assembly loader was not found in runtime file: $path"
            }
            if ($raw -notmatch 'Initialize-DpapiSupport[\s\S]*DataProtectionScope\]::\$Scope') {
                throw "DPAPI support is not initialized before scope resolution in runtime file: $path"
            }
        }
    }

    & $Assert 'docs do not instruct CurrentUser DPAPI for runtime secrets' {
        $docTargets = @(
            (Join-Path $PSScriptRoot '..\README.md'),
            (Join-Path $PSScriptRoot '..\install.md')
        ) | Where-Object { Test-Path -LiteralPath $_ }

        foreach ($path in $docTargets) {
            $raw = Get-Content -LiteralPath $path -Raw
            if ($raw -match 'CurrentUser') {
                throw "Doc references CurrentUser DPAPI guidance: $path"
            }
        }
    }

    & $Assert 'secret file ACL hardening exists and targets SYSTEM + Administrators' {
        $envLoaderPath = Join-Path $PSScriptRoot '..\core\Env-Loader.psm1'
        $raw = Get-Content -LiteralPath $envLoaderPath -Raw
        if ($raw -notmatch 'function\s+Set-EnvFileAcl') {
            throw 'Set-EnvFileAcl function was not found.'
        }
        if ($raw -notmatch "NTAccount\('SYSTEM'\)") {
            throw 'Set-EnvFileAcl does not grant SYSTEM.'
        }
        if ($raw -notmatch "NTAccount\('Administrators'\)") {
            throw 'Set-EnvFileAcl does not grant Administrators.'
        }
    }
}
