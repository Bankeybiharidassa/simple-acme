Set-StrictMode -Version Latest
function Invoke-TestRdsFarmConfigFileContract {
 param([scriptblock]$Assert)

 & $Assert 'deploy-rds-farm exposes optional ConfigFile and SessionHosts fallback contract (AST)' {
  $scriptPath = Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1'
  $errors = $null; $tokens = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Parser errors in deploy-rds-farm.ps1: $($errors.Count)" }
  $paramMap = @{}
  foreach ($parameter in $ast.ParamBlock.Parameters) { $paramMap[$parameter.Name.VariablePath.UserPath] = $parameter }
  foreach ($name in @('ConfigFile','SessionHosts','PfxStorePath','PfxPassword','RemoteTempDirectory')) {
    if (-not $paramMap.ContainsKey($name)) { throw "Missing parameter: $name" }
  }
  $sessionHosts = $paramMap['SessionHosts']
  foreach ($attr in $sessionHosts.Attributes) {
    if ($attr.TypeName.FullName -eq 'Parameter' -or $attr.TypeName.FullName -eq 'ParameterAttribute') {
      foreach ($namedArg in $attr.NamedArguments) {
        if ($namedArg.ArgumentName -eq 'Mandatory' -and [string]$namedArg.Argument.Extent.Text -eq '$true') { throw 'SessionHosts must not be mandatory because -ConfigFile and deployment-targets.json can provide fallback values.' }
      }
    }
  }
 }

 & $Assert 'deploy-rds-farm implements args over config over deployment-targets precedence hooks' {
  $txt = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1') -Raw
  foreach ($needle in @(
    'Read-ConnectorDeploymentConfigFile -Path $ConfigFile',
    '$PSBoundParameters.ContainsKey(''SessionHosts'')',
    'Resolve-ConnectorConfigValue -Config $config -Keys @(''HOSTS'',''SESSION_HOSTS'')',
    'Resolve-HostsFromTargets',
    "Pass -SessionHosts, set HOSTS in -ConfigFile, or configure deployment-targets.json"
  )) {
    if ($txt -notlike "*$needle*") { throw "Missing precedence/fallback hook: $needle" }
  }
 }

 & $Assert 'deploy-rds-farm supports secure PFX password references from config' {
  $txt = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1') -Raw
  foreach ($needle in @(
    'Resolve-DeploymentSecret',
    'PFX_PASSWORD_REF',
    'credentials.sec',
    'Unprotect-DpapiValue',
    'PFX_PASSWORD in -ConfigFile'
  )) {
    if ($txt -notlike "*$needle*") { throw "Missing secure secret fallback hook: $needle" }
  }
 }

 & $Assert 'rds-farm TUI persists deployment config and emits ConfigFile without plaintext PFX password parameter' {
  $txt = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\setup\Form-Runner.psm1') -Raw
  foreach ($needle in @(
    'Write-ExternalDeploymentConfigFile',
    "runtime\deployment",
    "rds-farm.env",
    "PFX_PASSWORD_REF = 'ACME_PFX_PASSWORD'",
    '-ConfigFile $quotedDeploymentConfigPath'
  )) {
    if ($txt -notlike "*$needle*") { throw "Missing TUI ConfigFile wiring: $needle" }
  }
  if ($txt -match "ACME_SCRIPT_PARAMETERS = .*PfxPassword") { throw 'RDS farm ACME_SCRIPT_PARAMETERS must not persist plaintext -PfxPassword.' }
 }
}
