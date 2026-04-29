Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'


$skipExitCode = 42
$requiresDesktop = $PSVersionTable.PSEdition -eq 'Desktop'
$requiresMajor5 = $PSVersionTable.PSVersion.Major -eq 5
if (-not ($requiresDesktop -and $requiresMajor5)) {
    Write-Host ('[SKIP_ENV_PS51_REQUIRED] requires Windows PowerShell 5.1 Desktop; detected edition={0} version={1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
    exit $skipExitCode
}


function Invoke-ScriptAnalyzerCheck {
    Write-Host '[INFO] ScriptAnalyzer check: linting PowerShell scripts.'

    $module = Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1
    if (-not $module) {
        Write-Host '[SKIP] ScriptAnalyzer check :: PSScriptAnalyzer is unavailable in this environment.'
        return
    }

    $settingsPath = Join-Path $PSScriptRoot '..' 'PSScriptAnalyzerSettings.psd1'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        throw "ScriptAnalyzer settings file not found at $settingsPath"
    }

    $analysisTargets = @(
        (Join-Path $PSScriptRoot '..' '*.ps1'),
        (Join-Path $PSScriptRoot '..' 'build/*.ps1'),
        (Join-Path $PSScriptRoot '..' 'core/*.psm1'),
        (Join-Path $PSScriptRoot '..' 'setup/*.ps1'),
        (Join-Path $PSScriptRoot '..' 'setup/*.psm1'),
        (Join-Path $PSScriptRoot '*.ps1')
    )

    $results = @(Invoke-ScriptAnalyzer -Path $analysisTargets -Settings $settingsPath -Recurse)
    if ($results.Count -gt 0) {
        $results | Format-Table -AutoSize RuleName, Severity, ScriptName, Line, Message | Out-Host
        throw "ScriptAnalyzer reported $($results.Count) issue(s)."
    }
}

Invoke-ScriptAnalyzerCheck

$testFiles = @(Get-ChildItem -Path $PSScriptRoot -File | Where-Object { $_.Name -like '*.Tests.ps1' -or $_.Name -like 'Test-*.ps1' } | Sort-Object Name)
$pass = 0
$fail = 0
$skip = 0

function Invoke-Assertion {
    param([string]$Name,[scriptblock]$Body)
    try {
        & $Body
        $script:pass++
        Write-Host "[PASS] $Name"
    } catch {
        $script:fail++
        Write-Host "[FAIL] $Name :: $($_.Exception.Message)"
    }
}

foreach ($file in $testFiles) {
    try {
        $raw = Get-Content -LiteralPath $file.FullName -Raw
        $looksLikePester = $raw -match '(?m)^\s*(Describe|Context|It)\b'
        $hasDescribe = $null -ne (Get-Command -Name 'Describe' -CommandType Function -ErrorAction SilentlyContinue)
        if ($looksLikePester -and -not $hasDescribe) {
            $skip++
            Write-Host "[SKIP] $($file.Name) :: Pester syntax detected but Pester is unavailable in this environment."
            continue
        }

        . $file.FullName
        $fns = @(Get-Command -Name 'Invoke-Test*' -CommandType Function | Where-Object { $_.ScriptBlock.File -eq $file.FullName })
        if ($fns.Count -eq 0) {
            $skip++
            Write-Host "[SKIP] $($file.Name) :: no Invoke-Test* function found (legacy/Pester style)."
            continue
        }
        foreach ($fn in $fns) {
            & $fn.Name -Assert ${function:Invoke-Assertion}
        }
    } catch {
        $fail++
        Write-Host "[FAIL] $($file.Name) :: $($_.Exception.Message)"
    }
}

Write-Host ("Summary: pass={0} fail={1} skip={2}" -f $pass, $fail, $skip)
if ($fail -gt 0) { exit 1 }
exit 0
