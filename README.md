# simple-acme helper/wrapper for Windows PowerShell 5.1

This project is a Windows PowerShell helper/wrapper around official simple-acme/WACS releases.

It provides:
- noob/supportdesk-friendly bootstrap;
- provider-specific ACME configuration;
- Networking4All test/production/product endpoint selection;
- EAB handling;
- RDS/script deployment integration;
- backup/restore;
- diagnostics and command preview.

simple-acme/WACS remains the ACME engine. simple-acme renewal JSON remains the runtime certificate source of truth.

## Runtime model

Install root is the WACS runtime directory.

Example:
- `<root> = C:\certificaat`
- official executable: `<root>\wacs.exe`
- official scripts: `<root>\Scripts\`

Runtime installs at `<root>` and not in nested `tools\simple-acme` or `vendor\simple-acme` folders unless explicitly overridden.

## Prerequisites

- Windows PowerShell 5.1
- Administrator rights for certificate store/RDS/IIS operations
- Internet access for official simple-acme ZIP download, unless `wacs.exe` is already installed in `<root>`
- Required Windows roles depend on chosen target, for example RDS or IIS

## First-time setup

1. Extract/copy this helper into an install root, for example `C:\certificaat`.
2. Run `certificate-setup.ps1` as Administrator.
3. The setup wizard creates or updates `<root>\certificate.env`.
4. The installer/updater downloads or verifies official simple-acme/WACS into `<root>\wacs.exe`.
5. The wizard guides provider, endpoint, EAB, target, domains and CSR selection.
6. Reconcile runs official `wacs.exe` non-interactively.

If an existing `certificate.env` exists, the wizard reads and reuses values where possible.

## Environment variables

### Phase 1 bootstrap/runtime

```dotenv
ACME_DIRECTORY=
DOMAINS=
ACME_SCRIPT_PATH=
ACME_SCRIPT_PARAMETERS={CertThumbprint}
ACME_PROVIDER=
ACME_REQUIRES_EAB=0/1
ACME_KID=
ACME_HMAC_SECRET=
ACME_VALIDATION_MODE=none
ACME_CSR_ALGORITHM=ec|rsa
ACME_ALLOW_CSR_FALLBACK=0/1
ACME_WACS_PATH=<root>\wacs.exe
ACME_WACS_SOURCE=official-release
ACME_WACS_VERSION=
ACME_WACS_AUTO_UPDATE=0/1
ACME_WACS_RELEASE_ZIP=
ACME_WACS_RELEASE_SHA256=
```

### Phase 2 / advanced orchestrator only

```dotenv
CERTIFICATE_CONFIG_DIR=
CERTIFICATE_DROP_DIR=
CERTIFICATE_STATE_DIR=
CERTIFICATE_LOG_DIR=
CERTIFICATE_API_KEY=
CERTIFICATE_HTTP_ENABLED=
CERTIFICATE_HTTP_PREFIX=
```

Phase-2 variables are not required for normal local/RDS phase-1 setup.

## certificate.env resolution

Resolution order:
1. explicit `-Path` when a script supports it
2. `CERTIFICATE_ENV_FILE` override
3. `<root>\certificate.env`

Canonical default is `<root>\certificate.env`.

## CSR and fallback policy

`ACME_CSR_ALGORITHM` defaults to `ec`.
`ACME_ALLOW_CSR_FALLBACK` defaults to `0`.
RSA fallback is disabled unless explicitly enabled.

EC example:
```dotenv
ACME_CSR_ALGORITHM=ec
ACME_KEY_TYPE=ec
ACME_EC_CURVE=P-256
ACME_RSA_KEY_SIZE=
ACME_ALLOW_CSR_FALLBACK=0
```

RSA example:
```dotenv
ACME_CSR_ALGORITHM=rsa
ACME_KEY_TYPE=rsa
ACME_RSA_KEY_SIZE=2048
ACME_EC_CURVE=
ACME_ALLOW_CSR_FALLBACK=0
```

## WACS path troubleshooting

Ensure `<root>\wacs.exe` exists, or set `ACME_WACS_PATH` explicitly. `PATH` is fallback only.

## Official release updater

Use `certificate-update-simple-acme.ps1` to download/refresh official simple-acme files in the install root.

Dry run:
```powershell
.\certificate-update-simple-acme.ps1 -DryRun
```

Update writes `<root>\simple-acme-release-manifest.json` and updates `ACME_WACS_*` keys in `<root>\certificate.env`.
When mutations occur, updater creates a deterministic backup folder (`backup-update-<version>-<sha256>`) before overwrite and rolls back file swaps if any mutation-phase step fails.

Do not silently replace WACS unless `ACME_WACS_AUTO_UPDATE=1` or the operator confirms.

## Startup/update check policy

At setup start:
1. resolve `<root>\wacs.exe`
2. read `simple-acme-release-manifest.json` when present
3. if `ACME_WACS_AUTO_UPDATE=1`, check latest release and prompt:
   - `[1] Update now`
   - `[2] Skip this time`
   - `[3] Disable auto-update checks`
4. if `ACME_WACS_AUTO_UPDATE=0`, no automatic check unless operator selects check explicitly.

## PR #538 awareness

Upstream PR `simple-acme/simple-acme#538` (Multiserver, open) is relevant for per-renewal endpoint metadata.

When official simple-acme includes PR #538 (or equivalent endpoint-per-renewal support), the helper should rely on native renewal endpoint metadata where possible.
Until then, the helper must always pass `--baseuri` explicitly during issuance/reconcile.

## Advanced / Phase 2 orchestrator

`certificate-orchestrator.ps1`, drop directories, HTTP listener, API key auth, and state/event workflows are advanced features. They are optional and not required for phase-1 local bootstrap or standard RDS deployment.
