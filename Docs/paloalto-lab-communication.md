# Palo Alto PA-VM Lab Communication Notes

Lab target: `https://192.168.45.155/`

Credentials used during validation were supplied interactively for the lab and are not stored in this repository.

## Findings

- TCP 443 is reachable on `192.168.45.155`.
- HTTPS root returns a redirect, which confirms the management web service is listening.
- XML API key generation succeeds at `/api/?type=keygen`.
- XML operational API succeeds for system info:
  - Hostname: `PA-VM`
  - Model: `PA-VM`
  - PAN-OS: `12.1.7`
  - VM mode: `VMware ESXi`
  - Management IP: `192.168.45.155`
- XML operational API succeeds for interface inventory.
- XML config root is readable. The lab config has:
  - `mgt-config`
  - `shared`
  - `devices`
  - device entry `localhost.localdomain`
  - virtual system `vsys1`
  - interface `ethernet1/1`
  - zone `wan`
- XML reads for certificate/profile/binding paths returned `No such node` on the clean lab config until those objects exist.
- REST API responds with JSON for `GET /restapi/v12.1/Network/EthernetInterfaces`.
- REST object and policy inventory requires location parameters. These succeeded:
  - `/restapi/v12.1/Objects/Addresses?location=vsys&vsys=vsys1`
  - `/restapi/v12.1/Policies/SecurityRules?location=vsys&vsys=vsys1`
- REST `System/Info` probes returned HTTP 501. Use XML operational API for system information.
- The lab firewall warned that the latest KeyGen used the deprecated algorithm. Configure the PAN-OS API key certificate with Setup -> Management -> Authentication Settings -> API Key Certificate, or CLI `set deviceconfig setting management api key certificate`.
- On the current lab firewall, the API key certificate XPath `/config/devices/entry[@name='localhost.localdomain']/deviceconfig/setting/management/api/key/certificate` returns `No such node`, which means the stronger API key certificate setting is not configured yet.

## Setup Impact

The Palo Alto device profile must not be host-only. It now needs to capture:

- management host and port
- API key for unattended renewal
- optional username/password for setup-time XML keygen tests
- lab/self-signed TLS bypass preference
- `vsys` for REST inventory and binding discovery
- certificate object name
- binding type and binding target
- REST inventory location
- selected target summary

The communication test should validate XML keygen or API-key auth, XML system info, and a REST inventory probe with `location=vsys&vsys=vsys1` by default.

When the API key certificate is configured, simple-acme does not need to parse or transform the resulting API key. The key is treated as an opaque token and URL-encoded on XML API calls or passed through `X-PAN-KEY` on REST calls. The guided communication test reads the API key certificate XPath and reports whether the stronger key infrastructure is configured.
