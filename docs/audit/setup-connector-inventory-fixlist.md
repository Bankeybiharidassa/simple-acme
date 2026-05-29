# Certificate Setup Connector Inventory and Fix List

## Scope

This inventory traces the setup and deployment wiring from the main entry points:

- `certificate-setup.ps1`
- `certificate-simple-acme-reconcile.ps1`
- `setup/Connector-Registry.ps1`
- `setup/Menu-Tree.ps1`
- `setup/Form-Runner.psm1`
- `setup/NetScaler-Runner.psm1`
- `core/Simple-Acme-Reconciler.psm1`
- `core/Fanout-Runner.psm1`
- `Scripts/*.ps1`
- `connectors/*.psm1`

The goal is to separate connectors that are actually reachable from the app from entries that are only listed, packaged, or partially implemented.

## Conclusions

The project currently has two deployment models:

1. Phase 1 WACS script installation, driven by `ACME_SCRIPT_PATH` and `ACME_SCRIPT_PARAMETERS`.
2. Phase 2 orchestrator fanout, driven by `policies.json` and `connectors/*.psm1`.

Those two models are not unified yet. Some connector registry entries point to `Scripts/*.ps1`, while the orchestrator expects `connectors/<connector-type>.psm1`. A connector can therefore be "registered" and "packaged" without being reachable from the main TUI or runnable through the orchestrator.

RDS and RDS farm are the most complete paths. NetScaler has a dedicated post-issuance TUI workflow. Sophos and Palo Alto are currently listed and packaged, but do not have complete main-app wiring.

## Connected

### Main Setup App

`certificate-setup.ps1` imports and checks the required setup modules, then dispatches menu actions from `setup/Menu-Tree.ps1`.

Connected actions:

- `setup-new` -> `Invoke-AcmeForm`
- `manage-certs` -> `Invoke-ManageCertificatesMenu`
- `acme` -> `Invoke-AcmeSettingsMenu`
- `logs-diagnostics` -> `Invoke-ViewLogsDiagnostics`
- `acme-tui-diagnostics` -> `Invoke-AcmeTuiDiagnostics`
- `netscaler-whatif` -> `Invoke-NetScalerDeploymentForm -WhatIfMode`
- `netscaler-deploy` -> `Invoke-NetScalerDeploymentForm`
- `netscaler-diagnostics` -> `Invoke-NetScalerDiagnostics`
- `policies` -> `Invoke-PolicyEditor`
- `policies-view` -> `Invoke-PolicyViewer`
- `task-register` -> `Invoke-OrchestratorTaskRegistration`
- backup and restore actions

### First-Run WACS Targets

These targets are reachable from `Invoke-AcmeForm` and can produce a WACS command line through `Get-WacsIssueArguments`.

| Target | Status | Script or installation path |
| --- | --- | --- |
| `iis` | Connected | Uses WACS native IIS installation, no script parameters |
| `rds` | Connected | `Scripts/cert2rds.ps1` with `{CertThumbprint}` |
| `rds-farm` | Connected | `Scripts/deploy-rds-farm.ps1` with thumbprint/cache/config parameters |
| `mail` | Connected as generic hook | `Scripts/cert2mail.ps1` |
| `firewall` | Connected as generic hook | `Scripts/cert2fw.ps1` |
| `waf` | Connected as generic hook | `Scripts/cert2waf.ps1` |
| `custom` | Connected | Operator-provided script path and parameters |

### RDS Single Server

`rds` is wired from the registry to setup and reconcile:

- Registry entry: `rds` -> `Scripts/cert2rds.ps1`
- Setup target selection supports `rds`.
- WACS script parameters are `{CertThumbprint}`.
- `Scripts/cert2rds.ps1` validates the thumbprint, normalizes the certificate into `LocalMachine\My`, and calls `Set-RDCertificate` for the RDS roles.

### RDS Farm

`rds-farm` is connected end to end for first-run issuance and post-issuance fanout to session hosts:

- Registry entry: `rds-farm` -> `Scripts/deploy-rds-farm.ps1`
- Setup target selection supports `rds-farm`.
- Setup collects session hosts and optional remote username.
- Setup writes `deployment-targets.json`.
- Setup writes `runtime/deployment/rds-farm.env`.
- Setup sets:
  - `ACME_STORE_PLUGIN=pfxfile,certificatestore`
  - `ACME_SCRIPT_PATH=Scripts\deploy-rds-farm.ps1`
  - `ACME_SCRIPT_PARAMETERS=-CertThumbprint '{CertThumbprint}' -CachePassword '{CachePassword}' -CacheFile '{CacheFile}' -ConfigFile '<runtime deployment config>'`
- `Scripts/deploy-rds-farm.ps1` resolves hosts from arguments, config, or `deployment-targets.json`.
- `Scripts/deploy-rds-farm.ps1` resolves PFX password from WACS cache, explicit argument, or secure config reference.
- `Scripts/deploy-rds-farm.ps1` remotes to session hosts and invokes `Scripts/deploy-rds-sessionhost.ps1`.

Existing tests cover the RDS farm parameter shape, config-file fallback, password reference behavior, and missing-target failure behavior.

### NetScaler Post-Issuance

NetScaler has the only dedicated appliance deployment workflow in the main TUI:

- Menu actions exist for preview, deploy, and diagnostics.
- `certificate-setup.ps1` dispatches these actions to `setup/NetScaler-Runner.psm1`.
- `Invoke-NetScalerDeploymentForm` collects fields from `setup/Device-Schemas.ps1`.
- `Convert-NetScalerFormValuesToArguments` builds arguments for `Scripts/cert2netscaler.ps1`.
- Deployment runs a WhatIf preview before real deploy.
- Real deploy requires explicit `DEPLOY` confirmation.

## Partially Connected

### Kemp

Kemp is partially connected:

- Registry entry exists.
- `Scripts/cert2kemp.ps1` exists.
- `connectors/kemp.psm1` exists for phase 2.
- Device schema exists.
- Release manifest includes the script.

Missing:

- No main TUI Deployment Targets action for Kemp.
- No dedicated Kemp runner equivalent to `NetScaler-Runner.psm1`.
- Generic `Invoke-DeviceForm` exists, but no menu item dispatches it for Kemp.

### Palo Alto

Palo Alto is partially connected:

- Registry entry exists.
- `Scripts/deploy-paloalto.ps1` exists.
- Release manifest includes the script.
- DPAPI guard tests include the script.

Missing:

- No main TUI Deployment Targets action.
- No dedicated runner.
- No `connectors/paloalto.psm1` for phase 2.
- Device schema only collects `host`, but the script requires firewall, API key or encrypted API key file, certificate name/path, key path, binding type, binding target, and related options.
- Registry default script parameters are `{CertThumbprint}`, but the script does not accept `CertThumbprint`.

### Sophos

Sophos is partially connected, but not usable through the main app:

- Registry entry exists.
- `Scripts/deploy-sophos.ps1` exists.
- Release manifest includes the script.
- DPAPI guard tests include the script.

Missing or mismatched:

- No main TUI Deployment Targets action.
- No dedicated runner.
- No `connectors/sophos.psm1` for phase 2.
- Device schema only collects `host`.
- The script requires firewall, username, encrypted password, cert name/path, key path, binding type, binding target, and optional temporary certificate data.
- Registry default script parameters are `{CertThumbprint}`, but the script does not accept `CertThumbprint`.
- Registry marks Sophos as requiring PFX, but the script does not accept a PFX password and loads PFX bytes without one.
- PEM handling uses `X509Certificate2.CreateFromPem`, which is not available in Windows PowerShell 5.1/.NET Framework.
- Dry-run logging can include certificate or private-key material inside the XML body.

## Listed But Not Main-App Connected

The following phase-2 connector modules exist and appear to export the expected connector lifecycle functions:

- `connectors/adfs.psm1`
- `connectors/citrix-adc.psm1`
- `connectors/exchange.psm1`
- `connectors/f5-bigip.psm1`
- `connectors/iis.psm1`
- `connectors/kemp.psm1`
- `connectors/ntds.psm1`
- `connectors/rd-gateway.psm1`
- `connectors/rdp-listener.psm1`
- `connectors/rds-full.psm1`
- `connectors/sql-server.psm1`
- `connectors/sstp.psm1`
- `connectors/windows-admin-center.psm1`
- `connectors/winrm.psm1`

These are reachable through phase-2 policy/orchestrator configuration, not through first-run WACS setup unless separately mapped by registry and script parameters.

## Fix List

### P0: PowerShell 5.1 Compatibility

- Replace the null-coalescing operator in `core/Logger.psm1` with PowerShell 5.1-compatible code.
- Re-run the Windows PowerShell 5.1 compatibility gate.

Reason: `core/Logger.psm1` currently uses `??`, which Windows PowerShell 5.1 cannot parse.

### P0: Decide Connector Product Model

Choose and document one model for appliance connectors:

1. Dedicated post-issuance TUI runner per appliance, like NetScaler.
2. Generic deployment-target runner that can execute registered `Scripts/*.ps1` with schema-derived arguments.
3. Phase-2 orchestrator modules only, using `connectors/*.psm1`.

Reason: the current app mixes all three ideas, which makes registry entries look complete before they are actually runnable.

### P1: Sophos Main-App Wiring

Implement or explicitly disable Sophos until implemented.

If implementing:

- Add a Sophos deployment menu action under Deployment targets.
- Add `Invoke-SophosDeploymentForm` or a generic runner that can call `Scripts/deploy-sophos.ps1`.
- Expand the Sophos schema to include all required script inputs.
- Generate script arguments from schema values.
- Support WhatIf/dry-run preview and explicit confirmation before mutation.
- Ensure secrets are masked in all logs.

If not implementing now:

- Mark Sophos disabled or experimental in the registry and menu text.
- Make diagnostics report it as not wired, not healthy.

### P1: Sophos Certificate Input Contract

Fix `Scripts/deploy-sophos.ps1` before exposing it:

- Add PFX password support or stop declaring `RequiresPfx`.
- Make `KeyPath` optional when `CertPath` is a PFX.
- Replace `CreateFromPem` with PowerShell 5.1-compatible certificate parsing.
- Avoid logging raw upload XML in dry-run when it contains certificate or private-key material.
- Align script parameters with WACS placeholders or post-issuance deployment config.

### P1: Palo Alto Main-App Wiring

- Add a Palo Alto deployment menu action and runner, or mark it explicitly unavailable.
- Expand schema beyond `host`.
- Align registry defaults with the script's actual parameter contract.
- Add a diagnostics check that verifies required schema fields cover mandatory script parameters.

### P1: Registry Diagnostics

Strengthen `Test-AcmeTuiWiring`:

- Detect post-issuance registry entries that have no menu action, runner, or phase-2 module.
- Compare registry `DefaultScriptParameters` with script mandatory parameters.
- Check that `RequiresPfx` entries have a PFX password path or documented non-WACS execution path.
- Fail or warn when `Device-Schemas.ps1` lacks required fields for a connector script.
- Report script existence separately from app reachability.

### P2: Kemp Deployment Target UX

- Decide whether Kemp should use phase-2 only or have a NetScaler-style TUI runner.
- If TUI-supported, add menu action and runner.
- If phase-2-only, update registry/operator text so it does not imply a Deployment Targets workflow that does not exist.

### P2: Generic Hooks

Review `mail`, `firewall`, and `waf`:

- Confirm whether they are intentionally generic placeholder hooks.
- Add clear operator-facing text explaining required mapping/config files.
- Add diagnostics that verify their config files exist when selected.

### P2: Test Runner Hygiene

The local test run is noisy under the available Pester version. Separate:

- Pester version/harness failures.
- Environment failures such as unavailable `wacs.exe`.
- Real PowerShell 5.1 parse failures.

Add a short documented command for the supported test environment and expected Pester version.

## Recommended Sequence

1. Fix `core/Logger.psm1` PowerShell 5.1 parsing.
2. Strengthen diagnostics so "script exists" is not treated as "connector is usable."
3. Mark Sophos and Palo Alto as unavailable/experimental unless implementing their runners immediately.
4. Implement Sophos runner/schema/PFX fixes.
5. Implement Palo Alto runner/schema fixes.
6. Decide whether Kemp gets a TUI runner or remains phase-2 only.
7. Re-run compatibility and connector wiring tests.

