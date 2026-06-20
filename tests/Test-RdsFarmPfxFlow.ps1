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
 & $Assert 'deploy-rds-farm captures local cert2rds child output on failure' {
  $txt = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1') -Raw
  foreach ($expected in @('RedirectStandardOutput','RedirectStandardError','stdoutTail','stderrTail','Last output')) {
   if ($txt -notmatch [regex]::Escape($expected)) { throw "Missing child-output capture marker: $expected" }
  }
 }
 & $Assert 'deploy-rds-farm keeps standalone farm safety checks' {
  $farm = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1') -Raw
  foreach ($expected in @('Assert-Admin','Assert-FileReadable','rds-cert-{0}.pfx','[guid]::NewGuid')) {
   if ($farm -notmatch [regex]::Escape($expected)) { throw "Missing farm safety marker: $expected" }
  }
  $sessionHost = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Scripts\deploy-rds-sessionhost.ps1') -Raw
  if ($sessionHost -match '-Exportable') { throw 'Session host PFX import must not mark private key exportable.' }
  foreach ($expected in @('HasPrivateKey','Remove-Item -LiteralPath $PfxPath')) {
   if ($sessionHost -notmatch [regex]::Escape($expected)) { throw "Missing session host safety marker: $expected" }
  }
 }
}
