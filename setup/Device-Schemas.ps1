[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments','DeviceSchemas',Justification='Dot-sourced data table consumed by setup modules and scripts.')]
param()
Set-StrictMode -Version Latest

$ServerConnectionMethods = @(
    @{ Key='ssh_key'; Label='SSH with private key'; DefaultPort='22' },
    @{ Key='ssh_password'; Label='SSH with username and password'; DefaultPort='22' },
    @{ Key='local'; Label='Local files/commands on this machine' }
)

$ApiOrSshConnectionMethods = @(
    @{ Key='api_token'; Label='HTTPS/API with token or key'; DefaultPort='443' },
    @{ Key='api_basic'; Label='HTTPS/API with username and password'; DefaultPort='443' },
    @{ Key='ssh_key'; Label='SSH with private key'; DefaultPort='22' },
    @{ Key='ssh_password'; Label='SSH with username and password'; DefaultPort='22' }
)

$SshConnectionMethods = @(
    @{ Key='ssh_key'; Label='SSH with private key'; DefaultPort='22' },
    @{ Key='ssh_password'; Label='SSH with username and password'; DefaultPort='22' }
)

$ServerProfileFields = @(
    @{ Name='host'; Label='Server address'; Type='string'; Required=$true; Placeholder='server.example.com'; HelpText='DNS name or IP address for remote SSH management.'; Methods=@('ssh_key','ssh_password') },
    @{ Name='port'; Label='SSH port'; Type='string'; Required=$true; Default='22'; Placeholder='22'; HelpText='SSH management port.'; Methods=@('ssh_key','ssh_password') },
    @{ Name='username'; Label='SSH username'; Type='string'; Required=$true; Placeholder='root'; HelpText='User allowed to update certificate files and reload the service.'; Methods=@('ssh_key','ssh_password') },
    @{ Name='password'; Label='SSH password'; Type='secret'; Required=$false; Placeholder=''; HelpText='SSH password. Leave empty when using a key.'; Methods=@('ssh_password') },
    @{ Name='private_key_path'; Label='SSH private key file'; Type='string'; Required=$false; Placeholder='C:\keys\server.ppk'; HelpText='Private key file used by the SSH deployment hook.'; Methods=@('ssh_key') },
    @{ Name='ssh_host_key_fingerprint'; Label='SSH host key fingerprint'; Type='string'; Required=$false; Placeholder='SHA256:...'; HelpText='Recommended host key pinning value.'; Methods=@('ssh_key','ssh_password') },
    @{ Name='cert_directory'; Label='Certificate directory'; Type='string'; Required=$false; Placeholder='/etc/ssl/simple-acme'; HelpText='Remote or local directory where certificate files should be placed.' },
    @{ Name='reload_command'; Label='Reload/test command'; Type='string'; Required=$false; Placeholder='systemctl reload nginx'; HelpText='Command the future deployment hook should run after writing files.' },
    @{ Name='webroot_path'; Label='Webroot path'; Type='string'; Required=$false; Placeholder='/var/www/html'; HelpText='Optional webroot for HTTP validation or local web-server workflows.' }
)

$ApiProfileFields = @(
    @{ Name='host'; Label='Device address'; Type='string'; Required=$true; Placeholder='device.example.com'; HelpText='Management DNS name or IP address.' },
    @{ Name='port'; Label='Management port'; Type='string'; Required=$true; Default='443'; Placeholder='443'; HelpText='HTTPS API or SSH management port.' },
    @{ Name='username'; Label='Username'; Type='string'; Required=$false; Placeholder='admin'; HelpText='API or SSH username.'; Methods=@('api_basic','ssh_key','ssh_password') },
    @{ Name='password'; Label='Password'; Type='secret'; Required=$false; Placeholder=''; HelpText='API or SSH password.'; Methods=@('api_basic','ssh_password') },
    @{ Name='api_token'; Label='API token/key'; Type='secret'; Required=$false; Placeholder=''; HelpText='Token, API key, or bearer credential for API-based devices.'; Methods=@('api_token') },
    @{ Name='private_key_path'; Label='SSH private key file'; Type='string'; Required=$false; Placeholder='C:\keys\device.ppk'; HelpText='Private key file used by SSH-based deployment.'; Methods=@('ssh_key') },
    @{ Name='ssh_host_key_fingerprint'; Label='SSH host key fingerprint'; Type='string'; Required=$false; Placeholder='SHA256:...'; HelpText='Recommended host key pinning value.'; Methods=@('ssh_key','ssh_password') },
    @{ Name='skip_certificate_check'; Label='Ignore management TLS warning'; Type='choice'; Required=$true; Choices=@('false','true'); Default='false'; Placeholder='false'; HelpText='Set true only for trusted management networks with self-signed/untrusted admin certificates.'; Methods=@('api_token','api_basic') },
    @{ Name='target_hint'; Label='Certificate target hint'; Type='string'; Required=$false; Placeholder='portal,virtual-server,rule,listener'; HelpText='Human-readable target note until the connector can pull exact bindings.' }
)

$CiscoProfileFields = @(
    @{ Name='host'; Label='Device address'; Type='string'; Required=$true; Placeholder='router.example.com'; HelpText='Cisco management DNS name or IP address.' },
    @{ Name='port'; Label='SSH/API port'; Type='string'; Required=$true; Default='22'; Placeholder='22'; HelpText='SSH or HTTPS API management port.' },
    @{ Name='username'; Label='Username'; Type='string'; Required=$true; Placeholder='admin'; HelpText='Cisco administrator username.' },
    @{ Name='password'; Label='Password'; Type='secret'; Required=$false; Placeholder=''; HelpText='SSH/API password.'; Methods=@('ssh_password','api_basic') },
    @{ Name='private_key_path'; Label='SSH private key file'; Type='string'; Required=$false; Placeholder='C:\keys\cisco.ppk'; HelpText='Private key file used by SSH-based deployment.'; Methods=@('ssh_key') },
    @{ Name='enable_secret'; Label='Enable secret'; Type='secret'; Required=$false; Placeholder=''; HelpText='Optional enable/privileged mode secret.' },
    @{ Name='ssh_host_key_fingerprint'; Label='SSH host key fingerprint'; Type='string'; Required=$false; Placeholder='SHA256:...'; HelpText='Recommended host key pinning value.' },
    @{ Name='target_hint'; Label='Certificate target hint'; Type='string'; Required=$false; Placeholder='trustpoint/webvpn/ssl profile'; HelpText='Where this certificate should be installed on the Cisco device.' }
)

$DeviceSchemas = @{
    iis = @{ ConnectorType='iis'; Label='IIS'; Category='local_windows'; Fields=@(
        @{ Name='site_name'; Label='Site name'; Type='string'; Required=$true; Placeholder='Default Web Site'; HelpText='IIS website name' },
        @{ Name='cert_store_location'; Label='Store location'; Type='choice'; Required=$true; Choices=@('My','WebHosting'); Placeholder='My'; HelpText='Certificate store location for IIS binding' }
    )}


    rds = @{ ConnectorType='rds'; Label='Remote Desktop Gateway / RD Web'; Category='local_windows'; Fields=@() }
    'rds-farm' = @{ ConnectorType='rds-farm'; Label='Remote Desktop Gateway + Session Hosts farm'; Category='local_windows'; Fields=@(
        @{ Name='session_hosts'; Label='Session hosts'; Type='string'; Required=$true; Placeholder='rdsh01.contoso.local,rdsh02.contoso.local'; HelpText='Comma-separated Session Host FQDNs for farm fan-out' }
    )}
    mail = @{ ConnectorType='mail'; Label='Mail server'; Category='server'; Fields=@() }
    firewall = @{ ConnectorType='firewall'; Label='Firewall / VPN'; Category='network_appliance'; Fields=@() }
    waf = @{ ConnectorType='waf'; Label='Load balancer / WAF'; Category='network_appliance'; Fields=@() }

    nginx = @{ ConnectorType='nginx'; Label='Nginx / OpenResty'; Category='web_server'; SetupMode='guided'; ConnectionMethods=$ServerConnectionMethods; Fields=$ServerProfileFields }
    apache = @{ ConnectorType='apache'; Label='Apache HTTPD'; Category='web_server'; SetupMode='guided'; ConnectionMethods=$ServerConnectionMethods; Fields=$ServerProfileFields }
    haproxy = @{ ConnectorType='haproxy'; Label='HAProxy'; Category='load_balancer'; SetupMode='guided'; ConnectionMethods=$ServerConnectionMethods; Fields=$ServerProfileFields }
    traefik = @{ ConnectorType='traefik'; Label='Traefik'; Category='load_balancer'; SetupMode='guided'; ConnectionMethods=$ServerConnectionMethods; Fields=$ServerProfileFields }
    caddy = @{ ConnectorType='caddy'; Label='Caddy'; Category='web_server'; SetupMode='guided'; ConnectionMethods=$ServerConnectionMethods; Fields=$ServerProfileFields }
    lighttpd = @{ ConnectorType='lighttpd'; Label='Lighttpd'; Category='web_server'; SetupMode='guided'; ConnectionMethods=$ServerConnectionMethods; Fields=$ServerProfileFields }

    opnsense = @{ ConnectorType='opnsense'; Label='OPNsense firewall'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$ApiProfileFields }
    pfsense = @{ ConnectorType='pfsense'; Label='pfSense firewall'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$ApiProfileFields }
    fortigate = @{ ConnectorType='fortigate'; Label='Fortinet FortiGate'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$ApiProfileFields }
    sonicwall = @{ ConnectorType='sonicwall'; Label='SonicWall firewall'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$ApiProfileFields }
    watchguard = @{ ConnectorType='watchguard'; Label='WatchGuard Firebox'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$ApiProfileFields }
    checkpoint = @{ ConnectorType='checkpoint'; Label='Check Point gateway'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$ApiProfileFields }
    juniper_srx = @{ ConnectorType='juniper_srx'; Label='Juniper SRX'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$SshConnectionMethods; Fields=$ApiProfileFields }
    mikrotik = @{ ConnectorType='mikrotik'; Label='MikroTik RouterOS'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$ApiProfileFields }
    ubiquiti = @{ ConnectorType='ubiquiti'; Label='Ubiquiti EdgeMAX / UniFi Gateway'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$ApiProfileFields }

    cisco_asa = @{ ConnectorType='cisco_asa'; Label='Cisco ASA / Firepower'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$CiscoProfileFields }
    cisco_iosxe = @{ ConnectorType='cisco_iosxe'; Label='Cisco IOS XE'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$SshConnectionMethods; Fields=$CiscoProfileFields }
    cisco_wlc = @{ ConnectorType='cisco_wlc'; Label='Cisco Wireless Controller'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$SshConnectionMethods; Fields=$CiscoProfileFields }
    aruba = @{ ConnectorType='aruba'; Label='Aruba / HPE Aruba'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$ApiProfileFields }

    proxmox = @{ ConnectorType='proxmox'; Label='Proxmox VE'; Category='server'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$ApiProfileFields }
    synology_dsm = @{ ConnectorType='synology_dsm'; Label='Synology DSM'; Category='server_appliance'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$ApiProfileFields }
    qnap = @{ ConnectorType='qnap'; Label='QNAP NAS'; Category='server_appliance'; SetupMode='guided'; ConnectionMethods=$ApiOrSshConnectionMethods; Fields=$ApiProfileFields }
    generic_ssh = @{ ConnectorType='generic_ssh'; Label='Generic SSH device'; Category='generic'; SetupMode='guided'; ConnectionMethods=$SshConnectionMethods; Fields=$ServerProfileFields }
    generic_api = @{ ConnectorType='generic_api'; Label='Generic HTTPS/API device'; Category='generic'; SetupMode='guided'; ConnectionMethods=@(@{ Key='api_token'; Label='HTTPS/API with token or key'; DefaultPort='443' },@{ Key='api_basic'; Label='HTTPS/API with username and password'; DefaultPort='443' }); Fields=$ApiProfileFields }

    adfs = @{ ConnectorType='adfs'; Label='ADFS'; Category='local_windows'; Fields=@() }
    rdp_listener = @{ ConnectorType='rdp_listener'; Label='RDP Listener'; Category='local_windows'; Fields=@() }
    rd_gateway = @{ ConnectorType='rd_gateway'; Label='RD Gateway'; Category='local_windows'; Fields=@() }
    rds_full = @{ ConnectorType='rds_full'; Label='RDS Full Stack'; Category='local_windows'; Fields=@(
        @{ Name='rdcb_fqdn'; Label='RDCB FQDN'; Type='string'; Required=$false; Placeholder='rdcb.contoso.local'; HelpText='Optional Connection Broker FQDN (local machine when empty)' }
    )}
    ntds = @{ ConnectorType='ntds'; Label='NTDS (AD LDAPS)'; Category='local_windows'; Fields=@() }
    sstp = @{ ConnectorType='sstp'; Label='SSTP VPN'; Category='local_windows'; Fields=@(
        @{ Name='recreate_default_bindings'; Label='Recreate default IIS :443 binding'; Type='choice'; Required=$true; Choices=@('false','true'); Placeholder='false'; HelpText='Set true to re-create *:443: binding before assigning cert' }
    )}
    winrm = @{ ConnectorType='winrm'; Label='WinRM'; Category='local_windows'; Fields=@() }
    sql_server = @{ ConnectorType='sql_server'; Label='SQL Server'; Category='local_windows'; Fields=@(
        @{ Name='instance_name'; Label='Instance name'; Type='string'; Required=$false; Placeholder='MSSQLSERVER'; HelpText='SQL instance name (default MSSQLSERVER)' }
    )}
    windows_admin_center = @{ ConnectorType='windows_admin_center'; Label='Windows Admin Center'; Category='local_windows'; Fields=@() }

    exchange = @{ ConnectorType='exchange'; Label='Exchange (local)'; Category='exchange'; Fields=@(
        @{ Name='services'; Label='Exchange services'; Type='string'; Required=$false; Placeholder='SMTP,IIS,POP,IMAP'; HelpText='Comma-separated list for Enable-ExchangeCertificate -Services' }
    )}

    exchange_hybrid = @{ ConnectorType='exchange_hybrid'; Label='Exchange Hybrid'; Category='exchange'; Disabled=$true; Requires='Requires hybrid transport tuning not yet implemented in native connector set.'; Fields=@(
        @{ Name='requires'; Label='Requires'; Type='string'; Required=$false; Placeholder='Exchange hybrid transport'; HelpText='Read-only information: not currently available.' }
    )}

    f5_bigip = @{ ConnectorType='f5_bigip'; Label='F5 BIG-IP'; Category='network_appliance'; Fields=@(
        @{ Name='host'; Label='Management hostname or IP'; Type='string'; Required=$true; Placeholder='f5.example.com'; HelpText='FQDN or IP of the F5 management interface' },
        @{ Name='token_env'; Label='Token env-var name'; Type='string'; Required=$true; Placeholder='F5_API_TOKEN'; HelpText='Environment variable that stores the iControl REST Bearer token' },
        @{ Name='ssl_profile'; Label='Client SSL profile name'; Type='string'; Required=$true; Placeholder='clientssl-prod'; HelpText='Name of the client SSL profile to update' }
    )}

    netscaler = @{ ConnectorType='netscaler'; Label='NetScaler / Citrix ADC'; Category='network_appliance'; Fields=@(
        @{ Name='host'; Label='Management hostname or IP'; Type='string'; Required=$true; Placeholder='adc.example.com'; HelpText='NetScaler / Citrix ADC management endpoint' },
        @{ Name='username'; Label='NITRO username'; Type='string'; Required=$true; Placeholder='nsroot'; HelpText='NITRO API username. The password is resolved by secret name, not stored in the TUI log.' },
        @{ Name='password_secret_name'; Label='Password secret name'; Type='string'; Required=$true; Placeholder='NETSCALER_PASSWORD'; HelpText='Secret/environment name used by cert2netscaler.ps1 to resolve the NITRO password' },
        @{ Name='certkey_name'; Label='sslcertkey name'; Type='string'; Required=$true; Placeholder='wildcard_example_com'; HelpText='Target sslcertkey object name' },
        @{ Name='cert_path'; Label='Certificate path'; Type='string'; Required=$true; Placeholder='/path/to/cert.crt'; HelpText='PEM certificate file path' },
        @{ Name='key_path'; Label='Private key path'; Type='string'; Required=$true; Placeholder='/path/to/cert.key'; HelpText='PEM private key file path. Contents are never logged.' },
        @{ Name='chain_path'; Label='Chain path'; Type='string'; Required=$false; Placeholder=''; HelpText='Optional PEM chain file path' },
        @{ Name='vserver_name'; Label='SSL vServer name'; Type='string'; Required=$true; Placeholder='prod-vsrv'; HelpText='SSL virtual server to bind the certificate to' },
        @{ Name='require_primary'; Label='Require HA primary'; Type='choice'; Required=$true; Choices=@('true','false'); Placeholder='true'; HelpText='Set false to allow operation when HA primary assertion should be bypassed' },
        @{ Name='sync_ha'; Label='Sync HA after deploy'; Type='choice'; Required=$true; Choices=@('true','false'); Placeholder='true'; HelpText='Set false to skip HA sync after successful deployment' },
        @{ Name='save_config'; Label='Save config after deploy'; Type='choice'; Required=$true; Choices=@('true','false'); Placeholder='true'; HelpText='Set false to skip saving the running NetScaler configuration' },
        @{ Name='replace_existing_server_certificate'; Label='Replace existing server cert'; Type='choice'; Required=$true; Choices=@('false','true'); Placeholder='false'; HelpText='When true, replace existing non-CA/non-SNI server certificate bindings' },
        @{ Name='skip_certificate_check'; Label='Skip TLS certificate check'; Type='choice'; Required=$true; Choices=@('false','true'); Placeholder='false'; HelpText='When true, skip management endpoint TLS certificate validation' }
    )}

    citrix_adc = @{ ConnectorType='citrix_adc'; Label='Citrix ADC'; Category='network_appliance'; Fields=@(
        @{ Name='host'; Label='Host'; Type='string'; Required=$true; Placeholder='adc.example.com'; HelpText='Citrix ADC management endpoint' },
        @{ Name='user_env'; Label='User env-var name'; Type='string'; Required=$true; Placeholder='ADC_USER'; HelpText='Environment variable name for NITRO API username' },
        @{ Name='password_env'; Label='Password env-var name'; Type='string'; Required=$true; Placeholder='ADC_PASSWORD'; HelpText='Environment variable name for NITRO API password' },
        @{ Name='vserver'; Label='vServer'; Type='string'; Required=$true; Placeholder='prod-vsrv'; HelpText='Target virtual server name' }
    )}
    kemp = @{ ConnectorType='kemp'; Label='Kemp LoadMaster'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=@(@{ Key='api_key'; Label='Kemp APIv2 key'; DefaultPort='443' },@{ Key='api_basic'; Label='Kemp APIv2 username and password'; DefaultPort='443' }); Fields=@(
        @{ Name='host'; Label='LoadMaster address'; Type='string'; Required=$true; Placeholder='192.168.45.150'; HelpText='Kemp LoadMaster management IP or DNS name.' },
        @{ Name='port'; Label='Management/API port'; Type='string'; Required=$true; Default='443'; Placeholder='443'; HelpText='HTTPS management/API port. Default is 443.' },
        @{ Name='username'; Label='Admin username'; Type='string'; Required=$false; Default='bal'; Placeholder='bal'; HelpText='Optional API username. API key is preferred when available.'; Methods=@('api_basic') },
        @{ Name='password'; Label='Admin password'; Type='secret'; Required=$false; Placeholder=''; HelpText='Optional API password. Leave empty when using API key only.'; Methods=@('api_basic') },
        @{ Name='api_key'; Label='API key'; Type='secret'; Required=$false; Placeholder=''; HelpText='Kemp API key. Preferred for scheduled renewal hooks.'; Methods=@('api_key') },
        @{ Name='skip_certificate_check'; Label='Ignore LoadMaster TLS warning'; Type='choice'; Required=$true; Choices=@('false','true'); Default='true'; Placeholder='true'; HelpText='Set true for lab/self-signed LoadMaster management certificates.' },
        @{ Name='virtual_service_ids'; Label='Virtual service IDs'; Type='string'; Required=$false; Placeholder='1'; HelpText='Selected LoadMaster virtual service IDs. Use the Kemp-specific target selection to fill this safely.' },
        @{ Name='certificate_name'; Label='Name in Kemp certificate store'; Type='string'; Required=$false; Placeholder='wildcard_example_com'; HelpText='Certificate object name uploaded to the LoadMaster.' }
    )}


    paloalto = @{ ConnectorType='paloalto'; Label='Palo Alto firewall'; Category='network_appliance'; Fields=@(
        @{ Name='host'; Label='Host'; Type='string'; Required=$true; Placeholder='pa.example.com'; HelpText='Palo Alto management endpoint' }
    )}
    sophos = @{ ConnectorType='sophos'; Label='Sophos firewall'; Category='network_appliance'; SetupMode='guided'; ConnectionMethods=@(@{ Key='api_basic'; Label='Sophos WebAdmin API username and password'; DefaultPort='4444' }); Fields=@(
        @{ Name='host'; Label='Firewall address'; Type='string'; Required=$true; Placeholder='192.168.45.138'; HelpText='IP address or DNS name of the Sophos firewall admin/API page.' },
        @{ Name='port'; Label='Admin/API port'; Type='string'; Required=$true; Default='4444'; Placeholder='4444'; HelpText='Sophos admin/API HTTPS port. Default is 4444.' },
        @{ Name='username'; Label='Admin username'; Type='string'; Required=$true; Default='admin'; Placeholder='admin'; HelpText='Sophos administrator username. Default is admin.' },
        @{ Name='password'; Label='Admin password'; Type='secret'; Required=$false; Placeholder=''; HelpText='Sophos administrator password. Use this field for the normal firewall password.' },
        @{ Name='skip_certificate_check'; Label='Ignore Sophos TLS warning'; Type='choice'; Required=$true; Choices=@('false','true'); Default='false'; Placeholder='false'; HelpText='Set true only if the Sophos admin page uses an untrusted/self-signed certificate.' }
    )}
    custom = @{ ConnectorType='custom'; Label='Custom script'; Category='custom'; Fields=@(
        @{ Name='script_path'; Label='Script path'; Type='string'; Required=$true; Placeholder='Scripts\my-deploy.ps1'; HelpText='Operator-provided deployment script path' },
        @{ Name='script_parameters'; Label='Script parameters'; Type='string'; Required=$false; Placeholder='{CertThumbprint}'; HelpText='WACS script parameters for the custom script' }
    )}

    java_keystore = @{ ConnectorType='java_keystore'; Label='Java KeyStore'; Category='external_dependency'; Disabled=$true; Requires='JDK (keytool.exe)'; Fields=@(
        @{ Name='requires'; Label='Requires'; Type='string'; Required=$false; Placeholder='JDK keytool.exe'; HelpText='Not available in native-only mode.' }
    )}
    kemp_module = @{ ConnectorType='kemp_module'; Label='Kemp (PowerShell module)'; Category='external_dependency'; Disabled=$true; Requires='Kemp.LoadBalancer.Powershell module'; Fields=@(
        @{ Name='requires'; Label='Requires'; Type='string'; Required=$false; Placeholder='Kemp PS module'; HelpText='Not available in native-only mode.' }
    )}
    vbr_cloud_gateway = @{ ConnectorType='vbr_cloud_gateway'; Label='Veeam VBR Cloud Gateway'; Category='external_dependency'; Disabled=$true; Requires='Veeam Backup & Replication PowerShell module'; Fields=@(
        @{ Name='requires'; Label='Requires'; Type='string'; Required=$false; Placeholder='VBR module'; HelpText='Not available in native-only mode.' }
    )}
    azure_ad_app_proxy = @{ ConnectorType='azure_ad_app_proxy'; Label='Azure AD Application Proxy'; Category='external_dependency'; Disabled=$true; Requires='AzureAD module'; Fields=@(
        @{ Name='requires'; Label='Requires'; Type='string'; Required=$false; Placeholder='AzureAD module'; HelpText='Not available in native-only mode.' }
    )}
    azure_application_gateway = @{ ConnectorType='azure_application_gateway'; Label='Azure Application Gateway'; Category='external_dependency'; Disabled=$true; Requires='AzureRM module'; Fields=@(
        @{ Name='requires'; Label='Requires'; Type='string'; Required=$false; Placeholder='AzureRM module'; HelpText='Not available in native-only mode.' }
    )}
    sparx_procloud = @{ ConnectorType='sparx_procloud'; Label='Sparx Pro Cloud'; Category='external_dependency'; Disabled=$true; Requires='PowerShell 7 and external tooling'; Fields=@(
        @{ Name='requires'; Label='Requires'; Type='string'; Required=$false; Placeholder='PowerShell 7'; HelpText='Not available in native-only mode.' }
    )}
}
