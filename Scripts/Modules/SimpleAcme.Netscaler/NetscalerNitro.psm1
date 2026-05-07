#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:NetscalerNitroSession = $null
$script:NetscalerNitroBaseUri = $null
$script:NetscalerNitroSkipCertificateCheck = $false
$script:NetscalerNitroRetryCount = 2
$script:NetscalerNitroRetryDelaySeconds = 1

function ConvertFrom-NetscalerSecureString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [SecureString]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Resolve-NetscalerPassword {
    [CmdletBinding(DefaultParameterSetName = 'SecureString')]
    param(
        [Parameter(ParameterSetName = 'SecureString')]
        [SecureString]$Password,

        [Parameter(ParameterSetName = 'SecretName')]
        [string]$PasswordSecretName
    )

    if ($PSCmdlet.ParameterSetName -eq 'SecretName') {
        if ([string]::IsNullOrWhiteSpace($PasswordSecretName)) {
            throw 'PasswordSecretName cannot be empty.'
        }

        if (Get-Command -Name Get-Secret -ErrorAction SilentlyContinue) {
            $secret = Get-Secret -Name $PasswordSecretName -ErrorAction Stop
            if ($secret -is [SecureString]) { return (ConvertFrom-NetscalerSecureString -SecureString $secret) }
            if ($secret -is [string]) { return $secret }
            if ($secret -is [pscredential]) { return (ConvertFrom-NetscalerSecureString -SecureString $secret.Password) }
            throw "Secret '$PasswordSecretName' returned unsupported type '$($secret.GetType().FullName)'."
        }

        $envName = ('SIMPLE_ACME_SECRET_{0}' -f ($PasswordSecretName -replace '[^A-Za-z0-9]', '_')).ToUpperInvariant()
        $envValue = [Environment]::GetEnvironmentVariable($envName)
        if ([string]::IsNullOrEmpty($envValue)) {
            throw "Secret '$PasswordSecretName' was not found. Install Microsoft.PowerShell.SecretManagement or set $envName."
        }
        return $envValue
    }

    if ($null -eq $Password) { throw 'Password is required when PasswordSecretName is not supplied.' }
    ConvertFrom-NetscalerSecureString -SecureString $Password
}

function Connect-NetscalerNitroSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Username,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Password,

        [switch]$SkipCertificateCheck,

        [ValidateRange(0, 10)]
        [int]$RetryCount = 2,

        [ValidateRange(0, 60)]
        [int]$RetryDelaySeconds = 1
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $script:NetscalerNitroSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $script:NetscalerNitroBaseUri = ('https://{0}/nitro/v1' -f $HostName.Trim('/'))
    $script:NetscalerNitroSkipCertificateCheck = [bool]$SkipCertificateCheck
    $script:NetscalerNitroRetryCount = $RetryCount
    $script:NetscalerNitroRetryDelaySeconds = $RetryDelaySeconds

    $body = @{ login = @{ username = $Username; password = $Password } }
    $null = Invoke-NetscalerNitroRequest -Method POST -Path '/config/login' -Body $body -RetryCount $RetryCount -RetryDelaySeconds $RetryDelaySeconds
}

function Disconnect-NetscalerNitroSession {
    [CmdletBinding()]
    param()

    if ($null -ne $script:NetscalerNitroSession -and -not [string]::IsNullOrWhiteSpace($script:NetscalerNitroBaseUri)) {
        try {
            $null = Invoke-NetscalerNitroRequest -Method POST -Path '/config/logout' -Body @{ logout = @{} } -RetryCount 0
        } catch {
            Write-Warning ('NetScaler logout failed: {0}' -f $_.Exception.Message)
        }
    }

    $script:NetscalerNitroSession = $null
    $script:NetscalerNitroBaseUri = $null
}

function Invoke-NetscalerNitroRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^/')]
        [string]$Path,

        [object]$Body,

        [ValidateRange(0, 10)]
        [int]$RetryCount = $script:NetscalerNitroRetryCount,

        [ValidateRange(0, 60)]
        [int]$RetryDelaySeconds = $script:NetscalerNitroRetryDelaySeconds
    )

    if ([string]::IsNullOrWhiteSpace($script:NetscalerNitroBaseUri)) {
        throw 'NetScaler NITRO session is not connected.'
    }

    $uri = '{0}{1}' -f $script:NetscalerNitroBaseUri, $Path
    $params = @{
        Method      = $Method
        Uri         = $uri
        ErrorAction = 'Stop'
        WebSession  = $script:NetscalerNitroSession
        Headers     = @{ 'X-NITRO-USER' = $null; 'X-NITRO-PASS' = $null }
    }
    $params.Remove('Headers')

    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
        $params.ContentType = 'application/json'
    }

    $previousCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    if ($script:NetscalerNitroSkipCertificateCheck) {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }

    $attempt = 0
    try {
        while ($true) {
            try {
                $response = Invoke-RestMethod @params
                if ($null -ne $response -and ($response.PSObject.Properties.Name -contains 'errorcode') -and [int]$response.errorcode -ne 0) {
                    $nitroMessage = if ($response.PSObject.Properties.Name -contains 'message') { [string]$response.message } else { 'NITRO returned an error.' }
                    throw "NetScaler NITRO $Method $Path returned errorcode $($response.errorcode): $nitroMessage"
                }
                return $response
            } catch {
                $attempt++
                $statusCode = $null
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
                $retryable = ($statusCode -eq 0 -or $statusCode -eq 408 -or $statusCode -eq 429 -or $statusCode -ge 500)
                if ($attempt -gt $RetryCount -or -not $retryable) {
                    $message = $_.Exception.Message
                    throw "NetScaler NITRO $Method $Path failed: $message"
                }
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    } finally {
        if ($script:NetscalerNitroSkipCertificateCheck) {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
        }
    }
}

function Test-NetscalerLocalCertificateFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CertPath,

        [Parameter(Mandatory = $true)]
        [string]$KeyPath,

        [string]$ChainPath
    )

    $paths = @(
        @{ Name = 'CertPath'; Path = $CertPath; Required = $true },
        @{ Name = 'KeyPath'; Path = $KeyPath; Required = $true },
        @{ Name = 'ChainPath'; Path = $ChainPath; Required = -not [string]::IsNullOrWhiteSpace($ChainPath) }
    )

    foreach ($entry in $paths) {
        if (-not $entry.Required) { continue }
        if ([string]::IsNullOrWhiteSpace($entry.Path)) { throw "$($entry.Name) is required." }
        if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) { throw "$($entry.Name) '$($entry.Path)' was not found." }
    }

    [pscustomobject]@{
        CertPath  = (Resolve-Path -LiteralPath $CertPath -ErrorAction Stop).Path
        KeyPath   = (Resolve-Path -LiteralPath $KeyPath -ErrorAction Stop).Path
        ChainPath = if ([string]::IsNullOrWhiteSpace($ChainPath)) { $null } else { (Resolve-Path -LiteralPath $ChainPath -ErrorAction Stop).Path }
    }
}

function Get-NetscalerHAState {
    [CmdletBinding()]
    param()

    try {
        $response = Invoke-NetscalerNitroRequest -Method GET -Path '/stat/hanode'
    } catch {
        return [pscustomobject]@{ HAConfigured = $false; HAMasterState = 'UNKNOWN'; Raw = $null }
    }

    $nodes = @($response.hanode)
    $primary = @($nodes | Where-Object { $_.hacurmasterstate -eq 'PRIMARY' -or $_.hamasterstate -eq 'PRIMARY' } | Select-Object -First 1)
    $local = @($nodes | Where-Object { $_.id -eq 0 -or $_.nodeid -eq 0 } | Select-Object -First 1)
    $selected = if ($local.Count -gt 0) { $local[0] } elseif ($primary.Count -gt 0) { $primary[0] } elseif ($nodes.Count -gt 0) { $nodes[0] } else { $null }
    $state = 'UNKNOWN'
    if ($null -ne $selected) {
        if ($selected.PSObject.Properties.Name -contains 'hacurmasterstate') { $state = [string]$selected.hacurmasterstate }
        elseif ($selected.PSObject.Properties.Name -contains 'hamasterstate') { $state = [string]$selected.hamasterstate }
    }

    [pscustomobject]@{
        HAConfigured  = ($nodes.Count -gt 1 -or ($state -and $state -ne 'UNKNOWN'))
        HAMasterState = $state
        Raw           = $nodes
    }
}

function Assert-NetscalerPrimary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HAState,

        [bool]$RequirePrimary = $true
    )

    if ($RequirePrimary -and $HAState.HAConfigured -and $HAState.HAMasterState -ne 'PRIMARY') {
        throw "NetScaler HA node is '$($HAState.HAMasterState)', not PRIMARY. Re-run against the PRIMARY node or disable RequirePrimary explicitly."
    }
}

function Send-NetscalerSslFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FileName
    )

    if ($PSCmdlet.ShouldProcess('/nsconfig/ssl/', "Upload $FileName")) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $body = @{ systemfile = @{ filename = $FileName; filelocation = '/nsconfig/ssl/'; filecontent = [Convert]::ToBase64String($bytes) } }
        $null = Invoke-NetscalerNitroRequest -Method POST -Path '/config/systemfile' -Body $body
        return $true
    }
    $false
}

function Get-NetscalerSslCertKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CertKeyName
    )

    try {
        $response = Invoke-NetscalerNitroRequest -Method GET -Path ("/config/sslcertkey/{0}" -f [uri]::EscapeDataString($CertKeyName))
        return @($response.sslcertkey | Select-Object -First 1)[0]
    } catch {
        if ($_.Exception.Message -match 'No such resource|not found|404') { return $null }
        throw
    }
}

function Set-NetscalerSslCertKey {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CertKeyName,

        [Parameter(Mandatory = $true)]
        [string]$CertFileName,

        [Parameter(Mandatory = $true)]
        [string]$KeyFileName,

        [string]$ChainFileName
    )

    $existing = Get-NetscalerSslCertKey -CertKeyName $CertKeyName
    $payload = @{ certkey = $CertKeyName; cert = $CertFileName; key = $KeyFileName; inform = 'PEM' }
    if (-not [string]::IsNullOrWhiteSpace($ChainFileName)) { $payload['cacert'] = $ChainFileName }

    if ($null -eq $existing) {
        if ($PSCmdlet.ShouldProcess($CertKeyName, 'Create sslcertkey')) {
            $null = Invoke-NetscalerNitroRequest -Method POST -Path '/config/sslcertkey' -Body @{ sslcertkey = $payload }
            return $true
        }
        return $false
    }

    if ($PSCmdlet.ShouldProcess($CertKeyName, 'Update sslcertkey')) {
        $null = Invoke-NetscalerNitroRequest -Method POST -Path '/config/sslcertkey?action=update' -Body @{ sslcertkey = $payload }
        return $true
    }
    $false
}

function Get-NetscalerSslVServerCertBindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VServerName
    )

    try {
        $response = Invoke-NetscalerNitroRequest -Method GET -Path ("/config/sslvserver_sslcertkey_binding/{0}" -f [uri]::EscapeDataString($VServerName))
        return @($response.sslvserver_sslcertkey_binding)
    } catch {
        if ($_.Exception.Message -match 'No such resource|not found|404') { return @() }
        throw
    }
}

function Set-NetscalerSslVServerCertBinding {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VServerName,

        [Parameter(Mandatory = $true)]
        [string]$CertKeyName,

        [switch]$ReplaceServerCertificate
    )

    $bindings = @(Get-NetscalerSslVServerCertBindings -VServerName $VServerName)
    $alreadyBound = @($bindings | Where-Object { $_.certkeyname -eq $CertKeyName })
    $changed = $false

    if ($alreadyBound.Count -eq 0) {
        if ($ReplaceServerCertificate) {
            $serverBindings = @($bindings | Where-Object {
                $isCa = ($_.PSObject.Properties.Name -contains 'ca') -and ([string]$_.ca -eq 'true' -or [string]$_.ca -eq 'YES')
                $isSni = ($_.PSObject.Properties.Name -contains 'snicert') -and ([string]$_.snicert -eq 'true' -or [string]$_.snicert -eq 'YES')
                -not $isCa -and -not $isSni
            })
            foreach ($binding in $serverBindings) {
                if ($PSCmdlet.ShouldProcess($VServerName, "Unbind server certificate $($binding.certkeyname)")) {
                    $path = "/config/sslvserver_sslcertkey_binding/{0}?args=certkeyname:{1}" -f [uri]::EscapeDataString($VServerName), [uri]::EscapeDataString($binding.certkeyname)
                    $null = Invoke-NetscalerNitroRequest -Method DELETE -Path $path
                    $changed = $true
                }
            }
        }

        if ($PSCmdlet.ShouldProcess($VServerName, "Bind certificate $CertKeyName")) {
            $body = @{ sslvserver_sslcertkey_binding = @{ vservername = $VServerName; certkeyname = $CertKeyName } }
            $null = Invoke-NetscalerNitroRequest -Method PUT -Path ("/config/sslvserver_sslcertkey_binding/{0}" -f [uri]::EscapeDataString($VServerName)) -Body $body
            $changed = $true
        }
    }

    $changed
}

function Save-NetscalerConfig {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    if ($PSCmdlet.ShouldProcess('NetScaler running configuration', 'Save')) {
        $null = Invoke-NetscalerNitroRequest -Method POST -Path '/config/nsconfig?action=save'
        return $true
    }
    $false
}

function Sync-NetscalerHA {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$Force)

    $forceValue = if ($Force) { 'YES' } else { 'NO' }
    if ($PSCmdlet.ShouldProcess('NetScaler HA pair', "Synchronize save=YES force=$forceValue")) {
        $null = Invoke-NetscalerNitroRequest -Method POST -Path '/config/hasync' -Body @{ hasync = @{ save = 'YES'; force = $forceValue } }
        return $true
    }
    $false
}

function Test-NetscalerDeploymentVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CertKeyName,

        [Parameter(Mandatory = $true)]
        [string]$VServerName
    )

    $certKey = Get-NetscalerSslCertKey -CertKeyName $CertKeyName
    $bindings = @(Get-NetscalerSslVServerCertBindings -VServerName $VServerName)
    $binding = @($bindings | Where-Object { $_.certkeyname -eq $CertKeyName })
    if ($null -ne $certKey -and $binding.Count -gt 0) { return 'Verified' }
    if ($null -eq $certKey) { return 'CertKeyMissing' }
    'BindingMissing'
}

Export-ModuleMember -Function ConvertFrom-NetscalerSecureString,Resolve-NetscalerPassword,Connect-NetscalerNitroSession,Disconnect-NetscalerNitroSession,Invoke-NetscalerNitroRequest,Test-NetscalerLocalCertificateFiles,Get-NetscalerHAState,Assert-NetscalerPrimary,Send-NetscalerSslFile,Get-NetscalerSslCertKey,Set-NetscalerSslCertKey,Get-NetscalerSslVServerCertBindings,Set-NetscalerSslVServerCertBinding,Save-NetscalerConfig,Sync-NetscalerHA,Test-NetscalerDeploymentVerification
