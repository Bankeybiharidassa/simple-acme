param([Parameter(Position=0, Mandatory=$true)][string]$NewCertThumbprint)
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'core\connector-core.psm1') -Force
$root = Split-Path $PSScriptRoot -Parent
$targetsPath = Join-Path $root 'deployment-targets.json'
if (-not (Test-Path -LiteralPath $targetsPath)) { Write-Error 'deployment-targets.json missing.'; exit 1 }
$targets = Get-Content -LiteralPath $targetsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$thumb = Assert-CertThumbprint -Thumbprint $NewCertThumbprint
$cert = Get-CertificateByThumbprint -Thumbprint $thumb -PrimaryStorePath 'Cert:\LocalMachine\My'
if ($null -eq $cert) { Write-Error 'Certificate not found.'; exit 1 }
if (-not $cert.HasPrivateKey) { Write-Error 'Certificate missing private key.'; exit 1 }
& (Join-Path $PSScriptRoot 'cert2rds.ps1') $thumb; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$runtime = Join-Path $root 'runtime'; if (-not (Test-Path $runtime)) { New-Item -ItemType Directory -Path $runtime | Out-Null }
Add-Type -AssemblyName System.Web
$plainPassword=[System.Web.Security.Membership]::GeneratePassword(32,8); $securePassword=ConvertTo-SecureString -String $plainPassword -AsPlainText -Force; $plainPassword=$null
$pfxPath = Join-Path $runtime ('cert-'+$thumb+'.pfx')
[IO.File]::WriteAllBytes($pfxPath, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $securePassword))
$failed=0
foreach($host in @($targets.sessionHosts)) { if(-not $host.enabled){continue}; try { Invoke-Command -ComputerName $host.computerName -ScriptBlock { param($t,$pp,$pw) & "$t\Scripts\deploy-rds-sessionhost.ps1" $pp $args[2] $pw } -ArgumentList $root,$thumb,$securePassword -ErrorAction Stop; Write-Host "OK $($host.computerName)" } catch { $failed++; Write-Warning "FAILED $($host.computerName): $($_.Exception.Message)" } }
Remove-Item -LiteralPath $pfxPath -Force -ErrorAction SilentlyContinue
if($failed -gt 0){ exit 1 }
exit 0
