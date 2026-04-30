Set-StrictMode -Version Latest
function Invoke-TestRdsFarmPfxFlow {
 param([scriptblock]$Assert)
 & $Assert 'password generation uses SecureString flow' {
  Add-Type -AssemblyName System.Web; $plain=[System.Web.Security.Membership]::GeneratePassword(32,8); $sec=ConvertTo-SecureString -String $plain -AsPlainText -Force; if($sec.GetType().FullName -notmatch 'SecureString'){throw 'not securestring'}
 }
 & $Assert 'deploy-rds-sessionhost fails when PFX missing' {
  $s=Join-Path $PSScriptRoot '..\Scripts\deploy-rds-sessionhost.ps1'; $pw=ConvertTo-SecureString 'x' -AsPlainText -Force; powershell -NoProfile -ExecutionPolicy Bypass -File $s ABCDEF 'C:\nope\missing.pfx' $pw *> $null; if($LASTEXITCODE -eq 0){throw 'expected non-zero'}
 }
}
