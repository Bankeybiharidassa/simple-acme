# Sophos Connector Build Plan

## Objective

Build a production-ready Sophos Firewall connector for certificate upload and assignment to selected Sophos XGS services:

- Web admin console.
- VPN and user portal certificate settings.
- WAF / web server protection rules.

When the operator selects Sophos, the app must ask which service or services should receive the certificate. For WAF, the app must discover existing WAF rules, show each rule's current certificate, and let the operator choose one or more rules to update.

## Source Inputs

- Sophos Firewall 22.0 API documentation.
- Sophos Firewall 21.5 API documentation.
- `sophos/sophos-firewall-sdk`.
- Existing local script: `Scripts/deploy-sophos.ps1`.
- Existing app wiring: `certificate-setup.ps1`, `setup/Menu-Tree.ps1`, `setup/Device-Schemas.ps1`, `setup/Form-Runner.psm1`, `setup/NetScaler-Runner.psm1`.

Key API facts from the docs:

- API access is off by default and must be enabled for allowed IP hosts.
- Requests are XML-based and are sent to `https://<firewall>:<port>/webconsole/APIController`.
- The API uses `<Request>`, `<Login>`, `<Get>`, `<Set operation="add|update">`, and `<Remove>` tags.
- `AdminSettings/WebAdminSettings` includes `HTTPSport`, `UserPortalHTTPSPort`, `VPNPortalHTTPSPort`, and `Certificate`.
- WAF / HTTP-based firewall rules expose `HTTPSCertificate` for the certificate used by the rule.
- Certificate upload supports external certificates including PEM and PKCS12/PFX formats.
- Lab validation on SFOS `22.0.0 GA-Build411` / API `2200.1` showed that `Get <Certificate/>` generates certificate export files on the firewall, but the HTTPS API response body can still be empty.
- The confirmed recovery path for that behavior is SSH into `Device Management > Advanced Shell`, then SCP the generated `/var/API-*.tar` export artifact. This must remain an explicit diagnostics/export recovery path, not the default deployment path.
- The official Python SDK models the API as generic `get_tag`, filtered get, update, and template/XML submit operations. We should mirror that shape in PowerShell rather than hard-coding a narrow one-off flow.

## Product Model Decision

Implement Sophos as a dedicated post-issuance deployment workflow, similar to NetScaler, not as a first-run WACS installation hook.

Reason:

- The operator must inspect live firewall state before choosing WAF rules.
- The target services are not known from the certificate request alone.
- WACS script parameters are not rich enough for interactive WAF discovery.
- This matches the current menu language: Sophos is post-issuance only.

Keep the first-run Sophos option blocked until the post-issuance workflow is implemented.

## User Flow

1. Operator opens `certificate-setup.ps1`.
2. Operator goes to `Deployment targets`.
3. Operator selects `Sophos Firewall`.
4. App asks for connection details:
   - Firewall host or IP.
   - API/admin port, default `4444`.
   - Username.
   - Password or encrypted password file.
   - TLS verification mode.
   - Timeout.
5. App tests authentication and API reachability.
6. App asks for certificate source:
   - Latest simple-acme PFX for the renewal.
   - Explicit PFX path and password.
   - PEM certificate + private key + optional chain.
7. App uploads or updates the certificate object.
8. App asks which Sophos services to bind:
   - Admin portal.
   - VPN/user portal.
   - WAF rules.
9. If WAF is selected:
   - App gets existing WAF / HTTP-based rules.
   - App displays rule name, status, domains, listen port, current `HTTPSCertificate`, and backend summary.
   - Operator selects one or more rules.
10. App runs a WhatIf preview showing:
   - Certificate upload action.
   - Services that will be changed.
   - Previous certificate values.
   - New certificate value.
11. App requires explicit confirmation, for example typing `DEPLOY`.
12. App applies changes.
13. App verifies each selected service now references the new certificate.
14. App writes a structured log without secrets or certificate private material.

## Proposed Files

### New Module

`Scripts/Modules/SimpleAcme.Sophos/SophosFirewallXml.psm1`

Responsibilities:

- Build XML safely.
- Escape XML values.
- Send requests to `/webconsole/APIController`.
- Support `-SkipCertificateCheck` only with explicit warning.
- Parse Sophos response status.
- Detect zero-byte certificate export responses and report the known SFOS `2200.1` behavior.
- Redact secrets and certificate/private-key payloads in logs.
- Expose reusable functions:
  - `Connect-SophosFirewallApi`
  - `Invoke-SophosXmlRequest`
  - `Get-SophosCertificate`
  - `Export-SophosCertificateArchive`
  - `Import-SophosCertificate`
  - `Get-SophosAdminWebSettings`
  - `Set-SophosAdminWebSettingsCertificate`
  - `Get-SophosWafRules`
  - `Set-SophosWafRuleCertificate`
  - `Get-SophosApiExportArtifact`
  - `Copy-SophosApiExportArtifact`
  - `Test-SophosDeploymentVerification`

### New Runner

`setup/Sophos-Runner.psm1`

Responsibilities:

- Provide the TUI workflow.
- Reuse the same preview-then-confirm pattern as `NetScaler-Runner.psm1`.
- Convert form values and selections to connector script/module calls.
- Write JSON and text deployment logs.
- Export:
  - `Invoke-SophosDeploymentForm`
  - `Invoke-SophosDiagnostics`
  - `Invoke-SophosCertificateExportRecovery`
  - `Convert-SophosFormValuesToPlan`
  - `Test-SophosTuiWiring`

### Script Update

`Scripts/deploy-sophos.ps1`

Options:

1. Refactor it to use `SimpleAcme.Sophos`.
2. Keep it as a thin non-interactive wrapper around the module.

Target contract:

- Accept `-Firewall`, `-Port`, `-Username`.
- Accept secret via `-Password`, `-PasswordSecretName`, or `-PasswordSecureFile`.
- Accept certificate input via:
  - `-PfxPath` and `-PfxPassword`
  - or `-CertPath`, `-KeyPath`, and optional `-ChainPath`
- Accept selected services:
  - `-BindAdminPortal`
  - `-BindVpnPortal`
  - `-BindUserPortal`
  - `-WafRuleNames`
- Accept `-WhatIf` / `SupportsShouldProcess`.
- Accept `-SkipCertificateCheck`.
- Accept optional diagnostics-only SSH parameters:
  - `-EnableSshExportRecovery`
  - `-SshPort`, default `22`
  - `-SshUsername`
  - `-SshPasswordSecretName` or `-SshPasswordSecureFile`
  - `-SshHostKeyFingerprint`

### Setup Wiring

Update:

- `certificate-setup.ps1`
- `setup/Menu-Tree.ps1`
- `setup/Device-Schemas.ps1`
- `setup/Connector-Registry.ps1`

Add menu entries:

- `Sophos Firewall - Check what would happen`
- `Sophos Firewall - Install certificate on selected services`
- `Sophos Firewall - Check setup and show diagnostics`
- `Sophos Firewall - Recover certificate export over SSH`

Keep `FirstRunAcmeSupported = $false`.

## API Plan

### Authentication and Transport

Use XML requests with `<Login>` credentials on each request.

Request endpoint:

```text
https://<firewall>:<port>/webconsole/APIController
```

Prefer body or form parameter handling that matches Sophos examples. Avoid placing credentials in URLs.

Preflight checks:

- API access enabled.
- Firewall reachable on configured port.
- Credentials accepted.
- Response has expected `<Response>` and `<Status>` shape.

### Certificate Inventory

Implement the documented certificate export request as a best-effort API path:

```xml
<Get>
  <Certificate></Certificate>
</Get>
```

Use this to:

- Detect whether the target certificate name exists.
- Compare thumbprint/fingerprint if exposed.
- Avoid unnecessary upload when the exact certificate already exists.

Lab finding:

- On the tested SFOS `22.0.0 GA-Build411` / API `2200.1` appliance, this request returned `HTTP 200`, `Content-Type: text/xml`, and `0` response bytes.
- The same request still generated `/var/API-*.tar`, `/var/APIXMLInput/*.xml`, and `/var/APIXMLOutput/*.xml` on the firewall.
- The generated XML output contained certificate metadata, and the generated tar contained `Entities.xml`, `snapversion`, certificate PEM files, and private key files.

Connector rule:

- Do not make HTTP certificate export/listing mandatory for deployment.
- Use the connector-chosen certificate name as the deployment identity after upload.
- Verify service assignment through `AdminSettings` and `FirewallRule` reads.
- If HTTP certificate export is empty, show a diagnostics warning and offer SSH/SCP export recovery only when the operator explicitly opts in.

### SSH/SCP Certificate Export Recovery

Provide an optional diagnostics/export recovery path for appliances where `Get <Certificate/>` creates export artifacts on disk but does not stream the tar over HTTPS.

Confirmed lab path:

1. Connect over SSH to the firewall.
2. Select `5. Device Management`.
3. Select `3. Advanced Shell`.
4. Locate the newest matching `/var/API-*.tar`.
5. Copy it with SCP to a local temporary diagnostics directory.
6. Inspect `Entities.xml` and archive entry names.
7. Delete the local copy unless the operator explicitly asks to preserve it.

Automation requirements:

- Require explicit operator opt-in with clear warning text before using SSH export recovery.
- Require SSH host key pinning. Do not implement a blind host-key accept mode.
- Treat the export archive as highly sensitive because it contains private keys.
- Never log tar contents, PEM content, private keys, archive bytes, or passwords.
- Prefer listing archive entry names over extraction.
- If extracting is required for diagnostics, extract only into a protected temporary directory and clean it up.
- Correlate the export artifact to the API request by timestamp and, where possible, matching `/var/APIXMLInput/*.xml` request content and `/var/APIXMLOutput/*.xml` output content.
- If multiple recent artifacts match, stop and ask the operator to choose instead of guessing.

Design boundary:

- This path is not part of normal certificate deployment.
- This path is diagnostics/recovery only.
- Deployment should still use documented API upload and service binding operations.
- Advanced Shell use may affect vendor support, so the UI must show the Sophos support warning before continuing.

### Certificate Upload

Support PFX first because the local RDS farm/PFX flow already exists.

Implementation requirements:

- PFX password must be supported.
- Password must not be logged.
- If Sophos requires a private-key passphrase length of 30 characters or fewer for some upload modes, validate before upload and explain the limitation.
- PEM mode should avoid `.NET` APIs unavailable in PowerShell 5.1.
- Certificate chain handling must be explicit.

Open question to validate against a real XGS:

- Whether the XML API expects base64 file content in XML fields, multipart/form-data, or a specific certificate import operation for PFX in SFOS 22.0. The current `deploy-sophos.ps1` assumes XML fields named `CertificateFormat`, `CertificateFile`, and `PrivateKeyFile`; this must be verified against the API help page and a lab firewall before exposing production deployment.

### Admin Portal, VPN Portal, User Portal

Use `AdminSettings/WebAdminSettings`.

Plan:

1. Get current settings.
2. Preserve all existing values.
3. Change only the certificate-related field or fields.
4. Send update.
5. Verify by reading settings back.

The docs expose one `Certificate` field under `WebAdminSettings`, plus ports for web admin, user portal, and VPN portal. The build must validate whether Sophos uses one shared certificate for these portals or whether additional version-specific tags exist for independent portal certificates.

UX implication:

- The UI can still ask for admin portal and VPN/user portal separately.
- If the API only supports one shared certificate field for the selected firmware, the preview must say that selecting any of those services updates the shared portal certificate.

### WAF Rules

Use WAF / HTTP-based firewall rule discovery.

Discovery:

```xml
<Get>
  <FirewallRule></FirewallRule>
</Get>
```

Filter in PowerShell to likely WAF rules:

- `PolicyType = HTTPBased`
- or rule has `HTTPSCertificate`
- or rule has WAF/web-server fields such as domains, listen port, backend, or path routing fields.

Display:

- Rule name.
- Enabled/disabled status.
- Domains.
- Listen port.
- Current `HTTPSCertificate`.
- Backend/server summary.

Update:

- Retrieve the full rule XML/object first.
- Preserve existing settings.
- Replace only `HTTPSCertificate`.
- Send `Set operation="update"` for the rule.
- Verify by reading back the selected rules.

Important:

- Do not rebuild WAF rules from a partial schema. The SDK guidance notes update operations often need the existing object first, then a modified payload. Follow that pattern.

## Data Model

Extend Sophos schema to include:

- `host`
- `port`
- `username`
- `password_secret_name` or encrypted password reference
- `skip_certificate_check`
- `certificate_name`
- `certificate_source`
- `pfx_path`
- `pfx_password_ref`
- `cert_path`
- `key_path`
- `chain_path`
- `ssh_export_recovery_enabled`
- `ssh_port`
- `ssh_username`
- `ssh_password_secret_name` or encrypted SSH password reference
- `ssh_host_key_fingerprint`
- `bind_admin_portal`
- `bind_vpn_portal`
- `bind_user_portal`
- `bind_waf`
- `selected_waf_rules`

For interactive selection, do not require `selected_waf_rules` in the initial device schema. Populate it after live discovery.

## Security Requirements

- Never log plaintext credentials.
- Never log PFX password.
- Never log private key, PFX bytes, or raw upload XML.
- Redact certificate payloads in dry-run and error logs.
- Store secrets through existing DPAPI LocalMachine flow or SecretManagement where available.
- Warn loudly when TLS verification is skipped.
- Prefer read-only discovery before any mutation.
- Require explicit confirmation before deployment.
- Store previous binding state in the deployment log for manual rollback.
- Warn before SSH Advanced Shell export recovery because Sophos displays a vendor support warning for Advanced Shell.
- Require pinned SSH host key fingerprint for SCP recovery.
- Treat `/var/API-*.tar` exports as private-key material.

## Rollback Plan

Automatic rollback can be phase 2. Phase 1 must record enough previous state for manual rollback.

For each deployment, log:

- Certificate object name.
- Previous admin/web settings certificate.
- Previous WAF rule certificate per selected rule.
- Changed services.
- Verification result.
- Whether HTTP certificate export returned bytes, returned XML, or returned an empty body.
- Whether SSH/SCP export recovery was offered or used.

Optional later:

- Add `-RollbackFromLog <path>` to restore prior bindings.

## Testing Plan

### Unit Tests

Add tests for:

- XML escaping.
- XML request construction.
- Response status parsing.
- Secret redaction.
- WAF rule detection from mocked API responses.
- Preserving WAF rule fields while changing only `HTTPSCertificate`.
- Admin settings update preserving ports and redirect settings.
- PFX password handling.
- Rejection of unsupported certificate input combinations.
- Empty certificate export response handling.
- SSH export recovery planning without secrets in logs.
- API export artifact correlation by timestamp and XML input/output metadata.

### TUI Tests

Add tests for:

- Sophos menu entries exist.
- `certificate-setup.ps1` dispatches Sophos actions.
- Sophos diagnostics detects missing script/module/schema.
- Sophos form does not write secrets to logs.
- WhatIf runs before deploy.
- Real deployment requires `DEPLOY`.
- SSH export recovery is hidden or blocked unless explicitly enabled.
- SSH export recovery shows support and private-key warnings.

### Integration Tests

Gate behind environment variables:

- `SOPHOS_HOST`
- `SOPHOS_PORT`
- `SOPHOS_USERNAME`
- `SOPHOS_PASSWORD`
- `SOPHOS_TEST_CERT_PFX`
- `SOPHOS_TEST_CERT_PASSWORD`
- `SOPHOS_TEST_SSH_USERNAME`
- `SOPHOS_TEST_SSH_PASSWORD`
- `SOPHOS_TEST_SSH_HOSTKEY`

Integration tests should:

- Log in.
- Attempt certificate inventory/export over HTTPS and accept the known zero-byte response as a diagnostic outcome, not a hard failure.
- List WAF rules.
- Upload a test certificate with a unique prefix.
- Bind to a test WAF rule only when `SOPHOS_TEST_WAF_RULE` is set.
- Restore previous binding.
- When SSH test variables are present, call certificate export, locate the matching `/var/API-*.tar`, copy it over SCP, list archive entries, and delete the local copy.

## Delivery Milestones

### Milestone 1: Discovery and Diagnostics

- Add `SimpleAcme.Sophos` module.
- Implement login, generic get/set, response parser, redaction.
- Add Sophos diagnostics menu action.
- Add WAF rule discovery and display.
- Add HTTP certificate export diagnostics, including zero-byte response detection.
- No mutations yet except login test.

### Milestone 1b: SSH Export Recovery Diagnostics

- Add SSH host-key fingerprint capture instructions.
- Add optional SSH/SCP export recovery flow behind explicit opt-in.
- Add artifact correlation for `/var/API-*.tar`, `/var/APIXMLInput/*.xml`, and `/var/APIXMLOutput/*.xml`.
- Add tests proving no private key material is logged.
- Keep this separate from normal deployment.

### Milestone 2: Certificate Upload

- Implement PFX upload with password support.
- Implement PEM upload only if PowerShell 5.1-compatible.
- Add idempotency where certificate metadata is available; otherwise use deterministic connector certificate naming and service binding verification.
- Add unit tests and mocked response fixtures.

### Milestone 3: Service Binding

- Implement admin/web settings binding.
- Implement WAF rule binding with live rule selection.
- Add preview-first TUI flow.
- Add verification reads.

### Milestone 4: Hardening

- Add rollback log.
- Add diagnostics coverage.
- Update registry wording.
- Update README/install docs.
- Add integration-test documentation.

## Acceptance Criteria

- Sophos appears in Deployment targets with preview, deploy, and diagnostics actions.
- Selecting Sophos first asks which services should be updated.
- WAF selection lists existing rules and current certificates.
- Operator can select multiple WAF rules.
- Deployment uploads the certificate and binds only selected services.
- Preview shows exact planned changes without secrets.
- Real deployment requires explicit confirmation.
- Verification confirms selected services reference the new certificate.
- Empty HTTP certificate export responses are reported clearly and do not block upload/bind deployment.
- Optional SSH export recovery can copy and list a generated Sophos export tar without logging or persisting private key material.
- No secret or private-key material appears in logs.
- All code parses under Windows PowerShell 5.1.

## Open Questions

- Which exact XML certificate upload payload is supported for PFX in SFOS 21.5 and 22.0?
- Does SFOS expose separate certificate fields for admin portal, VPN portal, and user portal in current API versions, or are they controlled by a shared `WebAdminSettings/Certificate` field?
- What is the exact XML shape returned for WAF rules on XGS 21.5 and 22.0?
- Does binding a new certificate to admin/web settings restart or interrupt any management/portal service?
- Does WAF rule update require additional commit/apply semantics, or is the XML update immediately active?
- Is the zero-byte HTTP certificate export response fixed in later SFOS/API builds?
- Is there a supported non-Advanced-Shell way to retrieve generated `/var/API-*.tar` artifacts when the web controller fails to stream them?

## References

- Sophos Firewall 22.0 API access documentation: https://docs.sophos.com/nsg/sophos-firewall/22.0/Help/en-us/webhelp/onlinehelp/AdministratorHelp/Administration/API/
- Sophos Firewall 21.5 API configuration: https://docs.sophos.com/nsg/sophos-firewall/21.5/help/en-us/webhelp/onlinehelp/AdministratorHelp/BackupAndFirmware/API/APIConfiguration/
- Sophos Firewall 21.5 API payload and XML tags: https://docs.sophos.com/nsg/sophos-firewall/21.5/Help/en-us/webhelp/onlinehelp/AdministratorHelp/BackupAndFirmware/API/APIXMLTags/
- Sophos Firewall 22.0 certificate API entity: https://docs.sophos.com/nsg/sophos-firewall/22.0/api/SYSTEM/Certificates/Certificate/certificate.html
- Sophos Firewall 22.0 WAF/firewall rule API reference: https://docs.sophos.com/nsg/sophos-firewall/22.0/api/PROTECT/Firewall/SecurityPolicy/operations/addfirewallrule%26editfirewallrule.html
- Sophos Firewall admin web settings API reference: https://docs.sophos.com/nsg/sophos-firewall/21.0/api/system/administration/adminsettings/operations/webadminsettings.html
- Sophos Firewall SDK: https://github.com/sophos/sophos-firewall-sdk
- Lab bug report and SSH workaround notes: `Docs/audit/sophos-certificate-export-bugreport.md`
