$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/Crypto.psm1" -Force

$script:RequiredEnvKeys = @(
    'ACME_DIRECTORY',
    'DOMAINS'
)

$script:OptionalEnvDefaults = @{
    ACME_SOURCE_PLUGIN            = 'manual'
    ACME_ORDER_PLUGIN             = 'single'
    ACME_STORE_PLUGIN             = 'certificatestore'
    ACME_ACCOUNT_NAME             = ''
    ACME_VALIDATION_MODE          = 'none'
    ACME_WACS_RETRY_ATTEMPTS      = '3'
    ACME_WACS_RETRY_DELAY_SECONDS = '2'
    ACME_INSTALLATION_PLUGINS     = 'script'
    ACME_CSR_ALGORITHM            = 'ec'
    ACME_WACS_PATH                = ''
    ACME_WACS_SOURCE              = 'official-release'
    ACME_WACS_AUTO_UPDATE         = '0'
    ACME_WACS_RELEASE_ZIP         = ''
    ACME_WACS_RELEASE_SHA256      = ''
    ACME_SCRIPT_PARAMETERS        = '{CertThumbprint}'
    CERTIFICATE_VERIFY_MAX_ATTEMPTS = '3'
    CERTIFICATE_ACTIVATE_TIMEOUT_MS = '120000'
    CERTIFICATE_DEFAULT_FANOUT      = 'fail-fast'
    CERTIFICATE_SKIP_TLS_CHECK      = '0'
    CERTIFICATE_RETRY_MAX_ATTEMPTS  = '3'
    CERTIFICATE_RETRY_BACKOFF_MS    = '1000'
    CERTIFICATE_HTTP_ENABLED        = '0'
    CERTIFICATE_HTTP_PREFIX         = 'http://localhost:8443/'
    CERTIFICATE_DISABLE_ROLLBACK    = '0'
    CERTIFICATE_HTTP_HOST           = '127.0.0.1'
    CERTIFICATE_HTTP_PORT           = '8088'
}


function ConvertFrom-SecureStringToPlainText {
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Import-SecureOverlay {
    param([Parameter(Mandatory)][hashtable]$Values)
    $configDir = if ($Values.ContainsKey('CERTIFICATE_CONFIG_DIR')) { [string]$Values.CERTIFICATE_CONFIG_DIR } else { [Environment]::GetEnvironmentVariable('CERTIFICATE_CONFIG_DIR') }
    if ([string]::IsNullOrWhiteSpace($configDir)) { return $Values }
    foreach ($name in @('env.secure','credentials.sec')) {
        $path = Join-Path $configDir $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try { $raw = [System.IO.File]::ReadAllText($path); $obj = $raw | ConvertFrom-Json }
        catch {
            try { $legacy = Import-Clixml -LiteralPath $path; if ($legacy) { foreach($k in $legacy.Keys){ $Values[$k] = [string]$legacy[$k] } } ; continue } catch { Write-Warning "Could not read ${name}: $($_.Exception.Message)"; continue }
        }
        foreach ($prop in $obj.PSObject.Properties) {
            try { $Values[$prop.Name] = Unprotect-DpapiValue -CiphertextBase64 ([string]$prop.Value) -Scope LocalMachine } catch { Write-Warning "Could not decrypt '$($prop.Name)' from ${name}: $($_.Exception.Message)" }
        }
    }
    return $Values
}

function Resolve-BootstrapEnvPath {
    param([string]$ProjectRoot = '')

    $fromEnv = [Environment]::GetEnvironmentVariable('CERTIFICATE_ENV_FILE')
    if (-not [string]::IsNullOrWhiteSpace([string]$fromEnv)) {
        return [System.IO.Path]::GetFullPath([string]$fromEnv)
    }

    $resolvedProjectRoot = [string]$ProjectRoot
    if ([string]::IsNullOrWhiteSpace($resolvedProjectRoot)) {
        $resolvedProjectRoot = Split-Path $PSScriptRoot -Parent
    }

    return [System.IO.Path]::GetFullPath((Join-Path $resolvedProjectRoot 'certificate.env'))
}

function Resolve-EnvPath {
    param(
        [string]$Path = '',
        [string]$ProjectRoot = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $explicit = [System.IO.Path]::GetFullPath($Path)
        if (Test-Path -LiteralPath $explicit) { return $explicit }
        throw "Env file not found: $explicit"
    }

    $candidate = Resolve-BootstrapEnvPath -ProjectRoot $ProjectRoot
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    throw "No certificate.env could be resolved. Expected: $candidate"
}

function Read-EnvFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Env file not found: $Path" }

    $result = @{}
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $lineNo++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trimStart = $line.TrimStart()
        if ($trimStart.StartsWith('#')) { continue }

        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { throw "Invalid .env line $lineNo in '$Path'. Expected KEY=VALUE format." }

        $key = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1)
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if ($result.ContainsKey($key)) { throw "Duplicate key '$key' found at line $lineNo in '$Path'." }
        $result[$key] = $value
    }

    return $result
}

function Read-EffectiveEnvFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$ValidateRequired
    )

    $values = Read-EnvFile -Path $Path
    $values = Import-SecureOverlay -Values $values
    if ($ValidateRequired) {
        $missing = @($script:RequiredEnvKeys | Where-Object { -not $values.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$values[$_]) })
        $requiresEab = $values.ContainsKey('ACME_REQUIRES_EAB') -and [string]$values.ACME_REQUIRES_EAB -eq '1'
        if ($requiresEab) {
            foreach ($key in @('ACME_KID','ACME_HMAC_SECRET')) {
                if (-not $values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$values[$key])) {
                    $missing += $key
                }
            }
        }
        $missing = @($missing | Select-Object -Unique)
        if ($missing.Count -gt 0) {
            throw "Missing required environment keys in '$Path': $($missing -join ', ')"
        }
    }
    return $values
}

function Import-EnvFile {
    param(
        [string]$Path = '',
        [switch]$Force,
        [switch]$AllowIncomplete,
        [string]$ProjectRoot = ''
    )

    $resolved = Resolve-EnvPath -Path $Path -ProjectRoot $ProjectRoot
    $values = Read-EnvFile -Path $resolved
    $values = Import-SecureOverlay -Values $values

    if (-not $AllowIncomplete) {
        $missing = @($script:RequiredEnvKeys | Where-Object { -not $values.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$values[$_]) })
        $requiresEab = $values.ContainsKey('ACME_REQUIRES_EAB') -and [string]$values.ACME_REQUIRES_EAB -eq '1'
        if ($requiresEab) {
            foreach ($key in @('ACME_KID','ACME_HMAC_SECRET')) {
                if (-not $values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$values[$key])) {
                    $missing += $key
                }
            }
        }

        $installationPlugins = @()
        if ($values.ContainsKey('ACME_INSTALLATION_PLUGINS')) {
            $installationPlugins = @([string]$values.ACME_INSTALLATION_PLUGINS -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
        } elseif ($script:OptionalEnvDefaults.ContainsKey('ACME_INSTALLATION_PLUGINS')) {
            $installationPlugins = @([string]$script:OptionalEnvDefaults.ACME_INSTALLATION_PLUGINS -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
        }
        if ($installationPlugins -contains 'script') {
            foreach ($key in @('ACME_SCRIPT_PATH')) {
                if (-not $values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$values[$key])) {
                    $missing += $key
                }
            }
        }
        $missing = @($missing | Select-Object -Unique)
        if ($missing.Count -gt 0) {
            throw "Missing required environment keys in '$resolved': $($missing -join ', ')"
        }
    }

    foreach ($key in $script:OptionalEnvDefaults.Keys) {
        if (-not $values.ContainsKey($key)) { $values[$key] = $script:OptionalEnvDefaults[$key] }
    }

    $appliedKeys = New-Object System.Collections.Generic.List[string]
    $skippedKeys = New-Object System.Collections.Generic.List[string]

    foreach ($key in $values.Keys) {
        $existing = [Environment]::GetEnvironmentVariable($key)
        if (-not $Force -and -not [string]::IsNullOrWhiteSpace($existing)) {
            $skippedKeys.Add([string]$key)
            Write-Verbose "Skipping existing env var '$key' because -Force was not specified."
            continue
        }
        [Environment]::SetEnvironmentVariable($key, [string]$values[$key])
        $appliedKeys.Add([string]$key)
    }

    $summary = [ordered]@{
        AppliedCount = $appliedKeys.Count
        SkippedCount = $skippedKeys.Count
        AppliedKeys = @($appliedKeys)
        SkippedKeys = @($skippedKeys)
    }
    $values['__ENV_IMPORT_SUMMARY'] = $summary

    Write-Verbose ("Env import summary: applied {0}, skipped {1}." -f $summary.AppliedCount, $summary.SkippedCount)

    return $values
}

function Set-EnvFileAcl {
    param([Parameter(Mandatory)][string]$Path)

    if (-not ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)) { return }

    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)

    $systemAccount = New-Object System.Security.Principal.NTAccount('SYSTEM')
    $administratorsAccount = New-Object System.Security.Principal.NTAccount('Administrators')

    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $inheritFlags = [System.Security.AccessControl.InheritanceFlags]::None
    $propagationFlags = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($systemAccount, $fullControl, $inheritFlags, $propagationFlags, $allow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($administratorsAccount, $fullControl, $inheritFlags, $propagationFlags, $allow)))

    [System.IO.File]::SetAccessControl($Path, $acl)
}


function Write-SecureOverlay {
    param([Parameter(Mandatory)][string]$ConfigDir,[Parameter(Mandatory)][hashtable]$Values)
    if (-not (Test-Path -LiteralPath $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    $out = [ordered]@{}
    foreach ($k in $Values.Keys) { $out[$k] = Protect-DpapiValue -Plaintext ([string]$Values[$k]) -Scope LocalMachine }
    ($out | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $ConfigDir 'env.secure') -Encoding UTF8
}

function Write-CredentialStore {
    param([Parameter(Mandatory)][string]$ConfigDir,[Parameter(Mandatory)][hashtable]$Values)
    if (-not (Test-Path -LiteralPath $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    $out = [ordered]@{}
    foreach ($k in @('ACME_KID','ACME_HMAC_SECRET','ACME_API_KEY')) {
        if ($Values.ContainsKey($k) -and -not [string]::IsNullOrWhiteSpace([string]$Values[$k])) {
            $out[$k] = Protect-DpapiValue -Plaintext ([string]$Values[$k]) -Scope LocalMachine
        }
    }
    ($out | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Join-Path $ConfigDir 'credentials.sec') -Encoding UTF8
}

function Write-EnvFile {
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$Path,
        [string]$Header = '# Certificate configuration - generated by certificate-setup.ps1'
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($Header)
    $lines.Add('')

    $allowed = @(
        # Bootstrap/plain env values: defaults + operator secrets used at first-run boundaries.
        'DOMAINS','ACME_DIRECTORY','ACME_WACS_PATH','CERTIFICATE_CONFIG_DIR','CERTIFICATE_DROP_DIR','CERTIFICATE_STATE_DIR','CERTIFICATE_LOG_DIR','ACME_DATA_DIR',
        'ACME_PROVIDER','ACME_REQUIRES_EAB','ACME_NETWORKING4ALL_ENVIRONMENT','ACME_NETWORKING4ALL_PRODUCT',
        'ACME_KID','ACME_HMAC_SECRET'
    )
    foreach ($key in ($Values.Keys | Where-Object { $allowed -contains $_ } | Sort-Object)) {
        $value = [string]$Values[$key]
        if ($value.Contains('=') -or $value.Contains('#')) {
            $escaped = '"{0}"' -f $value.Replace('"', '""')
            $lines.Add("$key=$escaped")
        } else {
            $lines.Add("$key=$value")
        }
    }

    $directory = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tmpPath = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllLines($tmpPath, $lines, [System.Text.Encoding]::UTF8)
    Move-Item -LiteralPath $tmpPath -Destination $Path -Force
    Set-EnvFileAcl -Path $Path
}

$FunctionsToExport = New-Object System.Collections.Generic.List[string]
$FunctionsToExport.Add('Resolve-BootstrapEnvPath')
$FunctionsToExport.Add('Read-EnvFile')
$FunctionsToExport.Add('Read-EffectiveEnvFile')
$FunctionsToExport.Add('Import-EnvFile')
$FunctionsToExport.Add('Write-EnvFile')
$FunctionsToExport.Add('Write-SecureOverlay')
$FunctionsToExport.Add('Write-CredentialStore')

$MissingExports = @()
foreach ($fn in $FunctionsToExport) {
    if (-not (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) {
        $MissingExports += $fn
    }
}

if ($MissingExports.Count -gt 0) {
    throw ('Export list contains missing function(s): ' + ($MissingExports -join ', '))
}

Export-ModuleMember -Function ([string[]]$FunctionsToExport.ToArray())
