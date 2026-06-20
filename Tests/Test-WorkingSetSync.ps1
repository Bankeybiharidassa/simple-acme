function Invoke-TestWorkingSetSync {
    param([scriptblock]$Assert)

    $root = Split-Path $PSScriptRoot -Parent
    $scriptPath = Join-Path $root 'build\sync-working-set.ps1'

    & $Assert 'working-set sync script exists and supports dev test dist modes' {
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw "Missing working-set sync script: $scriptPath"
        }
        $raw = Get-Content -LiteralPath $scriptPath -Raw
        foreach ($text in @(
            "ValidateSet('DevToTestAndDist','DevToTest','DevToDist','TestToDev','Check')",
            'Join-Path $ProjectRoot ''test\certificaat''',
            'Join-Path $ProjectRoot ''dist''',
            "build\release-file-list.txt",
            'git -C $Root ls-files',
            "'test\certificaat -> dev'",
            "'dev -> test\certificaat'",
            "'dev -> dist'",
            'Working-set sync check failed.'
        )) {
            if (-not $raw.Contains($text)) { throw "Missing sync contract text: $text" }
        }
    }

    & $Assert 'working-set sync script parses under Windows PowerShell AST' {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            throw "Parser errors in sync-working-set.ps1: $($errors.Count)"
        }
    }
}
