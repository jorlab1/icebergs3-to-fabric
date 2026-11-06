# Programmatic Fabric deployment

This is the REST sequence used to create the lakehouse, Amazon S3 connection, and initial Iceberg table shortcut in the originating POC, generalized to remove local identities and resource IDs. Use it as an alternative to the README's UI steps or adapt the requests to your approved IaC/pipeline tooling.

These are request templates and staged PowerShell examples, **not an idempotent infrastructure provider**. They do not create a workspace/capacity, AWS resources, Snowflake objects, or external data shares. They do not perform SQL acceptance checks. No request in this guide is executed merely by opening this file.

Need a capacity or workspace first? The separate [optional platform bootstrap](fabric-platform-bootstrap.md) covers an ARM capacity template, administrator-reviewed tenant settings, and workspace/role REST calls. Complete only the missing prerequisites, then return here with the workspace ID.

## API / file map

All Fabric endpoints below are relative to `https://api.fabric.microsoft.com/v1`.

| Order | Request | Request body / result |
|---|---|---|
| 1 | `GET /workspaces/{workspaceId}` | Confirm the intended workspace |
| 2 | `GET /workspaces/{workspaceId}/items` | Check for existing lakehouse names; follow pagination |
| 3 | `POST /workspaces/{workspaceId}/lakehouses` | [`lakehouse.json`](../templates/fabric/lakehouse.json); retain returned lakehouse `id` |
| 4 | `GET /connections/supportedConnectionTypes` | Confirm current `AmazonS3` creation method and credentials |
| 5 | `GET /connections` | Check for existing connection names; follow pagination |
| 6 | `POST /connections` | [`s3-connection.json`](../templates/fabric/s3-connection.json), with credentials injected in memory; retain connection `id` |
| 7 | `GET /workspaces/{workspaceId}/lakehouses/{lakehouseId}` | Inspect schema settings and SQL endpoint |
| 8 | `POST /workspaces/{workspaceId}/items/{lakehouseId}/shortcuts?shortcutConflictPolicy=Abort` | [`iceberg-shortcut.json`](../templates/fabric/iceberg-shortcut.json), with actual root, path, and connection ID |
| 9 | `GET /workspaces/{workspaceId}/items/{lakehouseId}/shortcuts/{path}/{name}` | Verify saved target |
| 10 | `GET /workspaces/{workspaceId}/lakehouses/{lakehouseId}/tables` | Inspect table registration; then run the README's SQL checks |

`itemId` in the shortcut endpoint is the **lakehouse ID**, not the SQL analytics endpoint ID. Connections are created through the tenant-level `/connections` API, not inside a workspace.

## Permissions and secret handling

- Use an existing workspace on active Fabric capacity. Grant the deployment identity Contributor or higher there.
- For a service principal, the Fabric administrator must allow applicable service-principal API access and **Service principals can create workspaces, connections, and deployment pipelines**. Workspace membership alone does not grant tenant-level connection-creation permission.
- Delegated user calls require the documented scopes: `Lakehouse.ReadWrite.All` or `Item.ReadWrite.All` for lakehouse creation, `Connection.ReadWrite.All` for the connection, and `OneLake.ReadWrite.All` for shortcuts. App-only authentication uses the Fabric `.default` scope with tenant settings and resource permissions; do not confuse it with delegated consent.
- Use a dedicated AWS reader with the [reader policy](../templates/aws/fabric-reader-policy.json), not Snowflake's writer role.
- Supply secrets through your CI secret store or local masked prompts. Never save a populated connection payload, print request bodies, enable HTTP debug logging, or pass secret literals on the command line.
- A connection created by a service principal is owned by that identity. Review connection permissions before expecting another user or deployment identity to reuse it; workspace membership and connection access are separate.

The examples use **PowerShell 7** built-in HTTP commands and no extra modules. Run them in order in the **same shell**, from the repository root. CI can substitute its approved token flow; this local example uses a client secret to match the original approach.

## 1. Authenticate and define safe request helpers

Replace the non-secret placeholders. `Read-Host -AsSecureString` prevents secrets from entering shell history, but the HTTPS client still needs plaintext values briefly in memory.

```powershell
$ErrorActionPreference = 'Stop'
$tenantId = 'YOUR_TENANT_ID'
$clientId = 'YOUR_APPLICATION_CLIENT_ID'
$workspaceId = 'YOUR_WORKSPACE_ID'
$base = 'https://api.fabric.microsoft.com/v1'

$clientSecret = Read-Host 'Entra application secret' -AsSecureString
$tokenBody = @{
    client_id = $clientId
    client_secret = [System.Net.NetworkCredential]::new('', $clientSecret).Password
    grant_type = 'client_credentials'
    scope = 'https://api.fabric.microsoft.com/.default'
}
try {
    $token = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Body $tokenBody
    $headers = @{ Authorization = "Bearer $($token.access_token)" }
} catch {
    throw 'Fabric token acquisition failed. Check identity, tenant, and credential configuration.'
} finally {
    $tokenBody.Clear()
    $clientSecret.Dispose()
    $token = $null
}

function Invoke-Fabric {
    param([string]$Method = 'GET', [string]$Path, $Body)
    $uri = if ($Path.StartsWith('https://')) { $Path } else { "$base$Path" }
    if (-not $uri.StartsWith("$base/", [StringComparison]::Ordinal)) {
        throw 'Refusing to send credentials to an unexpected API endpoint.'
    }
    $request = @{
        Method = $Method
        Uri = $uri
        Headers = $headers
        MaximumRedirection = 0
    }
    if ($null -ne $Body) {
        $request.ContentType = 'application/json'
        $request.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    try {
        $response = Invoke-WebRequest @request
    } catch {
        # Do not echo server bodies or request payloads containing credentials.
        $status = [int]$_.Exception.Response.StatusCode
        throw "Fabric $Method failed (HTTP $status). Inspect the resource before retrying a create."
    } finally {
        $request.Remove('Body')
    }
    return $response
}

function Get-FabricCollection {
    param([string]$Path)
    do {
        $page = (Invoke-Fabric -Path $Path).Content | ConvertFrom-Json
        $page.value
        $Path = $page.continuationUri
    } while ($Path)
}
```

Tokens expire. For a long session, authenticate again before subsequent calls rather than retrying a POST blindly. Avoid transcripts in shells that display credentials or populated payloads.

## 2. Create the lakehouse and handle provisioning

[`lakehouse.json`](../templates/fabric/lakehouse.json) supplies the display name and description. Set names before creating resources. This example deliberately refuses a matching name rather than silently reusing or overwriting it.

```powershell
$workspace = (Invoke-Fabric -Path "/workspaces/$workspaceId").Content | ConvertFrom-Json
$workspace | Select-Object id, displayName
# Confirm the workspace above before continuing.
$lakehouseBody = Get-Content '.\templates\fabric\lakehouse.json' -Raw | ConvertFrom-Json
$items = @(Get-FabricCollection -Path "/workspaces/$workspaceId/items")
if ($items | Where-Object displayName -EQ $lakehouseBody.displayName) {
    throw 'An item with this name exists. Inspect it instead of creating another.'
}
$created = Invoke-Fabric -Method POST -Path "/workspaces/$workspaceId/lakehouses" -Body $lakehouseBody
if ($created.StatusCode -eq 202) {
    $operation = [string]$created.Headers.Location[0]
    if (-not $operation.StartsWith("$base/operations/", [StringComparison]::Ordinal)) {
        throw 'Unexpected operation URL; inspect the response before continuing.'
    }
    # Keep this URL if you need to resume polling; do not repeat the create.
    Write-Host "Lakehouse operation: $operation"
    $deadline = [DateTime]::UtcNow.AddMinutes(15)
    $poll = $created
    do {
        $delay = if ($poll.Headers['Retry-After']) { [int]$poll.Headers['Retry-After'][0] } else { 5 }
        Start-Sleep -Seconds ([Math]::Max(1, $delay))
        $poll = Invoke-Fabric -Path $operation
        $status = $poll.Content | ConvertFrom-Json
        if ($status.status -in @('Failed', 'Cancelled')) {
            throw "Lakehouse operation ended: $($status.status). Inspect the operation."
        }
        if ([DateTime]::UtcNow -gt $deadline) {
            throw "Polling timed out. Resume GET $operation; do not repeat POST."
        }
    } while ($status.status -ne 'Succeeded')
    $lakehouse = (Invoke-Fabric -Path "$operation/result").Content | ConvertFrom-Json
} elseif ($created.StatusCode -eq 201) {
    $lakehouse = $created.Content | ConvertFrom-Json
} else {
    throw "Unexpected lakehouse response: $($created.StatusCode)"
}
$lakehouseId = $lakehouse.id
if (-not $lakehouseId) { throw 'Lakehouse response did not contain an ID.' }
Write-Host "Lakehouse ID: $lakehouseId"
```

Both `201 Created` and `202 Accepted` are valid. For `202`, follow `Location` and `Retry-After`, then retrieve the operation result. Preserve returned non-secret IDs in your deployment state.

## 3. Discover and create the S3 connection

The original deployment discovered `AmazonS3`, `AmazonS3.Storage`, parameter `url`, `Basic` credentials, and `NotEncrypted` as the supported connection-encryption enum. **All API calls and the bucket URL still use HTTPS.** This enum is connector configuration, not a request to disable TLS or change S3 at-rest encryption. Recheck the live supported types rather than assuming other connectors accept the same body.

```powershell
$bucketEndpoint = 'https://YOUR_BUCKET.s3.YOUR_REGION.amazonaws.com'
$connectionBody = Get-Content '.\templates\fabric\s3-connection.json' -Raw | ConvertFrom-Json
$connectionBody.connectionDetails.parameters[0].value = $bucketEndpoint
$types = @(Get-FabricCollection -Path '/connections/supportedConnectionTypes')
$s3 = $types | Where-Object type -EQ 'AmazonS3'
if (-not $s3 -or
    'AmazonS3.Storage' -notin @($s3.creationMethods.name) -or
    'Basic' -notin @($s3.supportedCredentialTypes) -or
    'NotEncrypted' -notin @($s3.supportedConnectionEncryptionTypes)) {
    throw 'The connector schema differs; review the supported types before creating credentials.'
}
$connections = @(Get-FabricCollection -Path '/connections')
if ($connections | Where-Object displayName -EQ $connectionBody.displayName) {
    throw 'Connection name exists. Inspect ownership, endpoint, and access before reusing.'
}
$accessKey = Read-Host 'AWS reader access key ID' -AsSecureString
$secretKey = Read-Host 'AWS reader secret access key' -AsSecureString
try {
    $connectionBody.credentialDetails.credentials.username =
        [System.Net.NetworkCredential]::new('', $accessKey).Password
    $connectionBody.credentialDetails.credentials.password =
        [System.Net.NetworkCredential]::new('', $secretKey).Password
    $response = Invoke-Fabric -Method POST -Path '/connections' -Body $connectionBody
    $connection = $response.Content | ConvertFrom-Json
    $connectionId = $connection.id
    if (-not $connectionId) { throw 'Connection response did not contain an ID.' }
    Write-Host "Connection ID: $connectionId"
} finally {
    $connectionBody.credentialDetails.credentials.username = $null
    $connectionBody.credentialDetails.credentials.password = $null
    $accessKey.Dispose()
    $secretKey.Dispose()
}
```

`skipTestConnection` remains `false`. IAM propagation can take time: do not skip testing to hide an access failure. If the connection fails, investigate policy/network/tenant settings and delete an unused new AWS key through your approved workflow. A transport timeout can leave the connection created: inspect `/connections` before retrying or deleting a potentially in-use key.

## 4. Set the actual table root and create the shortcut

Use the metadata location returned by Snowflake's `SYSTEM$GET_ICEBERG_TABLE_INFORMATION`. The actual root might be `/iceberg/orders.<generated-suffix>`. Do not use the literal example suffix, a metadata JSON path, or `/data`. The bucket is already in `$bucketEndpoint`, so do not repeat it in `subpath`.

```powershell
$details = (Invoke-Fabric -Path "/workspaces/$workspaceId/lakehouses/$lakehouseId").Content |
    ConvertFrom-Json
$shortcutBody = Get-Content '.\templates\fabric\iceberg-shortcut.json' -Raw | ConvertFrom-Json
$shortcutBody.target.amazonS3.location = $bucketEndpoint
$shortcutBody.target.amazonS3.connectionId = $connectionId
$shortcutBody.target.amazonS3.subpath = '/YOUR_ACTUAL_ICEBERG_TABLE_ROOT'
# Schema-enabled lakehouses use Tables/<schema>; the original POC used Tables.
$shortcutBody.path = if ($details.properties.defaultSchema) {
    "Tables/$($details.properties.defaultSchema)"
} else {
    'Tables'
}
if ($shortcutBody.target.amazonS3.subpath -like '*YOUR_*') {
    throw 'Replace the actual Iceberg table root before creating the shortcut.'
}
$shortcutResponse = Invoke-Fabric -Method POST `
    -Path "/workspaces/$workspaceId/items/$lakehouseId/shortcuts?shortcutConflictPolicy=Abort" `
    -Body $shortcutBody
$path = ($shortcutBody.path.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
$name = [Uri]::EscapeDataString($shortcutBody.name)
$saved = (Invoke-Fabric -Path "/workspaces/$workspaceId/items/$lakehouseId/shortcuts/$path/$name").Content |
    ConvertFrom-Json
if ($saved.target.amazonS3.connectionId -ne $connectionId -or
    $saved.target.amazonS3.location -ne $bucketEndpoint -or
    $saved.target.amazonS3.subpath -ne $shortcutBody.target.amazonS3.subpath) {
    throw 'Saved shortcut target differs from the intended deployment.'
}
$tables = (Invoke-Fabric -Path "/workspaces/$workspaceId/lakehouses/$lakehouseId/tables").Content |
    ConvertFrom-Json
$tables.data | Select-Object name, format, location
```

Inspect the lakehouse's schema configuration before using `Tables` as a fallback; for another existing schema, set `Tables/<actual-schema>` explicitly. Do not select Files for this table workflow. Default-schema behavior can vary with lakehouse creation options and API evolution.

`Abort` prevents accidental overwrite. Keep the saved lakehouse/connection IDs and shortcut path/name as deployment outputs; they are needed for inspection, reuse, and cleanup.

## 5. Validate and clean up authentication

Shortcut creation proves the reference exists, **not** that conversion or SQL access has succeeded. Continue with the [initial query and fourth-row acceptance checks](../README.md#5-validate-initial-reads-and-source-refresh). Inspect `_delta_log/latest_conversion_log.txt` through OneLake if conversion fails. A separate storage-audience token is needed for OneLake data-plane requests; the Fabric control-plane token is not interchangeable.

On completion or failure, clear `$headers` and close the shell:

```powershell
$headers.Clear()
Remove-Variable headers -ErrorAction SilentlyContinue
```

These requests are create-oriented, not transactional. A later failure does not roll back earlier resources. On `429`, honor `Retry-After`; on ambiguous failures, list/get resources and retain the operation URL before considering a retry. Do not automatically delete existing resources, overwrite shortcuts, or generate more reader keys on every run.

## Official API references

- [Create lakehouse](https://learn.microsoft.com/rest/api/fabric/lakehouse/items/create-lakehouse)
- [Long-running operations](https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation)
- [Supported connection types](https://learn.microsoft.com/rest/api/fabric/core/connections/list-supported-connection-types)
- [Create connection](https://learn.microsoft.com/rest/api/fabric/core/connections/create-connection)
- [Create shortcut](https://learn.microsoft.com/rest/api/fabric/core/onelake-shortcuts/create-shortcut)
- [Get lakehouse](https://learn.microsoft.com/rest/api/fabric/lakehouse/items/get-lakehouse)
- [List lakehouse tables](https://learn.microsoft.com/rest/api/fabric/lakehouse/tables/list-tables)
