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
