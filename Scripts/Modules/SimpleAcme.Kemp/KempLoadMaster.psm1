#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:KempCertificatePolicyTypeLoaded = $false

function New-KempApiEndpoint {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [switch]$UseHttp,
        [ValidateSet('v2','classic')][string]$ApiVersion = 'v2',
        [string]$Command = ''
    )

    $scheme = if ($UseHttp) { 'http' } else { 'https' }
    $path = if ($ApiVersion -eq 'classic') {
        if ([string]::IsNullOrWhiteSpace($Command)) { 'access' } else { 'access/' + [Uri]::EscapeDataString($Command) }
    } else {
        'accessv2'
    }
    if (($scheme -eq 'https' -and $Port -eq 443) -or ($scheme -eq 'http' -and $Port -eq 80)) {
        return "$scheme`://$HostName/$path"
    }
    return "$scheme`://$HostName`:$Port/$path"
}

function Invoke-KempWithCertificatePolicy {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [switch]$SkipCertificateCheck
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $previous = [Net.ServicePointManager]::ServerCertificateValidationCallback
    if ($SkipCertificateCheck) {
        if (-not $script:KempCertificatePolicyTypeLoaded -and $null -eq ('SimpleAcmeKempCertificatePolicy' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class SimpleAcmeKempCertificatePolicy
{
    public static bool TrustAnyCertificate(
        object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors)
    {
        return true;
    }
}
'@ -ErrorAction SilentlyContinue
        }
        $script:KempCertificatePolicyTypeLoaded = $true
        $policyType = 'SimpleAcmeKempCertificatePolicy' -as [type]
        if ($null -eq $policyType) { throw 'Unable to load SimpleAcmeKempCertificatePolicy for TLS certificate bypass.' }
        $method = $policyType.GetMethod('TrustAnyCertificate')
        [Net.ServicePointManager]::ServerCertificateValidationCallback =
            [System.Delegate]::CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback], $method)
    }
    try {
        & $ScriptBlock
    } finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $previous
    }
}

function ConvertFrom-KempSecureString {
    param([Parameter(Mandatory)][SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}

function Resolve-KempPassword {
    [CmdletBinding(DefaultParameterSetName = 'None')]
    param(
        [Parameter(ParameterSetName = 'SecureString')][SecureString]$Password,
        [Parameter(ParameterSetName = 'Plaintext')][string]$Plaintext,
        [Parameter(ParameterSetName = 'SecretName')][string]$PasswordSecretName
    )

    if ($PSCmdlet.ParameterSetName -eq 'SecureString' -and $null -ne $Password) {
        return ConvertFrom-KempSecureString -SecureString $Password
    }
    if ($PSCmdlet.ParameterSetName -eq 'Plaintext' -and -not [string]::IsNullOrWhiteSpace($Plaintext)) {
        return [string]$Plaintext
    }
    if ($PSCmdlet.ParameterSetName -eq 'SecretName' -and -not [string]::IsNullOrWhiteSpace($PasswordSecretName)) {
        $value = [Environment]::GetEnvironmentVariable($PasswordSecretName, 'Process')
        if ([string]::IsNullOrWhiteSpace($value)) { $value = [Environment]::GetEnvironmentVariable($PasswordSecretName, 'Machine') }
        if ([string]::IsNullOrWhiteSpace($value)) { throw "Kemp password secret '$PasswordSecretName' was not found in process or machine environment." }
        return [string]$value
    }
    return ''
}

function Invoke-KempApiV2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Parameters = @{},
        [string]$ApiKey = '',
        [string]$Username = '',
        [string]$Password = '',
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    $endpoint = New-KempApiEndpoint -HostName $HostName -Port $Port -UseHttp:$UseHttp
    $payload = [ordered]@{ cmd = $Command }
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $payload['apikey'] = $ApiKey
    } elseif (-not [string]::IsNullOrWhiteSpace($Username) -and -not [string]::IsNullOrWhiteSpace($Password)) {
        $payload['apiuser'] = $Username
        $payload['apipass'] = $Password
    }
    foreach ($key in $Parameters.Keys) { $payload[[string]$key] = $Parameters[$key] }
    $body = $payload | ConvertTo-Json -Depth 20 -Compress

    try {
        Invoke-KempWithCertificatePolicy -SkipCertificateCheck:$SkipCertificateCheck -ScriptBlock {
            Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType 'application/json' -TimeoutSec $TimeoutSeconds
        }
    } catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($null -ne $response -and [int]$response.StatusCode -eq 404) {
            throw "Kemp APIv2 endpoint returned 404 at $endpoint. Enable RESTful API/APIv2 access on the LoadMaster and confirm the management port."
        }
        throw
    } catch {
        throw
    }
}

function Invoke-KempClassicApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Parameters = @{},
        [string]$Username = '',
        [string]$Password = '',
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) {
        throw 'Kemp classic /access API requires LoadMaster username and password.'
    }

    $endpoint = New-KempApiEndpoint -HostName $HostName -Port $Port -UseHttp:$UseHttp -ApiVersion classic -Command $Command
    if ($Parameters.Count -gt 0) {
        $pairs = @()
        foreach ($key in $Parameters.Keys) {
            $pairs += ('{0}={1}' -f [Uri]::EscapeDataString([string]$key), [Uri]::EscapeDataString([string]$Parameters[$key]))
        }
        $endpoint = $endpoint + '?' + ($pairs -join '&')
    }

    $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
    $credential = New-Object Management.Automation.PSCredential($Username, $secure)

    try {
        Invoke-KempWithCertificatePolicy -SkipCertificateCheck:$SkipCertificateCheck -ScriptBlock {
            Invoke-RestMethod -Uri $endpoint -Method Get -Credential $credential -TimeoutSec $TimeoutSeconds
        }
    } catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($null -ne $response -and [int]$response.StatusCode -eq 404) {
            throw "Kemp classic API endpoint returned 404 at $endpoint. Enable RESTful API access on the LoadMaster and confirm the management port."
        }
        throw
    } catch {
        throw
    }
}

function Invoke-KempApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Parameters = @{},
        [string]$ApiKey = '',
        [string]$Username = '',
        [string]$Password = '',
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    $apiV2Endpoint = New-KempApiEndpoint -HostName $HostName -Port $Port -UseHttp:$UseHttp -ApiVersion v2
    $classicEndpoint = New-KempApiEndpoint -HostName $HostName -Port $Port -UseHttp:$UseHttp -ApiVersion classic -Command $Command
    $apiV2Failure = ''

    try {
        return Invoke-KempApiV2 -HostName $HostName -Port $Port -Command $Command -Parameters $Parameters -ApiKey $ApiKey -Username $Username -Password $Password -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
    } catch [System.Net.WebException] {
        if ($_.Exception.Response -eq $null -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
        $apiV2Failure = $_.Exception.Message
    } catch {
        if ($_.Exception.Message -notmatch 'Kemp APIv2 endpoint returned 404') { throw }
        $apiV2Failure = $_.Exception.Message
    }

    try {
        return Invoke-KempClassicApi -HostName $HostName -Port $Port -Command $Command -Parameters $Parameters -Username $Username -Password $Password -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
    } catch {
        throw "Kemp API did not respond on either supported REST endpoint. Tried APIv2 $apiV2Endpoint and classic $classicEndpoint. APIv2 result: $apiV2Failure Classic result: $($_.Exception.Message)"
    }
}

function Test-KempManagementUi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 20
    )

    $scheme = if ($UseHttp) { 'http' } else { 'https' }
    $uri = if (($scheme -eq 'https' -and $Port -eq 443) -or ($scheme -eq 'http' -and $Port -eq 80)) {
        "$scheme`://$HostName/"
    } else {
        "$scheme`://$HostName`:$Port/"
    }

    try {
        $response = Invoke-KempWithCertificatePolicy -SkipCertificateCheck:$SkipCertificateCheck -ScriptBlock {
            Invoke-WebRequest -Uri $uri -Method Get -UseBasicParsing -TimeoutSec $TimeoutSeconds
        }
        return [pscustomobject]@{
            Status = 'Succeeded'
            Message = 'Kemp management UI responded.'
            Endpoint = $uri
            StatusCode = [int]$response.StatusCode
            ContentType = [string]$response.Headers['Content-Type']
        }
    } catch {
        return [pscustomobject]@{
            Status = 'Failed'
            Message = $_.Exception.Message
            Endpoint = $uri
        }
    }
}

function Connect-KempLoadMaster {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [string]$ApiKey = '',
        [string]$Username = '',
        [string]$Password = '',
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    Invoke-KempApi -HostName $HostName -Port $Port -Command 'listvs' -ApiKey $ApiKey -Username $Username -Password $Password -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
}

function Get-KempResponseData {
    param([Parameter(Mandatory)]$Response)

    if ($null -eq $Response) { return $null }
    if ($Response.PSObject.Properties.Name -contains 'data') { return $Response.data }
    return $Response
}

function Get-KempVirtualServices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [string]$ApiKey = '',
        [string]$Username = '',
        [string]$Password = '',
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    $response = Invoke-KempApi -HostName $HostName -Port $Port -Command 'listvs' -ApiKey $ApiKey -Username $Username -Password $Password -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
    $data = Get-KempResponseData -Response $response
    if ($null -eq $data) { return @() }

    $candidates = @()
    foreach ($name in @('VS','Vs','vs','VirtualService','VirtualServices','services')) {
        if ($data.PSObject.Properties.Name -contains $name) { $candidates += @($data.$name) }
    }
    if ($candidates.Count -eq 0) { $candidates = @($data) }

    foreach ($item in @($candidates)) {
        if ($null -eq $item) { continue }
        [pscustomobject]@{
            Id = if ($item.PSObject.Properties.Name -contains 'Index') { [string]$item.Index } elseif ($item.PSObject.Properties.Name -contains 'VSIndex') { [string]$item.VSIndex } elseif ($item.PSObject.Properties.Name -contains 'Id') { [string]$item.Id } else { '' }
            Address = if ($item.PSObject.Properties.Name -contains 'VSAddress') { [string]$item.VSAddress } elseif ($item.PSObject.Properties.Name -contains 'Address') { [string]$item.Address } elseif ($item.PSObject.Properties.Name -contains 'vs') { [string]$item.vs } else { '' }
            Port = if ($item.PSObject.Properties.Name -contains 'VSPort') { [string]$item.VSPort } elseif ($item.PSObject.Properties.Name -contains 'Port') { [string]$item.Port } elseif ($item.PSObject.Properties.Name -contains 'port') { [string]$item.port } else { '' }
            Protocol = if ($item.PSObject.Properties.Name -contains 'Protocol') { [string]$item.Protocol } elseif ($item.PSObject.Properties.Name -contains 'prot') { [string]$item.prot } else { 'tcp' }
            NickName = if ($item.PSObject.Properties.Name -contains 'NickName') { [string]$item.NickName } elseif ($item.PSObject.Properties.Name -contains 'Name') { [string]$item.Name } else { '' }
            CurrentCertificate = if ($item.PSObject.Properties.Name -contains 'CertFile') { [string]$item.CertFile } elseif ($item.PSObject.Properties.Name -contains 'cert') { [string]$item.cert } else { '' }
            Raw = $item
        }
    }
}

function Convert-KempPfxToPemBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PfxPath,
        [string]$Password = '',
        [string]$OpenSslPath = ''
    )

    if (-not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) { throw "PFX file was not found: $PfxPath" }
    if ([string]::IsNullOrWhiteSpace($OpenSslPath)) {
        $cmd = Get-Command openssl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $cmd) { throw 'OpenSSL was not found. Kemp PFX deployment needs openssl.exe to export the private key as PEM.' }
        $OpenSslPath = [string]$cmd.Source
    }
    $tempPath = Join-Path ([IO.Path]::GetTempPath()) ("simple-acme-kemp-{0}.pem" -f ([guid]::NewGuid().ToString('N')))
    $passIn = if ([string]::IsNullOrEmpty($Password)) { 'pass:' } else { 'pass:' + $Password }
    $args = @('pkcs12','-in',$PfxPath,'-nodes','-out',$tempPath,'-passin',$passIn)
    $process = Start-Process -FilePath $OpenSslPath -ArgumentList $args -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $tempPath -PathType Leaf)) {
        throw "OpenSSL failed to convert PFX to PEM for Kemp upload. ExitCode=$($process.ExitCode)"
    }
    return $tempPath
}

function Import-KempCertificate {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [Parameter(Mandatory)][string]$CertificateName,
        [Parameter(Mandatory)][string]$PemBundlePath,
        [string]$ApiKey = '',
        [string]$Username = '',
        [string]$Password = '',
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [switch]$Replace,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    if (-not (Test-Path -LiteralPath $PemBundlePath -PathType Leaf)) { throw "PEM bundle was not found: $PemBundlePath" }
    $data = [Convert]::ToBase64String([IO.File]::ReadAllBytes($PemBundlePath))
    $parameters = @{ cert = $CertificateName; data = $data; replace = $(if ($Replace) { '1' } else { '0' }) }
    if ($PSCmdlet.ShouldProcess($HostName, "Upload Kemp certificate '$CertificateName'")) {
        Invoke-KempApi -HostName $HostName -Port $Port -Command 'addcert' -Parameters $parameters -ApiKey $ApiKey -Username $Username -Password $Password -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
    }
}

function Set-KempVirtualServiceCertificate {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [Parameter(Mandatory)][string]$VirtualServiceId,
        [Parameter(Mandatory)][string]$CertificateName,
        [string]$ApiKey = '',
        [string]$Username = '',
        [string]$Password = '',
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    $parameters = @{ vs = $VirtualServiceId; cert = $CertificateName }
    if ($PSCmdlet.ShouldProcess($HostName, "Bind Kemp certificate '$CertificateName' to VS '$VirtualServiceId'")) {
        Invoke-KempApi -HostName $HostName -Port $Port -Command 'modvs' -Parameters $parameters -ApiKey $ApiKey -Username $Username -Password $Password -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
    }
}

function Test-KempVirtualServiceCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [Parameter(Mandatory)][string]$VirtualServiceId,
        [Parameter(Mandatory)][string]$CertificateName,
        [string]$ApiKey = '',
        [string]$Username = '',
        [string]$Password = '',
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 60
    )

    $response = Invoke-KempApi -HostName $HostName -Port $Port -Command 'showvs' -Parameters @{ vs = $VirtualServiceId } -ApiKey $ApiKey -Username $Username -Password $Password -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
    $text = $response | ConvertTo-Json -Depth 20 -Compress
    return ($text -match [regex]::Escape($CertificateName))
}

Export-ModuleMember -Function Invoke-KempApiV2,Invoke-KempClassicApi,Invoke-KempApi,Test-KempManagementUi,Connect-KempLoadMaster,Get-KempVirtualServices,Import-KempCertificate,Set-KempVirtualServiceCertificate,Test-KempVirtualServiceCertificate,Convert-KempPfxToPemBundle,Resolve-KempPassword,New-KempApiEndpoint
