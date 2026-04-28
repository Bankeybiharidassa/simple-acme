$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module "$PSScriptRoot/Native-Process.psm1" -Force


function ConvertTo-HashtableRecursive {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string]) -and -not ($InputObject -is [System.Management.Automation.PSCustomObject])) {
        $array = @()
        foreach ($item in $InputObject) {
            $array += ConvertTo-HashtableRecursive -InputObject $item
        }
        return $array
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $hash = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-HashtableRecursive -InputObject $prop.Value
        }
        return $hash
    }

    return $InputObject
}

function Get-NormalizedDomains {
    param([Parameter(Mandatory)][string]$Domains)

    return @(
        $Domains -split ',' |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}




function Get-SafeCount {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return 0
    }

    return @($Value).Count
}

function As-Array {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return @()
    }

    return @($Value)
}

function Get-EnvValue {
    param(
        [Parameter(Mandatory)]
        [hashtable]$EnvValues,

        [Parameter(Mandatory)]
        [string]$Key,

        [string]$Default = ''
    )

    if ($null -eq $EnvValues) {
        return $Default
    }

    if ($EnvValues.ContainsKey($Key)) {
        $value = $EnvValues[$Key]
        if ($null -eq $value) {
            return $Default
        }
        return [string]$value
    }

    return $Default
}

function Test-EnvFlag {
    param(
        [Parameter(Mandatory)][hashtable]$EnvValues,
        [Parameter(Mandatory)][string]$Key
    )

    $value = (Get-EnvValue -EnvValues $EnvValues -Key $Key -Default '').Trim().ToLowerInvariant()
    return ($value -in @('1','true','yes','y','on'))
}

function Resolve-WacsExecutable {
    param([hashtable]$EnvValues = @{})

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($null -ne $EnvValues -and $EnvValues.ContainsKey('ACME_WACS_PATH')) {
        $configured = (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_WACS_PATH')
        if (-not [string]::IsNullOrWhiteSpace($configured)) {
            $candidates.Add($configured)
        }
    }

    $projectRoot = Split-Path $PSScriptRoot -Parent
    $candidates.Add((Join-Path $projectRoot 'wacs.exe'))
    $candidates.Add((Join-Path $projectRoot 'simple-acme.exe'))

    foreach ($cmdName in @('wacs.exe','wacs')) {
        $cmd = Get-Command $cmdName -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            $candidates.Add([string]$cmd.Source)
        }
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        if (-not [System.IO.Path]::IsPathRooted($expanded)) {
            $expanded = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $expanded))
        }
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            return [string](Convert-Path -LiteralPath $expanded -ErrorAction Stop)
        }
    }

    throw @"
simple-acme executable not found.

Expected one of:
- .\wacs.exe
- .\simple-acme.exe
- configured ACME_WACS_PATH
- wacs.exe on PATH

Fix:
Place wacs.exe in the project root or set ACME_WACS_PATH in certificate.env.
"@
}

function Test-ValidDomainName {
    param([Parameter(Mandatory)][string]$Domain)
    $candidate = $Domain.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
    if ($candidate.Length -gt 253) { return $false }
    if ($candidate -notmatch '^(?=.{1,253}$)(?!-)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') { return $false }
    return $true
}

function Get-RenewalFiles {
    param([string]$SimpleAcmeDir = (Join-Path $env:ProgramData 'simple-acme'))

    if ([string]::IsNullOrWhiteSpace($SimpleAcmeDir) -or -not (Test-Path -LiteralPath $SimpleAcmeDir)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $SimpleAcmeDir -Filter '*.renewal.json' -File -ErrorAction SilentlyContinue)
}

function Get-SimpleAcmeLogDirectories {
    param([string]$SimpleAcmeDir = (Join-Path $env:ProgramData 'simple-acme'))
    $dirs = New-Object System.Collections.Generic.List[string]
    $rootLog = Join-Path $SimpleAcmeDir 'Log'
    if (Test-Path -LiteralPath $rootLog -PathType Container) { $dirs.Add((Convert-Path -LiteralPath $rootLog -ErrorAction Stop)) }
    if (Test-Path -LiteralPath $SimpleAcmeDir -PathType Container) {
        foreach ($child in @(Get-ChildItem -LiteralPath $SimpleAcmeDir -Directory -ErrorAction SilentlyContinue)) {
            $candidate = Join-Path $child.FullName 'Log'
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                $dirs.Add((Convert-Path -LiteralPath $candidate -ErrorAction Stop))
            }
        }
    }
    return @($dirs | Select-Object -Unique)
}

function Get-LatestSimpleAcmeLogFile {
    param([string[]]$Directories = @(Get-SimpleAcmeLogDirectories))
    $files = @()
    foreach ($dir in @($Directories)) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $files += @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)
        }
    }
    if ((Get-SafeCount $files) -eq 0) { return $null }
    return ($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
}

function Get-SimpleAcmeLogDiagnosticSummary {
    param([string]$LogPath)
    if ([string]::IsNullOrWhiteSpace([string]$LogPath) -or -not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return [pscustomobject]@{
            LogPath = $LogPath
            WarningCount = 0
            ErrorCount = 0
            HasAssemblyLoadErrors = $false
        }
    }
    $lines = @(Get-Content -LiteralPath $LogPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    $warnings = @($lines | Where-Object { $_ -match '\[WARN\]' })
    $errors = @($lines | Where-Object { $_ -match '\[EROR\]' })
    $assembly = @($errors | Where-Object { $_ -match 'Error loading assembly' })
    return [pscustomobject]@{
        LogPath = $LogPath
        WarningCount = (Get-SafeCount $warnings)
        ErrorCount = (Get-SafeCount $errors)
        HasAssemblyLoadErrors = ((Get-SafeCount $assembly) -gt 0)
    }
}

function Write-SimpleAcmeLogDiagnosticSummary {
    $latest = Get-LatestSimpleAcmeLogFile
    if ($null -eq $latest) {
        Write-Host 'No log files discovered under ProgramData\simple-acme.'
        return
    }
    $summary = Get-SimpleAcmeLogDiagnosticSummary -LogPath $latest.FullName
    Write-Host "Errors: $($summary.ErrorCount)"
    Write-Host "Warnings: $($summary.WarningCount)"
    Write-Host 'Latest log:'
    Write-Host $summary.LogPath
    if ($summary.HasAssemblyLoadErrors) {
        Write-Host ''
        Write-Host 'Assembly load errors were found.'
        Write-Host 'This may indicate blocked DLLs, incompatible bundle files, or optional plugin load failures.'
        Write-Host ''
        Write-Host 'Optional manual repair:'
        Write-Host 'Get-ChildItem C:\certificaat -Recurse | Unblock-File'
    }
}


function Write-ReconcileDiagnostics {
    param(
        [string]$Context = 'simple-acme diagnostics'
    )

    Write-Host ''
    Write-Host $Context
    Write-Host '-----------------------'
    Write-SimpleAcmeLogDiagnosticSummary
    Write-Host ''
}

function Find-PropertyValues {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string[]]$Names
    )

    $matches = New-Object System.Collections.Generic.List[object]

    function Visit-Node {
        param($Node)
        if ($null -eq $Node) { return }

        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($key in $Node.Keys) {
                if ($Names -contains [string]$key) {
                    $matches.Add($Node[$key])
                }
                Visit-Node -Node $Node[$key]
            }
            return
        }

        if ($Node -is [System.Management.Automation.PSCustomObject]) {
            foreach ($property in $Node.PSObject.Properties) {
                if ($Names -contains [string]$property.Name) {
                    $matches.Add($property.Value)
                }
                Visit-Node -Node $property.Value
            }
            return
        }

        if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
            foreach ($item in $Node) {
                Visit-Node -Node $item
            }
        }
    }

    Visit-Node -Node $InputObject
    return @($matches)
}

function Get-RenewalHosts {
    param([Parameter(Mandatory)]$Renewal)

    $hostValues = New-Object System.Collections.Generic.List[string]
    $hostCandidates = Find-PropertyValues -InputObject $Renewal -Names @('Host','Hosts','Identifiers','Identifier')
    foreach ($candidate in $hostCandidates) {
        if ($candidate -is [string]) {
            foreach ($part in ($candidate -split ',')) {
                $v = $part.Trim().ToLowerInvariant()
                if (-not [string]::IsNullOrWhiteSpace($v)) { $hostValues.Add($v) }
            }
        } elseif ($candidate -is [System.Collections.IEnumerable] -and -not ($candidate -is [string])) {
            foreach ($item in $candidate) {
                if ($item -is [string]) {
                    $v = $item.Trim().ToLowerInvariant()
                    if (-not [string]::IsNullOrWhiteSpace($v)) { $hostValues.Add($v) }
                }
            }
        }
    }

    return @($hostValues | Sort-Object -Unique)
}


function Get-NestedValue {
    param([Parameter(Mandatory)]$InputObject,[Parameter(Mandatory)][string[]]$Path)
    $current = $InputObject
    foreach ($part in $Path) {
        if ($null -eq $current) { return $null }
        $prop = $current.PSObject.Properties[$part]
        if ($null -eq $prop) { return $null }
        $current = $prop.Value
    }
    return $current
}

function Get-RenewalSummarySafe {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    try { return Get-RenewalSummary -File $File }
    catch { Write-Warning "Skipping malformed renewal JSON '$($File.FullName)': $($_.Exception.Message)"; return $null }
}

function Get-RenewalSummary {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    try {
        $renewal = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Failed to parse renewal JSON '$($File.FullName)': $($_.Exception.Message)"
    }
    if ($null -eq $renewal) {
        throw "Renewal JSON '$($File.FullName)' parsed as null."
    }
    $baseUriCandidates = Find-PropertyValues -InputObject $renewal -Names @('BaseUri')
    $kidCandidates = Find-PropertyValues -InputObject $renewal -Names @('KeyIdentifier','Kid','EabKeyIdentifier')
    $validationCandidates = Find-PropertyValues -InputObject $renewal -Names @('Plugin','Name','ValidationPlugin')
    $storeCandidates = Find-PropertyValues -InputObject $renewal -Names @('StorePlugin','StoreType','Store')
    $installationCandidates = Find-PropertyValues -InputObject $renewal -Names @('InstallationPlugin','InstallationPlugins','Installation')
    $accountCandidates = Find-PropertyValues -InputObject $renewal -Names @('Account','AccountName')
    $sourceCandidates = Find-PropertyValues -InputObject $renewal -Names @('SourcePlugin','Source')
    $orderCandidates = Find-PropertyValues -InputObject $renewal -Names @('OrderPlugin','Order')
    $renewalIdCandidates = Find-PropertyValues -InputObject $renewal -Names @('Id','RenewalId')
    $scriptCandidates = Find-PropertyValues -InputObject $renewal -Names @('Script','ScriptFileName')
    $scriptParameterCandidates = Find-PropertyValues -InputObject $renewal -Names @('ScriptParameters','Parameters')
    $csrCandidates = Find-PropertyValues -InputObject $renewal -Names @('CsrPlugin','Csr')
    $keyTypeCandidates = Find-PropertyValues -InputObject $renewal -Names @('KeyType','KeyAlgorithm','Algorithm')

    $hosts = Get-RenewalHosts -Renewal $renewal

    $normalizedValidationCandidates = @($validationCandidates | Where-Object { $_ -is [string] } | ForEach-Object { $_.Trim().ToLowerInvariant() })
    $normalizedStoreCandidates = @($storeCandidates | Where-Object { $_ -is [string] } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $normalizedInstallCandidates = @($installationCandidates | Where-Object { $_ -is [string] } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    $resolvedRenewalId = ($renewalIdCandidates | Where-Object { $_ -is [string] } | Select-Object -First 1)
    $resolvedSourcePlugin = ($sourceCandidates | Where-Object { $_ -is [string] } | Select-Object -First 1)
    $resolvedOrderPlugin = ($orderCandidates | Where-Object { $_ -is [string] } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace([string]$resolvedRenewalId)) {
        throw "Renewal JSON '$($File.FullName)' did not contain a usable renewal identifier."
    }
    if ([string]::IsNullOrWhiteSpace([string]$resolvedSourcePlugin)) {
        throw "Renewal JSON '$($File.FullName)' did not contain source plugin metadata."
    }
    if ([string]::IsNullOrWhiteSpace([string]$resolvedOrderPlugin)) {
        throw "Renewal JSON '$($File.FullName)' did not contain order plugin metadata."
    }

    [pscustomobject]@{
        File             = $File
        Renewal          = $renewal
        RenewalId        = $resolvedRenewalId
        Hosts            = $hosts
        BaseUri          = ($baseUriCandidates | Where-Object { $_ -is [string] } | Select-Object -First 1)
        EabKid           = ($kidCandidates | Where-Object { $_ -is [string] } | Select-Object -First 1)
        SourcePlugin     = $resolvedSourcePlugin
        OrderPlugin      = $resolvedOrderPlugin
        StorePlugin      = ($normalizedStoreCandidates | Select-Object -First 1)
        StorePlugins     = $normalizedStoreCandidates
        InstallationPlugins = $normalizedInstallCandidates
        AccountName      = ($accountCandidates | Where-Object { $_ -is [string] } | Select-Object -First 1)
        HasValidationNone = ((Get-SafeCount (@($normalizedValidationCandidates | Where-Object { $_ -eq 'none' }))) -gt 0)
        HasScriptInstallation = ((Get-SafeCount (@($normalizedInstallCandidates | Where-Object { $_ -eq 'script' }))) -gt 0)
        ScriptPaths      = @($scriptCandidates | Where-Object { $_ -is [string] })
        ScriptParameters = @($scriptParameterCandidates | Where-Object { $_ -is [string] })
        CsrPlugin        = ($csrCandidates | Where-Object { $_ -is [string] } | Select-Object -First 1)
        KeyType          = ($keyTypeCandidates | Where-Object { $_ -is [string] } | Select-Object -First 1)
    }
}

function Get-NormalizedCsvValues {
    param([string]$InputText)
    if ([string]::IsNullOrWhiteSpace($InputText)) { return @() }
    return @(
        $InputText -split ',' |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Compare-RenewalWithEnv {
    param(
        [Parameter(Mandatory)]$RenewalSummary,
        [Parameter(Mandatory)][hashtable]$EnvValues
    )

    $expectedHosts = Get-NormalizedDomains -Domains (Get-EnvValue -EnvValues $EnvValues -Key 'DOMAINS')
    $actualHosts = @($RenewalSummary.Hosts | Sort-Object -Unique)
    $expectedScriptPath = (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SCRIPT_PATH')

    $mismatches = New-Object System.Collections.Generic.List[string]

    if ([string]$RenewalSummary.BaseUri -ne (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_DIRECTORY')) {
        $mismatches.Add('BaseUri')
    }

    if (($expectedHosts -join ',') -ne ($actualHosts -join ',')) {
        $mismatches.Add('Domains')
    }

    if ([string]$RenewalSummary.EabKid -ne (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_KID')) {
        $mismatches.Add('EAB kid')
    }
    if ([string]$RenewalSummary.SourcePlugin -ne 'manual') {
        $mismatches.Add('Source plugin')
    }
    if ([string]$RenewalSummary.OrderPlugin -ne (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_ORDER_PLUGIN')) {
        $mismatches.Add('Order plugin')
    }
    $expectedStores = @('certificatestore')
    $actualStores = @($RenewalSummary.StorePlugins | Sort-Object -Unique)
    if (($expectedStores -join ',') -ne ($actualStores -join ',')) {
        $mismatches.Add('Store plugin')
    }
    if ([string]$RenewalSummary.AccountName -ne (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_ACCOUNT_NAME')) {
        $mismatches.Add('Account name')
    }

    if (-not $RenewalSummary.HasValidationNone) {
        $mismatches.Add('Validation plugin none')
    }

    $expectedInstallers = @('script')
    $actualInstallers = @($RenewalSummary.InstallationPlugins | Sort-Object -Unique)
    if (($expectedInstallers -join ',') -ne ($actualInstallers -join ',')) {
        $mismatches.Add('Installation plugins')
    }
    $normalizedScriptPaths = @($RenewalSummary.ScriptPaths | ForEach-Object { [string]$_ })
    if (-not ($normalizedScriptPaths -contains $expectedScriptPath)) {
        $mismatches.Add('Script path')
    }
    $normalizedScriptParameters = @($RenewalSummary.ScriptParameters | ForEach-Object { [string]$_ })
    if (-not ($normalizedScriptParameters -contains '{CertThumbprint}')) {
        $mismatches.Add('Script parameters')
    }

    $requestedCsr = (Get-CsrAlgorithms -EnvValues $EnvValues | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace($requestedCsr) -and -not [string]::IsNullOrWhiteSpace([string]$RenewalSummary.CsrPlugin)) {
        if ([string]$RenewalSummary.CsrPlugin -ne $requestedCsr) {
            $mismatches.Add('CSR plugin')
        }
    }

    if (-not [string]::IsNullOrWhiteSpace((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_KEY_TYPE')) -and -not [string]::IsNullOrWhiteSpace([string]$RenewalSummary.KeyType)) {
        if ([string]$RenewalSummary.KeyType -ne (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_KEY_TYPE')) {
            $mismatches.Add('Key type')
        }
    }

    return [pscustomobject]@{
        Matches    = ((Get-SafeCount $mismatches) -eq 0)
        Mismatches = @($mismatches)
    }
}

function Test-ReconcilePreflight {
    param([Parameter(Mandatory)][hashtable]$EnvValues)

    $wacsPath = Resolve-WacsExecutable -EnvValues $EnvValues
    $detectedVersion = Get-WacsVersion -EnvValues $EnvValues
    $minimumVersion = [version]'2.2'
    $testedRangeNote = 'Tested with simple-acme/wacs 2.2.x through 2.4.x.'
    if ($null -ne $detectedVersion) {
        if ($detectedVersion -lt $minimumVersion) {
            throw "Unsupported simple-acme/wacs version '$detectedVersion'. Minimum supported version is '$minimumVersion'. $testedRangeNote"
        }
    } else {
        Write-Warning 'simple-acme/wacs version could not be detected. Continuing because hard version check is disabled.'
    }

    $missing = @()
    foreach ($key in @('ACME_DIRECTORY','DOMAINS')) {
        if (-not $EnvValues.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$EnvValues[$key])) {
            $missing += $key
        }
    }
    if ((Get-SafeCount $missing) -gt 0) {
        throw "Missing required environment values for reconcile: $($missing -join ', ')"
    }

    $defaultScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts/cert2rds.ps1'
    $scriptPathValue = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SCRIPT_PATH'
    $scriptPath = if (-not [string]::IsNullOrWhiteSpace($scriptPathValue)) { $scriptPathValue } else { $defaultScriptPath }
    if (-not [System.IO.Path]::IsPathRooted($scriptPath)) {
        $scriptPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $PSScriptRoot -Parent) $scriptPath))
    }
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Script installation path does not exist: '$scriptPath'"
    }
    $EnvValues['ACME_SCRIPT_PATH'] = $scriptPath
    $EnvValues['ACME_SCRIPT_PARAMETERS'] = '{CertThumbprint}'
    $requiredRolesRaw = (Get-EnvValue -EnvValues $EnvValues -Key 'CERTIFICATE_REQUIRED_WINDOWS_ROLES')
    if (-not [string]::IsNullOrWhiteSpace($requiredRolesRaw) -and (Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue)) {
        $requiredRoles = @(
            $requiredRolesRaw -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        foreach ($role in $requiredRoles) {
            $feature = Get-WindowsFeature -Name $role -ErrorAction SilentlyContinue
            if ($null -eq $feature -or -not $feature.Installed) {
                throw "Required Windows role/feature '$role' is not installed."
            }
        }
    }

    $domains = Get-NormalizedDomains -Domains ([string](Get-EnvValue -EnvValues $EnvValues -Key 'DOMAINS'))
    if ((Get-SafeCount $domains) -eq 0) {
        throw "DOMAINS did not contain any valid hostnames. Current value: '$((Get-EnvValue -EnvValues $EnvValues -Key 'DOMAINS'))'"
    }
    foreach ($domain in $domains) {
        if (-not (Test-ValidDomainName -Domain $domain)) {
            throw "Invalid domain format in DOMAINS: '$domain'"
        }
    }

    return [pscustomobject]@{
        WacsPath = [string]$wacsPath
        WacsVersion = if ($null -eq $detectedVersion) { '(unknown)' } else { [string]$detectedVersion }
        DomainCount = (Get-SafeCount $domains)
        ScriptPath = $scriptPath
        InstallationPlugins = @('script')
    }
}

function Set-SimpleAcmeSettings {
    param(
        [string]$SimpleAcmeDir = (Join-Path $env:ProgramData 'simple-acme'),
        [hashtable]$EnvValues
    )

    if (-not (Test-Path -LiteralPath $SimpleAcmeDir)) {
        New-Item -ItemType Directory -Path $SimpleAcmeDir -Force | Out-Null
    }

    $settingsPath = Join-Path $SimpleAcmeDir 'settings.json'
    $settings = @{}
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            $existingJson = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $existing = ConvertTo-HashtableRecursive -InputObject $existingJson
        } catch {
            throw "Failed to parse settings JSON '$settingsPath': $($_.Exception.Message)"
        }
        if ($existing) { $settings = $existing }
    }

    if (-not $settings.ContainsKey('ScheduledTask') -or $null -eq $settings.ScheduledTask) {
        $settings.ScheduledTask = @{}
    }

    $settings.ScheduledTask.RenewalDays = 199
    $settings.ScheduledTask.RenewalMinimumValidDays = 16

    if (-not $settings.ContainsKey('Store') -or $null -eq $settings.Store) { $settings.Store = @{} }
    if (-not $settings.Store.ContainsKey('CertificateStore') -or $null -eq $settings.Store.CertificateStore) {
        $settings.Store.CertificateStore = @{}
    }
    $requiresExportable = $false
    if ($null -ne $EnvValues) {
        $targetSystem = (Get-EnvValue -EnvValues $EnvValues -Key 'TARGET_SYSTEM')
        $targetLocation = (Get-EnvValue -EnvValues $EnvValues -Key 'TARGET_LOCATION')
        $explicitExportable = (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_PRIVATEKEY_EXPORTABLE')
        if ($targetSystem -eq 'rds' -or $targetLocation -eq 'cluster-farm' -or $targetLocation -eq 'another-server' -or $explicitExportable -eq 'true') {
            $requiresExportable = $true
        }
    }
    $settings.Store.CertificateStore.PrivateKeyExportable = $requiresExportable

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 12), $utf8NoBom)
}

function Get-InstallationPlugins {
    param([Parameter(Mandatory)][hashtable]$EnvValues)

    $raw = (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_INSTALLATION_PLUGINS')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @('script')
    }

    $valid = @('script','iis')
    $plugins = Get-NormalizedCsvValues -InputText $raw
    if ((Get-SafeCount $plugins) -eq 0) {
        throw 'ACME_INSTALLATION_PLUGINS does not contain any valid values.'
    }

    $unknown = @($plugins | Where-Object { $valid -notcontains $_ })
    if ((Get-SafeCount $unknown) -gt 0) {
        throw "ACME_INSTALLATION_PLUGINS contains unsupported values: $($unknown -join ', ')"
    }

    return $plugins
}

function Get-CsrAlgorithms {
    param([Parameter(Mandatory)][hashtable]$EnvValues)

    $preferred = (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_CSR_ALGORITHM')
    if ([string]::IsNullOrWhiteSpace($preferred)) {
        return @('ec','rsa')
    }

    $normalized = $preferred.Trim().ToLowerInvariant()
    switch ($normalized) {
        'ec' { return @('ec','rsa') }
        'rsa' { return @('rsa') }
        default { throw "Unsupported ACME_CSR_ALGORITHM value '$preferred'. Supported values: ec, rsa." }
    }
}

function Invoke-WacsWithRetry {
    param(
        [Parameter(Mandatory)][string[]]$Args,
        [Parameter(Mandatory)][hashtable]$EnvValues,
        [int]$TimeoutSeconds = 300
    )
    if ((Get-SafeCount $Args) -eq 0) {
        throw @'
wacs was launched without non-interactive arguments and entered interactive mode.
Fix the wrapper command generation.
'@
    }

    $attempts = 3
    [void][int]::TryParse((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_WACS_RETRY_ATTEMPTS' -Default '3'), [ref]$attempts)
    if ($attempts -lt 1) { $attempts = 1 }
    $delaySeconds = 2
    [void][int]::TryParse((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_WACS_RETRY_DELAY_SECONDS' -Default '2'), [ref]$delaySeconds)
    if ($delaySeconds -lt 0) { $delaySeconds = 0 }

    $wacsPath = Resolve-WacsExecutable -EnvValues $EnvValues
    if (-not [System.IO.Path]::IsPathRooted([string]$wacsPath)) {
        throw "Resolved wacs path is not absolute: '$wacsPath'"
    }

    $last = $null
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $last = Invoke-NativeProcess -FilePath $wacsPath -ArgumentList $Args -TimeoutSeconds $TimeoutSeconds -FatalPatterns @('(?i)\bfatal\b')
        $null = Get-WacsOutputAnalysis -OutputLines @($last.OutputLines) -RequireNonInteractiveMode
        foreach ($line in $last.OutputLines) { Write-Host ([string]$line) }
        if ($last.Succeeded) { return $last }
        if ($attempt -lt $attempts) {
            $effectiveDelay = [math]::Pow(2, ($attempt - 1)) * $delaySeconds
            Start-Sleep -Seconds ([int][math]::Ceiling($effectiveDelay))
        }
    }

    if ($last.TimedOut) { throw "wacs timed out after $attempts attempt(s)." }
    $lastOutput = @($last.OutputLines | Select-Object -Last 30)
    $latestLog = Get-LatestSimpleAcmeLogFile
    $stderr = [string]$last.StdErr
    $messageParts = New-Object System.Collections.Generic.List[string]
    $messageParts.Add("wacs issuance failed with exit code $($last.ExitCode).")
    $messageParts.Add('')
    if ((Get-SafeCount $lastOutput) -gt 0) {
        $messageParts.Add('Last output:')
        foreach ($line in $lastOutput) { $messageParts.Add([string]$line) }
        $messageParts.Add('')
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        $messageParts.Add('stderr:')
        $messageParts.Add($stderr.Trim())
        $messageParts.Add('')
    }
    if ($null -ne $latestLog) {
        $messageParts.Add('Latest log:')
        $messageParts.Add([string]$latestLog.FullName)
    } else {
        $messageParts.Add('Latest log:')
        $messageParts.Add('Not found under ProgramData\\simple-acme.')
    }
    throw ($messageParts -join [Environment]::NewLine)
}

function Wait-RenewalFileRemoval {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).ToUniversalTime().AddSeconds($TimeoutSeconds)
    while ((Get-Date).ToUniversalTime() -lt $deadline) {
        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }
        Start-Sleep -Milliseconds 300
    }
    throw "Timed out waiting for renewal file to be removed: $Path"
}

function New-ReconcileConfigHash {
    param([Parameter(Mandatory)][hashtable]$EnvValues)

    $domains = Get-NormalizedDomains -Domains ([string](Get-EnvValue -EnvValues $EnvValues -Key 'DOMAINS'))
    $installers = Get-InstallationPlugins -EnvValues $EnvValues
    $stores = Get-NormalizedCsvValues -InputText ((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_STORE_PLUGIN'))
    $hashInput = @(
        "domains=$($domains -join ',')"
        "validation=$((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_VALIDATION_MODE'))"
        "csr=$((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_CSR_ALGORITHM'))"
        "keytype=$((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_KEY_TYPE'))"
        "script=$((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SCRIPT_PATH'))"
        "installation=$($installers -join ',')"
        "store=$($stores -join ',')"
    ) -join '|'

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($hashInput)
        $hash = $sha.ComputeHash($bytes)
        return [System.BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-WacsFileVersion {
    param([Parameter(Mandatory)][string]$WacsPath)

    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($WacsPath)

        foreach ($candidate in @($info.ProductVersion, $info.FileVersion)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                $m = [regex]::Match([string]$candidate, '\d+\.\d+(?:\.\d+){0,2}')
                if ($m.Success) {
                    return [version]$m.Value
                }
            }
        }
    } catch {
        return $null
    }

    return $null
}

function Get-WacsVersion {
    param([hashtable]$EnvValues)

    $configured = (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_WACS_VERSION')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        $analysis = Get-WacsOutputAnalysis -OutputLines @($configured) -RequireVersion
        return $analysis.Version
    }

    $wacsPath = Resolve-WacsExecutable -EnvValues $EnvValues

    $fileVersion = Get-WacsFileVersion -WacsPath $wacsPath
    if ($null -ne $fileVersion) {
        return $fileVersion
    }

    $timeout = 90
    [void][int]::TryParse((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_WACS_VERSION_TIMEOUT_SECONDS' -Default '90'), [ref]$timeout)
    if ($timeout -lt 10) { $timeout = 10 }

    $requireVersion = Test-EnvFlag -EnvValues $EnvValues -Key 'ACME_REQUIRE_WACS_VERSION_CHECK'

    try {
        $result = Invoke-NativeProcess -FilePath $wacsPath -ArgumentList @('--version') -TimeoutSeconds $timeout
        if ($result.TimedOut) {
            if ($requireVersion) { throw 'wacs --version timed out.' }
            Write-Warning "wacs --version timed out after $timeout seconds. Continuing because ACME_REQUIRE_WACS_VERSION_CHECK is not enabled."
            return $null
        }
        if (-not $result.Succeeded) {
            throw "wacs --version failed with exit code $($result.ExitCode)."
        }

        $outputLines = @($result.OutputLines)
        $analysis = Get-WacsOutputAnalysis -OutputLines $outputLines -RequireVersion -RequireNonInteractiveMode
        return $analysis.Version
    } catch {
        if ($requireVersion) { throw }
        Write-Warning ("Unable to detect simple-acme/wacs version: " + $_.Exception.Message + ". Continuing because ACME_REQUIRE_WACS_VERSION_CHECK is not enabled.")
        return $null
    }
}

function Get-WacsOutputAnalysis {
    param(
        [string[]]$OutputLines,
        [switch]$RequireVersion,
        [switch]$RequireNonInteractiveMode
    )

    $lines = @($OutputLines | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $enteredInteractiveMode = ((@($lines | Where-Object { $_ -match 'Please choose from the menu:' }).Count) -gt 0)

    if ($RequireNonInteractiveMode -and $enteredInteractiveMode) {
        throw @'
wacs was launched without non-interactive arguments and entered interactive mode.
Fix the wrapper command generation.
'@
    }

    $versionText = $null
    $version = $null

    foreach ($line in $lines) {
        $m = [regex]::Match([string]$line, 'Software version\s+(\d+\.\d+(?:\.\d+){0,2})')
        if ($m.Success) {
            $versionText = [string]$m.Groups[1].Value
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($versionText)) {
        foreach ($line in $lines) {
            $m = [regex]::Match([string]$line, '\b\d+\.\d+(?:\.\d+){0,2}\b')
            if ($m.Success) {
                $versionText = [string]$m.Value
                break
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($versionText)) {
        $version = [version]$versionText
    }

    if ($RequireVersion -and $null -eq $version) {
        throw ('Unable to parse simple-acme/wacs version from output. Output was:' + [Environment]::NewLine + ($lines -join [Environment]::NewLine))
    }

    return [pscustomobject]@{
        Version = $version
        VersionText = $versionText
        EnteredInteractiveMode = $enteredInteractiveMode
        OutputLines = $lines
    }
}

function Invoke-WacsIssue {
    param([Parameter(Mandatory)][hashtable]$EnvValues)

    $storePlugins = @('certificatestore')
    $csrAlgorithms = Get-CsrAlgorithms -EnvValues $EnvValues
    $args = @(
        '--accepttos',
        '--source', 'manual',
        '--order', 'single',
        '--baseuri', (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_DIRECTORY'),
        '--validation', 'none',
        '--globalvalidation', 'none',
        '--host', [string](Get-EnvValue -EnvValues $EnvValues -Key 'DOMAINS')
    )
    $args += @('--store', ($storePlugins -join ','))
    if ((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_REQUIRES_EAB') -eq '1' -and -not [string]::IsNullOrWhiteSpace((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_KID'))) {
        $args += @('--eab-key-identifier', (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_KID'))
    }
    if ((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_REQUIRES_EAB') -eq '1' -and -not [string]::IsNullOrWhiteSpace((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_HMAC_SECRET'))) {
        $args += @('--eab-key', (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_HMAC_SECRET'))
    }
    if (-not [string]::IsNullOrWhiteSpace((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_ACCOUNT_NAME'))) {
        $args += @('--account', (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_ACCOUNT_NAME'))
    }

    $args += @('--installation', 'script')
    $args += @('--script', (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SCRIPT_PATH'), '--scriptparameters', '{CertThumbprint}')

    $lastError = $null
    foreach ($algorithm in $csrAlgorithms) {
        try {
            Invoke-WacsWithRetry -Args ($args + @('--csr', $algorithm)) -EnvValues $EnvValues
            return
        } catch {
            $lastError = $_
            Write-Warning "wacs issuance with CSR '$algorithm' failed: $($_.Exception.Message)"
            [Console]::WriteLine('')
        }
    }

    if ($null -ne $lastError) { throw $lastError }
    throw 'wacs issuance failed for unknown reason.'
}

# Regression guard: exact-set comparison must stay strict (no subset/superset acceptance).
function Test-ExactDomainSetMatch {
    param([string[]]$Requested,[string[]]$Actual)
    $left = @($Requested | Sort-Object -Unique)
    $right = @($Actual | Sort-Object -Unique)
    return (($left -join ',') -eq ($right -join ','))
}

function Get-RenewalIdForCancel {
    param([Parameter(Mandatory)]$RenewalSummary)
    if (-not [string]::IsNullOrWhiteSpace([string]$RenewalSummary.RenewalId)) { return [string]$RenewalSummary.RenewalId }
    throw "Unable to determine renewal id from renewal JSON file '$($RenewalSummary.File.FullName)'"
}

function Write-ReconcileLog {
    param(
        [Parameter(Mandatory)][ValidateSet('create','update','no-op')][string]$Action,
        [Parameter(Mandatory)][string[]]$Domains,
        [Parameter(Mandatory)][ValidateSet('success','failure')][string]$Result,
        [Parameter(Mandatory)][string]$Message
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $entry = [ordered]@{
        timestamp = $timestamp
        action = $Action
        domains = @($Domains)
        result = $Result
        message = $Message
    }
    $serialized = $entry | ConvertTo-Json -Compress -Depth 5
    Write-Host $serialized
    $logDir = [string][Environment]::GetEnvironmentVariable('CERTIFICATE_LOG_DIR')
    if (-not [string]::IsNullOrWhiteSpace($logDir)) {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $logPath = Join-Path $logDir ("reconcile-{0}.log" -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd'))
        Add-Content -LiteralPath $logPath -Value $serialized -Encoding UTF8
    }
}

function Invoke-SimpleAcmeReconcile {
    param(
        [Parameter(Mandatory)][hashtable]$EnvValues,
        [switch]$SkipWacs,
        [switch]$DryRun
    )

    Test-ReconcilePreflight -EnvValues $EnvValues | Out-Null
    $simpleAcmeDir = Join-Path $env:ProgramData 'simple-acme'
    if (-not (Test-Path -LiteralPath $simpleAcmeDir)) {
        New-Item -ItemType Directory -Path $simpleAcmeDir -Force | Out-Null
    }
    $lockFilePath = Join-Path $simpleAcmeDir 'reconcile.lock'
    $lockFileStream = $null
    $hasLock = $false
    try {
        $deadline = (Get-Date).ToUniversalTime().AddMinutes(5)
        while ((Get-Date).ToUniversalTime() -lt $deadline -and -not $hasLock) {
            try {
                $lockFileStream = [System.IO.File]::Open($lockFilePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                $hasLock = $true
            } catch {
                Start-Sleep -Milliseconds 300
            }
        }
        if (-not $hasLock) {
            throw "Another reconcile run is in progress (could not acquire file lock '$lockFilePath')."
        }

    if ($DryRun) {
        Write-ReconcileLog -Action 'no-op' -Domains (Get-NormalizedDomains -Domains (Get-EnvValue -EnvValues $EnvValues -Key 'DOMAINS')) -Result 'success' -Message 'Dry-run preflight passed; no wacs actions executed.'
        return 'dry-run'
    }

    $domains = Get-NormalizedDomains -Domains (Get-EnvValue -EnvValues $EnvValues -Key 'DOMAINS')
    if ((Get-SafeCount $domains) -eq 0) {
        throw 'DOMAINS did not contain any valid host names.'
    }

    Set-SimpleAcmeSettings -EnvValues $EnvValues

    $allRenewalFiles = Get-RenewalFiles
    $matching = @()
    foreach ($file in $allRenewalFiles) {
        $summary = Get-RenewalSummarySafe -File $file
        if ($null -eq $summary) { continue }
        if (Test-ExactDomainSetMatch -Requested $domains -Actual $summary.Hosts) {
            $matching += ,$summary
        }
    }

    if ((Get-SafeCount $matching) -eq 0) {
        if (-not $SkipWacs) {
            Invoke-WacsIssue -EnvValues $EnvValues
            $allRenewalFiles = Get-RenewalFiles
        }

        $postMatch = @()
        foreach ($file in $allRenewalFiles) {
            $summary = Get-RenewalSummarySafe -File $file
            if ($null -eq $summary) { continue }
            if (Test-ExactDomainSetMatch -Requested $domains -Actual $summary.Hosts) { $postMatch += ,$summary }
        }

        if ((Get-SafeCount $postMatch) -eq 0) {
            Write-ReconcileLog -Action 'create' -Domains $domains -Result 'failure' -Message 'No matching renewal file found after issuance.'
            if ((Get-SafeCount $allRenewalFiles) -gt 0) { throw 'No matching renewal file found after issuance; at least one renewal file may be malformed.' }
            throw 'No matching renewal file found after issuance.'
        }

        $validation = Compare-RenewalWithEnv -RenewalSummary $postMatch[0] -EnvValues $EnvValues
        if (-not $validation.Matches) {
            Write-ReconcileLog -Action 'create' -Domains $domains -Result 'failure' -Message ("Post-create validation failed: {0}" -f ($validation.Mismatches -join ', '))
            throw "Post-create validation failed: $($validation.Mismatches -join ', ')"
        }

        Write-ReconcileLog -Action 'create' -Domains $domains -Result 'success' -Message 'Initial issuance completed.'
        return 'create'
    }

    if ((Get-SafeCount $matching) -gt 1) {
        throw "Multiple renewal entries match requested domains: $($domains -join ', ')"
    }

    $current = $matching[0]
    $compare = Compare-RenewalWithEnv -RenewalSummary $current -EnvValues $EnvValues
    if ($compare.Matches) {
        Write-ReconcileLog -Action 'no-op' -Domains $domains -Result 'success' -Message 'Renewal configuration already matches .env.'
        return 'no-op'
    }

    if (-not $SkipWacs) {
        $renewalId = Get-RenewalIdForCancel -RenewalSummary $current
        $cancelPath = $current.File.FullName
        # Regression guard: keep cancellation by renewal id (`--cancel --id <renewal-id>`).
        Invoke-WacsWithRetry -Args @('--cancel', '--id', $renewalId) -EnvValues $EnvValues
        Wait-RenewalFileRemoval -Path $cancelPath
        Start-Sleep -Seconds 2
        Invoke-WacsIssue -EnvValues $EnvValues
    }

    $freshFiles = Get-RenewalFiles
    $postUpdate = @()
    foreach ($file in $freshFiles) {
        $summary = Get-RenewalSummarySafe -File $file
        if ($null -eq $summary) { continue }
        if (Test-ExactDomainSetMatch -Requested $domains -Actual $summary.Hosts) { $postUpdate += ,$summary }
    }

    if ((Get-SafeCount $postUpdate) -ne 1) {
        Write-ReconcileLog -Action 'update' -Domains $domains -Result 'failure' -Message 'Expected exactly one renewal after update.'
        throw 'Expected exactly one renewal after update.'
    }

    $postCompare = Compare-RenewalWithEnv -RenewalSummary $postUpdate[0] -EnvValues $EnvValues
    if (-not $postCompare.Matches) {
        Write-ReconcileLog -Action 'update' -Domains $domains -Result 'failure' -Message ("Post-update validation failed: {0}" -f ($postCompare.Mismatches -join ', '))
        throw "Post-update validation failed: $($postCompare.Mismatches -join ', ')"
    }

    Write-ReconcileLog -Action 'update' -Domains $domains -Result 'success' -Message 'Renewal was recreated safely.'
    return 'update'
    } catch {
        throw
    } finally {
        if ($null -ne $lockFileStream) {
            $lockFileStream.Dispose()
        }
    }
}

$FunctionsToExport = New-Object System.Collections.Generic.List[string]
$FunctionsToExport.Add('Resolve-WacsExecutable')
$FunctionsToExport.Add('Compare-RenewalWithEnv')
$FunctionsToExport.Add('Test-ReconcilePreflight')
$FunctionsToExport.Add('Set-SimpleAcmeSettings')
$FunctionsToExport.Add('Get-NormalizedDomains')
$FunctionsToExport.Add('Get-SafeCount')
$FunctionsToExport.Add('Get-RenewalFiles')
$FunctionsToExport.Add('Get-RenewalSummary')
$FunctionsToExport.Add('Get-RenewalSummarySafe')
$FunctionsToExport.Add('Get-InstallationPlugins')
$FunctionsToExport.Add('Get-RenewalIdForCancel')
$FunctionsToExport.Add('Invoke-SimpleAcmeReconcile')
$FunctionsToExport.Add('Get-WacsFileVersion')
$FunctionsToExport.Add('Get-WacsVersion')
$FunctionsToExport.Add('Get-WacsOutputAnalysis')
$FunctionsToExport.Add('Invoke-WacsWithRetry')
$FunctionsToExport.Add('Invoke-WacsIssue')
$FunctionsToExport.Add('Get-NormalizedCsvValues')
$FunctionsToExport.Add('Wait-RenewalFileRemoval')
$FunctionsToExport.Add('New-ReconcileConfigHash')
$FunctionsToExport.Add('Test-ExactDomainSetMatch')
$FunctionsToExport.Add('Write-ReconcileLog')
$FunctionsToExport.Add('Write-ReconcileDiagnostics')
$FunctionsToExport.Add('Write-SimpleAcmeLogDiagnosticSummary')
$FunctionsToExport.Add('Get-SimpleAcmeLogDiagnosticSummary')

$MissingExports = @()
foreach ($fn in $FunctionsToExport) {
    if (-not (Get-Command -Name $fn -CommandType Function -ErrorAction SilentlyContinue)) {
        $MissingExports += $fn
    }
}

if ((Get-SafeCount $MissingExports) -gt 0) {
    throw ('Export list contains missing function(s): ' + ($MissingExports -join ', '))
}

Export-ModuleMember -Function ([string[]]$FunctionsToExport.ToArray())
