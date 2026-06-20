#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:OPNsenseCertificatePolicyTypeLoaded = $false

function New-OPNsenseApiBaseUri {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [switch]$UseHttp
    )

    $scheme = if ($UseHttp) { 'http' } else { 'https' }
    if (($scheme -eq 'https' -and $Port -eq 443) -or ($scheme -eq 'http' -and $Port -eq 80)) {
        return "$scheme`://$HostName"
    }
    return "$scheme`://$HostName`:$Port"
}

function Invoke-OPNsenseWithCertificatePolicy {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [switch]$SkipCertificateCheck
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $previous = [Net.ServicePointManager]::ServerCertificateValidationCallback
    if ($SkipCertificateCheck) {
        if (-not $script:OPNsenseCertificatePolicyTypeLoaded -and $null -eq ('SimpleAcmeOPNsenseApiCertificatePolicy' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class SimpleAcmeOPNsenseApiCertificatePolicy
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
        $script:OPNsenseCertificatePolicyTypeLoaded = $true
        $policyType = 'SimpleAcmeOPNsenseApiCertificatePolicy' -as [type]
        if ($null -eq $policyType) { throw 'Unable to load SimpleAcmeOPNsenseApiCertificatePolicy for TLS certificate bypass.' }
        $callbackMethod = $policyType.GetMethod('TrustAnyCertificate')
        [Net.ServicePointManager]::ServerCertificateValidationCallback =
            [System.Delegate]::CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback], $callbackMethod)
    }
    try {
        & $ScriptBlock
    } finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $previous
    }
}

function New-OPNsenseAuthHeader {
    param(
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$ApiSecret
    )

    if ([string]::IsNullOrWhiteSpace($ApiKey) -or [string]::IsNullOrWhiteSpace($ApiSecret)) {
        throw 'OPNsense API key and API secret are required.'
    }
    $pair = '{0}:{1}' -f $ApiKey, $ApiSecret
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    return @{ Authorization = "Basic $basic" }
}

function Invoke-OPNsenseApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$ApiSecret,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET','POST')][string]$Method = 'GET',
        [object]$Body = $null,
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $base = New-OPNsenseApiBaseUri -HostName $HostName -Port $Port -UseHttp:$UseHttp
    $normalizedPath = if ($Path.StartsWith('/')) { $Path } else { '/' + $Path }
    $uri = $base + $normalizedPath
    $headers = New-OPNsenseAuthHeader -ApiKey $ApiKey -ApiSecret $ApiSecret
    $invoke = {
        $parameters = @{
            Uri = $uri
            Method = $Method
            Headers = $headers
            TimeoutSec = $TimeoutSeconds
        }
        if ($null -ne $Body) {
            $parameters['Body'] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 }
            $parameters['ContentType'] = 'application/json'
        }
        Invoke-RestMethod @parameters
    }
    Invoke-OPNsenseWithCertificatePolicy -SkipCertificateCheck:$SkipCertificateCheck -ScriptBlock $invoke
}

function Test-OPNsenseApiConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$ApiSecret,
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $started = Get-Date
    $response = Invoke-OPNsenseApi -HostName $HostName -Port $Port -ApiKey $ApiKey -ApiSecret $ApiSecret -Path '/api/core/firmware/status' -Method GET -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
    $product = if ($response.PSObject.Properties.Name -contains 'product') { $response.product } else { $null }
    [pscustomobject]@{
        Status = 'Succeeded'
        Message = 'OPNsense API connected.'
        Endpoint = (New-OPNsenseApiBaseUri -HostName $HostName -Port $Port -UseHttp:$UseHttp) + '/api/core/firmware/status'
        Product = if ($null -ne $product -and $product.PSObject.Properties.Name -contains 'product_name') { [string]$product.product_name } else { 'OPNsense' }
        Version = if ($null -ne $product -and $product.PSObject.Properties.Name -contains 'product_version') { [string]$product.product_version } else { '' }
        ElapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
        Raw = $response
    }
}

function Search-OPNsenseCertificates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$ApiSecret,
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $body = @{ current = 1; rowCount = 100; sort = @{}; searchPhrase = '' }
    Invoke-OPNsenseApi -HostName $HostName -Port $Port -ApiKey $ApiKey -ApiSecret $ApiSecret -Path '/api/trust/cert/search' -Method POST -Body $body -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
}

function Get-OPNsenseCertificateServiceInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [ValidateRange(1, 65535)][int]$Port = 443,
        [Parameter(Mandatory)][string]$ApiKey,
        [Parameter(Mandatory)][string]$ApiSecret,
        [switch]$UseHttp,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $base = New-OPNsenseApiBaseUri -HostName $HostName -Port $Port -UseHttp:$UseHttp
    $items = @(
        [pscustomobject]@{
            Id = 'webgui'
            Kind = 'core'
            Name = 'OPNsense Web GUI'
            Description = 'System > Settings > Administration SSL certificate. Binding API differs by release; inspect WebGUI API call before enabling automatic writes.'
            Endpoint = "$base/system_advanced_admin.php"
            BindingStatus = 'manual-api-discovery-required'
        }
    )

    foreach ($candidate in @(
        @{ Id='haproxy'; Kind='plugin'; Name='HAProxy frontends'; Probe='/api/haproxy/settings/get'; Service='/api/haproxy/service/reconfigure' },
        @{ Id='nginx'; Kind='plugin'; Name='Nginx locations/upstreams'; Probe='/api/nginx/settings/get'; Service='/api/nginx/service/reconfigure' },
        @{ Id='openvpn'; Kind='core'; Name='OpenVPN servers'; Probe='/api/openvpn/service/search'; Service='/api/openvpn/service/reconfigure' },
        @{ Id='ipsec'; Kind='core'; Name='IPsec certificate services'; Probe='/api/ipsec/service/status'; Service='/api/ipsec/service/reconfigure' }
    )) {
        try {
            $null = Invoke-OPNsenseApi -HostName $HostName -Port $Port -ApiKey $ApiKey -ApiSecret $ApiSecret -Path $candidate.Probe -Method GET -UseHttp:$UseHttp -SkipCertificateCheck:$SkipCertificateCheck -TimeoutSeconds $TimeoutSeconds
            $items += [pscustomobject]@{
                Id = [string]$candidate.Id
                Kind = [string]$candidate.Kind
                Name = [string]$candidate.Name
                Description = "Detected API surface $($candidate.Probe). Certificate field mapping must be selected from inventory before write support is enabled."
                Endpoint = $base + [string]$candidate.Probe
                BindingStatus = 'detected-read-only'
            }
        } catch {
            $items += [pscustomobject]@{
                Id = [string]$candidate.Id
                Kind = [string]$candidate.Kind
                Name = [string]$candidate.Name
                Description = "Not detected or not authorized: $($_.Exception.Message)"
                Endpoint = $base + [string]$candidate.Probe
                BindingStatus = 'not-detected'
            }
        }
    }

    return @($items)
}

function New-OPNsenseCertificateImportPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CertificatePem,
        [Parameter(Mandatory)][string]$PrivateKeyPem,
        [string]$ChainPem = ''
    )

    $payload = if ([string]::IsNullOrWhiteSpace($ChainPem)) { $CertificatePem } else { ($CertificatePem.TrimEnd() + "`n" + $ChainPem.Trim()) }
    return @{
        cert = @{
            descr = $Name
            crt_payload = $payload
            prv_payload = $PrivateKeyPem
        }
    }
}

Export-ModuleMember -Function New-OPNsenseApiBaseUri,Invoke-OPNsenseApi,Test-OPNsenseApiConnection,Search-OPNsenseCertificates,Get-OPNsenseCertificateServiceInventory,New-OPNsenseCertificateImportPayload
