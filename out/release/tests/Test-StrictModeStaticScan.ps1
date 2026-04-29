#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
$files = @(Get-ChildItem -Path $root -Include *.ps1,*.psm1 -Recurse)

foreach ($file in $files) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    if ($text -match '\$EnvValues\.[A-Za-z0-9_]+\b(?!\s*\()') {
        throw "Unsafe EnvValues dot-property access in $($file.FullName)"
    }
    if ($text -match '\.[Cc]ount\b') {
        Write-Warning "Review .Count usage in $($file.FullName)"
    }
}

Write-Host 'StrictMode static scan passed.'

$issuanceFiles = @('core/Simple-Acme-Reconciler.psm1','certificate-simple-acme-reconcile.ps1','certificate-setup.ps1')
foreach ($relative in $issuanceFiles) {
    $full = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $raw = [System.IO.File]::ReadAllText($full)
    if ($raw -match '(?<!function\s)Get-CsrAlgorithms') {
        throw "Legacy CSR execution path detected in $relative"
    }
}
