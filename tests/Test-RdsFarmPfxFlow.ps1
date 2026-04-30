Set-StrictMode -Version Latest
function Invoke-TestRdsFarmPfxFlow {
 param([scriptblock]$Assert)
 & $Assert 'password generation uses SecureString pattern' {
  $txt = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1') -Raw
  if ($txt -notmatch 'GeneratePassword\(32,\s*8\)') { throw 'Missing GeneratePassword call.' }
  if ($txt -notmatch 'ConvertTo-SecureString') { throw 'Missing SecureString conversion.' }
 }
 & $Assert 'deploy-rds-sessionhost exits non-zero when PFX path missing' {
  $script = Join-Path $PSScriptRoot '..\Scripts\deploy-rds-sessionhost.ps1'
  $pwd = ConvertTo-SecureString 'x' -AsPlainText -Force
  $p = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'ABCDEF','C:\notfound.pfx') -Wait -PassThru
  if ($p.ExitCode -eq 0) { throw 'Expected non-zero exit code.' }
 }
}
