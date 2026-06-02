# Kemp LoadMaster Lab Communication Check

Date: 2026-06-02

Lab target:

- LoadMaster management address: `192.168.45.150`
- Management/API port: `443`
- Virtual service expected by operator: `192.168.45.151:443`
- Real server expected by operator: `172.16.17.30:443`

Secrets are intentionally not recorded here.

## Verified From This Workstation

Working:

- TCP connection to `192.168.45.150:443`.
- HTTPS management UI responds on `https://192.168.45.150/` with HTTP `200 OK`.

Not working yet:

- Kemp APIv2 endpoint `https://192.168.45.150/accessv2` returns HTTP `404 File not found`.
- Kemp classic REST endpoint `https://192.168.45.150/access/listvs` returns HTTP `404 File not found`.

REST procedures tested:

- APIv2 JSON API key: `POST /accessv2` with `{"cmd":"listvs","apikey":"<hidden>"}`.
- APIv2 JSON username/password: `POST /accessv2` with `{"cmd":"listvs","apiuser":"bal","apipass":"<hidden>"}`.
- APIv2 query API key: `GET /accessv2?cmd=listvs&apikey=<hidden>`.
- Classic REST Basic auth: `GET /access/listvs`.
- Classic REST API key query: `GET /access/listvs?apikey=<hidden>`.
- Classic REST username/password query: `GET /access/listvs?apiuser=bal&apipass=<hidden>`.
- Broader path sweep including `/api/listvs`, `/api/v2/listvs`, `/rest/listvs`, and `/progs/access/listvs`.

## Current Conclusion

The LoadMaster management UI is reachable, but the certificate deployment API is not currently exposed on the configured management port from this workstation.

The simple-acme Kemp communication test should therefore report:

- Management UI: reachable.
- REST certificate API: failed.
- Attempted REST endpoints: APIv2 `/accessv2` and classic `/access/listvs`.

This is not enough for automatic certificate deployment. Certificate target selection and renewal-hook deployment need REST API access to return `listvs`.

SSH is intentionally not part of the Kemp certificate deployment procedure.
