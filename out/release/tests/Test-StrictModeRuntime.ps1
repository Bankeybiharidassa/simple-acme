#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent

Import-Module (Join-Path $root 'core/Native-Process.psm1') -Force
Import-Module (Join-Path $root 'core/Simple-Acme-Reconciler.psm1') -Force

$envValues = @{
    ACME_DIRECTORY='https://test-acme.networking4all.com/dv'
    DOMAINS='remote4.itsecured.nl'
    ACME_SCRIPT_PATH=(Join-Path $root 'Scripts/cert2rds.ps1')
    ACME_SCRIPT_PARAMETERS='{CertThumbprint}'
    ACME_WACS_VERSION='Software version 2.3.0.0 (release)'
    ACME_INSTALLATION_PLUGINS='script'
    ACME_ORDER_PLUGIN='single'
    ACME_STORE_PLUGIN='certificatestore'
}

Test-ReconcilePreflight -EnvValues $envValues | Out-Null

Write-Host 'StrictMode runtime test passed.'
