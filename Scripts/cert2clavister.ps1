#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CertThumbprint = '',
    [string]$CacheFile = '',
    [string]$PfxPath = '',
    [string]$CachePassword = '',
    [SecureString]$PfxPassword,
    [string]$CertPath = '',
    [string]$KeyPath = '',
    [string]$ConfigDir = $env:CERTIFICATE_CONFIG_DIR,
    [string]$DeviceId = 'clavister-netwall',
    [string]$ClavisterHost = '',
    [ValidateRange(1, 65535)][int]$Port = 22,
    [string]$Username = '',
    [SecureString]$Password,
    [string]$PrivateKeyPath = '',
    [string]$SshHostKeyFingerprint = '',
    [string]$CertificateName = '',
    [switch]$Commit,
    [switch]$Activate,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
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
