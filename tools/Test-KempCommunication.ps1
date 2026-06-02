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

function Invoke-CurlProbe {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = & curl.exe @Arguments 2>&1
    $status = @($output | Select-String -Pattern '^HTTP/' | Select-Object -Last 1)
    $body = @($output | Where-Object { $_ -notmatch '^HTTP/|^[A-Za-z-]+:|^\s*$' }) -join ' '
    $body = Hide-ProbeSecret -Text ($body -replace '\s+', ' ')
    if ($body.Length -gt 220) { $body = $body.Substring(0, 220) }
    [pscustomobject]@{
        Name = $Name
        StatusLine = if ($status.Count -gt 0) { [string]$status[0].Line } else { '<no http status>' }
        Body = $body
    }
}

$base = 'https://{0}' -f $HostName
if ($Port -ne 443) { $base = 'https://{0}:{1}' -f $HostName, $Port }
$basicAuth = '{0}:{1}' -f $Username, $Password
$encodedApiKey = [Uri]::EscapeDataString($ApiKey)
$encodedUser = [Uri]::EscapeDataString($Username)
$encodedPassword = [Uri]::EscapeDataString($Password)
$common = @('-k', '-sS', '-m', '20')

$jsonApiKey = '{"cmd":"listvs","apikey":"' + $ApiKey.Replace('\', '\\').Replace('"', '\"') + '"}'
$jsonBasic = '{"cmd":"listvs","apiuser":"' + $Username.Replace('\', '\\').Replace('"', '\"') + '","apipass":"' + $Password.Replace('\', '\\').Replace('"', '\"') + '"}'

$results = @()
$results += Invoke-CurlProbe -Name 'Management UI root' -Arguments ($common + @('-D', '-', '-o', '-', "$base/"))
$results += Invoke-CurlProbe -Name 'Classic REST listvs with Basic auth' -Arguments ($common + @('-u', $basicAuth, '-D', '-', '-o', '-', "$base/access/listvs"))
$results += Invoke-CurlProbe -Name 'Classic REST listvs with API key query' -Arguments ($common + @('-D', '-', '-o', '-', "$base/access/listvs?apikey=$encodedApiKey"))
$results += Invoke-CurlProbe -Name 'Classic REST listvs with user/pass query' -Arguments ($common + @('-D', '-', '-o', '-', "$base/access/listvs?apiuser=$encodedUser&apipass=$encodedPassword"))
$results += Invoke-CurlProbe -Name 'APIv2 listvs JSON API key' -Arguments ($common + @('-H', 'Content-Type: application/json', '-d', $jsonApiKey, '-D', '-', '-o', '-', "$base/accessv2"))
$results += Invoke-CurlProbe -Name 'APIv2 listvs JSON user/pass' -Arguments ($common + @('-H', 'Content-Type: application/json', '-d', $jsonBasic, '-D', '-', '-o', '-', "$base/accessv2"))
$results += Invoke-CurlProbe -Name 'APIv2 listvs query API key' -Arguments ($common + @('-D', '-', '-o', '-', "$base/accessv2?cmd=listvs&apikey=$encodedApiKey"))

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Scripts\Modules\SimpleAcme.Kemp\SimpleAcme.Kemp.psd1'
if (Test-Path -LiteralPath $modulePath -PathType Leaf) {
    Import-Module $modulePath -Force
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
} else {
    $ui = [pscustomobject]@{ Status = 'Skipped'; Message = "Module not found: $modulePath" }
    $moduleResult = [pscustomobject]@{ Status = 'Skipped'; Message = "Module not found: $modulePath" }
}

[pscustomobject]@{
    Target = $base
    CurlResults = $results
    ManagementUiProbe = $ui
    ModuleCommunicationProbe = $moduleResult
} | ConvertTo-Json -Depth 12
