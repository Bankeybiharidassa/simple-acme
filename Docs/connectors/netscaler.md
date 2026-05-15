# NetScaler / Citrix ADC deployment connector

## Architecture

`simple-acme` owns the ACME account, issuance, renewal, and ARI lifecycle. NetScaler / Citrix ADC is a deployment target only: this connector uploads certificate material that `simple-acme` already obtained and then updates the ADC NITRO configuration.

The connector deliberately does **not** implement ACME issuance on NetScaler, does **not** use NetScaler Console as the primary flow, and does **not** call `acme.sh` on the appliance.

## Public NITRO source map

NITRO resources are tracked in [`netscaler-source-map.json`](netscaler-source-map.json). Every endpoint used by the module is mapped to an implementation function, source URL, confidence level, and notes. The unit tests parse this JSON and check that code-used resources have source-map coverage.

No live NetScaler appliance was available in this environment, so `LiveNetScalerValidated` remains `false` and integration tests are opt-in only.

## Requirements and permissions

Supported runtime: Windows PowerShell 5.1 or PowerShell 7.

Required ADC permissions:

- `login` / `logout` NITRO session access.
- `systemfile` upload to `/nsconfig/ssl/`.
- Read/add/update `sslcertkey`.
- Read/add/delete `sslvserver_sslcertkey_binding` for the target SSL vServer.
- Read `hanode` statistics when HA detection is enabled.
- `nsconfig?action=save` when saving is enabled.
- `hasync?action=Force` when HA sync is enabled.

Supported certificate inputs are PEM certificate, PEM private key, and optional PEM chain files. PFX conversion and ACME issuance are outside this connector.

## Runtime flow

Normal execution follows this order:

1. Validate parameters and local certificate/key/chain paths.
2. Resolve the NetScaler password from `SecureString`, SecretManagement, or the documented environment fallback.
3. Connect to NITRO.
4. Detect HA and fail safe if primary-node enforcement is enabled.
5. Read current `sslcertkey` and SSL vServer binding state.
6. Upload certificate/key/chain files to `/nsconfig/ssl/`.
7. Create or update the `sslcertkey`.
8. Bind the requested certkey to the SSL vServer, optionally replacing safe old server cert bindings.
9. Verify certkey and binding state.
10. Save configuration only after verification passes.
11. Sync HA only after verification passes and HA is configured.
12. Run final verification after save/sync when either occurred.
13. Logout in `finally`.
14. Return a structured result.

The script does not save configuration if deployment verification fails.

## `-WhatIf` behavior

`-WhatIf` is **connected planning**:

- The script still validates local files.
- The script still resolves credentials and logs in so safe read-only checks can run.
- HA detection and current certkey/binding reads still run.
- Mutating functions receive `-WhatIf` and emit PowerShell WhatIf messages.
- No mutating NITRO calls are made for `systemfile`, `sslcertkey` changes, binding changes, save, or HA sync.
- Verification is reported as `Planned`, not `Passed`, because the appliance was not changed.

Use `-WhatIf` to preview intended operations and HA/read-only state; remove it only after reviewing the planned actions.

## HA behavior

Defaults are conservative: HA detection and `RequirePrimary` are enabled. If HA is not configured, deployment continues. If HA is configured and exactly one node reports `PRIMARY`, deployment continues. If the node is `SECONDARY`, state is unknown, or multiple records make the primary state ambiguous, the connector fails safe when `RequirePrimary` is true.

Use `-NoDetectHA` only when you intentionally cannot query HA. Use `-RequirePrimary:$false` only with an explicit change-control reason.

## Binding replacement behavior

The connector reads `sslvserver_sslcertkey_binding` before modifying bindings.

- Existing requested certkey binding is not duplicated.
- Missing requested binding is added once.
- `-ReplaceExistingServerCertificate` removes only bindings whose metadata explicitly identifies them as non-CA and non-SNI server certificate bindings.
- CA bindings are preserved.
- SNI bindings are preserved.
- Missing CA/SNI metadata is treated conservatively and preserved.

The compatibility alias `-ReplaceServerCertificate` maps to `-ReplaceExistingServerCertificate`.

## Secret and key-password handling

The NetScaler login password can be provided with `-Password` as `SecureString` or with `-PasswordSecretName`. SecretManagement is used when available; otherwise the fallback environment variable is `SIMPLE_ACME_SECRET_<NAME>` with non-alphanumeric characters converted to underscores and upper-cased.

`-KeyPassword` accepts a `SecureString`. The plaintext must briefly exist as a PowerShell string for JSON serialization to NITRO and cannot be securely erased because .NET strings are immutable; the connector avoids logging it and clears the local payload hashtable entry in `finally` after the request path.

## TLS certificate validation option

`-SkipCertificateCheck` changes the process-global `[Net.ServicePointManager]::ServerCertificateValidationCallback` while a request runs and restores the previous callback in `finally`. This is for lab/bootstrap use only. Production should use HTTPS with a trusted management certificate.

## Return object

The script returns the existing compatibility fields plus planning metadata:

```powershell
Host, CertKeyName, VServerName, HAConfigured, HAMasterState,
Saved, HASynced, Changed, VerificationStatus,
Mode, PlannedActions, ExecutedActions, SkippedActions, Warnings,
SourceMapVersion, LiveNetScalerValidated
```

`Mode` is `Execute` or `WhatIfConnected`. `VerificationStatus` is `Passed`, `Failed`, `Partial`, `NotRun`, or `Planned`.

## Testing

Run parser checks:

```powershell
$files = @(
  'Scripts/cert2netscaler.ps1',
  'Scripts/Modules/SimpleAcme.Netscaler/NetscalerNitro.psm1',
  'Scripts/Modules/SimpleAcme.Netscaler/SimpleAcme.Netscaler.psd1'
)
foreach ($f in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -gt 0) { throw $errors }
}
```

Run unit tests:

```powershell
Import-Module Pester
Invoke-Pester -Path Tests/Netscaler -Output Detailed
```

Live integration tests are skipped unless all of these variables are set:

- `NETSCALER_HOST`
- `NETSCALER_USER`
- `NETSCALER_PASSWORD`
- `NETSCALER_TEST_VSERVER`

They must not be counted as live validation unless they actually run against an appliance.

## Known limitations

- No live NetScaler validation was performed in this environment.
- PEM certificate/key deployment only.
- No ACME account/order/challenge/ARI lifecycle on NetScaler.
- NITRO behavior can vary by firmware; first production rollout should be manually validated on the target version.
- `-SkipCertificateCheck` is process-global during each web request despite reliable restoration.
