# NetScaler (Citrix ADC) deployment connector

The NetScaler connector deploys certificates that were already issued by the `simple-acme` / `win-acme` lifecycle. It does **not** request, renew, or schedule ACME certificates on the appliance. NetScaler is treated only as a deployment target that receives PEM files over the NITRO API.

```text
simple-acme / win-acme
        ↓
certificate issuance and renewal, including ARI
        ↓
export certificate, private key, and optional chain as PEM files
        ↓
Scripts/cert2netscaler.ps1
        ↓
NetScaler NITRO API
        ↓
sslcertkey create/update and SSL vServer binding
        ↓
optional save config and HA synchronization
```

## Files

- `Scripts/cert2netscaler.ps1` is the command-line connector entry point.
- `Scripts/Modules/SimpleAcme.Netscaler/NetscalerNitro.psm1` contains the NITRO session, request, HA, upload, certkey, binding, save, sync, and verification helpers.
- `Scripts/Modules/SimpleAcme.Netscaler/SimpleAcme.Netscaler.psd1` is the module manifest.
- `Tests/Netscaler/*.Tests.ps1` contains unit and opt-in integration coverage.

## Prerequisites

- PowerShell 5.1 or newer.
- Network access from the deployment host to `https://<NetScalerHost>/nitro/v1`.
- PEM certificate and key files on the deployment host.
- An optional PEM chain file if your deployment needs a separate CA chain object.
- A NetScaler account that can use NITRO.

## Required NetScaler permissions

Use the least-privileged NetScaler command policy that can perform these operations:

- Login and logout through NITRO.
- Read `hanode`, `sslcertkey`, and `sslvserver_sslcertkey_binding` objects.
- Upload files to `/nsconfig/ssl/` through `systemfile`.
- Add or update `sslcertkey` objects.
- Bind and, only when requested, unbind SSL vServer certificate bindings.
- Save configuration with `nsconfig?action=save` when `-SaveConfig` is enabled.
- Trigger `hasync` when `-SyncHA` is enabled and HA is configured.

## HA behavior

`-DetectHA` defaults to `$true`. The connector queries `/nitro/v1/stat/hanode` and records whether HA appears to be configured and the current master state.

`-RequirePrimary` defaults to `$true`. If HA is detected and the current node is not `PRIMARY`, the connector stops before uploading or binding certificate material. This prevents certificate changes from being made on a secondary appliance by accident.

`-SyncHA` defaults to `$true`. After a successful changed deployment on an HA pair, the connector posts to `/nitro/v1/config/hasync` with `save=YES` and `force=NO`. Use `-SyncHAForce` only when your operational procedure explicitly requires a forced sync.

## Certificate deployment behavior

Before any NITRO API call, the connector validates that `-CertPath`, `-KeyPath`, and optional `-ChainPath` exist as local files. This fail-fast behavior avoids logging in to the appliance when the certificate artifacts are incomplete.

The connector uploads files to `/nsconfig/ssl/` using the NITRO `systemfile` resource with base64 file content. It then checks for the requested `sslcertkey` name:

- If the `sslcertkey` does not exist, it is created.
- If it exists, it is updated in place.
- No other `sslcertkey` names are modified.

## Binding behavior

The connector reads existing certificate bindings for the target SSL vServer before making changes. If the requested certkey is already bound, no duplicate binding is created.

By default, existing server, CA, and SNI bindings are preserved. If `-ReplaceServerCertificate` is specified, only non-CA and non-SNI server certificate bindings are removed before the new certkey is bound. CA and SNI bindings are intentionally left in place.

## Save config

`-SaveConfig` defaults to `$true`, but the connector saves only after all deployment and verification steps have succeeded and at least one change was attempted. This avoids persisting partial or failed deployments.

## Verification result

The script returns a structured object:

```powershell
Host
CertKeyName
VServerName
HAConfigured
HAMasterState
Saved
HASynced
Changed
VerificationStatus
```

`VerificationStatus` is `Verified` only when the certkey exists and the SSL vServer binding points to the requested certkey.

## Example usage

```powershell
$securePassword = Read-Host -Prompt 'NetScaler password' -AsSecureString

.\Scripts\cert2netscaler.ps1 `
  -NetScalerHost 'adc01.example.local' `
  -Username 'svc-simple-acme' `
  -Password $securePassword `
  -CertKeyName 'wildcard_example_com_2026' `
  -CertPath 'C:\certs\wildcard.crt' `
  -KeyPath 'C:\certs\wildcard.key' `
  -ChainPath 'C:\certs\chain.crt' `
  -VServerName 'ssl_vsrv_gateway' `
  -DetectHA $true `
  -RequirePrimary $true `
  -SyncHA $true `
  -SaveConfig $true `
  -WhatIf
```

Remove `-WhatIf` after reviewing the planned changes.

You can also use SecretManagement when available:

```powershell
.\Scripts\cert2netscaler.ps1 `
  -NetScalerHost 'adc01.example.local' `
  -Username 'svc-simple-acme' `
  -PasswordSecretName 'netscaler-adc01' `
  -CertKeyName 'wildcard_example_com_2026' `
  -CertPath 'C:\certs\wildcard.crt' `
  -KeyPath 'C:\certs\wildcard.key' `
  -VServerName 'ssl_vsrv_gateway'
```

If SecretManagement is not installed, `-PasswordSecretName netscaler-adc01` falls back to an environment variable named `SIMPLE_ACME_SECRET_NETSCALER_ADC01`. This is a compatibility fallback, not a new `.env` model.

## Rollback

The connector does not guess rollback targets. To roll back safely:

1. Identify the previously known-good `sslcertkey` name.
2. Re-run the connector with that previous certificate/key pair and certkey name, or manually bind the previous certkey in NetScaler.
3. Verify the SSL vServer binding.
4. Save configuration.
5. Sync HA if applicable.

If `-ReplaceServerCertificate` was not used, previous server certificate bindings are preserved and can be restored by rebinding the desired certkey.

## Limitations and assumptions

- This connector intentionally does not implement ACME issuance, renewal, ARI handling, NetScaler Console workflows, or `acme.sh` integration.
- NITRO upload is implemented through the `systemfile` resource and writes to `/nsconfig/ssl/`.
- Binding replacement relies on NetScaler binding metadata fields commonly exposed as `ca` and `snicert`; CA and SNI bindings are preserved when those fields indicate such bindings.
- The script supports `-SkipCertificateCheck` for lab or bootstrap scenarios, but production deployments should use trusted appliance certificates.
- The integration test is disabled by default and runs only when all required `NETSCALER_*` environment variables are set.
