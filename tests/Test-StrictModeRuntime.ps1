#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent

Import-Module (Join-Path $root 'core/Native-Process.psm1') -Force
Import-Module (Join-Path $root 'core/Simple-Acme-Reconciler.psm1') -Force

$tempRoot = Join-Path $env:TEMP ('simple-acme-strictmode-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$stubWacs = Join-Path $tempRoot 'simple-acme.exe'
Set-Content -LiteralPath $stubWacs -Value 'stub' -Encoding ASCII

$envValues = @{
    ACME_DIRECTORY='https://test-acme.networking4all.com/dv'
    DOMAINS='remote4.itsecured.nl'
    ACME_SCRIPT_PATH=(Join-Path $root 'Scripts/cert2rds.ps1')
    ACME_SCRIPT_PARAMETERS='{CacheFile}'
    ACME_WACS_PATH=$stubWacs
    ACME_WACS_VERSION='Software version 2.3.0.0 (release)'
    ACME_INSTALLATION_PLUGINS='script'
    ACME_ORDER_PLUGIN='single'
    ACME_STORE_PLUGIN='pfxfile'
    ACME_PFX_FILE_PATH=$tempRoot
}

try {
    Test-ReconcilePreflight -EnvValues $envValues | Out-Null
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'StrictMode runtime test passed.'
