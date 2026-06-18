#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CertThumbprint = '',
    [string]$CertCommonName = '',
    [string]$CacheFile = '',
    [string]$PfxPath = '',
    [string]$CachePassword = '',
    [SecureString]$PfxPassword,
    [string]$CertPath = '',
    [string]$KeyPath = '',
    [string]$ConfigDir = $env:CERTIFICATE_CONFIG_DIR,
    [string]$DeviceId = 'paloalto-firewall',
    [string]$Firewall = '',
    [ValidateRange(1, 65535)][int]$Port = 443,
    [string]$ApiKey = '',
    [string]$ApiKeySecureFile = '',
    [string]$CertName = '',
    [string]$BindingType = '',
    [string]$BindingTarget = '',
    [string]$Vsys = '',
    [string]$KeyPassphrase = '',
    [switch]$SkipCertificateCheck,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 120
)

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = Join-Path $ScriptRoot ("connectors/{0}" -f [System.IO.Path]::GetFileName($MyInvocation.MyCommand.Path))

if (-not (Test-Path -LiteralPath $ScriptPath)) {
throw @"
Required deployment script not found.

Expected:
$ScriptPath

Check:

* Scripts folder location
* Installation directory

Tip:
Re-run installer or verify installation.
"@
}

$ResolvedScriptPath = (Resolve-Path -LiteralPath $ScriptPath -ErrorAction Stop).Path
$forward = @{}
foreach ($key in $PSBoundParameters.Keys) {
    $forward[$key] = $PSBoundParameters[$key]
}
& $ResolvedScriptPath @forward
exit $LASTEXITCODE
