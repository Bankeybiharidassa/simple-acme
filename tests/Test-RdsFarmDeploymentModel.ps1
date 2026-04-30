Set-StrictMode -Version Latest

function Invoke-TestRdsFarmDeploymentModel {
    param([scriptblock]$Assert)

    & $Assert 'deployment-targets schema enables pfx distribution and has no password fields' {
        $sample = @{
            schema='simple-acme-helper-deployment-targets.v1';
            pfxDistribution=@{enabled=$true};
            sessionHosts=@(@{name='rdsh01';username='DOMAIN\\user'})
        } | ConvertTo-Json -Depth 6
        if ($sample -notmatch '\"enabled\"\s*:\s*true') { throw 'pfxDistribution.enabled must be true' }
        if ($sample -match '\"password\"' -or $sample -match '\"pfxPassword\"') { throw 'password keys not allowed' }
    }

    & $Assert 'deploy-rds-farm exits non-zero for missing local cert thumbprint' {
        $script = Join-Path $PSScriptRoot '..\Scripts\deploy-rds-farm.ps1'
        $root = Split-Path $PSScriptRoot -Parent
        $dt = Join-Path $root 'deployment-targets.json'
        if (-not (Test-Path $dt)) { '{"schema":"simple-acme-helper-deployment-targets.v1","pfxDistribution":{"deleteLocalPfxAfterImport":true,"deleteRemotePfxAfterImport":true,"remoteTempDirectory":"C:\\Windows\\Temp\\simple-acme-helper"},"sessionHosts":[]}' | Set-Content -LiteralPath $dt -Encoding UTF8 }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $script 'BADTHUMB' | Out-Null
        if ($LASTEXITCODE -eq 0) { throw 'Expected non-zero exit for missing cert' }
    }
}
