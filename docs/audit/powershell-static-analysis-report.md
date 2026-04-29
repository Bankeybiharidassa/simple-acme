# PowerShell static analysis report

## Scope
- Runtime scripts/modules: `certificate-*.ps1`, `core/*.psm1`, `setup/*.psm1`, `connectors/*.psm1`.

## Commands executed
- `rg -n "\?\s*:|\?\?|ForEach-Object\s+-Parallel|Start-ThreadJob|ConvertFrom-Json\s+-AsHashtable" certificate-*.ps1 core setup connectors`
- `rg -n "--baseuri|--eab-key|ACME_HMAC_SECRET|ACME_WACS_PATH|wacs.exe" certificate-*.ps1 core setup`

## Results
- No confirmed runtime usage of `ForEach-Object -Parallel`, `Start-ThreadJob`, `??`, or `ConvertFrom-Json -AsHashtable`.
- Prior `? :` detections were mostly regex false positives due to non-capturing groups `(?:...)`.
- WACS command construction includes `--baseuri` in setup/reconcile flows.
- Secret preview masking exists (`--eab-key <hidden>`).

## Environment limitation
- `powershell.exe` is unavailable in this container; true PS5.1 parser/import validation remains pending on Windows host.
