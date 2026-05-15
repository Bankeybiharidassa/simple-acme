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

function New-NetscalerNitroBaseUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [string]$NitroBaseUrl,

        [switch]$UseHttp
    )

    if (-not [string]::IsNullOrWhiteSpace($NitroBaseUrl)) {
        $trimmedBase = $NitroBaseUrl.TrimEnd('/')
        if ($trimmedBase -notmatch '^https?://') { throw 'NitroBaseUrl must start with http:// or https://.' }
        if ($trimmedBase -notmatch '/nitro/v1$') { throw 'NitroBaseUrl must point to the /nitro/v1 API root.' }
        return $trimmedBase
    }

    if ([string]::IsNullOrWhiteSpace($HostName)) { throw 'NetScalerHost cannot be empty.' }
    if ($HostName -match '^https?://') { throw 'NetScalerHost must be a host name or IP address only. Use NitroBaseUrl for a full URL.' }
    if ($HostName -match '[/?#]') { throw 'NetScalerHost must not include a path or query string.' }

    $scheme = if ($UseHttp) { 'http' } else { 'https' }
    '{0}://{1}/nitro/v1' -f $scheme, $HostName.Trim('/')
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

        [string]$NitroBaseUrl,

        [switch]$UseHttp,

        [switch]$SkipCertificateCheck,

        [ValidateRange(0, 10)]
        [int]$RetryCount = 2,

        [ValidateRange(0, 60)]
        [int]$RetryDelaySeconds = 1
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $script:NetscalerNitroSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $script:NetscalerNitroBaseUri = New-NetscalerNitroBaseUri -HostName $HostName -NitroBaseUrl $NitroBaseUrl -UseHttp:$UseHttp
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

function Get-NetscalerWebExceptionBody {
    [CmdletBinding()]
    param([object]$Exception)

    try {
        if ($Exception.Response -and $Exception.Response.GetResponseStream()) {
            $reader = New-Object IO.StreamReader($Exception.Response.GetResponseStream())
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
    } catch {
        return $null
    }
    $null
}

function Assert-NetscalerNitroResponse {
    [CmdletBinding()]
    param(
        [object]$Response,
        [string]$Method,
        [string]$Path
    )

    if ($null -eq $Response) { return }
    $names = @($Response.PSObject.Properties.Name)
    if ($names -contains 'errorcode') {
        $errorCode = [int]$Response.errorcode
        $message = if ($names -contains 'message') { [string]$Response.message } else { 'NITRO returned an error.' }
        $severity = if ($names -contains 'severity') { [string]$Response.severity } else { '' }
        if ($errorCode -ne 0) {
            throw "NetScaler NITRO $Method $Path returned errorcode ${errorCode}: $message"
        }
        if ($severity -match 'WARNING' -or $message -match 'warning') {
            Write-Warning ("NetScaler NITRO $Method $Path warning: $message")
        }
    }
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
    }

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
                Assert-NetscalerNitroResponse -Response $response -Method $Method -Path $Path
                return $response
            } catch {
                $attempt++
                $statusCode = 0
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
                if ($_.Exception.Message -match '^NetScaler NITRO .* returned errorcode') { throw }
                $retryable = ($statusCode -eq 0 -or $statusCode -eq 408 -or $statusCode -eq 429 -or $statusCode -ge 500)
                if ($attempt -gt $RetryCount -or -not $retryable) {
                    $message = $_.Exception.Message
                    $bodyText = Get-NetscalerWebExceptionBody -Exception $_.Exception
                    if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
                        try {
                            $errorPayload = $bodyText | ConvertFrom-Json -ErrorAction Stop
                            Assert-NetscalerNitroResponse -Response $errorPayload -Method $Method -Path $Path
                            if ($errorPayload.PSObject.Properties.Name -contains 'message') { $message = [string]$errorPayload.message }
                        } catch {
                            $message = '{0} Response body: {1}' -f $message, $bodyText
                        }
                    }
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
    $selected = @($nodes | Select-Object -First 1)
    $state = 'UNKNOWN'
    $status = 'NO'
    if ($selected.Count -gt 0) {
        $node = $selected[0]
        if ($node.PSObject.Properties.Name -contains 'hacurmasterstate') { $state = [string]$node.hacurmasterstate }
        elseif ($node.PSObject.Properties.Name -contains 'hamasterstate') { $state = [string]$node.hamasterstate }
        if ($node.PSObject.Properties.Name -contains 'hacurstatus') { $status = [string]$node.hacurstatus }
    }

    [pscustomobject]@{
        HAConfigured  = ($status -eq 'YES' -or $nodes.Count -gt 1)
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

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Path '$Path' was not found." }
    if ($FileName -match '[\\/]') { throw 'FileName must not contain a path separator.' }

    if ($PSCmdlet.ShouldProcess('/nsconfig/ssl/', "Upload $FileName")) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $body = @{ systemfile = @{ filename = $FileName; filelocation = '/nsconfig/ssl/'; filecontent = [Convert]::ToBase64String($bytes); fileencoding = 'BASE64' } }
        $null = Invoke-NetscalerNitroRequest -Method POST -Path '/config/systemfile?override=yes' -Body $body
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

    if ([string]::IsNullOrWhiteSpace($CertKeyName)) { throw 'CertKeyName cannot be empty.' }
    try {
        $response = Invoke-NetscalerNitroRequest -Method GET -Path ("/config/sslcertkey/{0}" -f [uri]::EscapeDataString($CertKeyName))
        $items = @($response.sslcertkey)
        if ($items.Count -gt 0) { return $items[0] }
        return $null
    } catch {
        if ($_.Exception.Message -match 'No such resource|not found|404') { return $null }
        throw
    }
}

function Set-NetscalerSslCertKey {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CertKeyName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CertFileName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$KeyFileName,

        [string]$ChainFileName,

        [SecureString]$KeyPassword
    )

    $existing = Get-NetscalerSslCertKey -CertKeyName $CertKeyName
    $payload = @{ certkey = $CertKeyName; cert = $CertFileName; key = $KeyFileName; inform = 'PEM' }
    if (-not [string]::IsNullOrWhiteSpace($ChainFileName)) { $payload['cacert'] = $ChainFileName }
    if ($null -ne $KeyPassword) {
        $payload['password'] = $true
        $payload['passplain'] = ConvertFrom-NetscalerSecureString -SecureString $KeyPassword
    }

    try {
        if ($null -eq $existing) {
            if ($PSCmdlet.ShouldProcess($CertKeyName, 'Create sslcertkey')) {
                $null = Invoke-NetscalerNitroRequest -Method POST -Path '/config/sslcertkey' -Body @{ sslcertkey = $payload }
                return $true
            }
            return $false
        }

        if ($PSCmdlet.ShouldProcess($CertKeyName, 'Change sslcertkey certificate and key')) {
            $null = Invoke-NetscalerNitroRequest -Method POST -Path '/config/sslcertkey?action=update' -Body @{ sslcertkey = $payload }
            return $true
        }
        $false
    } finally {
        if ($payload.ContainsKey('passplain')) { $payload['passplain'] = $null }
    }
}

function Get-NetscalerSslVServerCertBindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
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

function Test-NetscalerServerCertificateBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Binding)

    $isCa = ($Binding.PSObject.Properties.Name -contains 'ca') -and ([string]$Binding.ca -match '^(true|YES)$')
    $isSni = ($Binding.PSObject.Properties.Name -contains 'snicert') -and ([string]$Binding.snicert -match '^(true|YES)$')
    (-not $isCa -and -not $isSni)
}

function Set-NetscalerSslVServerCertBinding {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$VServerName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CertKeyName,

        [Alias('ReplaceServerCertificate')]
        [switch]$ReplaceExistingServerCertificate
    )

    $bindings = @(Get-NetscalerSslVServerCertBindings -VServerName $VServerName)
    $alreadyBound = @($bindings | Where-Object { $_.certkeyname -eq $CertKeyName })
    $changed = $false

    if ($alreadyBound.Count -eq 0) {
        if ($ReplaceExistingServerCertificate) {
            $serverBindings = @($bindings | Where-Object { Test-NetscalerServerCertificateBinding -Binding $_ })
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
        $null = Invoke-NetscalerNitroRequest -Method POST -Path '/config/hasync?action=Force' -Body @{ hasync = @{ save = 'YES'; force = $forceValue } }
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
    if ($null -ne $certKey -and $binding.Count -gt 0) { return 'Passed' }
    if ($null -eq $certKey -and $binding.Count -eq 0) { return 'Failed' }
    'Partial'
}

Export-ModuleMember -Function ConvertFrom-NetscalerSecureString,Resolve-NetscalerPassword,New-NetscalerNitroBaseUri,Connect-NetscalerNitroSession,Disconnect-NetscalerNitroSession,Invoke-NetscalerNitroRequest,Test-NetscalerLocalCertificateFiles,Get-NetscalerHAState,Assert-NetscalerPrimary,Send-NetscalerSslFile,Get-NetscalerSslCertKey,Set-NetscalerSslCertKey,Get-NetscalerSslVServerCertBindings,Test-NetscalerServerCertificateBinding,Set-NetscalerSslVServerCertBinding,Save-NetscalerConfig,Sync-NetscalerHA,Test-NetscalerDeploymentVerification
