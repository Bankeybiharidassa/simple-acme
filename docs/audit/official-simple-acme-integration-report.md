# Official simple-acme integration report

## Commands/evidence
- `rg -n "ACME_WACS_PATH|wacs.exe|Get-Command|--baseuri" core/Simple-Acme-Reconciler.psm1 certificate-setup.ps1 setup/Form-Runner.psm1`

## Results
- Resolver logic includes configured path + install-root `wacs.exe` + PATH fallback.
- Setup and reconcile command previews include `--baseuri`.
- EAB values are masked in preview output.

## Risk status
- Runtime execution against official `wacs.exe` not performed in this Linux environment.
