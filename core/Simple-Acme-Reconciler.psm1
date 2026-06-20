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

function ConvertTo-Array {
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

    if (([System.Collections.IDictionary]$EnvValues).Contains($Key)) {
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
    if ($null -ne $EnvValues -and ([System.Collections.IDictionary]$EnvValues).Contains('ACME_WACS_PATH')) {
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
- <install-root>\wacs.exe
- configured ACME_WACS_PATH
- wacs.exe on PATH

Fix:
Install official simple-acme release directly into the install root and set ACME_WACS_PATH to <install-root>\wacs.exe.
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

function Test-ValidWildcardDomainName {
    param([Parameter(Mandatory)][string]$Domain)
    $candidate = $Domain.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
    if ($candidate -notlike '*.*') { return $false }
    if (-not $candidate.StartsWith('*.')) { return $false }
    if ((Get-SafeCount ($candidate.ToCharArray() | Where-Object { $_ -eq '*' })) -ne 1) { return $false }
    $suffix = $candidate.Substring(2)
    if ([string]::IsNullOrWhiteSpace($suffix)) { return $false }
    return (Test-ValidDomainName -Domain $suffix)
}

function Get-RenewalFiles {
    param([string]$SimpleAcmeDir = (Join-Path $env:ProgramData 'simple-acme'))

    if ([string]::IsNullOrWhiteSpace($SimpleAcmeDir) -or -not (Test-Path -LiteralPath $SimpleAcmeDir)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $SimpleAcmeDir -Filter '*.renewal.json' -File -Recurse -ErrorAction SilentlyContinue)
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
    param(
        [string[]]$Directories = @(Get-SimpleAcmeLogDirectories),
        [string]$FilterText = ''
    )
    $files = @()
    foreach ($dir in @($Directories)) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $selected = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)
            if (-not [string]::IsNullOrWhiteSpace($FilterText)) {
                $selected = @($selected | Where-Object { $_.FullName -like "*$FilterText*" })
            }
            $files += $selected
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
    $filterText = ''
    $acmeDirValue = [Environment]::GetEnvironmentVariable('ACME_DIRECTORY')
    if (-not [string]::IsNullOrWhiteSpace($acmeDirValue)) {
        try { $filterText = ([System.Uri]$acmeDirValue).Host } catch {}
    }
    $latest = Get-LatestSimpleAcmeLogFile -FilterText $filterText
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

    $foundValues = [System.Collections.ArrayList]::new()

    function Invoke-NodeVisit {
        param($Node)
        if ($null -eq $Node) { return }

        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($key in $Node.Keys) {
                if ($Names -contains [string]$key) {
                    [void]$foundValues.Add([object]$Node[$key])
                }
                Invoke-NodeVisit -Node $Node[$key]
            }
            return
        }

        if ($Node -is [System.Management.Automation.PSCustomObject]) {
            foreach ($property in $Node.PSObject.Properties) {
                if ($Names -contains [string]$property.Name) {
                    [void]$foundValues.Add([object]$property.Value)
                }
                Invoke-NodeVisit -Node $property.Value
            }
            return
        }

        if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
            foreach ($item in $Node) {
                Invoke-NodeVisit -Node $item
            }
        }
    }

    Invoke-NodeVisit -Node $InputObject
    return @($foundValues)
}

function Get-RenewalHosts {
    param([Parameter(Mandatory)]$Renewal)

    $hostValues = New-Object System.Collections.Generic.List[string]
    $hostCandidates = Find-PropertyValues -InputObject $Renewal -Names @('Host','Hosts','Identifiers','Identifier','AlternativeNames','CommonName')
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
                } elseif ($item -is [System.Management.Automation.PSCustomObject]) {
                    $valueProp = $item.PSObject.Properties['Value']
                    if ($null -ne $valueProp -and $valueProp.Value -is [string]) {
                        $v = ([string]$valueProp.Value).Trim().ToLowerInvariant()
                        if (-not [string]::IsNullOrWhiteSpace($v)) { $hostValues.Add($v) }
                    }
                }
            }
        } elseif ($candidate -is [System.Management.Automation.PSCustomObject]) {
            $valueProp = $candidate.PSObject.Properties['Value']
            if ($null -ne $valueProp -and $valueProp.Value -is [string]) {
                $v = ([string]$valueProp.Value).Trim().ToLowerInvariant()
                if (-not [string]::IsNullOrWhiteSpace($v)) { $hostValues.Add($v) }
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
    catch {
        $detail = $_.Exception.GetType().FullName
        if ($null -ne $_.Exception.InnerException) { $detail += " - $($_.Exception.InnerException.Message)" }
        Write-Warning "Skipping malformed renewal JSON '$($File.FullName)': $($_.Exception.Message) [$detail]"
        return $null
    }
}

function Remove-MalformedRenewalFiles {
    param([string]$SimpleAcmeDir = (Join-Path $env:ProgramData 'simple-acme'))
    $files = @(Get-RenewalFiles -SimpleAcmeDir $SimpleAcmeDir)
    $quarantined = 0
    foreach ($file in $files) {
        try { $null = Get-RenewalSummary -File $file; continue } catch {}
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $backupPath = $file.FullName + ".bad-$stamp"
        try {
            Rename-Item -LiteralPath $file.FullName -NewName ([System.IO.Path]::GetFileName($backupPath)) -Force
            Write-Warning "Quarantined malformed renewal JSON to '$backupPath'."
            $quarantined++
        } catch {
            Write-Warning "Failed to quarantine '$($file.FullName)': $($_.Exception.Message)"
        }
    }
    return $quarantined
}

function Get-RenewalSummary {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)

    $rawJson = $null
    try {
        $rawJson = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8
        $renewal = $rawJson | ConvertFrom-Json
    } catch {
        if ($null -eq $rawJson) { throw "Failed to parse renewal JSON '$($File.FullName)': $($_.Exception.Message)" }
        try {
            # Newtonsoft.Json $type discriminators cause ConvertFrom-Json to fail on PowerShell 5.x; strip and retry
            $c = [regex]::Replace($rawJson, ',\s*"\$type"\s*:\s*"[^"]*"', '')
            $c = [regex]::Replace($c,       '"\$type"\s*:\s*"[^"]*"\s*,\s*', '')
            $c = [regex]::Replace($c,       '"\$type"\s*:\s*"[^"]*"', '')
            $renewal = $c | ConvertFrom-Json
        } catch {
            throw "Failed to parse renewal JSON '$($File.FullName)': $($_.Exception.Message)"
        }
    }
    if ($null -eq $renewal) {
        throw "Renewal JSON '$($File.FullName)' parsed as null."
    }
    $baseUriCandidates = $null; $kidCandidates = $null; $validationCandidates = $null
    $storeCandidates = $null; $installationCandidates = $null; $accountCandidates = $null
    $sourceCandidates = $null; $orderCandidates = $null; $renewalIdCandidates = $null
    $scriptCandidates = $null; $scriptParameterCandidates = $null; $csrCandidates = $null; $keyTypeCandidates = $null
    # WACS 2.3.6 uses $schema instead of Newtonsoft $type discriminators and uses a different
    # schema: no SourcePlugin/OrderPlugin fields, domains in TargetPluginOptions.AlternativeNames,
    # stores in StorePluginOptions[*] (structural), installs in InstallationPluginOptions[*].
    $isNewFormat = ($null -ne $renewal.PSObject.Properties['$schema'])

    try {
        $baseUriCandidates = Find-PropertyValues -InputObject $renewal -Names @('BaseUri')
        $kidCandidates = Find-PropertyValues -InputObject $renewal -Names @('KeyIdentifier','Kid','EabKeyIdentifier')
        $validationCandidates = Find-PropertyValues -InputObject $renewal -Names @('Plugin','Name','ValidationPlugin')
        $storeCandidates = [System.Collections.ArrayList]@(Find-PropertyValues -InputObject $renewal -Names @('StorePlugin','StoreType','Store'))
        $installationCandidates = [System.Collections.ArrayList]@(Find-PropertyValues -InputObject $renewal -Names @('InstallationPlugin','InstallationPlugins','Installation'))
        $accountCandidates = Find-PropertyValues -InputObject $renewal -Names @('Account','AccountName')
        $sourceCandidates = Find-PropertyValues -InputObject $renewal -Names @('SourcePlugin','Source')
        $orderCandidates = Find-PropertyValues -InputObject $renewal -Names @('OrderPlugin','Order')
        $renewalIdCandidates = Find-PropertyValues -InputObject $renewal -Names @('Id','RenewalId')
        $scriptCandidates = [System.Collections.ArrayList]@(Find-PropertyValues -InputObject $renewal -Names @('Script','ScriptFileName'))
        $scriptParameterCandidates = [System.Collections.ArrayList]@(Find-PropertyValues -InputObject $renewal -Names @('ScriptParameters','Parameters'))
        $csrCandidates = Find-PropertyValues -InputObject $renewal -Names @('CsrPlugin','Csr')
        $keyTypeCandidates = Find-PropertyValues -InputObject $renewal -Names @('KeyType','KeyAlgorithm','Algorithm')
    } catch {
        throw "Failed to traverse property values in '$($File.FullName)': $($_.Exception.Message) [$($_.Exception.GetType().FullName)]"
    }

    if ($isNewFormat) {
        $validationOptions = $renewal.PSObject.Properties['ValidationPluginOptions']
        if ($null -ne $validationOptions -and $null -ne $validationOptions.Value) {
            $validationPluginId = ''
            $pluginProperty = $validationOptions.Value.PSObject.Properties['Plugin']
            if ($null -ne $pluginProperty) { $validationPluginId = [string]$pluginProperty.Value }
            if ($validationPluginId -eq 'a37b41dc-b45a-42fe-8d81-82ca409a5491') {
                $validationCandidates = @($validationCandidates + 'none')
            }
        }

        # Derive store plugin names from StorePluginOptions structure:
        #   entry with a non-empty Path property → pfxfile; entry without Path → certificatestore
        $spoRaw = $renewal.PSObject.Properties['StorePluginOptions']
        if ($null -ne $spoRaw -and $spoRaw.Value -is [System.Collections.IEnumerable]) {
            foreach ($spo in $spoRaw.Value) {
                $pathProp = $spo.PSObject.Properties['Path']
                if ($null -ne $pathProp -and -not [string]::IsNullOrWhiteSpace([string]$pathProp.Value)) {
                    [void]$storeCandidates.Add([object]'pfxfile')
                } else {
                    [void]$storeCandidates.Add([object]'certificatestore')
                }
            }
        }
        # Derive installation plugin names from InstallationPluginOptions structure:
        #   entry with a Script property → script (also capture Script/ScriptParameters values)
        $ipoRaw = $renewal.PSObject.Properties['InstallationPluginOptions']
        if ($null -ne $ipoRaw -and $ipoRaw.Value -is [System.Collections.IEnumerable]) {
            foreach ($ipo in $ipoRaw.Value) {
                $scriptProp = $ipo.PSObject.Properties['Script']
                if ($null -ne $scriptProp -and -not [string]::IsNullOrWhiteSpace([string]$scriptProp.Value)) {
                    [void]$installationCandidates.Add([object]'script')
                    [void]$scriptCandidates.Add([object]$scriptProp.Value)
                    $paramProp = $ipo.PSObject.Properties['ScriptParameters']
                    if ($null -ne $paramProp) { [void]$scriptParameterCandidates.Add([object]$paramProp.Value) }
                }
            }
        }
    }

    $hosts = try { Get-RenewalHosts -Renewal $renewal } catch { throw "Failed to extract hosts from '$($File.FullName)': $($_.Exception.Message) [$($_.Exception.GetType().FullName)]" }

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
        if ($isNewFormat) {
            $resolvedSourcePlugin = 'manual'
        } else {
            throw "Renewal JSON '$($File.FullName)' did not contain source plugin metadata."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$resolvedOrderPlugin)) {
        if ($isNewFormat) {
            $resolvedOrderPlugin = 'single'
        } else {
            throw "Renewal JSON '$($File.FullName)' did not contain order plugin metadata."
        }
    }

    $latestThumbprint = ''
    $latestOrderErrorMessages = @()
    try {
        $historyProperty = $renewal.PSObject.Properties['History']
        if ($null -ne $historyProperty -and $null -ne $historyProperty.Value) {
            foreach ($historyItem in @($historyProperty.Value)) {
                $orderResultsProperty = $historyItem.PSObject.Properties['OrderResults']
                if ($null -eq $orderResultsProperty -or $null -eq $orderResultsProperty.Value) { continue }
                foreach ($orderResult in @($orderResultsProperty.Value)) {
                    $thumbProp = $orderResult.PSObject.Properties['Thumbprint']
                    if ($null -ne $thumbProp -and -not [string]::IsNullOrWhiteSpace([string]$thumbProp.Value)) {
                        $latestThumbprint = ([string]$thumbProp.Value).Trim().ToUpperInvariant()
                        $latestOrderErrorMessages = @()
                    }
                    $errorsProp = $orderResult.PSObject.Properties['ErrorMessages']
                    if ($null -ne $errorsProp -and $null -ne $errorsProp.Value -and -not [string]::IsNullOrWhiteSpace($latestThumbprint)) {
                        $latestOrderErrorMessages = @($errorsProp.Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    }
                }
            }
        }
    } catch {
        $latestThumbprint = ''
        $latestOrderErrorMessages = @()
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
        HasValidationMetadata = ((Get-SafeCount $normalizedValidationCandidates) -gt 0)
        HasValidationNone = ((Get-SafeCount (@($normalizedValidationCandidates | Where-Object { $_ -eq 'none' }))) -gt 0)
        HasScriptInstallation = ((Get-SafeCount (@($normalizedInstallCandidates | Where-Object { $_ -eq 'script' }))) -gt 0)
        ScriptPaths      = @($scriptCandidates | Where-Object { $_ -is [string] })
        ScriptParameters = @($scriptParameterCandidates | Where-Object { $_ -is [string] })
        CsrPlugin        = ($csrCandidates | Where-Object { $_ -is [string] } | Select-Object -First 1)
        KeyType          = ($keyTypeCandidates | Where-Object { $_ -is [string] } | Select-Object -First 1)
        LatestThumbprint = $latestThumbprint
        LatestOrderErrorMessages = @($latestOrderErrorMessages)
    }
}

function Get-NormalizedCsvValues {
    param([string]$InputText)
    if ([string]::IsNullOrWhiteSpace($InputText)) { return @() }
    return @(
        $InputText -split '[,;\s]+' |
            ForEach-Object {
                $token = $_.Trim()
                $token = $token -replace '^"', ''
                $token = $token -replace "^'", ''
                $token = $token -replace '"$', ''
                $token = $token -replace "'$", ''
                $token.ToLowerInvariant()
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Test-IsAdministrator {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-EffectiveWacsStorePlugins {
    param([Parameter(Mandatory)][hashtable]$EnvValues)

    $storePlugin = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_STORE_PLUGIN' -Default 'certificatestore'
    $storePlugins = Get-NormalizedCsvValues -InputText $storePlugin
    if ((Get-SafeCount $storePlugins) -eq 0) { $storePlugins = @('certificatestore') }
    $validStorePlugins = @('certificatestore','pfxfile','pemfiles','centralssl','p7bfile','keyvault','userstore')
    $repairedPlugins = New-Object System.Collections.Generic.List[string]
    foreach ($token in $storePlugins) {
        if ($validStorePlugins -contains $token) {
            $repairedPlugins.Add($token)
            continue
        }

        $remaining = $token
        $parts = New-Object System.Collections.Generic.List[string]
        $ok = $true
        while ($remaining.Length -gt 0 -and $ok) {
            $hit = @($validStorePlugins | Where-Object { $remaining.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) } | Sort-Object { $_.Length } -Descending | Select-Object -First 1)
            if ($hit.Count -eq 0) {
                $ok = $false
            } else {
                $parts.Add($hit[0])
                $remaining = $remaining.Substring($hit[0].Length)
            }
        }
        if ($ok -and $parts.Count -gt 1) {
            Write-Warning "ACME_STORE_PLUGIN token '$token' looks like plugin names concatenated without a comma separator. Auto-correcting to: $($parts -join ', '). Fix your config: ACME_STORE_PLUGIN=$($parts -join ',')."
            foreach ($part in $parts) { $repairedPlugins.Add($part) }
        } else {
            $repairedPlugins.Add($token)
        }
    }

    $storePlugins = @($repairedPlugins | Sort-Object -Unique)
    $unknownStorePlugins = @($storePlugins | Where-Object { $validStorePlugins -notcontains $_ })
    if ((Get-SafeCount $unknownStorePlugins) -gt 0) {
        throw "ACME_STORE_PLUGIN contains unrecognized token(s): $($unknownStorePlugins -join ', '). Valid values: $($validStorePlugins -join ', '). Check for missing comma separator (e.g. 'pfxfile,certificatestore' not 'pfxfilecertificatestore')."
    }

    $installationPlugins = Get-InstallationPlugins -EnvValues $EnvValues
    $scriptParamsForStoreDecision = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SCRIPT_PARAMETERS' -Default ''
    $scriptNeedsThumbprint = ([string]$scriptParamsForStoreDecision -match '\{CertThumbprint\}')
    if ($installationPlugins -contains 'script' -and $scriptNeedsThumbprint -and -not ($storePlugins -contains 'certificatestore')) {
        $storePlugins = @($storePlugins + 'certificatestore' | Sort-Object -Unique)
        Write-Warning 'ACME_INSTALLATION_PLUGINS includes a script that uses {CertThumbprint}, but ACME_STORE_PLUGIN does not include certificatestore. Adding certificatestore automatically so script thumbprint lookups succeed.'
    }

    return @($storePlugins)
}

function Test-CertificateDomainPatternMatch {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Domain
    )

    $candidatePattern = $Pattern.Trim().TrimEnd('.').ToLowerInvariant()
    $candidateDomain = $Domain.Trim().TrimEnd('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($candidatePattern) -or [string]::IsNullOrWhiteSpace($candidateDomain)) { return $false }
    if ($candidatePattern -eq $candidateDomain) { return $true }
    if (-not $candidatePattern.StartsWith('*.')) { return $false }

    $suffix = $candidatePattern.Substring(1)
    if (-not $candidateDomain.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    $prefix = $candidateDomain.Substring(0, $candidateDomain.Length - $suffix.Length)
    return ($prefix.Length -gt 0 -and $prefix.IndexOf('.') -lt 0)
}

function Get-CertificateDnsNames {
    param([Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($extension in @($Certificate.Extensions)) {
        if ($extension.Oid.Value -ne '2.5.29.17') { continue }
        $formatted = $extension.Format($true)
        foreach ($match in [regex]::Matches($formatted, 'DNS Name=([^\r\n,]+)')) {
            $name = ([string]$match.Groups[1].Value).Trim()
            if (-not [string]::IsNullOrWhiteSpace($name)) { $names.Add($name.ToLowerInvariant()) }
        }
    }

    if ($names.Count -lt 1 -and $Certificate.Subject -match '(?i)(?:^|,\s*)CN\s*=\s*([^,]+)') {
        $cn = ([string]$Matches[1]).Trim()
        if (-not [string]::IsNullOrWhiteSpace($cn)) { $names.Add($cn.ToLowerInvariant()) }
    }

    return @($names | Sort-Object -Unique)
}

function Test-CertificateCoversDomains {
    param(
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][string[]]$Domains
    )

    $names = @(Get-CertificateDnsNames -Certificate $Certificate)
    if ((Get-SafeCount $names) -lt 1) { return $false }
    foreach ($domain in @($Domains)) {
        $matched = $false
        foreach ($name in $names) {
            if (Test-CertificateDomainPatternMatch -Pattern $name -Domain $domain) {
                $matched = $true
                break
            }
        }
        if (-not $matched) { return $false }
    }
    return $true
}

function Get-RenewalCertificateCandidates {
    param([Parameter(Mandatory)][string[]]$Domains)

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($storeRoot in @('Cert:\LocalMachine\My','Cert:\CurrentUser\My')) {
        if (-not (Test-Path -LiteralPath $storeRoot)) { continue }
        foreach ($cert in @(Get-ChildItem -LiteralPath $storeRoot -ErrorAction SilentlyContinue)) {
            if ($null -eq $cert) { continue }
            if (Test-CertificateCoversDomains -Certificate $cert -Domains $Domains) {
                $candidates.Add($cert)
            }
        }
    }
    return @($candidates | Sort-Object NotAfter -Descending)
}

function Test-CertificateRevoked {
    param([Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    try {
        $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::Online
        $chain.ChainPolicy.RevocationFlag = [System.Security.Cryptography.X509Certificates.X509RevocationFlag]::EndCertificateOnly
        $chain.ChainPolicy.UrlRetrievalTimeout = New-TimeSpan -Seconds 15
        $null = $chain.Build($Certificate)
        foreach ($status in @($chain.ChainStatus)) {
            if (($status.Status -band [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::Revoked) -ne 0) {
                return $true
            }
        }
        return $false
    } finally {
        $chain.Dispose()
    }
}

function Test-RenewalCertificateHealth {
    param(
        [Parameter(Mandatory)]$RenewalSummary,
        [Parameter(Mandatory)][hashtable]$EnvValues
    )

    # Diagnostic only. Renewal timing belongs to simple-acme's ACME Renewal Information (ARI, RFC 9773) support.
    if ((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_CERTIFICATE_HEALTH_CHECK' -Default '1') -in @('0','false','False','FALSE','no','No','NO')) {
        return [pscustomobject]@{ Status = 'Skipped'; Message = 'Certificate health check disabled.' }
    }

    $expectedStores = @(Get-NormalizedCsvValues -InputText (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_STORE_PLUGIN' -Default 'certificatestore'))
    $actualStores = @($RenewalSummary.StorePlugins)
    if (($expectedStores -notcontains 'certificatestore') -and ($actualStores -notcontains 'certificatestore')) {
        return [pscustomobject]@{ Status = 'Skipped'; Message = 'Certificate store is not part of this renewal.' }
    }

    $domains = @(Get-NormalizedDomains -Domains (Get-EnvValue -EnvValues $EnvValues -Key 'DOMAINS'))
    if ((Get-SafeCount $domains) -lt 1) {
        return [pscustomobject]@{ Status = 'Skipped'; Message = 'No domains available for certificate health check.' }
    }

    $latestErrors = @()
    $latestErrorsProperty = $RenewalSummary.PSObject.Properties['LatestOrderErrorMessages']
    if ($null -ne $latestErrorsProperty) { $latestErrors = @($latestErrorsProperty.Value) }
    if ((Get-SafeCount $latestErrors) -gt 0) {
        return [pscustomobject]@{ Status = 'InstallationFailed'; Message = "Renewal history recorded certificate/order error(s): $($latestErrors -join '; ')" }
    }

    $latestThumbprint = ''
    $thumbProperty = $RenewalSummary.PSObject.Properties['LatestThumbprint']
    if ($null -ne $thumbProperty) { $latestThumbprint = ([string]$thumbProperty.Value).Trim().ToUpperInvariant() }

    $candidates = @(Get-RenewalCertificateCandidates -Domains $domains)
    if (-not [string]::IsNullOrWhiteSpace($latestThumbprint)) {
        $candidates = @($candidates | Where-Object { ([string]$_.Thumbprint).ToUpperInvariant() -eq $latestThumbprint })
    }
    if ((Get-SafeCount $candidates) -lt 1) {
        if (-not [string]::IsNullOrWhiteSpace($latestThumbprint)) {
            return [pscustomobject]@{ Status = 'Missing'; Message = "Renewal certificate '$latestThumbprint' was not found in Windows certificate stores." }
        }
        return [pscustomobject]@{ Status = 'Missing'; Message = 'No matching certificate found in Windows certificate stores.' }
    }

    $now = Get-Date
    $sawExpired = $false
    $sawNotYetValid = $false
    foreach ($cert in $candidates) {
        if ($cert.NotAfter -le $now) {
            $sawExpired = $true
            continue
        }
        if ($cert.NotBefore -gt $now) {
            $sawNotYetValid = $true
            continue
        }
        if (Test-CertificateRevoked -Certificate $cert) {
            return [pscustomobject]@{ Status = 'Revoked'; Message = "Matching certificate '$($cert.Thumbprint)' is revoked; simple-acme ARI renewal check will decide the certificate request." }
        }
        return [pscustomobject]@{ Status = 'Valid'; Message = "Matching certificate '$($cert.Thumbprint)' is locally valid; simple-acme ARI remains authoritative for renewal timing." }
    }

    if ($sawExpired) {
        return [pscustomobject]@{ Status = 'Expired'; Message = 'Only expired matching certificates were found.' }
    }
    if ($sawNotYetValid) {
        return [pscustomobject]@{ Status = 'NotYetValid'; Message = 'Only not-yet-valid matching certificates were found.' }
    }
    return [pscustomobject]@{ Status = 'Unknown'; Message = 'Certificate health could not be determined.' }
}

function ConvertTo-NormalizedWacsScriptParametersText {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = $text.Trim()
    $text = $text -replace '\\"', '"'
    $text = $text -replace '\''', "'"
    $text = $text -replace '\s+', ' '
    return $text
}

function Compare-RenewalWithEnv {
    param(
        [Parameter(Mandatory)]$RenewalSummary,
        [Parameter(Mandatory)][hashtable]$EnvValues
    )

    $expectedHosts = Get-NormalizedDomains -Domains (Get-EnvValue -EnvValues $EnvValues -Key 'DOMAINS')
    $actualHosts = @($RenewalSummary.Hosts | Sort-Object -Unique)
    $expectedScriptPath = (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SCRIPT_PATH')
    $scriptParametersProperty = $RenewalSummary.PSObject.Properties['ScriptParameters']
    $renewalScriptParameters = @()
    if ($null -ne $scriptParametersProperty) {
        $renewalScriptParameters = @($scriptParametersProperty.Value)
    }

    $mismatches = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace([string]$RenewalSummary.BaseUri) -and [string]$RenewalSummary.BaseUri -ne (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_DIRECTORY')) {
        $mismatches.Add('BaseUri')
    }

    if (($expectedHosts -join ',') -ne ($actualHosts -join ',')) {
        $mismatches.Add('Domains')
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$RenewalSummary.EabKid) -and [string]$RenewalSummary.EabKid -ne (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_KID')) {
        $mismatches.Add('EAB kid')
    }
    if ([string]$RenewalSummary.SourcePlugin -ne (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SOURCE_PLUGIN' -Default 'manual')) {
        $mismatches.Add('Source plugin')
    }
    if ([string]$RenewalSummary.OrderPlugin -ne (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_ORDER_PLUGIN')) {
        $mismatches.Add('Order plugin')
    }
    $expectedStores = @(Get-NormalizedCsvValues -InputText (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_STORE_PLUGIN' -Default 'certificatestore') | Sort-Object -Unique)
    $compareInstallPlugins = Get-InstallationPlugins -EnvValues $EnvValues
    $compareScriptParams = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SCRIPT_PARAMETERS' -Default '{CertThumbprint}'
    $compareScriptNeedsThumbprint = ([string]$compareScriptParams -match '\{CertThumbprint\}')
    if ($compareInstallPlugins -contains 'script' -and $compareScriptNeedsThumbprint -and $expectedStores -notcontains 'certificatestore') {
        $expectedStores = @($expectedStores + 'certificatestore' | Sort-Object -Unique)
    }
    $actualStores = @($RenewalSummary.StorePlugins | Sort-Object -Unique)
    if (($expectedStores -join ',') -ne ($actualStores -join ',')) {
        $mismatches.Add('Store plugin')
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$RenewalSummary.AccountName) -and [string]$RenewalSummary.AccountName -ne (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_ACCOUNT_NAME')) {
        $mismatches.Add('Account name')
    }

    $hasValidationMetadata = $true
    if ($RenewalSummary.PSObject.Properties.Name -contains 'HasValidationMetadata') {
        $hasValidationMetadata = [bool]$RenewalSummary.HasValidationMetadata
    }
    if ($hasValidationMetadata -and -not $RenewalSummary.HasValidationNone) {
        $mismatches.Add('Validation plugin none')
    }

    $expectedInstallers = @(Get-InstallationPlugins -EnvValues $EnvValues | Sort-Object -Unique)
    $actualInstallers = @($RenewalSummary.InstallationPlugins | Sort-Object -Unique)
    if (($expectedInstallers -join ',') -ne ($actualInstallers -join ',')) {
        $mismatches.Add('Installation plugins')
    }
    if ($expectedInstallers -contains 'script') {
        $normalizedScriptPaths = @($RenewalSummary.ScriptPaths | ForEach-Object { [string]$_ })
        if (-not ($normalizedScriptPaths -contains $expectedScriptPath)) {
            $mismatches.Add('Script path')
        }
        $expectedScriptParameters = ConvertTo-NormalizedWacsScriptParametersText -Value (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SCRIPT_PARAMETERS' -Default '{CertThumbprint}')
        $normalizedScriptParameters = @(
            $renewalScriptParameters |
                ForEach-Object { ConvertTo-NormalizedWacsScriptParametersText -Value ([string]$_) } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        if ([string]::IsNullOrWhiteSpace($expectedScriptParameters) -or -not ($normalizedScriptParameters -contains $expectedScriptParameters)) {
            $mismatches.Add('Script parameters')
        }
    }

    $requestedCsr = [string](Get-CsrExecutionPlan -EnvValues $EnvValues | Select-Object -First 1)
    $actualCsrPlugin = ''
    if ($RenewalSummary.PSObject.Properties.Name -contains 'CsrPlugin') { $actualCsrPlugin = [string]$RenewalSummary.CsrPlugin }
    if (-not [string]::IsNullOrWhiteSpace($requestedCsr) -and -not [string]::IsNullOrWhiteSpace($actualCsrPlugin)) {
        if ($actualCsrPlugin -ne $requestedCsr) {
            $mismatches.Add('CSR plugin')
        }
    }

    $actualKeyType = ''
    if ($RenewalSummary.PSObject.Properties.Name -contains 'KeyType') { $actualKeyType = [string]$RenewalSummary.KeyType }
    if (-not [string]::IsNullOrWhiteSpace((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_KEY_TYPE')) -and -not [string]::IsNullOrWhiteSpace($actualKeyType)) {
        if ($actualKeyType -ne (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_KEY_TYPE')) {
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
        if (-not ([System.Collections.IDictionary]$EnvValues).Contains($key) -or [string]::IsNullOrWhiteSpace([string]$EnvValues[$key])) {
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
    if ([string]::IsNullOrWhiteSpace((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SCRIPT_PARAMETERS'))) {
        $EnvValues['ACME_SCRIPT_PARAMETERS'] = '{CertThumbprint}'
    }
    $effectiveStorePlugins = @(Get-EffectiveWacsStorePlugins -EnvValues $EnvValues)
    if ($effectiveStorePlugins -contains 'certificatestore') {
        if (-not (Test-IsAdministrator)) {
            throw "ACME_STORE_PLUGIN resolves to certificatestore, but current Windows PowerShell is not elevated. Run Windows PowerShell as Administrator before reconcile/renewal so simple-acme can write the Windows certificate store."
        }
    }
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
    $product = (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_NETWORKING4ALL_PRODUCT')
    $isWildcardProduct = (-not [string]::IsNullOrWhiteSpace($product) -and $product -like '*wildcard*')
    if ((Get-SafeCount $domains) -eq 0) {
        throw "DOMAINS did not contain any valid hostnames. Current value: '$((Get-EnvValue -EnvValues $EnvValues -Key 'DOMAINS'))'"
    }
    foreach ($domain in $domains) {
        if ($domain.StartsWith('*.')) {
            if (-not $isWildcardProduct) {
                throw "Wildcard domain '$domain' requires a wildcard product, current product is '$product'."
            }
            if (-not (Test-ValidWildcardDomainName -Domain $domain)) {
                throw "Invalid wildcard domain format in DOMAINS: '$domain'"
            }
            continue
        }
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
        $storeExplicit = (Get-EnvValue -EnvValues $EnvValues -Key 'Store_CertificateStore_PrivateKeyExportable')
        if ($targetSystem -eq 'rds' -or $targetLocation -eq 'cluster-farm' -or $targetLocation -eq 'another-server' -or $explicitExportable -eq 'true' -or $storeExplicit -eq 'true') {
            $requiresExportable = $true
        }
    }
    $settings.Store.CertificateStore.PrivateKeyExportable = $requiresExportable
    Write-Verbose "Set-SimpleAcmeSettings: writing PrivateKeyExportable=$requiresExportable to '$settingsPath'"

    # WACS 2.3.x reads the PFX output path from settings.json (Store.PfxFile.DefaultPath) on
    # scheduled renewals — it does not re-read --pfxfilepath from the command line. Writing this
    # here ensures the path persists across renewals even if it was not stored in the renewal JSON.
    if ($null -ne $EnvValues) {
        $pfxFilePath = (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_PFX_FILE_PATH')
        if (-not [string]::IsNullOrWhiteSpace($pfxFilePath)) {
            if (-not $settings.Store.ContainsKey('PfxFile') -or $null -eq $settings.Store.PfxFile) {
                $settings.Store.PfxFile = @{}
            }
            $settings.Store.PfxFile.DefaultPath = [string]$pfxFilePath
            Write-Verbose "Set-SimpleAcmeSettings: writing Store.PfxFile.DefaultPath='$pfxFilePath' to '$settingsPath'"
        }
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 12), $utf8NoBom)
}

function Get-InstallationPlugins {
    param([Parameter(Mandatory)][hashtable]$EnvValues)

    $raw = (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_INSTALLATION_PLUGINS')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @('script')
    }

    # Backward compatibility: some environments accidentally put store plugin values
    # (for example "pfxfile") in ACME_INSTALLATION_PLUGINS. We accept these and
    # treat them as no-op installers so reconcile can continue.
    $valid = @('script','iis','pfxfile')
    $plugins = Get-NormalizedCsvValues -InputText $raw
    if ((Get-SafeCount $plugins) -eq 0) {
        throw 'ACME_INSTALLATION_PLUGINS does not contain any valid values.'
    }

    $storeTokensInInstallation = @($plugins | Where-Object { $_ -eq 'pfxfile' })
    if ((Get-SafeCount $storeTokensInInstallation) -gt 0) {
        $warningMessage = 'ACME_INSTALLATION_PLUGINS contains pfxfile. pfxfile is a store plugin; move it to ACME_STORE_PLUGIN. Ignoring pfxfile in installation list.'
        if (Get-Command -Name Write-CertificateLog -ErrorAction SilentlyContinue) {
            Write-CertificateLog -Level WARN -Message $warningMessage
        } else {
            Write-Warning $warningMessage
        }
        $plugins = @($plugins | Where-Object { $_ -ne 'pfxfile' })
    }

    if ((Get-SafeCount $plugins) -eq 0) {
        return @()
    }

    $unknown = @($plugins | Where-Object { $valid -notcontains $_ })
    if ((Get-SafeCount $unknown) -gt 0) {
        throw "ACME_INSTALLATION_PLUGINS contains unsupported values: $($unknown -join ', ')"
    }

    return $plugins
}

function Get-CsrExecutionPlan {
    param([Parameter(Mandatory)][hashtable]$EnvValues)

    $preferred = ((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_CSR_ALGORITHM' -Default 'ec').Trim().ToLowerInvariant())
    $fallbackEnabled = ((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_ALLOW_CSR_FALLBACK' -Default '1').Trim() -eq '1')
    if ($preferred -notin @('ec','rsa')) { throw "Unsupported ACME_CSR_ALGORITHM value '$preferred'. Supported values: ec, rsa." }
    if ($preferred -eq 'ec' -and $fallbackEnabled) { return @('ec','rsa') }
    return $preferred
}

function Get-MaskedWacsArgumentsText {
    param([Alias('Args')][AllowNull()][string[]]$ArgumentList)

    $argList = @($ArgumentList | ForEach-Object { [string]$_ })
    $masked = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt (Get-SafeCount $argList); $i++) {
        $arg = [string]$argList[$i]

        if (($arg -eq '--eab-key' -or $arg -eq '--pfxpassword') -and $i -lt ((Get-SafeCount $argList) - 1)) {
            $masked.Add($arg)
            $masked.Add('<hidden>')
            $i++
            continue
        }

        if ($arg -eq '--eab-key-identifier' -and $i -lt ((Get-SafeCount $argList) - 1)) {
            $masked.Add($arg)
            $masked.Add('<set>')
            $i++
            continue
        }

        $masked.Add($arg)
    }

    return @($masked)
}

function Test-WacsDeferredRetrySuggested {
    param([AllowNull()][string[]]$OutputLines)

    $text = (@($OutputLines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }

    return (
        $text -match '(?i)Unexpected order status processing' -or
        $text -match '(?i)\border\b.*\bprocessing\b' -or
        $text -match '(?i)rateLimited' -or
        $text -match '(?i)Please wait a short moment before retrying this request'
    )
}

function Get-WacsRetryArgumentList {
    param(
        [Alias('Args')][AllowNull()][string[]]$ArgumentList,
        [switch]$AllowCache
    )

    if (-not $AllowCache) { return @($ArgumentList) }
    return @($ArgumentList | Where-Object { [string]$_ -ne '--nocache' })
}

function Invoke-WacsWithRetry {
    param(
        [Parameter(Mandatory)][string[]]$Args,
        [Parameter(Mandatory)][hashtable]$EnvValues,
        [int]$TimeoutSeconds = 300
    )
    if ((Get-SafeCount $Args) -eq 0) {
        throw @'
WACS entered interactive menu. The generated command is incomplete.
'@
    }

    $attempts = 1
    [void][int]::TryParse((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_WACS_RETRY_ATTEMPTS' -Default '1'), [ref]$attempts)
    if ($attempts -lt 1) { $attempts = 1 }
    $delaySeconds = 2
    [void][int]::TryParse((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_WACS_RETRY_DELAY_SECONDS' -Default '2'), [ref]$delaySeconds)
    if ($delaySeconds -lt 0) { $delaySeconds = 0 }
    $deferredDelaySeconds = 120
    [void][int]::TryParse((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_WACS_DEFERRED_RETRY_DELAY_SECONDS' -Default '120'), [ref]$deferredDelaySeconds)
    if ($deferredDelaySeconds -lt 0) { $deferredDelaySeconds = 0 }

    $wacsPath = Resolve-WacsExecutable -EnvValues $EnvValues
    if (-not [System.IO.Path]::IsPathRooted([string]$wacsPath)) {
        throw "Resolved wacs path is not absolute: '$wacsPath'"
    }

    $last = $null
    $allowCacheOnRetry = $false
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        $attemptArgs = Get-WacsRetryArgumentList -Args $Args -AllowCache:$allowCacheOnRetry
        $last = Invoke-NativeProcess -FilePath $wacsPath -ArgumentList $attemptArgs -TimeoutSeconds $TimeoutSeconds -FatalPatterns @('(?i)\bfatal\b')
        $null = Get-WacsOutputAnalysis -OutputLines @($last.OutputLines) -RequireNonInteractiveMode
        foreach ($line in $last.OutputLines) { Write-Host ([string]$line) }
        if ($last.Succeeded) { return $last }
        if ($attempt -lt $attempts) {
            $deferredRetry = Test-WacsDeferredRetrySuggested -OutputLines @($last.OutputLines)
            if ($deferredRetry) {
                $allowCacheOnRetry = $true
                $effectiveDelay = [math]::Max(([math]::Pow(2, ($attempt - 1)) * $delaySeconds), $deferredDelaySeconds)
                Write-Warning "ACME order is still processing or temporarily rate limited. Waiting $([int][math]::Ceiling($effectiveDelay)) second(s) and retrying without --nocache so WACS can reuse the pending order."
            } else {
                $effectiveDelay = [math]::Pow(2, ($attempt - 1)) * $delaySeconds
            }
            Start-Sleep -Seconds ([int][math]::Ceiling($effectiveDelay))
        }
    }

    if ($last.TimedOut) { throw "wacs timed out after $TimeoutSeconds seconds and was terminated." }
    $lastOutput = @($last.OutputLines | Select-Object -Last 30)
    $wacsLogFilter = ''
    $acmeDirValue = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_DIRECTORY' -Default ''
    if (-not [string]::IsNullOrWhiteSpace($acmeDirValue)) {
        try { $wacsLogFilter = ([System.Uri]$acmeDirValue).Host } catch {}
    }
    $latestLog = Get-LatestSimpleAcmeLogFile -FilterText $wacsLogFilter
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
    $enteredInteractiveMode = ((Get-SafeCount (@($lines | Where-Object { $_ -match 'Please choose from the menu:' }))) -gt 0)

    if ($RequireNonInteractiveMode -and $enteredInteractiveMode) {
        throw @'
WACS entered interactive menu. The generated command is incomplete.
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


function ConvertTo-WacsCommandLineText {
    param([Alias('Args')][AllowNull()][string[]]$ArgumentList)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($arg in @($ArgumentList | ForEach-Object { [string]$_ })) {
        if ($arg -match '[\s"]') {
            $parts.Add(('"{0}"' -f $arg.Replace('"','\"')))
        } else {
            $parts.Add($arg)
        }
    }
    return ($parts -join ' ')
}

function Get-MaskedWacsIssueCommandPreview {
    param(
        [Parameter(Mandatory)][hashtable]$EnvValues,
        [string]$CsrAlgorithm = '',
        [switch]$EnsurePfxDirectory
    )

    $args = Get-WacsIssueArguments -EnvValues $EnvValues -CsrAlgorithm $CsrAlgorithm -EnsurePfxDirectory:$EnsurePfxDirectory
    $maskedArgs = Get-MaskedWacsArgumentsText -Args $args
    return ('wacs.exe ' + (ConvertTo-WacsCommandLineText -Args $maskedArgs))
}

function Get-WacsIssueArguments {
    param(
        [Parameter(Mandatory)][hashtable]$EnvValues,
        [string]$CsrAlgorithm = '',
        [switch]$EnsurePfxDirectory
    )

    $storePlugins = @(Get-EffectiveWacsStorePlugins -EnvValues $EnvValues)
    $installationPlugins = Get-InstallationPlugins -EnvValues $EnvValues

    $sourcePlugin = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SOURCE_PLUGIN' -Default 'manual'
    $orderPlugin = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_ORDER_PLUGIN' -Default 'single'
    $validationMode = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_VALIDATION_MODE' -Default 'none'
    $args = @(
        '--accepttos','--source', [string]$sourcePlugin,'--order', [string]$orderPlugin,'--baseuri', (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_DIRECTORY'),
        '--validation', [string]$validationMode,'--host', [string](Get-EnvValue -EnvValues $EnvValues -Key 'DOMAINS')
    )
    $args += @('--store', ($storePlugins -join ','))
    if ($storePlugins -contains 'pfxfile') {
        $pfxFilePath = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_PFX_FILE_PATH'
        if ([string]::IsNullOrWhiteSpace([string]$pfxFilePath)) {
            throw 'ACME_STORE_PLUGIN includes pfxfile, but ACME_PFX_FILE_PATH is empty.'
        }
        if ([System.IO.Path]::GetExtension([string]$pfxFilePath) -ne '') {
            throw "ACME_PFX_FILE_PATH must be a directory path, not a file path. Got: '$pfxFilePath'. Remove the filename (e.g. use 'C:\certs' instead of 'C:\certs\certificate.pfx')."
        }
        if ($EnsurePfxDirectory -and -not (Test-Path -LiteralPath ([string]$pfxFilePath) -PathType Container)) {
            New-Item -ItemType Directory -Path ([string]$pfxFilePath) -Force | Out-Null
        }
        $args += @('--pfxfilepath', [string]$pfxFilePath)
        $pfxPassword = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_PFX_PASSWORD'
        $requiresPfxPassword = ((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_PRIVATE_KEY_STRATEGY') -eq 'pfx-distribution' -or (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_TARGET_SYSTEM') -eq 'rds-farm' -or (Get-EnvValue -EnvValues $EnvValues -Key 'TARGET_SYSTEM') -eq 'rds-farm')
        if ([string]::IsNullOrWhiteSpace([string]$pfxPassword) -and $requiresPfxPassword) {
            throw 'ACME_STORE_PLUGIN includes pfxfile for PFX distribution, but ACME_PFX_PASSWORD is empty.'
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$pfxPassword)) {
            $args += @('--pfxpassword', [string]$pfxPassword)
        }
    }
    if ($storePlugins -contains 'certificatestore') {
        $certStoreLocation = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_CERT_STORE_LOCATION' -Default 'My'
        if (-not [string]::IsNullOrWhiteSpace([string]$certStoreLocation)) {
            $args += @('--certificatestore', [string]$certStoreLocation)
        }
    }
    $args += @('--nocache')
    if ((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_REQUIRES_EAB') -eq '1' -and -not [string]::IsNullOrWhiteSpace((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_KID'))) { $args += @('--eab-key-identifier', (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_KID')) }
    if ((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_REQUIRES_EAB') -eq '1' -and -not [string]::IsNullOrWhiteSpace((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_HMAC_SECRET'))) { $args += @('--eab-key', (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_HMAC_SECRET')) }
    if (-not [string]::IsNullOrWhiteSpace((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_ACCOUNT_NAME'))) { $args += @('--account', (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_ACCOUNT_NAME')) }
    if ($installationPlugins -contains 'script') {
        $scriptPath = (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SCRIPT_PATH')
        if ([string]::IsNullOrWhiteSpace([string]$scriptPath)) { throw 'ACME_INSTALLATION_PLUGINS includes script, but ACME_SCRIPT_PATH is empty.' }
        $scriptParams = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_SCRIPT_PARAMETERS' -Default '{CertThumbprint}'
        $args += @('--installation', 'script','--script', [string]$scriptPath, '--scriptparameters', [string]$scriptParams)
    } elseif ($installationPlugins -contains 'iis') {
        $args += @('--installation', 'iis')
    }
    if (-not [string]::IsNullOrWhiteSpace($CsrAlgorithm)) { $args += @('--csr', [string]$CsrAlgorithm) }
    return @($args)
}

function Invoke-WacsIssue {
    param([Parameter(Mandatory)][hashtable]$EnvValues)

    $csrAlgorithms = @(Get-CsrExecutionPlan -EnvValues $EnvValues)
    $timeoutSeconds = 300
    [void][int]::TryParse((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_WACS_TIMEOUT_SECONDS' -Default '300'), [ref]$timeoutSeconds)
    if ($timeoutSeconds -lt 30) { $timeoutSeconds = 30 }

    $logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $wrapperLog = Join-Path $logDir ('reconcile-{0}.log' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
    [Console]::WriteLine('Wrapper log:')
    [Console]::WriteLine($wrapperLog)

    Add-Content -LiteralPath $wrapperLog -Value ('timestamp=' + (Get-Date).ToString('o')) -Encoding UTF8
    Add-Content -LiteralPath $wrapperLog -Value ('env_path=' + [string]([Environment]::GetEnvironmentVariable('CERTIFICATE_ENV_FILE'))) -Encoding UTF8
    Add-Content -LiteralPath $wrapperLog -Value ('csr_selected=' + [string](Get-EnvValue -EnvValues $EnvValues -Key 'ACME_CSR_ALGORITHM' -Default 'ec')) -Encoding UTF8
    Add-Content -LiteralPath $wrapperLog -Value ('csr_fallback=' + $(if ((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_ALLOW_CSR_FALLBACK' -Default '1') -eq '1') { 'enabled' } else { 'disabled' })) -Encoding UTF8

    $lastError = $null
    for ($idx = 0; $idx -lt (Get-SafeCount $csrAlgorithms); $idx++) {
        $algorithm = [string]$csrAlgorithms[$idx]
        $commandArgs = Get-WacsIssueArguments -EnvValues $EnvValues -CsrAlgorithm $algorithm -EnsurePfxDirectory
        Add-Content -LiteralPath $wrapperLog -Value ('wacs_path=' + [string](Resolve-WacsExecutable -EnvValues $EnvValues)) -Encoding UTF8
        $maskedArgs = Get-MaskedWacsArgumentsText -Args $commandArgs
        $attemptNumber = $idx + 1
        Add-Content -LiteralPath $wrapperLog -Value ('attempt=' + $attemptNumber) -Encoding UTF8
        Add-Content -LiteralPath $wrapperLog -Value ('timeout_seconds=' + $timeoutSeconds) -Encoding UTF8
        Add-Content -LiteralPath $wrapperLog -Value ('masked_command=' + ($maskedArgs -join ' ')) -Encoding UTF8
        [Console]::WriteLine('Executing WACS command')
        [Console]::WriteLine('----------------------')
        [Console]::WriteLine('Arguments:')
        foreach ($a in $maskedArgs) { [Console]::WriteLine($a) }
        [Console]::WriteLine('')
        [Console]::WriteLine("Timeout seconds:`n$timeoutSeconds")
        try {
            $result = Invoke-WacsWithRetry -Args $commandArgs -EnvValues $EnvValues -TimeoutSeconds $timeoutSeconds
            Add-Content -LiteralPath $wrapperLog -Value ('stdout=' + (@($result.OutputLines) -join ' | ')) -Encoding UTF8
            Add-Content -LiteralPath $wrapperLog -Value ('stderr=' + [string]$result.StdErr) -Encoding UTF8
            Add-Content -LiteralPath $wrapperLog -Value ('exit_code=' + [string]$result.ExitCode) -Encoding UTF8
            Add-Content -LiteralPath $wrapperLog -Value ('timed_out=' + [string]$result.TimedOut) -Encoding UTF8
            Add-Content -LiteralPath $wrapperLog -Value ((Get-Date).ToString('s') + ' result=success csr=' + $algorithm) -Encoding UTF8
            return
        } catch {
            $lastError = $_
            Add-Content -LiteralPath $wrapperLog -Value ((Get-Date).ToString('s') + ' result=failure csr=' + $algorithm + ' message=' + $_.Exception.Message) -Encoding UTF8
            if ($_.InvocationInfo) {
                Add-Content -LiteralPath $wrapperLog -Value ('ps_exception_script=' + [string]$_.InvocationInfo.ScriptName) -Encoding UTF8
                Add-Content -LiteralPath $wrapperLog -Value ('ps_exception_line=' + [string]$_.InvocationInfo.ScriptLineNumber) -Encoding UTF8
                Add-Content -LiteralPath $wrapperLog -Value ('ps_exception_command=' + [string]$_.InvocationInfo.Line) -Encoding UTF8
            }
            Add-Content -LiteralPath $wrapperLog -Value ('ps_exception_message=' + [string]$_.Exception.Message) -Encoding UTF8
            Add-Content -LiteralPath $wrapperLog -Value ('ps_script_stack=' + [string]$_.ScriptStackTrace) -Encoding UTF8
            if ($idx -lt ((Get-SafeCount $csrAlgorithms) - 1)) { Write-Warning "WACS issuance failed using selected CSR algorithm: $algorithm. Fallback enabled; trying rsa." }
            else { if ((Get-SafeCount $csrAlgorithms) -eq 1 -and $algorithm -eq 'ec') { Write-Warning 'WACS issuance failed using selected CSR algorithm: ec'; Write-Warning 'Fallback to RSA is disabled.' } }
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

function Test-RenewalAcmeDirectoryMatch {
    param(
        [Parameter(Mandatory)]$RenewalSummary,
        [Parameter(Mandatory)][hashtable]$EnvValues
    )

    $renewalBaseUri = [string]$RenewalSummary.BaseUri
    if ([string]::IsNullOrWhiteSpace($renewalBaseUri)) {
        return $true
    }

    $expectedBaseUri = Get-EnvValue -EnvValues $EnvValues -Key 'ACME_DIRECTORY'
    if ([string]::IsNullOrWhiteSpace($expectedBaseUri)) {
        return $true
    }

    return ($renewalBaseUri.TrimEnd('/') -eq ([string]$expectedBaseUri).TrimEnd('/'))
}

function Get-RenewalIdForCancel {
    param([Parameter(Mandatory)]$RenewalSummary)
    if (-not [string]::IsNullOrWhiteSpace([string]$RenewalSummary.RenewalId)) { return [string]$RenewalSummary.RenewalId }
    throw "Unable to determine renewal id from renewal JSON file '$($RenewalSummary.File.FullName)'"
}

function Invoke-WacsRenewalCheck {
    param(
        [Parameter(Mandatory)][hashtable]$EnvValues,
        [Parameter(Mandatory)][string]$RenewalId,
        [switch]$Force
    )

    $args = @('--baseuri', (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_DIRECTORY'), '--renew', '--id', $RenewalId)
    if ($Force) { $args += '--force' }
    $timeoutSeconds = 600
    [void][int]::TryParse((Get-EnvValue -EnvValues $EnvValues -Key 'ACME_WACS_TIMEOUT_SECONDS' -Default '600'), [ref]$timeoutSeconds)
    if ($timeoutSeconds -lt 60) { $timeoutSeconds = 60 }
    return Invoke-WacsWithRetry -Args $args -EnvValues $EnvValues -TimeoutSeconds $timeoutSeconds
}

function Write-ReconcileLog {
    param(
        [Parameter(Mandatory)][ValidateSet('create','update','renew','no-op')][string]$Action,
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
    if ([string]::IsNullOrWhiteSpace($logDir)) {
        $logDir = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') 'logs'))
    }
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logPath = Join-Path $logDir ("reconcile-{0}.log" -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd'))
    Add-Content -LiteralPath $logPath -Value $serialized -Encoding UTF8
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

    $null = Remove-MalformedRenewalFiles
    $allRenewalFiles = Get-RenewalFiles
    $matching = @()
    foreach ($file in $allRenewalFiles) {
        $summary = Get-RenewalSummarySafe -File $file
        if ($null -eq $summary) { continue }
        if ((Test-ExactDomainSetMatch -Requested $domains -Actual $summary.Hosts) -and (Test-RenewalAcmeDirectoryMatch -RenewalSummary $summary -EnvValues $EnvValues)) {
            $matching += ,$summary
        }
    }

    if ((Get-SafeCount $matching) -eq 0) {
        $preIssuanceFilePaths = @($allRenewalFiles | ForEach-Object { [string]$_.FullName })
        if (-not $SkipWacs) {
            Invoke-WacsIssue -EnvValues $EnvValues
            $allRenewalFiles = Get-RenewalFiles
        }

        $postMatch = @()
        foreach ($file in $allRenewalFiles) {
            $summary = Get-RenewalSummarySafe -File $file
            if ($null -eq $summary) { continue }
            if ((Test-ExactDomainSetMatch -Requested $domains -Actual $summary.Hosts) -and (Test-RenewalAcmeDirectoryMatch -RenewalSummary $summary -EnvValues $EnvValues)) { $postMatch += ,$summary }
        }

        if ((Get-SafeCount $postMatch) -eq 0) {
            $newFiles = @($allRenewalFiles | Where-Object { $preIssuanceFilePaths -notcontains [string]$_.FullName })
            $malformedCount = (Get-SafeCount @($allRenewalFiles | Where-Object {
                $s = Get-RenewalSummarySafe -File $_
                $null -eq $s
            }))
            $diagMsg = "No matching renewal file found after issuance. New files written by WACS: $(Get-SafeCount $newFiles). Total files: $(Get-SafeCount $allRenewalFiles). Unreadable/malformed: $malformedCount."
            Write-ReconcileLog -Action 'create' -Domains $domains -Result 'failure' -Message $diagMsg
            throw $diagMsg
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
        $certificateHealth = Test-RenewalCertificateHealth -RenewalSummary $current -EnvValues $EnvValues
        $renewalId = Get-RenewalIdForCancel -RenewalSummary $current
        $forceInstallRepair = ([string]$certificateHealth.Status -eq 'InstallationFailed')
        if (-not $SkipWacs) {
            Invoke-WacsRenewalCheck -EnvValues $EnvValues -RenewalId $renewalId -Force:$forceInstallRepair | Out-Null
        }
        $renewMessage = if ($forceInstallRepair) {
            "Renewal configuration already matches .env. Previous installation failed, so simple-acme renewal was forced to rerun the installation hook. Local certificate state: $($certificateHealth.Status). $($certificateHealth.Message)"
        } else {
            "Renewal configuration already matches .env. simple-acme ARI renewal check completed. Local certificate state: $($certificateHealth.Status). $($certificateHealth.Message)"
        }
        Write-ReconcileLog -Action 'renew' -Domains $domains -Result 'success' -Message $renewMessage
        return 'renew'
    }

    if (-not $SkipWacs) {
        $renewalId = Get-RenewalIdForCancel -RenewalSummary $current
        $cancelPath = $current.File.FullName
        # Regression guard: keep cancellation by renewal id (`--cancel --id <renewal-id>`),
        # but bind the cancel command to the configured ACME directory so non-default providers
        # (for example Networking4All test/prod endpoints) do not fall back to Let's Encrypt.
        Invoke-WacsWithRetry -Args @('--baseuri', (Get-EnvValue -EnvValues $EnvValues -Key 'ACME_DIRECTORY'), '--cancel', '--id', $renewalId) -EnvValues $EnvValues
        Wait-RenewalFileRemoval -Path $cancelPath
        Start-Sleep -Seconds 2
        Invoke-WacsIssue -EnvValues $EnvValues
    }

    $freshFiles = Get-RenewalFiles
    $postUpdate = @()
    foreach ($file in $freshFiles) {
        $summary = Get-RenewalSummarySafe -File $file
        if ($null -eq $summary) { continue }
        if ((Test-ExactDomainSetMatch -Requested $domains -Actual $summary.Hosts) -and (Test-RenewalAcmeDirectoryMatch -RenewalSummary $summary -EnvValues $EnvValues)) { $postUpdate += ,$summary }
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
$FunctionsToExport.Add('ConvertTo-HashtableRecursive')
$FunctionsToExport.Add('Get-NormalizedDomains')
$FunctionsToExport.Add('Get-SafeCount')
$FunctionsToExport.Add('Get-RenewalFiles')
$FunctionsToExport.Add('Get-RenewalSummary')
$FunctionsToExport.Add('Get-RenewalSummarySafe')
$FunctionsToExport.Add('Remove-MalformedRenewalFiles')
$FunctionsToExport.Add('Get-InstallationPlugins')
$FunctionsToExport.Add('Get-CsrExecutionPlan')
$FunctionsToExport.Add('Get-RenewalIdForCancel')
$FunctionsToExport.Add('Invoke-SimpleAcmeReconcile')
$FunctionsToExport.Add('Get-WacsFileVersion')
$FunctionsToExport.Add('Get-WacsVersion')
$FunctionsToExport.Add('Get-WacsOutputAnalysis')
$FunctionsToExport.Add('Invoke-WacsWithRetry')
$FunctionsToExport.Add('Invoke-WacsIssue')
$FunctionsToExport.Add('Get-MaskedWacsArgumentsText')
$FunctionsToExport.Add('Test-WacsDeferredRetrySuggested')
$FunctionsToExport.Add('Get-WacsRetryArgumentList')
$FunctionsToExport.Add('ConvertTo-WacsCommandLineText')
$FunctionsToExport.Add('Get-WacsIssueArguments')
$FunctionsToExport.Add('Invoke-WacsRenewalCheck')
$FunctionsToExport.Add('Get-MaskedWacsIssueCommandPreview')
$FunctionsToExport.Add('ConvertTo-NormalizedWacsScriptParametersText')
$FunctionsToExport.Add('Get-NormalizedCsvValues')
$FunctionsToExport.Add('Wait-RenewalFileRemoval')
$FunctionsToExport.Add('New-ReconcileConfigHash')
$FunctionsToExport.Add('Test-ExactDomainSetMatch')
$FunctionsToExport.Add('Test-RenewalAcmeDirectoryMatch')
$FunctionsToExport.Add('Write-ReconcileLog')
$FunctionsToExport.Add('Test-RenewalCertificateHealth')
$FunctionsToExport.Add('Test-CertificateDomainPatternMatch')
$FunctionsToExport.Add('Test-CertificateCoversDomains')
$FunctionsToExport.Add('Get-EffectiveWacsStorePlugins')
$FunctionsToExport.Add('Test-IsAdministrator')

Set-Alias -Name Normalize-WacsScriptParametersText -Value ConvertTo-NormalizedWacsScriptParametersText

$AliasesToExport = New-Object System.Collections.Generic.List[string]
$AliasesToExport.Add('Normalize-WacsScriptParametersText')
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

Export-ModuleMember -Function ([string[]]$FunctionsToExport.ToArray()) -Alias ([string[]]$AliasesToExport.ToArray())
