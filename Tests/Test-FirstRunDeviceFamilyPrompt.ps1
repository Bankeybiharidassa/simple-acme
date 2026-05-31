Set-StrictMode -Version Latest

function Invoke-TestFirstRunDeviceFamilyPrompt {
    param([scriptblock]$Assert)

    & $Assert 'first-run setup asks for firewall and load balancer device families' {
        $formRunnerPath = Join-Path $PSScriptRoot '..\setup\Form-Runner.psm1'
        $raw = Get-Content -LiteralPath $formRunnerPath -Raw
        if ($raw -notmatch 'function\s+Select-FirstRunDeviceFamily') {
            throw 'Missing first-run device family selection helper.'
        }
        foreach ($text in @(
            'Which firewall/VPN device family is this certificate for?',
            'Sophos firewall - issue now, deploy from Deployment targets after issuance',
            'Palo Alto firewall - issue now, deploy from Deployment targets after issuance',
            'Which load balancer/WAF family is this certificate for?',
            'NetScaler / Citrix ADC - issue now, deploy from Deployment targets after issuance',
            'Kemp LoadMaster - issue now, deploy from Deployment targets after issuance',
            'F5 BIG-IP - issue now, configure as a deployment device after issuance'
        )) {
            if ($raw -notmatch [regex]::Escape($text)) {
                throw "Missing operator prompt text: $text"
            }
        }
    }

    & $Assert 'selected first-run device family is persisted into certificate.env values' {
        $formRunnerPath = Join-Path $PSScriptRoot '..\setup\Form-Runner.psm1'
        $raw = Get-Content -LiteralPath $formRunnerPath -Raw
        if ($raw -notmatch 'ACME_TARGET_DEVICE_TYPE') {
            throw 'Selected device family type is not persisted.'
        }
        if ($raw -notmatch 'ACME_TARGET_DEVICE_LABEL') {
            throw 'Selected device family label is not persisted.'
        }
        if ($raw -notmatch 'Select-FirstRunDeviceFamily[\s\S]*Get-AcmeConnectorRegistryEntry') {
            throw 'Target selection is not resolved through the device family prompt before registry lookup.'
        }
    }

    & $Assert 'post-issuance appliance menu choices can still start certificate issuance' {
        $formRunnerPath = Join-Path $PSScriptRoot '..\setup\Form-Runner.psm1'
        $raw = Get-Content -LiteralPath $formRunnerPath -Raw
        foreach ($text in @(
            'Sophos firewall certificate issuance',
            'Palo Alto firewall certificate issuance',
            'NetScaler / Citrix ADC certificate issuance',
            'Kemp LoadMaster certificate issuance',
            'Continue certificate issuance / verification now'
        )) {
            if ($raw -notmatch [regex]::Escape($text)) {
                throw "Missing post-issuance first-run routing text: $text"
            }
        }
        if ($raw -notmatch "sophos\s*=\s*@\{[^}]*TargetSystem\s*=\s*'firewall'") {
            throw 'Sophos first-run menu choice is not routed to firewall issuance.'
        }
        if ($raw -notmatch "netscaler\s*=\s*@\{[^}]*TargetSystem\s*=\s*'waf'") {
            throw 'NetScaler first-run menu choice is not routed to WAF issuance.'
        }
    }
}
