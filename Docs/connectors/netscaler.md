# NetScaler / Citrix ADC deployment connector

## Architecture

`simple-acme` remains the ACME owner. It performs issuance, renewal lifecycle management, and ARI-aware renewal decisions. NetScaler / Citrix ADC is only a deployment target for certificate material that `simple-acme` has already obtained.

This connector does **not** implement ACME issuance on NetScaler and does **not** use NetScaler Console or `acme.sh` as the primary ACME flow. NetScaler-native ACME and NetScaler Console workflows exist in the product ecosystem, but they are separate from this connector by design.

## Public source verification

The NITRO resources used by this connector are mapped in [`netscaler-source-map.json`](netscaler-source-map.json). The map records the endpoint/resource, implementation function, source URL, confidence, and remaining notes for:

- login / logout
- `systemfile` upload
- `sslcertkey` add and cert/key change
- `sslvserver_sslcertkey_binding` read/add/delete
- `hanode` statistics
- `nsconfig` save
- `hasync`

No live NetScaler validation was available when this connector was implemented. The production logic is based on official public NITRO documentation, and integration tests are opt-in for operators who have a real appliance.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 where practical.
- Network access from the runner to the NetScaler NSIP / management endpoint.
- A NetScaler account with permission to:
  - log in through NITRO,
  - upload files to `/nsconfig/ssl/` through `systemfile`,
  - read/add/change `sslcertkey`,
  - read/add/delete SSL vServer certkey bindings,
  - read `hanode` statistics,
  - save configuration with `nsconfig?action=save`,
  - run `hasync` when HA sync is enabled.
- PEM certificate and PEM private key files already produced by the `simple-acme` issuance flow.

## Secret handling

Use `-Password` with a `SecureString` or `-PasswordSecretName`. `-PasswordSecretName` uses Microsoft SecretManagement `Get-Secret` when available. If SecretManagement is not installed, it falls back to an environment variable named from the secret, for example `netscaler-adc01` becomes `SIMPLE_ACME_SECRET_NETSCALER_ADC01`.

The connector does not introduce a new `.env` model and does not log password or private-key material.

## HA behavior

Defaults are conservative:

- HA detection is enabled.
- Primary-node enforcement is enabled.
- If HA is not configured, deployment continues normally.
- If HA is configured and the local node reports `PRIMARY`, deployment continues.
- If HA is configured and the local node is not `PRIMARY`, deployment aborts by default.

HA is detected from `GET /nitro/v1/stat/hanode`, specifically the documented `hacurstatus` and `hacurmasterstate` fields. The connector does not infer HA state from hostnames.

`-NoDetectHA` disables HA detection. `-RequirePrimary:$false` disables the primary-node gate, but this should be used only with a deliberate operator reason.

## File upload

The connector validates all local files before any mutating API call. It uploads the certificate, private key, and optional chain file to `/nsconfig/ssl/` with the documented `systemfile` resource using base64 `filecontent` and `fileencoding = BASE64`.

The upload path uses `POST /nitro/v1/config/systemfile?override=yes`. The official `systemfile` documentation describes the `override` query parameter, but operators should live-test overwrite behavior on their target firmware before first production use.

## sslcertkey management

`CertKeyName` is always explicit. The connector first queries the requested `sslcertkey`:

- Missing certkey: add `sslcertkey` with `certkey`, `cert`, `key`, and `inform = PEM`.
- Existing certkey: use the documented `sslcertkey?action=update` change operation to point the certkey at the uploaded certificate/key material.

Optional chain support is implemented by passing `cacert` when `-ChainPath` is supplied. Key-password support is available through `-KeyPassword` as a `SecureString`; the plaintext is materialized only for JSON payload creation and is cleared from the local payload hashtable after the request path completes.

## SSL vServer binding behavior

The connector uses `sslvserver_sslcertkey_binding`, which is reliable for querying all certificate bindings on one SSL vServer before modifying anything.

Behavior:

- Query existing bindings first.
- If `CertKeyName` is already bound, do not duplicate it.
- If missing, bind `CertKeyName` to `VServerName`.
- `-ReplaceExistingServerCertificate` optionally removes old server certificate bindings before binding the new certkey.

Replacement safety rules:

- CA bindings are preserved when documented `ca` metadata indicates a CA binding.
- SNI bindings are preserved when documented `snicert` metadata indicates an SNI binding.
- Replacement is not the default.

The old `-ReplaceServerCertificate` parameter name is accepted as an alias for compatibility.

## Save and HA sync

`-SaveConfig` defaults to enabled. The connector saves only after upload, sslcertkey management, vServer binding, and verification have succeeded.

`-SyncHA` defaults to enabled, but sync is attempted only when HA is detected. The `hasync` payload defaults to:

```json
{
  "hasync": {
    "save": "YES",
    "force": "NO"
  }
}
```

`force` is set to `YES` only when the operator explicitly supplies `-SyncHAForce`.

Use `-NoSaveConfig` or `-NoSyncHA` to suppress those actions.

## Example usage

```powershell
.\Scripts\cert2netscaler.ps1 `
  -NetScalerHost 'adc01.example.local' `
  -Username 'svc-simple-acme' `
  -PasswordSecretName 'netscaler-adc01' `
  -CertKeyName 'wildcard_example_com_2026' `
  -CertPath 'C:\certs\wildcard.crt' `
  -KeyPath 'C:\certs\wildcard.key' `
  -ChainPath 'C:\certs\chain.crt' `
  -VServerName 'ssl_vsrv_gateway' `
  -DetectHA `
  -RequirePrimary `
  -SyncHA `
  -SaveConfig `
  -WhatIf
```

Remove `-WhatIf` after reviewing the planned actions.

Lab/bootstrap-only options:

```powershell
.\Scripts\cert2netscaler.ps1 `
  -NetScalerHost 'adc01.example.local' `
  -UseHttp `
  -SkipCertificateCheck `
  -Username 'svc-simple-acme' `
  -Password (Read-Host -Prompt 'NetScaler password' -AsSecureString) `
  -CertKeyName 'wildcard_example_com_2026' `
  -CertPath 'C:\certs\wildcard.crt' `
  -KeyPath 'C:\certs\wildcard.key' `
  -VServerName 'ssl_vsrv_gateway'
```

Prefer HTTPS with a trusted management certificate in production.

## Return object

The script returns:

```powershell
[pscustomobject]@{
    Host               = '<target host>'
    CertKeyName        = '<certkey name>'
    VServerName        = '<SSL vServer>'
    HAConfigured       = $true_or_false
    HAMasterState      = '<PRIMARY|SECONDARY|...>'
    Saved              = $true_or_false
    HASynced           = $true_or_false
    Changed            = $true_or_false
    VerificationStatus = 'Passed|Failed|Partial|NotRun'
}
```

## Rollback

The connector does not guess rollback targets. To roll back safely:

1. Identify the previously known-good certkey and certificate/key files.
2. Re-run the connector with that previous certificate material and certkey name, or manually bind the previous certkey in NetScaler.
3. Verify the SSL vServer binding.
4. Save configuration.
5. Sync HA if applicable.

If `-ReplaceExistingServerCertificate` was not used, previous server certificate bindings remain available for manual recovery.

## Troubleshooting

- **Login fails:** verify NITRO access, management endpoint, account permissions, and whether HTTPS certificate trust requires `-SkipCertificateCheck` for a lab.
- **HA aborts:** connect to the node reporting `PRIMARY`, or intentionally run with `-RequirePrimary:$false` only if your change plan allows it.
- **File upload fails:** verify permissions for `systemfile` and available space under `/nsconfig/ssl/`.
- **sslcertkey update fails:** verify the certificate and key match, the filenames exist under `/nsconfig/ssl/`, and encrypted-key handling is compatible with the target firmware.
- **Binding replacement does not remove an old cert:** inspect binding metadata; CA and SNI bindings are intentionally preserved.
- **Configuration disappears after reboot:** ensure `SaveConfig` was not disabled and review `nsconfig?action=save` permissions.

## Known limitations

- No live-device validation was performed in this environment.
- The connector handles PEM certificate/key deployment only.
- It does not issue certificates and does not manage ACME accounts, orders, ARI, or DNS challenges on NetScaler.
- `systemfile` overwrite behavior and binding metadata casing should be confirmed on the target firmware before first production rollout.
- Integration tests are disabled by default and require explicit `NETSCALER_*` variables.
