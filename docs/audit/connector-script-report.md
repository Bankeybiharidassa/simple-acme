# Connector script report

## Scope
- `connectors/*.psm1`
- `Scripts/connectors/*.ps1`

## Commands
- `rg --files connectors Scripts/connectors`
- Pattern scan for secret prints and placeholder markers.

## Findings
- Connector modules are present and discoverable.
- Static scan did not identify explicit raw `ACME_HMAC_SECRET` output in connector modules.
- Runtime execution checks (including `Scripts/cert2rds.ps1` behavior with `{CertThumbprint}`) remain pending Windows verification.
