# README/code alignment report

## Checked artifacts
- `README.md`
- `certificate-setup.ps1`
- `certificate-simple-acme-reconcile.ps1`
- `certificate-update-simple-acme.ps1`
- `core/Simple-Acme-Reconciler.psm1`

## Findings
- Code paths are wrapper-oriented around official `wacs.exe` and do not implement a custom ACME engine.
- Reconcile path assembles WACS command arguments including `--baseuri` and masked EAB output.
- README still requires periodic validation as implementation evolves; no hard evidence found that PATH is mandatory in normal flow.

## Required follow-up
- Validate README statements on a Windows PS5.1 host against real install layout and `%ProgramData%\simple-acme` renewal files.
