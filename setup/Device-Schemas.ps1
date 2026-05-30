Set-StrictMode -Version Latest

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
    kemp = @{ ConnectorType='kemp'; Label='Kemp LoadMaster'; Category='network_appliance'; Fields=@(
        @{ Name='host'; Label='Host'; Type='string'; Required=$true; Placeholder='kemp.example.com'; HelpText='Kemp LoadMaster host' },
        @{ Name='user_env'; Label='User env-var name'; Type='string'; Required=$true; Placeholder='KEMP_USER'; HelpText='Environment variable name for API username' },
        @{ Name='password_env'; Label='Password env-var name'; Type='string'; Required=$true; Placeholder='KEMP_PASSWORD'; HelpText='Environment variable name for API password' },
        @{ Name='vs_id'; Label='Virtual service ID'; Type='string'; Required=$true; Placeholder='1'; HelpText='LoadMaster virtual service id' }
    )}


    paloalto = @{ ConnectorType='paloalto'; Label='Palo Alto firewall'; Category='network_appliance'; Fields=@(
        @{ Name='host'; Label='Host'; Type='string'; Required=$true; Placeholder='pa.example.com'; HelpText='Palo Alto management endpoint' }
    )}
    sophos = @{ ConnectorType='sophos'; Label='Sophos firewall'; Category='network_appliance'; Fields=@(
        @{ Name='host'; Label='Management hostname or IP'; Type='string'; Required=$true; Placeholder='sophos.example.com'; HelpText='Sophos Firewall management endpoint' },
        @{ Name='port'; Label='API/admin port'; Type='string'; Required=$true; Placeholder='4444'; HelpText='Sophos XML API/admin port' },
        @{ Name='username'; Label='API username'; Type='string'; Required=$true; Placeholder='admin'; HelpText='Sophos API username' },
        @{ Name='password_secret_name'; Label='Password secret name'; Type='string'; Required=$true; Placeholder='SOPHOS_PASSWORD'; HelpText='Secret/environment name used to resolve the Sophos API password' },
        @{ Name='certificate_name'; Label='Certificate object name'; Type='string'; Required=$true; Placeholder='wildcard-example-com'; HelpText='Sophos certificate object name to upload or update' },
        @{ Name='pfx_path'; Label='PFX path'; Type='string'; Required=$false; Placeholder='C:\certs\wildcard.pfx'; HelpText='Optional PFX certificate path' },
        @{ Name='cert_path'; Label='PEM certificate path'; Type='string'; Required=$false; Placeholder='C:\certs\fullchain.pem'; HelpText='PEM certificate path when not using PFX' },
        @{ Name='key_path'; Label='PEM private key path'; Type='string'; Required=$false; Placeholder='C:\certs\privkey.pem'; HelpText='PEM private key path when not using PFX' },
        @{ Name='chain_path'; Label='PEM chain path'; Type='string'; Required=$false; Placeholder=''; HelpText='Optional chain path' },
        @{ Name='bind_admin_portal'; Label='Bind admin portal'; Type='choice'; Required=$true; Choices=@('true','false'); Placeholder='true'; HelpText='Bind WebAdminSettings/Certificate' },
        @{ Name='bind_vpn_portal'; Label='Bind VPN portal'; Type='choice'; Required=$true; Choices=@('false','true'); Placeholder='false'; HelpText='On tested SFOS this shares WebAdminSettings/Certificate' },
        @{ Name='bind_user_portal'; Label='Bind user portal'; Type='choice'; Required=$true; Choices=@('false','true'); Placeholder='false'; HelpText='On tested SFOS this shares WebAdminSettings/Certificate' },
        @{ Name='bind_waf'; Label='Bind WAF rules'; Type='choice'; Required=$true; Choices=@('false','true'); Placeholder='false'; HelpText='Set true and provide WAF rule names' },
        @{ Name='waf_rule_names'; Label='WAF rule names'; Type='string'; Required=$false; Placeholder='rdgw,public-web'; HelpText='Comma-separated WAF/HTTPBased rule names' },
        @{ Name='skip_certificate_check'; Label='Skip TLS certificate check'; Type='choice'; Required=$true; Choices=@('false','true'); Placeholder='false'; HelpText='Skip validation for the Sophos management endpoint certificate' },
        @{ Name='enable_ssh_export_recovery'; Label='Enable SSH export recovery'; Type='choice'; Required=$true; Choices=@('false','true'); Placeholder='false'; HelpText='Diagnostics-only fallback when API certificate export returns an empty body' },
        @{ Name='ssh_username'; Label='SSH username'; Type='string'; Required=$false; Placeholder='admin'; HelpText='SSH user for diagnostics-only export recovery' },
        @{ Name='ssh_port'; Label='SSH port'; Type='string'; Required=$false; Placeholder='22'; HelpText='SSH port for diagnostics-only export recovery' },
        @{ Name='ssh_password_secret_name'; Label='SSH password secret name'; Type='string'; Required=$false; Placeholder='SOPHOS_SSH_PASSWORD'; HelpText='Optional SSH password secret name. Leave empty when using an SSH key.' },
        @{ Name='ssh_private_key_path'; Label='SSH private key path'; Type='string'; Required=$false; Placeholder='C:\keys\sophos.ppk'; HelpText='Optional PuTTY private key for SSH/SCP recovery' },
        @{ Name='ssh_host_key_fingerprint'; Label='SSH host key fingerprint'; Type='string'; Required=$false; Placeholder='SHA256:...'; HelpText='Required when SSH export recovery is enabled' },
        @{ Name='export_recovery_path'; Label='Export recovery output path'; Type='string'; Required=$false; Placeholder='C:\temp\sophos-export.tar'; HelpText='Temporary diagnostics output path for recovered export archive' }
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
