Set-StrictMode -Version Latest
function Invoke-TestRdsFarmDeploymentModel {
 param([scriptblock]$Assert)
 & $Assert 'deployment-targets excludes password fields' {
  $p=Join-Path $PSScriptRoot '..\deployment-targets.json'; if(Test-Path $p){$t=Get-Content -Raw $p; if($t -match 'password' -or $t -match 'pfxPassword'){throw 'contains password keys'}; if($t -notmatch '"schema"'){throw 'missing schema'}}
 }
 & $Assert 'deploy-rds-farm fails without targets file' {
  $s=Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1'; $tmp=Join-Path $env:TEMP ('dt-'+[guid]::NewGuid()); New-Item -ItemType Directory $tmp|Out-Null; Copy-Item $s (Join-Path $tmp 'deploy-rds-farm.ps1'); powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'deploy-rds-farm.ps1') BAD *> $null; if($LASTEXITCODE -eq 0){throw 'expected non-zero'}
 }
}
