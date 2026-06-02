#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$HostName = '192.168.45.150',
    [int]$Port = 443,
    [Parameter(Mandatory)][string]$Username,
    [Parameter(Mandatory)][string]$Password,
    [Parameter(Mandatory)][string]$ApiKey,
    [switch]$SkipCertificateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:KempProbeCertificatePolicyTypeLoaded = $false

function Invoke-KempProbeWithCertificatePolicy {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [switch]$SkipCertificateCheck
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $previous = [Net.ServicePointManager]::ServerCertificateValidationCallback
    if ($SkipCertificateCheck) {
        if (-not $script:KempProbeCertificatePolicyTypeLoaded -and $null -eq ('SimpleAcmeKempProbeCertificatePolicy' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class SimpleAcmeKempProbeCertificatePolicy
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
        $script:KempProbeCertificatePolicyTypeLoaded = $true
        $policyType = 'SimpleAcmeKempProbeCertificatePolicy' -as [type]
        if ($null -eq $policyType) { throw 'Unable to load SimpleAcmeKempProbeCertificatePolicy for TLS certificate bypass.' }
        $certificatePolicyMethod = $policyType.GetMethod('TrustAnyCertificate')
        [Net.ServicePointManager]::ServerCertificateValidationCallback =
            [System.Delegate]::CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback], $certificatePolicyMethod)
    }
    try {
        & $ScriptBlock
    } finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $previous
    }
}

function Hide-ProbeSecret {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    $safe = [string]$Text
    foreach ($secret in @($Password, $ApiKey)) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $safe = $safe.Replace($secret, '<hidden>')
        }
    }
    return $safe
}

function Invoke-NativeWebProbe {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('Get','Post')][string]$Method = 'Get',
        [string]$Body = '',
        [string]$ContentType = '',
        [Management.Automation.PSCredential]$Credential = $null
    )

    try {
        $scriptBlock = {
            $parameters = @{
                Uri = $Uri
                Method = $Method
                TimeoutSec = 20
                UseBasicParsing = $true
            }
            if ($null -ne $Credential) { $parameters['Credential'] = $Credential }
            if (-not [string]::IsNullOrEmpty($Body)) { $parameters['Body'] = $Body }
            if (-not [string]::IsNullOrEmpty($ContentType)) { $parameters['ContentType'] = $ContentType }
            Invoke-WebRequest @parameters
        }

        $response = Invoke-KempProbeWithCertificatePolicy -SkipCertificateCheck:$SkipCertificateCheck -ScriptBlock $scriptBlock
        $snippet = Hide-ProbeSecret -Text (($response.Content -replace '\s+', ' ').Trim())
        if ($snippet.Length -gt 220) { $snippet = $snippet.Substring(0, 220) }
        return [pscustomobject]@{
            Name = $Name
            StatusLine = 'HTTP {0}' -f ([int]$response.StatusCode)
            Body = $snippet
        }
    } catch [Net.WebException] {
        $response = $_.Exception.Response
        $body = ''
        $code = '<no http status>'
        if ($null -ne $response) {
            $code = 'HTTP {0}' -f ([int]$response.StatusCode)
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            try { $body = $reader.ReadToEnd() } finally { $reader.Close() }
        }
        $snippet = Hide-ProbeSecret -Text (($body -replace '\s+', ' ').Trim())
        if ($snippet.Length -gt 220) { $snippet = $snippet.Substring(0, 220) }
        return [pscustomobject]@{
            Name = $Name
            StatusLine = $code
            Body = $snippet
        }
    } catch {
        return [pscustomobject]@{
            Name = $Name
            StatusLine = '<error>'
            Body = Hide-ProbeSecret -Text $_.Exception.Message
        }
    }
}

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts\Modules\SimpleAcme.Kemp\SimpleAcme.Kemp.psd1'
Import-Module $modulePath -Force

$base = 'https://{0}' -f $HostName
if ($Port -ne 443) { $base = 'https://{0}:{1}' -f $HostName, $Port }

$secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
$credential = New-Object Management.Automation.PSCredential($Username, $secure)
$jsonApiKey = '{"cmd":"listvs","apikey":"' + $ApiKey.Replace('\', '\\').Replace('"', '\"') + '"}'
$jsonBasic = '{"cmd":"listvs","apiuser":"' + $Username.Replace('\', '\\').Replace('"', '\"') + '","apipass":"' + $Password.Replace('\', '\\').Replace('"', '\"') + '"}'
$encodedApiKey = [Uri]::EscapeDataString($ApiKey)

$results = @()
$results += Invoke-NativeWebProbe -Name 'Management UI root' -Uri "$base/"
$results += Invoke-NativeWebProbe -Name 'Classic REST listvs with Basic auth' -Uri "$base/access/listvs" -Credential $credential
$results += Invoke-NativeWebProbe -Name 'Classic REST listvs with API key query' -Uri "$base/access/listvs?apikey=$encodedApiKey"
$results += Invoke-NativeWebProbe -Name 'APIv2 listvs JSON API key' -Uri "$base/accessv2" -Method Post -Body $jsonApiKey -ContentType 'application/json'
$results += Invoke-NativeWebProbe -Name 'APIv2 listvs JSON user/pass' -Uri "$base/accessv2" -Method Post -Body $jsonBasic -ContentType 'application/json'
$results += Invoke-NativeWebProbe -Name 'APIv2 listvs query API key' -Uri "$base/accessv2?cmd=listvs&apikey=$encodedApiKey"

$ui = Test-KempManagementUi -HostName $HostName -Port $Port -SkipCertificateCheck:$SkipCertificateCheck
try {
    $services = @(Get-KempVirtualServices -HostName $HostName -Port $Port -Username $Username -Password $Password -ApiKey $ApiKey -SkipCertificateCheck:$SkipCertificateCheck)
    $moduleResult = [pscustomobject]@{
        Status = 'Succeeded'
        Message = 'Kemp module returned virtual services.'
        VirtualServiceCount = $services.Count
        VirtualServices = $services
    }
} catch {
    $moduleResult = [pscustomobject]@{
        Status = 'Failed'
        Message = Hide-ProbeSecret -Text $_.Exception.Message
    }
}

[pscustomobject]@{
    Target = $base
    NativeWebResults = $results
    ManagementUiProbe = $ui
    ModuleCommunicationProbe = $moduleResult
} | ConvertTo-Json -Depth 12
