Set-StrictMode -Version Latest

function Invoke-TestRdsFarmContract {
 param([scriptblock]$Assert)

 & $Assert 'deploy-rds-farm parameter contract matches reference shape (AST)' {
  $scriptPath = Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1'
  $errors = $null; $tokens = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Parser errors in deploy-rds-farm.ps1: $($errors.Count)" }
  $paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
  $expected = @('CertThumbprint','CachePassword','CacheFile','PfxStorePath','PfxPassword','SessionHosts')
  foreach ($name in $expected) { if ($paramNames -notcontains $name) { throw "Missing required parameter: $name" } }
 }

 & $Assert 'deploy-rds-farm CertThumbprint supports NewCertThumbprint alias (AST)' {
  $scriptPath = Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1'
  $errors = $null; $tokens = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
  $certParam = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'CertThumbprint' })[0]
  if ($null -eq $certParam) { throw 'CertThumbprint parameter missing.' }
  $aliases = @()
  foreach($attr in $certParam.Attributes){
    if($attr.TypeName.FullName -eq 'Alias' -or $attr.TypeName.FullName -eq 'AliasAttribute'){
      foreach($arg in $attr.PositionalArguments){
        if($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]){ $aliases += $arg.Value }
      }
    }
  }
  if ($aliases -notcontains 'NewCertThumbprint') { throw 'CertThumbprint must include Alias(NewCertThumbprint).' }
 }

 & $Assert 'rds-farm ACME_SCRIPT_PARAMETERS contains thumbprint/cache placeholders and session-host emission' {
  $path = Join-Path $PSScriptRoot '..\setup\Form-Runner.psm1'
  $txt = Get-Content -LiteralPath $path -Raw
  if ($txt -notmatch "-CertThumbprint '\{CertThumbprint\}'") { throw 'Missing CertThumbprint placeholder for rds-farm.' }
  if ($txt -notmatch "-CachePassword '\{CachePassword\}'") { throw 'Missing CachePassword placeholder for rds-farm.' }
  if ($txt -notmatch "-CacheFile '\{CacheFile\}'") { throw 'Missing CacheFile placeholder for rds-farm.' }
  if ($txt -notmatch "-SessionHosts '\$\(\[string\]::Join\(',', \$sessionHosts\)\)'") { throw 'Missing SessionHosts emission from selected session hosts.' }
 }
}
