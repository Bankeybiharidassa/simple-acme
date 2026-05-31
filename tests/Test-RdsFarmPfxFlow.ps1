Set-StrictMode -Version Latest
function Invoke-TestRdsFarmPfxFlow {
 param([scriptblock]$Assert)
 & $Assert 'RDS farm PFX password is resolved from wacs cache or secure config reference' {
  $txt = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1') -Raw
  if ($txt -notmatch 'CachePassword') { throw 'Missing CachePassword support.' }
  if ($txt -notmatch 'Resolve-DeploymentSecret') { throw 'Missing secure deployment secret resolution.' }
  if ($txt -notmatch 'PFX_PASSWORD_REF') { throw 'Missing PFX_PASSWORD_REF support.' }
 }
 & $Assert 'deploy-rds-sessionhost exits non-zero when PFX path missing' {
  $script = Join-Path $PSScriptRoot '..\Scripts\deploy-rds-sessionhost.ps1'
  $p = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'ABCDEF','C:\notfound.pfx','dummy-password') -Wait -PassThru
  if ($p.ExitCode -eq 0) { throw 'Expected non-zero exit code.' }
 }
}
