[CmdletBinding()]
param(
    [string]$ArtifactPath = './artifacts/simple-acme.v2.3.0.0.linux-x64.trimmed.zip',
    [string]$DebugPath = './debug',
    [string]$HostName = 'linux.wouter.tinus.online'
)

if (Test-Path $DebugPath) {
    Remove-Item -Path $DebugPath -Recurse -Force
}

New-Item -ItemType Directory -Path $DebugPath -Force | Out-Null
Expand-Archive -Path $ArtifactPath -DestinationPath $DebugPath -Force

$arguments = @(
    '--source', 'manual',
    '--host', $HostName,
    '--store', 'pemfiles',
    '--pemfilespath', '/mnt/i',
    '--installation', 'script',
    '--script', '/mnt/i/script.ps1',
    '--scriptparameters', 'bla',
    '--verbose',
    '--test',
    '--accepttos'
)

& (Join-Path $DebugPath 'wacs') @arguments
