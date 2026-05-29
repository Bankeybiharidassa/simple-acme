# Bug Report: Sophos Firewall Certificate Export API Returns Empty Body

## Summary

The Sophos Firewall XML API accepts authenticated read operations and certificate write operations on the lab XGS, but the documented certificate export call returns an empty response body.

The failing operation is:

```xml
<Request>
  <Login>
    <Username>...</Username>
    <Password>...</Password>
  </Login>
  <Get>
    <Certificate/>
  </Get>
</Request>
```

According to the Sophos documentation, this request should download an archive containing certificates, private keys, and `Entities.xml`. On the tested lab appliance, it consistently returns `HTTP 200` with `Content-Type: text/xml` and `0` response bytes.

## Environment

- Product: Sophos Firewall / XGS lab appliance.
- API endpoint: `https://<firewall>:4444/webconsole/APIController`.
- API version reported by appliance: `2200.1`.
- Appliance hostname reported by API: `XG_Test`.
- Test date: 2026-05-29.
- Client OS: Windows PowerShell from `D:\GitHub\simple-acme`.
- Additional client checks: Windows `curl.exe` and WSL/Linux `curl`.
- Accounts tested:
  - Dedicated Sophos API/admin-style account.
  - Built-in/admin account.
- Credentials were intentionally excluded from this report.

## Documentation References

- Sophos help: `Get certificates using API`.
  - Expected behavior: `Get <Certificate/>` downloads certificates, private keys, and `Entities.xml`.
  - URL: https://docs.sophos.com/nsg/sophos-firewall/22.0/help/en-us/webhelp/onlinehelp/AdministratorHelp/Certificates/HowToArticles/CertificatesAPIGetCertificate/
- Sophos API entity: `Certificate`.
  - Documents add/update operations for certificate objects.
  - URL: https://docs.sophos.com/nsg/sophos-firewall/22.0/api/SYSTEM/Certificates/Certificate/certificate.html
- Sophos API operation: `AddCertificate & UpdateCertificate`.
  - Documents `UploadCertificate`, supported file formats, certificate file fields, private key file fields, and password fields.
  - URL: https://docs.sophos.com/nsg/sophos-firewall/22.0/api/SYSTEM/Certificates/Certificate/operations/AddCertificate%26UpdateCertificate.html

## Expected Behavior

When an authenticated API client sends:

```xml
<Request>
  <Login>
    <Username>valid-user</Username>
    <Password>valid-password</Password>
  </Login>
  <Get>
    <Certificate/>
  </Get>
</Request>
```

the firewall should return a downloadable archive containing certificate export material, as described by the Sophos documentation.

At minimum, the response should not be an empty `HTTP 200` response. If the export is unsupported, disabled, denied, or blocked by policy, the API should return an XML status/error response explaining the reason.

## Actual Behavior

The firewall returns:

- HTTP status: `200`.
- Content type: `text/xml; charset=UTF-8`.
- Response size: `0` bytes.
- No XML status body.
- No archive content.
- No diagnostic message.

This was reproducible with multiple request encodings and clients.

## Reproduction Steps

1. Enable Sophos Firewall API access for the client IP.
2. Confirm normal XML API requests work:

   ```xml
   <Request>
     <Login>
       <Username>valid-user</Username>
       <Password>valid-password</Password>
     </Login>
     <Get>
       <AdminSettings/>
     </Get>
   </Request>
   ```

3. Confirm WAF/firewall rule discovery works:

   ```xml
   <Request>
     <Login>
       <Username>valid-user</Username>
       <Password>valid-password</Password>
     </Login>
     <Get>
       <FirewallRule/>
     </Get>
   </Request>
   ```

4. Attempt certificate export:

   ```xml
   <Request>
     <Login>
       <Username>valid-user</Username>
       <Password>valid-password</Password>
     </Login>
     <Get>
       <Certificate/>
     </Get>
   </Request>
   ```

5. Save the response body to a file and inspect the result.

## Commands Used

The certificate export was tested with equivalent request shapes using PowerShell and `curl.exe`. Example command shape with secrets omitted:

```powershell
$req = @'
<Request>
  <Login>
    <Username>valid-user</Username>
    <Password>valid-password</Password>
  </Login>
  <Get>
    <Certificate/>
  </Get>
</Request>
'@

curl.exe -k -L --max-time 180 --connect-timeout 15 `
  --get --data-urlencode "reqxml=$req" `
  --output certificates.tar `
  --write-out "http=%{http_code} bytes=%{size_download} type=%{content_type}`n" `
  "https://<firewall>:4444/webconsole/APIController"
```

Observed output:

```text
http=200 bytes=0 type=text/xml; charset=UTF-8
```

## Control Tests That Passed

### Admin Settings Read

`Get <AdminSettings/>` returned XML successfully.

Relevant fields observed:

- `WebAdminSettings/Certificate`: `ApplianceCertificate`.
- Web admin HTTPS port: `4444`.
- User portal HTTPS port: `4443`.
- VPN portal HTTPS port: `444`.

### Firewall Rule Read

`Get <FirewallRule/>` returned XML successfully.

Relevant WAF/HTTP-based rule observed:

- Rule name: `rdgw`.
- Policy type: `HTTPBased`.
- HTTPS: enabled.
- Listen port: `443`.
- Hosted address: `#PortB`.
- Domains included `remote.orselen.nl`.
- `HTTPSCertificate` was empty in the retrieved rule.

### Certificate Create

A temporary self-signed certificate named `CodexTempCertDeleteMe` was created with:

```xml
<Set operation="add">
  <Certificate>
    <Action>GenerateSelfSignedCertificate</Action>
    ...
  </Certificate>
</Set>
```

The firewall returned:

```xml
<Status code="200">Configuration applied successfully.</Status>
```

### Certificate Delete

The same temporary certificate was removed with:

```xml
<Remove>
  <Certificate>
    <Name>CodexTempCertDeleteMe</Name>
  </Certificate>
</Remove>
```

The firewall returned:

```xml
<Status code="200">Configuration applied successfully.</Status>
```

This proves the certificate API tag itself is usable for write operations on this appliance.

## Additional Certificate GET Variants Tested

The following variants were also tested and returned empty bodies:

```xml
<Get>
  <Certificate>
    <Name>ApplianceCertificate</Name>
  </Certificate>
</Get>
```

```xml
<Get>
  <Certificate>
    <Name>CodexTempCertDeleteMe</Name>
  </Certificate>
</Get>
```

```xml
<Get>
  <Certificate>
    <Filter>
      <key name="Name" criteria="=">CodexTempCertDeleteMe</key>
    </Filter>
  </Certificate>
</Get>
```

```xml
<Get>
  <Certificate>
    <Filter>
      <key name="Name" criteria="like">CodexTemp</key>
    </Filter>
  </Certificate>
</Get>
```

One malformed/unsupported filter test returned:

```xml
<Status code="533">API request failed.</Status>
```

That response confirms the firewall can return XML error bodies for some invalid certificate requests, but it does not return an error for the documented export request.

## Authentication Notes

The built-in/admin account behaved inconsistently for a login-only request:

```xml
<Request>
  <Login>
    <Username>admin</Username>
    <Password>...</Password>
  </Login>
</Request>
```

That request returned:

```xml
<status>Authentication Failure</status>
```

However, the same account succeeded when a valid `<Get>` operation was included, and returned full XML for `AdminSettings` and `FirewallRule`.

Therefore, the certificate export failure is not explained by general authentication failure.

## Impact

The connector cannot safely rely on `Get <Certificate/>` as a source of truth for certificate inventory on this appliance.

For the `simple-acme` Sophos connector, this affects:

- Showing a complete list of existing Sophos certificate objects.
- Verifying uploaded certificate objects by exporting or reading the certificate entity directly.
- Comparing the uploaded certificate contents against what the firewall stores.

It does not block:

- Uploading or generating certificate objects.
- Reading admin portal, user portal, VPN portal, and WAF/firewall-rule service configuration.
- Assigning a known certificate name to supported services.
- Showing WAF rules and their configured `HTTPSCertificate` field.

## Current Connector Design Decision

Until the export behavior is explained or fixed, the Sophos connector should:

1. Upload certificates using the documented `UploadCertificate` path.
2. Use a deterministic certificate name generated by the connector.
3. Treat the connector's uploaded certificate name as the deployment identity.
4. Verify service assignment through `AdminSettings` and `FirewallRule` reads.
5. Avoid depending on `Get <Certificate/>` for inventory or post-upload validation.
6. Surface a warning if the operator asks for certificate inventory/export on appliances with this behavior.

## Severity

Suggested severity: medium.

Reason:

- Core Sophos API connectivity works.
- Certificate create/delete works.
- Service discovery works.
- The missing export response blocks inventory/export verification, but it does not block the primary upload-and-assign deployment path.

## Open Questions

- Is `Get <Certificate/>` gated by an appliance setting, hidden permission, or license state not reflected in normal API authentication?
- Is the certificate export endpoint intentionally disabled on some XGS/SFOS builds despite the documentation?
- Does the endpoint require a browser session, alternate port, or different content negotiation that is not documented?
- Should an empty export return a structured XML status response instead of `HTTP 200` with zero bytes?
- Is this specific to API version `2200.1`?

## Proposed Vendor-Facing Bug Statement

On Sophos Firewall API version `2200.1`, the documented certificate export request `Get <Certificate/>` returns `HTTP 200` with `Content-Type: text/xml` and a zero-byte response body. Other authenticated API reads such as `AdminSettings` and `FirewallRule` succeed, and certificate write operations such as self-signed certificate creation and removal also succeed. The documented behavior says the certificate GET should download an archive containing certificate material and `Entities.xml`. The appliance should either return the documented archive or return a structured XML error explaining why export is unavailable.
