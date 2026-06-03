#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-ClavisterSecureString {
    param([Parameter(Mandatory)][SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}

function Join-ClavisterProcessArguments {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ArgumentList)

    $quoted = foreach ($arg in $ArgumentList) {
        $text = if ($null -eq $arg) { '' } else { [string]$arg }
        if ($text.Length -eq 0) { '""'; continue }
        if ($text -notmatch '[\s"]') { $text; continue }
        $escaped = $text -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        '"' + $escaped + '"'
    }
    return ($quoted -join ' ')
}

function Invoke-ClavisterProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = Join-ClavisterProcessArguments -ArgumentList $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            throw "Process timed out after $TimeoutSeconds second(s): $FilePath"
        }
        [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Output = [string]$stdoutTask.Result
            Error = [string]$stderrTask.Result
        }
    } finally {
        $process.Dispose()
    }
}

function Resolve-ClavisterToolPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Names)

    foreach ($name in $Names) {
        $command = @(Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($command.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$command[0].Source)) {
            return [string]$command[0].Source
        }
    }
    return ''
}

function Resolve-ClavisterOpenSslPath {
    [CmdletBinding()]
    param([string]$OpenSslPath = '')

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($OpenSslPath)) {
        $candidates += $OpenSslPath
    } else {
        foreach ($command in @(Get-Command openssl.exe -All -ErrorAction SilentlyContinue)) {
            $candidates += [string]$command.Source
        }
    }

    foreach ($candidate in @($candidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($candidate -match '\\Git\\usr\\bin\\openssl\.exe$') {
            $gitRoot = Split-Path (Split-Path (Split-Path $candidate -Parent) -Parent) -Parent
            $mingwOpenSsl = Join-Path $gitRoot 'mingw64\bin\openssl.exe'
            if (Test-Path -LiteralPath $mingwOpenSsl -PathType Leaf) { return $mingwOpenSsl }
        }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

function Get-ClavisterOpenSslModulePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OpenSslPath)

    $opensslDir = Split-Path -Parent $OpenSslPath
    foreach ($candidate in @(
        (Join-Path $opensslDir '..\lib\ossl-modules'),
        (Join-Path $opensslDir '..\..\mingw64\lib\ossl-modules'),
        (Join-Path $opensslDir '..\..\lib\ossl-modules')
    )) {
        try {
            $resolved = [IO.Path]::GetFullPath($candidate)
            if (Test-Path -LiteralPath (Join-Path $resolved 'legacy.dll') -PathType Leaf) { return $resolved }
        } catch {
            continue
        }
    }
    return ''
}

function Invoke-ClavisterOpenSsl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OpenSslPath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $modulePath = Get-ClavisterOpenSslModulePath -OpenSslPath $OpenSslPath
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $OpenSslPath
    $psi.Arguments = Join-ClavisterProcessArguments -ArgumentList $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($modulePath)) {
        $psi.EnvironmentVariables['OPENSSL_MODULES'] = $modulePath
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        $errorText = $process.StandardError.ReadToEnd()
        [void]$process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Error = [string]$errorText }
    } finally {
        $process.Dispose()
    }
}

function Invoke-ClavisterOpenSslWithLegacyRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OpenSslPath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$ExpectedOutputPath
    )

    $result = Invoke-ClavisterOpenSsl -OpenSslPath $OpenSslPath -ArgumentList $ArgumentList
    if (($result.ExitCode -eq 0) -and (Test-Path -LiteralPath $ExpectedOutputPath -PathType Leaf)) { return $result }
    if ([string]$result.Error -notmatch 'unsupported|RC2-40-CBC|legacy') { return $result }

    if (Test-Path -LiteralPath $ExpectedOutputPath -PathType Leaf) { Remove-Item -LiteralPath $ExpectedOutputPath -Force }
    $legacyArgs = @('pkcs12','-legacy') + @($ArgumentList | Select-Object -Skip 1)
    return Invoke-ClavisterOpenSsl -OpenSslPath $OpenSslPath -ArgumentList $legacyArgs
}

function Convert-ClavisterPfxToPemFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PfxPath,
        [string]$Password = '',
        [string]$OpenSslPath = ''
    )

    if (-not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) { throw "PFX file was not found: $PfxPath" }
    if ([string]::IsNullOrWhiteSpace($OpenSslPath)) {
        $OpenSslPath = Resolve-ClavisterOpenSslPath
    } else {
        $OpenSslPath = Resolve-ClavisterOpenSslPath -OpenSslPath $OpenSslPath
    }
    if ([string]::IsNullOrWhiteSpace($OpenSslPath)) { throw 'OpenSSL was not found. Clavister deployment needs openssl.exe to export PEM certificate and private key files.' }

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("simple-acme-clavister-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $certPath = Join-Path $tempDir 'fullchain.pem'
    $keyPath = Join-Path $tempDir 'privkey.pem'
    $passIn = if ([string]::IsNullOrEmpty($Password)) { 'pass:' } else { 'pass:' + $Password }

    $certArgs = @('pkcs12','-in',$PfxPath,'-nokeys','-out',$certPath,'-passin',$passIn)
    $certResult = Invoke-ClavisterOpenSslWithLegacyRetry -OpenSslPath $OpenSslPath -ArgumentList $certArgs -ExpectedOutputPath $certPath
    if ($certResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $certPath -PathType Leaf)) {
        throw "OpenSSL failed to export Clavister certificate chain. ExitCode=$($certResult.ExitCode). Error: $($certResult.Error.Trim())"
    }

    $keyArgs = @('pkcs12','-in',$PfxPath,'-nocerts','-nodes','-out',$keyPath,'-passin',$passIn)
    $keyResult = Invoke-ClavisterOpenSslWithLegacyRetry -OpenSslPath $OpenSslPath -ArgumentList $keyArgs -ExpectedOutputPath $keyPath
    if ($keyResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
        throw "OpenSSL failed to export Clavister private key. ExitCode=$($keyResult.ExitCode). Error: $($keyResult.Error.Trim())"
    }

    [pscustomobject]@{ TempDirectory = $tempDir; CertificatePath = $certPath; KeyPath = $keyPath }
}

function New-ClavisterSshArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 22,
        [Parameter(Mandatory)][string]$Username,
        [string]$PrivateKeyPath = '',
        [string]$HostKeyFingerprint = '',
        [string]$Password = '',
        [switch]$ForScp,
        [string]$LocalPath = '',
        [string]$RemotePath = '',
        [string]$Command = ''
    )

    $hasPassword = -not [string]::IsNullOrWhiteSpace($Password)
    $hasKey = -not [string]::IsNullOrWhiteSpace($PrivateKeyPath)
    $puttyTool = if ($ForScp) { Resolve-ClavisterToolPath -Names @('pscp.exe','pscp') } else { Resolve-ClavisterToolPath -Names @('plink.exe','plink') }

    if ($hasPassword -or -not [string]::IsNullOrWhiteSpace($HostKeyFingerprint) -or ($hasKey -and $PrivateKeyPath -match '\.ppk$')) {
        if ([string]::IsNullOrWhiteSpace($puttyTool)) {
            throw 'Clavister password auth or PPK/host-key-pinned auth needs PuTTY pscp.exe/plink.exe on PATH. Use an OpenSSH private key or install PuTTY tools.'
        }
        $args = @('-batch','-P',[string]$Port)
        if ($hasPassword) { $args += @('-pw',$Password) }
        if ($hasKey) { $args += @('-i',$PrivateKeyPath) }
        if (-not [string]::IsNullOrWhiteSpace($HostKeyFingerprint)) { $args += @('-hostkey',$HostKeyFingerprint) }
        if ($ForScp) {
            $args += @($LocalPath, ("{0}@{1}:{2}" -f $Username, $HostName, $RemotePath))
        } else {
            $args += @("-ssh", ("{0}@{1}" -f $Username, $HostName), $Command)
        }
        return [pscustomobject]@{ Tool = $puttyTool; Arguments = $args; ToolFamily = 'putty' }
    }

    if ($ForScp) {
        $scpTool = Resolve-ClavisterToolPath -Names @('scp.exe','scp')
        if ([string]::IsNullOrWhiteSpace($scpTool)) { throw 'scp.exe was not found on PATH.' }
        $args = @('-P',[string]$Port,'-o','BatchMode=yes','-o','StrictHostKeyChecking=accept-new')
        if ($hasKey) { $args += @('-i',$PrivateKeyPath) }
        $args += @($LocalPath, ("{0}@{1}:{2}" -f $Username, $HostName, $RemotePath))
        return [pscustomobject]@{ Tool = $scpTool; Arguments = $args; ToolFamily = 'openssh' }
    }

    $sshTool = Resolve-ClavisterToolPath -Names @('ssh.exe','ssh')
    if ([string]::IsNullOrWhiteSpace($sshTool)) { throw 'ssh.exe was not found on PATH.' }
    $sshArgs = @('-p',[string]$Port,'-o','BatchMode=yes','-o','StrictHostKeyChecking=accept-new')
    if ($hasKey) { $sshArgs += @('-i',$PrivateKeyPath) }
    $sshArgs += @("{0}@{1}" -f $Username, $HostName, $Command)
    return [pscustomobject]@{ Tool = $sshTool; Arguments = $sshArgs; ToolFamily = 'openssh' }
}

function Invoke-ClavisterScpUpload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 22,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$CertificateName,
        [string]$Password = '',
        [string]$PrivateKeyPath = '',
        [string]$HostKeyFingerprint = '',
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) { throw "Upload file was not found: $LocalPath" }
    $remotePath = "certificate/$CertificateName"
    $resolved = New-ClavisterSshArguments -HostName $HostName -Port $Port -Username $Username -PrivateKeyPath $PrivateKeyPath -HostKeyFingerprint $HostKeyFingerprint -Password $Password -ForScp -LocalPath $LocalPath -RemotePath $remotePath
    $result = Invoke-ClavisterProcess -FilePath $resolved.Tool -ArgumentList $resolved.Arguments -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        throw "Clavister SCP upload failed for $remotePath. ExitCode=$($result.ExitCode). Error: $($result.Error.Trim())"
    }
    [pscustomobject]@{ Status='Succeeded'; RemotePath=$remotePath; ToolFamily=$resolved.ToolFamily }
}

function Invoke-ClavisterSshCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 22,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Command,
        [string]$Password = '',
        [string]$PrivateKeyPath = '',
        [string]$HostKeyFingerprint = '',
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    $resolved = New-ClavisterSshArguments -HostName $HostName -Port $Port -Username $Username -PrivateKeyPath $PrivateKeyPath -HostKeyFingerprint $HostKeyFingerprint -Password $Password -Command $Command
    $result = Invoke-ClavisterProcess -FilePath $resolved.Tool -ArgumentList $resolved.Arguments -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        throw "Clavister SSH command '$Command' failed. ExitCode=$($result.ExitCode). Error: $($result.Error.Trim())"
    }
    [pscustomobject]@{ Status='Succeeded'; Command=$Command; Output=$result.Output; ToolFamily=$resolved.ToolFamily }
}

function Test-ClavisterSshConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 22,
        [Parameter(Mandatory)][string]$Username,
        [string]$Password = '',
        [string]$PrivateKeyPath = '',
        [string]$HostKeyFingerprint = '',
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 30
    )

    try {
        $result = Invoke-ClavisterSshCommand -HostName $HostName -Port $Port -Username $Username -Password $Password -PrivateKeyPath $PrivateKeyPath -HostKeyFingerprint $HostKeyFingerprint -Command 'help' -TimeoutSeconds $TimeoutSeconds
        [pscustomobject]@{ Status='Succeeded'; Message='Clavister SSH command authentication succeeded.'; Host=$HostName; Port=$Port; ToolFamily=$result.ToolFamily }
    } catch {
        [pscustomobject]@{ Status='Failed'; Message=$_.Exception.Message; Host=$HostName; Port=$Port }
    }
}

Export-ModuleMember -Function ConvertFrom-ClavisterSecureString,Convert-ClavisterPfxToPemFiles,Invoke-ClavisterScpUpload,Invoke-ClavisterSshCommand,Test-ClavisterSshConnection
