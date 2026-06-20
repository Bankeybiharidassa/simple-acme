#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:SophosSession = $null
$script:SophosCertificatePolicyTypeLoaded = $false

function ConvertFrom-SophosSecureString {
    [CmdletBinding()]
    param([Parameter(Mandatory)][SecureString]$SecureString)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Resolve-SophosPassword {
    [CmdletBinding(DefaultParameterSetName = 'SecureString')]
    param(
        [Parameter(ParameterSetName = 'SecureString')]
        [SecureString]$Password,

        [Parameter(ParameterSetName = 'SecretName')]
        [string]$PasswordSecretName,

        [Parameter(ParameterSetName = 'SecureFile')]
        [string]$PasswordSecureFile
    )

    if ($PSCmdlet.ParameterSetName -eq 'SecretName') {
        if ([string]::IsNullOrWhiteSpace($PasswordSecretName)) { throw 'PasswordSecretName cannot be empty.' }
        if (Get-Command -Name Get-Secret -ErrorAction SilentlyContinue) {
            $secret = Get-Secret -Name $PasswordSecretName -ErrorAction Stop
            if ($secret -is [SecureString]) { return ConvertFrom-SophosSecureString -SecureString $secret }
            if ($secret -is [string]) { return $secret }
            if ($secret -is [pscredential]) { return ConvertFrom-SophosSecureString -SecureString $secret.Password }
            throw "Secret '$PasswordSecretName' returned unsupported type '$($secret.GetType().FullName)'."
        }

        $envName = ('SIMPLE_ACME_SECRET_{0}' -f ($PasswordSecretName -replace '[^A-Za-z0-9]', '_')).ToUpperInvariant()
        $envValue = [Environment]::GetEnvironmentVariable($envName)
        if ([string]::IsNullOrEmpty($envValue)) {
            throw "Secret '$PasswordSecretName' was not found. Install SecretManagement or set $envName."
        }
        return $envValue
    }

    if ($PSCmdlet.ParameterSetName -eq 'SecureFile') {
        if ([string]::IsNullOrWhiteSpace($PasswordSecureFile)) { throw 'PasswordSecureFile cannot be empty.' }
        if (-not (Test-Path -LiteralPath $PasswordSecureFile -PathType Leaf)) { throw "PasswordSecureFile not found: $PasswordSecureFile" }
        $secure = Get-Content -LiteralPath $PasswordSecureFile -Raw | ConvertTo-SecureString
        return ConvertFrom-SophosSecureString -SecureString $secure
    }

    if ($null -eq $Password) { throw 'Password is required when no password secret source is supplied.' }
    ConvertFrom-SophosSecureString -SecureString $Password
}

function New-SophosApiEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Firewall,
        [ValidateRange(1, 65535)][int]$Port = 4444
    )

    if ([string]::IsNullOrWhiteSpace($Firewall)) { throw 'Firewall cannot be empty.' }
    if ($Firewall -match '^https?://') { throw 'Firewall must be a host name or IP address only.' }
    if ($Firewall -match '[/?#]') { throw 'Firewall must not include a path or query string.' }
    'https://{0}:{1}/webconsole/APIController' -f $Firewall.Trim('/'), $Port
}

function Protect-SophosLogText {
    [CmdletBinding()]
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $safe = $Text -replace '(?is)<Password[^>]*>.*?</Password>', '<Password>***</Password>'
    $safe = $safe -replace '(?is)<PrivateKeyFile[^>]*>.*?</PrivateKeyFile>', '<PrivateKeyFile>***</PrivateKeyFile>'
    $safe = $safe -replace '(?is)<CertificateFile[^>]*>.*?</CertificateFile>', '<CertificateFile>***</CertificateFile>'
    $safe = $safe -replace '(?i)((?:password|passphrase|secret)\s*[:=]\s*)\S+', '$1***'
    $safe
}

function ConvertTo-SophosXmlText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    [System.Security.SecurityElement]::Escape($Text)
}

function New-SophosRequestXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$InnerXml
    )

@"
<Request>
  <Login>
    <Username>$(ConvertTo-SophosXmlText $Username)</Username>
    <Password>$(ConvertTo-SophosXmlText $Password)</Password>
  </Login>
  $InnerXml
</Request>
"@
}

function Invoke-SophosWithCertificatePolicy {
    param(
        [scriptblock]$ScriptBlock,
        [switch]$SkipCertificateCheck
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $previous = [Net.ServicePointManager]::ServerCertificateValidationCallback
    if ($SkipCertificateCheck) {
        if (-not $script:SophosCertificatePolicyTypeLoaded -and $null -eq ('SimpleAcmeSophosCertificatePolicy' -as [type])) {
            Add-Type -TypeDefinition @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class SimpleAcmeSophosCertificatePolicy
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
        $script:SophosCertificatePolicyTypeLoaded = $true
        $policyType = 'SimpleAcmeSophosCertificatePolicy' -as [type]
        if ($null -eq $policyType) { throw 'Unable to load SimpleAcmeSophosCertificatePolicy for TLS certificate bypass.' }
        $method = $policyType.GetMethod('TrustAnyCertificate')
        [Net.ServicePointManager]::ServerCertificateValidationCallback = [System.Delegate]::CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback], $method)
    }
    try {
        & $ScriptBlock
    } finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $previous
    }
}

function ConvertTo-SophosXmlResponse {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$RawContent,
        [int]$StatusCode = 0,
        [string]$ContentType = ''
    )

    $isEmpty = [string]::IsNullOrEmpty($RawContent)
    $xml = $null
    if (-not $isEmpty) {
        try { $xml = [xml]$RawContent } catch { $xml = $null }
    }

    $statuses = @()
    if ($null -ne $xml) {
        $statuses = @($xml.SelectNodes('//Status|//status') | ForEach-Object {
            [pscustomobject]@{
                Code = if ($_.Attributes['code']) { [string]$_.Attributes['code'].Value } else { '' }
                Text = [string]$_.InnerText
            }
        })
    }

    [pscustomobject]@{
        StatusCode = $StatusCode
        ContentType = $ContentType
        RawContent = $RawContent
        Xml = $xml
        IsEmpty = $isEmpty
        Statuses = $statuses
    }
}

function Get-SophosChildText {
    param(
        [Parameter(Mandatory)][System.Xml.XmlNode]$Node,
        [Parameter(Mandatory)][string]$Path
    )
    $child = $Node.SelectSingleNode($Path)
    if ($null -eq $child) { return '' }
    [string]$child.InnerText
}

function Assert-SophosXmlResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Response,
        [string]$Operation = 'Sophos API request'
    )

    if ($Response.IsEmpty) { return }
    foreach ($status in @($Response.Statuses)) {
        $text = [string]$status.Text
        $code = [string]$status.Code
        if ($text -match '(?i)authentication failure|access denied|failed' -or ($code -and $code -notin @('200','201','202'))) {
            throw ("{0} failed: code={1} text={2}" -f $Operation, $code, (Protect-SophosLogText $text))
        }
    }
}

function Connect-SophosFirewallApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Firewall,
        [ValidateRange(1,65535)][int]$Port = 4444,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Password,
        [switch]$SkipCertificateCheck,
        [ValidateRange(1,600)][int]$TimeoutSeconds = 120
    )

    $script:SophosSession = [pscustomobject]@{
        Firewall = $Firewall
        Port = $Port
        Username = $Username
        Password = $Password
        Endpoint = New-SophosApiEndpoint -Firewall $Firewall -Port $Port
        SkipCertificateCheck = [bool]$SkipCertificateCheck
        TimeoutSeconds = $TimeoutSeconds
    }

    $response = Invoke-SophosXmlRequest -InnerXml '<Get><AdminSettings></AdminSettings></Get>' -Operation 'Connect-SophosFirewallApi' -Method POST
    Assert-SophosXmlResponse -Response $response -Operation 'Connect-SophosFirewallApi'
    $script:SophosSession
}

function Get-SophosSession {
    if ($null -eq $script:SophosSession) { throw 'No Sophos API session. Call Connect-SophosFirewallApi first.' }
    $script:SophosSession
}

function Invoke-SophosXmlRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InnerXml,
        [string]$Operation = 'Sophos API request',
        [ValidateSet('GET','POST')][string]$Method = 'POST'
    )

    $session = Get-SophosSession
    $requestXml = New-SophosRequestXml -Username $session.Username -Password $session.Password -InnerXml $InnerXml
    $encoded = [uri]::EscapeDataString($requestXml)
    $uri = if ($Method -eq 'GET') { '{0}?reqxml={1}' -f $session.Endpoint, $encoded } else { $session.Endpoint }

    $webResponse = Invoke-SophosWithCertificatePolicy -SkipCertificateCheck:([bool]$session.SkipCertificateCheck) -ScriptBlock {
        $supportsSkipCertificateCheck = (Get-Command -Name Invoke-WebRequest).Parameters.ContainsKey('SkipCertificateCheck')
        if ($Method -eq 'GET') {
            $invokeParams = @{
                Uri = $uri
                Method = 'Get'
                UseBasicParsing = $true
                TimeoutSec = $session.TimeoutSeconds
            }
            if ($session.SkipCertificateCheck -and $supportsSkipCertificateCheck) { $invokeParams['SkipCertificateCheck'] = $true }
            Invoke-WebRequest @invokeParams
        } else {
            $invokeParams = @{
                Uri = $uri
                Method = 'Post'
                Body = $requestXml
                ContentType = 'application/xml'
                UseBasicParsing = $true
                TimeoutSec = $session.TimeoutSeconds
            }
            if ($session.SkipCertificateCheck -and $supportsSkipCertificateCheck) { $invokeParams['SkipCertificateCheck'] = $true }
            Invoke-WebRequest @invokeParams
        }
    }

    $response = ConvertTo-SophosXmlResponse -RawContent ([string]$webResponse.Content) -StatusCode ([int]$webResponse.StatusCode) -ContentType ([string]$webResponse.Headers['Content-Type'])
    Assert-SophosXmlResponse -Response $response -Operation $Operation
    $response
}

function Get-SophosCertificate {
    [CmdletBinding()]
    param([string]$Name)

    $inner = if ([string]::IsNullOrWhiteSpace($Name)) {
        '<Get><Certificate></Certificate></Get>'
    } else {
        '<Get><Certificate><Name>{0}</Name></Certificate></Get>' -f (ConvertTo-SophosXmlText $Name)
    }
    $response = Invoke-SophosXmlRequest -InnerXml $inner -Operation 'Get-SophosCertificate'
    if ($response.IsEmpty) {
        return [pscustomobject]@{
            Certificates = @()
            IsEmptyExportResponse = $true
            RawResponse = $response
        }
    }

    $certificates = @($response.Xml.SelectNodes('//Certificate') | ForEach-Object {
        [pscustomobject]@{
            Name = Get-SophosChildText -Node $_ -Path 'Name'
            Action = Get-SophosChildText -Node $_ -Path 'Action'
            CertificateFormat = Get-SophosChildText -Node $_ -Path 'CertificateFormat'
            CertificateFile = Get-SophosChildText -Node $_ -Path 'CertificateFile'
            PrivateKeyFile = Get-SophosChildText -Node $_ -Path 'PrivateKeyFile'
        }
    })
    [pscustomobject]@{
        Certificates = $certificates
        IsEmptyExportResponse = $false
        RawResponse = $response
    }
}

function New-SophosMultipartBody {
    param(
        [Parameter(Mandatory)][string]$Boundary,
        [Parameter(Mandatory)][hashtable]$Fields,
        [Parameter(Mandatory)][hashtable]$Files
    )

    $stream = New-Object IO.MemoryStream
    $writer = New-Object IO.StreamWriter($stream, [Text.Encoding]::UTF8)
    foreach ($key in $Fields.Keys) {
        $writer.Write("--$Boundary`r`n")
        $writer.Write("Content-Disposition: form-data; name=`"$key`"`r`n`r`n")
        $writer.Write([string]$Fields[$key])
        $writer.Write("`r`n")
    }
    $writer.Flush()

    foreach ($key in $Files.Keys) {
        $path = [string]$Files[$key]
        $name = [IO.Path]::GetFileName($path)
        $writer.Write("--$Boundary`r`n")
        $writer.Write("Content-Disposition: form-data; name=`"$key`"; filename=`"$name`"`r`n")
        $writer.Write("Content-Type: application/octet-stream`r`n`r`n")
        $writer.Flush()
        $bytes = [IO.File]::ReadAllBytes($path)
        $stream.Write($bytes, 0, $bytes.Length)
        $writer.Write("`r`n")
        $writer.Flush()
    }

    $writer.Write("--$Boundary--`r`n")
    $writer.Flush()
    $stream.ToArray()
}

function Invoke-SophosMultipartRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RequestXml,
        [Parameter(Mandatory)][hashtable]$Files,
        [string]$Operation = 'Sophos multipart request'
    )

    $session = Get-SophosSession
    $boundary = '----simple-acme-sophos-{0}' -f ([guid]::NewGuid().ToString('N'))
    $invokeWebRequest = Get-Command -Name Invoke-WebRequest
    if ($invokeWebRequest.Parameters.ContainsKey('Form')) {
        $form = @{ reqxml = $RequestXml }
        foreach ($key in $Files.Keys) {
            $form[$key] = Get-Item -LiteralPath ([string]$Files[$key])
        }
        $invokeParams = @{
            Uri = $session.Endpoint
            Method = 'Post'
            Form = $form
            TimeoutSec = $session.TimeoutSeconds
        }
        if ($session.SkipCertificateCheck -and $invokeWebRequest.Parameters.ContainsKey('SkipCertificateCheck')) { $invokeParams['SkipCertificateCheck'] = $true }
        $webResponse = Invoke-WebRequest @invokeParams
        $response = ConvertTo-SophosXmlResponse -RawContent ([string]$webResponse.Content) -StatusCode ([int]$webResponse.StatusCode) -ContentType ([string]$webResponse.Headers['Content-Type'])
        Assert-SophosXmlResponse -Response $response -Operation $Operation
        return $response
    }

    $body = New-SophosMultipartBody -Boundary $boundary -Fields @{ reqxml = $RequestXml } -Files $Files

    $raw = Invoke-SophosWithCertificatePolicy -SkipCertificateCheck:([bool]$session.SkipCertificateCheck) -ScriptBlock {
        $request = [Net.HttpWebRequest]::Create($session.Endpoint)
        $request.Method = 'POST'
        $request.ContentType = 'multipart/form-data; boundary={0}' -f $boundary
        $request.Timeout = $session.TimeoutSeconds * 1000
        $request.ContentLength = $body.Length
        $requestStream = $request.GetRequestStream()
        try { $requestStream.Write($body, 0, $body.Length) } finally { $requestStream.Dispose() }
        $response = $request.GetResponse()
        try {
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            try { $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally {
            $response.Dispose()
        }
    }

    $response = ConvertTo-SophosXmlResponse -RawContent ([string]$raw) -StatusCode 200 -ContentType 'text/xml'
    Assert-SophosXmlResponse -Response $response -Operation $Operation
    $response
}

function Import-SophosCertificate {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$PfxPath,
        [SecureString]$PfxPassword,
        [string]$CertPath,
        [string]$KeyPath,
        [string]$ChainPath
    )

    if ([string]::IsNullOrWhiteSpace($PfxPath) -and ([string]::IsNullOrWhiteSpace($CertPath) -or [string]::IsNullOrWhiteSpace($KeyPath))) {
        throw 'Supply either PfxPath or CertPath plus KeyPath.'
    }

    $session = Get-SophosSession
    $files = @{}
    $format = 'pem'
    $certFileName = ''
    $keyFileName = ''
    $passwordText = ''

    if (-not [string]::IsNullOrWhiteSpace($PfxPath)) {
        if (-not (Test-Path -LiteralPath $PfxPath -PathType Leaf)) { throw "PfxPath not found: $PfxPath" }
        $format = 'pfx'
        $certFileName = [IO.Path]::GetFileName($PfxPath)
        $files['CertificateFile'] = $PfxPath
        if ($null -ne $PfxPassword) { $passwordText = ConvertFrom-SophosSecureString -SecureString $PfxPassword }
    } else {
        foreach ($path in @($CertPath,$KeyPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Certificate input file not found: $path" }
        }
        $certFileName = [IO.Path]::GetFileName($CertPath)
        $keyFileName = [IO.Path]::GetFileName($KeyPath)
        $files['CertificateFile'] = $CertPath
        $files['PrivateKeyFile'] = $KeyPath
    }

    $keyXml = ''
    if (-not [string]::IsNullOrWhiteSpace($keyFileName)) {
        $keyXml = '<PrivateKeyFile>{0}</PrivateKeyFile>' -f (ConvertTo-SophosXmlText $keyFileName)
    }
    $chainXml = ''
    if (-not [string]::IsNullOrWhiteSpace($ChainPath)) {
        if (-not (Test-Path -LiteralPath $ChainPath -PathType Leaf)) { throw "ChainPath not found: $ChainPath" }
        $files['CACertificateFile'] = $ChainPath
        $chainXml = '<CACertificateFile>{0}</CACertificateFile>' -f (ConvertTo-SophosXmlText ([IO.Path]::GetFileName($ChainPath)))
    }

    $inner = @"
<Set operation="add">
  <Certificate>
    <Action>UploadCertificate</Action>
    <Name>$(ConvertTo-SophosXmlText $Name)</Name>
    <CertificateFormat>$(ConvertTo-SophosXmlText $format)</CertificateFormat>
    <Password>$(ConvertTo-SophosXmlText $passwordText)</Password>
    <CertificateFile>$(ConvertTo-SophosXmlText $certFileName)</CertificateFile>
    $keyXml
    $chainXml
  </Certificate>
</Set>
"@
    $requestXml = New-SophosRequestXml -Username $session.Username -Password $session.Password -InnerXml $inner
    if ($PSCmdlet.ShouldProcess($session.Firewall, "Upload Sophos certificate '$Name'")) {
        Invoke-SophosMultipartRequest -RequestXml $requestXml -Files $files -Operation 'Import-SophosCertificate'
    } else {
        [pscustomobject]@{ WhatIf = $true; CertificateName = $Name; Files = @($files.Keys) }
    }
}

function Remove-SophosCertificate {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name)

    $session = Get-SophosSession
    $inner = @"
<Remove>
  <Certificate>
    <Name>$(ConvertTo-SophosXmlText $Name)</Name>
  </Certificate>
</Remove>
"@
    if ($PSCmdlet.ShouldProcess($session.Firewall, "Remove Sophos certificate '$Name'")) {
        Invoke-SophosXmlRequest -InnerXml $inner -Operation 'Remove-SophosCertificate' -Method POST
    } else {
        [pscustomobject]@{ WhatIf = $true; CertificateName = $Name }
    }
}

function Get-SophosAdminWebSettings {
    [CmdletBinding()]
    param()

    $response = Invoke-SophosXmlRequest -InnerXml '<Get><AdminSettings></AdminSettings></Get>' -Operation 'Get-SophosAdminWebSettings'
    if ($response.IsEmpty -or $null -eq $response.Xml) {
        return [pscustomobject]@{
            Node = $null
            Certificate = ''
            HTTPSport = ''
            UserPortalHTTPSPort = ''
            VPNPortalHTTPSPort = ''
            IsEmptyResponse = $true
        }
    }
    $node = $response.Xml.SelectSingleNode('//AdminSettings/WebAdminSettings')
    if ($null -eq $node) { throw 'Sophos AdminSettings/WebAdminSettings was not found in response.' }
    [pscustomobject]@{
        Node = $node
        Certificate = Get-SophosChildText -Node $node -Path 'Certificate'
        HTTPSport = Get-SophosChildText -Node $node -Path 'HTTPSport'
        UserPortalHTTPSPort = Get-SophosChildText -Node $node -Path 'UserPortalHTTPSPort'
        VPNPortalHTTPSPort = Get-SophosChildText -Node $node -Path 'VPNPortalHTTPSPort'
        IsEmptyResponse = $false
    }
}

function Set-SophosAdminWebSettingsCertificate {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$CertificateName)

    $settings = Get-SophosAdminWebSettings
    if ($null -eq $settings.Node) { throw 'Sophos AdminSettings/WebAdminSettings cannot be updated because the API returned an empty response.' }
    $node = $settings.Node.Clone()
    $certNode = $node.SelectSingleNode('Certificate')
    if ($null -eq $certNode) {
        $certNode = $node.OwnerDocument.CreateElement('Certificate')
        $null = $node.PrependChild($certNode)
    }
    $certNode.InnerText = $CertificateName
    $inner = '<Set operation="update"><AdminSettings><WebAdminSettings>{0}</WebAdminSettings></AdminSettings></Set>' -f $node.InnerXml
    $session = Get-SophosSession
    if ($PSCmdlet.ShouldProcess($session.Firewall, "Set WebAdminSettings certificate '$CertificateName'")) {
        Invoke-SophosXmlRequest -InnerXml $inner -Operation 'Set-SophosAdminWebSettingsCertificate' -Method POST
    } else {
        [pscustomobject]@{ WhatIf = $true; PreviousCertificate = $settings.Certificate; NewCertificate = $CertificateName }
    }
}

function Get-SophosWafRules {
    [CmdletBinding()]
    param()

    $response = Invoke-SophosXmlRequest -InnerXml '<Get><FirewallRule></FirewallRule></Get>' -Operation 'Get-SophosWafRules'
    if ($response.IsEmpty -or $null -eq $response.Xml) { return @() }
    @($response.Xml.SelectNodes('//FirewallRule') | Where-Object {
        (Get-SophosChildText -Node $_ -Path 'PolicyType') -eq 'HTTPBased' -or $null -ne $_.SelectSingleNode('.//HTTPSCertificate')
    } | ForEach-Object {
        $certNode = $_.SelectSingleNode('.//HTTPSCertificate')
        $domains = @($_.SelectNodes('.//Domains/Domain') | ForEach-Object { [string]$_.InnerText })
        [pscustomobject]@{
            Name = Get-SophosChildText -Node $_ -Path 'Name'
            Status = Get-SophosChildText -Node $_ -Path 'Status'
            PolicyType = Get-SophosChildText -Node $_ -Path 'PolicyType'
            HttpsCertificate = if ($null -ne $certNode) { [string]$certNode.InnerText } else { '' }
            ListenPort = Get-SophosChildText -Node $_ -Path './/ListenPort'
            HostedAddress = Get-SophosChildText -Node $_ -Path './/HostedAddress'
            Domains = $domains
            Node = $_
        }
    })
}

function Set-SophosWafRuleCertificate {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][string]$CertificateName
    )

    $rule = @(Get-SophosWafRules | Where-Object { $_.Name -eq $RuleName } | Select-Object -First 1)
    if ($null -eq $rule -or $rule.Count -eq 0) { throw "Sophos WAF/HTTPBased rule '$RuleName' was not found." }
    $node = $rule[0].Node.Clone()
    $certNode = $node.SelectSingleNode('.//HTTPSCertificate')
    if ($null -eq $certNode) {
        $policyNode = $node.SelectSingleNode('.//HTTPBasedPolicy')
        if ($null -eq $policyNode) { throw "Rule '$RuleName' does not contain HTTPBasedPolicy." }
        $certNode = $node.OwnerDocument.CreateElement('HTTPSCertificate')
        $null = $policyNode.AppendChild($certNode)
    }
    $certNode.InnerText = $CertificateName
    $inner = '<Set operation="update"><FirewallRule>{0}</FirewallRule></Set>' -f $node.InnerXml
    $session = Get-SophosSession
    if ($PSCmdlet.ShouldProcess($session.Firewall, "Set WAF rule '$RuleName' certificate '$CertificateName'")) {
        Invoke-SophosXmlRequest -InnerXml $inner -Operation 'Set-SophosWafRuleCertificate' -Method POST
    } else {
        [pscustomobject]@{ WhatIf = $true; RuleName = $RuleName; PreviousCertificate = $rule[0].HttpsCertificate; NewCertificate = $CertificateName }
    }
}

function Test-SophosDeploymentVerification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CertificateName,
        [switch]$BindAdminPortal,
        [string[]]$WafRuleNames = @()
    )

    $checks = New-Object System.Collections.Generic.List[object]
    if ($BindAdminPortal) {
        $settings = Get-SophosAdminWebSettings
        $checks.Add([pscustomobject]@{ Target = 'AdminWebSettings'; Expected = $CertificateName; Actual = $settings.Certificate; Passed = ($settings.Certificate -eq $CertificateName) }) | Out-Null
    }
    if ($null -ne $WafRuleNames) {
        $rules = @(Get-SophosWafRules)
        foreach ($name in $WafRuleNames) {
            $rule = @($rules | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
            $actual = if ($rule.Count -gt 0) { [string]$rule[0].HttpsCertificate } else { '<missing>' }
            $checks.Add([pscustomobject]@{ Target = "WAF:$name"; Expected = $CertificateName; Actual = $actual; Passed = ($actual -eq $CertificateName) }) | Out-Null
        }
    }
    $failed = @($checks | Where-Object { -not $_.Passed })
    [pscustomobject]@{ Passed = ($failed.Count -eq 0); Checks = @($checks) }
}

function New-SophosSshCommandArguments {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$Username,
        [ValidateRange(1,65535)][int]$Port = 22,
        [Parameter(Mandatory)][string]$HostKeyFingerprint,
        [string]$Password,
        [string]$PrivateKeyPath,
        [string]$RemotePath,
        [string]$LocalPath
    )

    if ([string]::IsNullOrWhiteSpace($HostKeyFingerprint)) { throw 'SSH host key fingerprint is required.' }
    if ([string]::IsNullOrWhiteSpace($Password) -and [string]::IsNullOrWhiteSpace($PrivateKeyPath)) {
        throw 'Supply either an SSH password or a private key path.'
    }
    if (-not [string]::IsNullOrWhiteSpace($PrivateKeyPath) -and -not (Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf)) {
        throw "SSH private key file not found: $PrivateKeyPath"
    }

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add('-batch') | Out-Null
    if ($Executable -match 'plink') {
        $args.Add('-ssh') | Out-Null
        $args.Add('-t') | Out-Null
    }
    $args.Add('-P') | Out-Null
    $args.Add([string]$Port) | Out-Null
    $args.Add('-hostkey') | Out-Null
    $args.Add($HostKeyFingerprint) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($Password)) {
        $args.Add('-pw') | Out-Null
        $args.Add($Password) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($PrivateKeyPath)) {
        $args.Add('-i') | Out-Null
        $args.Add($PrivateKeyPath) | Out-Null
    }
    if ($Executable -match 'pscp') {
        $args.Add(('{0}@{1}:{2}' -f $Username, $HostName, $RemotePath)) | Out-Null
        $args.Add($LocalPath) | Out-Null
    } else {
        $args.Add(('{0}@{1}' -f $Username, $HostName)) | Out-Null
    }
    @($args)
}

function Invoke-SophosAdvancedShellCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Firewall,
        [string]$SshUsername = 'admin',
        [ValidateRange(1,65535)][int]$SshPort = 22,
        [Parameter(Mandatory)][string]$SshHostKeyFingerprint,
        [string]$SshPassword,
        [string]$SshPrivateKeyPath,
        [Parameter(Mandatory)][string]$Command,
        [string]$PlinkPath = 'plink.exe'
    )

    $args = New-SophosSshCommandArguments -Executable $PlinkPath -HostName $Firewall -Username $SshUsername -Port $SshPort -HostKeyFingerprint $SshHostKeyFingerprint -Password $SshPassword -PrivateKeyPath $SshPrivateKeyPath
    $inputText = "5`n3`n$Command`nexit`n0`n0`n"
    $output = $inputText | & $PlinkPath @args 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "Sophos SSH command failed with exit code $exitCode. Output: $(Protect-SophosLogText ([string]($output -join [Environment]::NewLine)))" }
    $output
}

function Get-SophosApiExportArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Firewall,
        [string]$SshUsername = 'admin',
        [ValidateRange(1,65535)][int]$SshPort = 22,
        [Parameter(Mandatory)][string]$SshHostKeyFingerprint,
        [string]$SshPassword,
        [string]$SshPrivateKeyPath,
        [int]$MaxCandidates = 10,
        [string]$PlinkPath = 'plink.exe'
    )

    $command = "ls -t /var/API-*.tar 2>/dev/null | head -$MaxCandidates"
    $output = Invoke-SophosAdvancedShellCommand -Firewall $Firewall -SshUsername $SshUsername -SshPort $SshPort -SshHostKeyFingerprint $SshHostKeyFingerprint -SshPassword $SshPassword -SshPrivateKeyPath $SshPrivateKeyPath -Command $command -PlinkPath $PlinkPath
    @($output | Where-Object { $_ -match '^/var/API-.*\.tar$' } | ForEach-Object { [string]$_ })
}

function Copy-SophosApiExportArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Firewall,
        [string]$SshUsername = 'admin',
        [ValidateRange(1,65535)][int]$SshPort = 22,
        [Parameter(Mandatory)][string]$SshHostKeyFingerprint,
        [string]$SshPassword,
        [string]$SshPrivateKeyPath,
        [Parameter(Mandatory)][string]$RemotePath,
        [Parameter(Mandatory)][string]$LocalPath,
        [string]$PscpPath = 'pscp.exe'
    )

    $args = New-SophosSshCommandArguments -Executable $PscpPath -HostName $Firewall -Username $SshUsername -Port $SshPort -HostKeyFingerprint $SshHostKeyFingerprint -Password $SshPassword -PrivateKeyPath $SshPrivateKeyPath -RemotePath $RemotePath -LocalPath $LocalPath
    $output = & $PscpPath @args 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "Sophos SCP copy failed with exit code $exitCode. Output: $(Protect-SophosLogText ([string]($output -join [Environment]::NewLine)))" }
    Get-Item -LiteralPath $LocalPath
}

function Export-SophosCertificateArchive {
    [CmdletBinding()]
    param(
        [string]$OutputPath,
        [switch]$EnableSshExportRecovery,
        [string]$SshUsername = 'admin',
        [ValidateRange(1,65535)][int]$SshPort = 22,
        [string]$SshHostKeyFingerprint,
        [string]$SshPassword,
        [string]$SshPrivateKeyPath,
        [string]$PlinkPath = 'plink.exe',
        [string]$PscpPath = 'pscp.exe'
    )

    $session = Get-SophosSession
    $response = Invoke-SophosXmlRequest -InnerXml '<Get><Certificate></Certificate></Get>' -Operation 'Export-SophosCertificateArchive'
    if (-not $response.IsEmpty) {
        if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
            [IO.File]::WriteAllText($OutputPath, $response.RawContent)
        }
        return [pscustomobject]@{ Method = 'Api'; Response = $response; OutputPath = $OutputPath; UsedSshRecovery = $false }
    }

    if (-not $EnableSshExportRecovery) {
        return [pscustomobject]@{ Method = 'Api'; Response = $response; OutputPath = $null; UsedSshRecovery = $false; EmptyApiResponse = $true }
    }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) { throw 'OutputPath is required when SSH export recovery is enabled.' }
    if ([string]::IsNullOrWhiteSpace($SshHostKeyFingerprint)) { throw 'SshHostKeyFingerprint is required for SSH export recovery.' }

    $artifacts = @(Get-SophosApiExportArtifact -Firewall $session.Firewall -SshUsername $SshUsername -SshPort $SshPort -SshHostKeyFingerprint $SshHostKeyFingerprint -SshPassword $SshPassword -SshPrivateKeyPath $SshPrivateKeyPath -PlinkPath $PlinkPath)
    if ($artifacts.Count -eq 0) { throw 'No Sophos API export artifacts were found under /var/API-*.tar.' }
    $remote = $artifacts[0]
    $item = Copy-SophosApiExportArtifact -Firewall $session.Firewall -SshUsername $SshUsername -SshPort $SshPort -SshHostKeyFingerprint $SshHostKeyFingerprint -SshPassword $SshPassword -SshPrivateKeyPath $SshPrivateKeyPath -RemotePath $remote -LocalPath $OutputPath -PscpPath $PscpPath
    [pscustomobject]@{ Method = 'SshRecovery'; RemotePath = $remote; OutputPath = $item.FullName; Length = $item.Length; UsedSshRecovery = $true; EmptyApiResponse = $true }
}

Export-ModuleMember -Function ConvertFrom-SophosSecureString,Resolve-SophosPassword,New-SophosApiEndpoint,Protect-SophosLogText,New-SophosRequestXml,Connect-SophosFirewallApi,Invoke-SophosXmlRequest,Get-SophosCertificate,Export-SophosCertificateArchive,Import-SophosCertificate,Remove-SophosCertificate,Get-SophosAdminWebSettings,Set-SophosAdminWebSettingsCertificate,Get-SophosWafRules,Set-SophosWafRuleCertificate,Test-SophosDeploymentVerification,New-SophosSshCommandArguments,Invoke-SophosAdvancedShellCommand,Get-SophosApiExportArtifact,Copy-SophosApiExportArtifact
