Set-StrictMode -Version Latest
function Invoke-TestRdsFarmDeploymentModel {
 param([scriptblock]$Assert)
 & $Assert 'deployment model should not store password keys' {
  $path = Join-Path $PSScriptRoot '..\deployment-targets.json'
  if (Test-Path -LiteralPath $path) {
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ($raw -match 'pfxPassword' -or $raw -match '"password"') { throw 'Found forbidden password key.' }
    if ($raw -notmatch '"schema"') { throw 'Missing schema field.' }
  }
 }
 & $Assert 'deploy-rds-farm exits non-zero when deployment-targets missing' {
  $script = Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1'
  $tmp = Join-Path $env:TEMP ('sa-' + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  Copy-Item -LiteralPath $script -Destination (Join-Path $tmp 'deploy-rds-farm.ps1')
  $p = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $tmp 'deploy-rds-farm.ps1'),'ABC') -Wait -PassThru
  if ($p.ExitCode -eq 0) { throw 'Expected non-zero exit code.' }
 }
}
