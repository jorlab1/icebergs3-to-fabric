# Optional IaC: Fabric capacity, tenant settings, and workspace

Use this **optional, administrator-owned bootstrap** before the [lakehouse/shortcut REST guide](fabric-rest-deployment.md) when a suitable Fabric environment does not already exist. Existing tenants can skip every resource or setting they already have.

This guide adds an Azure ARM capacity template and Fabric REST examples. It does not purchase capacity, modify tenant settings, or deploy anything automatically. The original POC used an existing capacity/workspace; this bootstrap is a reusable extension, not a record of additional deployed resources.

## Separate the three control planes

| Layer | Deployment artifact / API | Authorization and approval |
|---|---|---|
| Azure capacity | [`fabric-capacity.json`](../templates/azure/fabric-capacity.json), `Microsoft.Fabric/capacities@2023-11-01` | Azure subscription/resource-group deployment permissions; explicit region, SKU, cost, and capacity-admin approval |
| Fabric tenant policy | Admin `GET /v1/admin/tenantsettings` and `POST /v1/admin/tenantsettings/{settingName}/update` | Fabric administrator or separately authorized admin-API automation identity; reviewed tenant-wide change |
| Fabric workspace | [`workspace.json`](../templates/fabric/workspace.json), `POST /v1/workspaces` | Workspace-creation permission plus Contributor/Admin access on the selected Fabric capacity |
| Workspace access | [`workspace-role-assignment.json`](../templates/fabric/workspace-role-assignment.json) | Workspace Member or Admin; assigning Admin requires Admin |

Azure RBAC, Fabric capacity permissions, tenant settings, workspace roles, and connection access are distinct. Azure Contributor is not a Fabric tenant administrator or automatically a Fabric capacity contributor. Keep tenant-policy automation separate from routine lakehouse deployments.

**Order:** approve/bootstrap tenant access and identities; provision or select capacity; authorize the workspace creator on that capacity; create the capacity-assigned workspace; grant item-deployment access; continue with lakehouse, connection, and shortcut creation. Tenant settings can be reviewed before capacity creation, and must be effective before the API calls they enable.

## 1. Provision an Azure F capacity, only if needed

The [ARM template](../templates/azure/fabric-capacity.json) pins the stable `2023-11-01` API rather than a preview. It requires capacity name, region, SKU, and administrator identities explicitly; no paid SKU is selected by default. It targets an **existing resource group** and creates no role assignments, budget alerts, or reservations.

Prerequisites:

- An Azure subscription associated with the intended Fabric tenant and an approved resource group.
- Registered `Microsoft.Fabric` resource provider, regional availability and enough CU quota for the selected SKU.
- Azure permission to deploy ARM templates and create/read capacity resources. Optional suspend/resume/delete operations require their own permissions.
- Approved capacity administrator users from the target tenant. B2B guest users cannot be capacity administrators.
- A cost owner, spending approval, and a pause/retirement plan. F capacities are billable and not paid for by Snowflake credits; ARM what-if is not a price quote or spending cap.

Using Azure CLI in PowerShell, sign in through your approved Azure flow, choose the intended subscription, and inspect provider registration:

```powershell
az login --tenant YOUR_TENANT_ID
if ($LASTEXITCODE -ne 0) { throw 'Azure sign-in failed.' }
az account set --subscription YOUR_SUBSCRIPTION_ID
if ($LASTEXITCODE -ne 0) { throw 'Subscription selection failed.' }
az account show --query '{subscription:id,tenant:tenantId,name:name}' --output table
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect selected subscription.' }
az provider show --namespace Microsoft.Fabric --query registrationState --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect Fabric resource provider.' }
```

If unregistered, an authorized subscription administrator can approve and run `az provider register --namespace Microsoft.Fabric --wait`. Do not register providers or request quota automatically as part of routine item deployment.

Create `local\capacity.parameters.json` using your approved values (`local/` is gitignored):

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "capacityName": { "value": "YOUR_APPROVED_LOWERCASE_CAPACITY_NAME" },
    "location": { "value": "YOUR_APPROVED_AZURE_REGION" },
    "skuName": { "value": "YOUR_APPROVED_F_SKU" },
    "administratorMembers": { "value": ["YOUR_CAPACITY_ADMIN_UPN"] },
    "tags": { "value": { "purpose": "iceberg-evaluation" } }
  }
}
```

Capacity names must match `^[a-z][a-z0-9]*$` (3-63 characters); the uppercase placeholder is deliberately not deployable. Review current region/quota/pricing and use actual values before proceeding.

First validate and review the plan from the repository root. These commands call Azure but do not deploy the capacity:

```powershell
az deployment group validate --resource-group YOUR_RESOURCE_GROUP `
    --template-file '.\templates\azure\fabric-capacity.json' `
    --parameters '@local\capacity.parameters.json'
if ($LASTEXITCODE -ne 0) { throw 'ARM validation failed.' }
az deployment group what-if --resource-group YOUR_RESOURCE_GROUP `
    --template-file '.\templates\azure\fabric-capacity.json' `
    --parameters '@local\capacity.parameters.json'
if ($LASTEXITCODE -ne 0) { throw 'ARM what-if failed.' }
```

**Separate paid-deployment gate:** only after approval of the subscription, region, SKU, administrators, and what-if:

```powershell
az deployment group create --name iceberg-fabric-capacity `
    --resource-group YOUR_RESOURCE_GROUP --mode Incremental `
    --template-file '.\templates\azure\fabric-capacity.json' `
    --parameters '@local\capacity.parameters.json'
if ($LASTEXITCODE -ne 0) { throw 'Capacity deployment failed; inspect the ARM deployment.' }
```

Record the ARM deployment result and `capacityResourceId`. This output is an **Azure resource ID**, not the Fabric capacity GUID used by workspace APIs. ARM redeployment reconciles the named Azure resource; it does not reconcile tenant policies or workspace objects. Review what-if on every change.

Terraform users can adapt the same resource schema through AzAPI or use the [Azure Verified Module for Fabric capacity](https://github.com/Azure/terraform-azure-avm-res-fabric-capacity). Pin and review your provider/module versions; this repository does not include a second Terraform implementation.

## 2. Review and manage tenant settings as policy

These settings are not properties of the ARM capacity. A Fabric administrator should review them in **Tenant settings** and approve only the necessary security groups:

| Setting title / capability to locate | When needed |
|---|---|
| Users can create Fabric items | Enable the intended users to create Fabric workloads; review applicable capacity overrides |
| Create workspaces | Allow the selected workspace-creator users, subject to your tenant's workspace policy |
| Service principals can call Fabric public APIs | App-only lakehouse/shortcut APIs; allow the deployment principal's security group |
| Service principals can create workspaces, connections, and deployment pipelines | App-only workspace/connection creation; distinct from public-API access |
| External data sharing | Provider tenant only, for the approved people creating shares |
| Users can accept external data shares | Recipient tenant only, for the approved people accepting shares |
| Service principals can access read-only admin APIs | Only if a dedicated automation principal inventories admin settings |
| Service principals can access admin APIs used for updates | Only if a dedicated automation principal changes admin settings |

Do not grant routine item-deployment principals tenant-policy write access. A principal cannot self-enable its own initially blocked admin API access: an already authorized administrator must bootstrap that permission. The recipient tenant's settings require **its own** administrator and credentials; the provider's bootstrap cannot administer that other tenant.

### Discover, plan, and update one approved setting

Use the authentication/request helpers in [REST guide section 1](fabric-rest-deployment.md#1-authenticate-and-define-safe-request-helpers). For this section only, authenticate as a **separately approved admin-API service principal**, not the normal item deployer. Have the administrator authorize the appropriate admin API settings first. Alternatively use an approved delegated-admin authentication client with `Tenant.Read.All` (inventory) / `Tenant.ReadWrite.All` (update) and a Fabric administrator user. The helper needs a bearer token for `https://api.fabric.microsoft.com`; an ARM token for `management.azure.com` is not interchangeable.

Inventory settings and choose the exact returned `settingName` for the administrator-approved title. Do not guess internal setting names from display text or apply all settings in bulk:

```powershell
$settings = @(Get-FabricCollection -Path '/admin/tenantsettings')
$settings | Select-Object settingName, title, enabled, canSpecifySecurityGroups
$settingName = 'YOUR_DISCOVERED_AND_APPROVED_SETTING_NAME'
$matches = @($settings | Where-Object settingName -EQ $settingName)
if ($matches.Count -ne 1) { throw 'Select exactly one discovered tenant setting.' }
$before = $matches[0]
if (-not $before.canSpecifySecurityGroups) {
    throw 'This setting is not group-scopable; require separate tenant-wide review in the portal.'
}
if ($before.enabled -and @($before.enabledSecurityGroups).Count -eq 0) {
    throw 'Setting may be tenant-wide already. Do not change its scope through this narrow example.'
}
$groupId = 'YOUR_APPROVED_ENTRA_SECURITY_GROUP_OBJECT_ID'
$groupName = 'YOUR_APPROVED_GROUP_DISPLAY_NAME'
if ($settingName -like 'YOUR_*' -or $groupId -like 'YOUR_*') {
    throw 'Replace and review setting and group placeholders first.'
}
# Preserve exclusions, delegation, properties, and existing allowed groups.
$update = @{ enabled = $true }
foreach ($key in @('delegateToCapacity','delegateToDomain','delegateToWorkspace',
                   'excludedSecurityGroups','properties')) {
    if ($before.PSObject.Properties.Name -contains $key) {
        $update[$key] = $before.$key
    }
}
$groups = @($before.enabledSecurityGroups | Where-Object { $null -ne $_ })
if ($groupId -notin @($groups.graphId)) {
    $groups += [PSCustomObject]@{ graphId = $groupId; name = $groupName }
}
$update.enabledSecurityGroups = $groups
New-Item -ItemType Directory -Path '.\local' -Force | Out-Null
$before | ConvertTo-Json -Depth 20 | Set-Content '.\local\tenant-setting-before.json'
$update | ConvertTo-Json -Depth 20 | Set-Content '.\local\tenant-setting-proposed.json'
# Review these local artifacts and the setting's semantics before applying.
```

An excluded group can still block your principal. Enabling a previously disabled setting also activates its retained allowed groups: explicitly review those memberships, not just the group being added. Never remove an exclusion to make the example succeed. Protect these non-secret but sensitive tenant-policy snapshots in your normal audit system, not the public repository.

**Separate policy-change gate:** after the administrator approves the exact proposed scope, apply just that setting:

```powershell
$current = @(Get-FabricCollection -Path '/admin/tenantsettings' |
    Where-Object settingName -EQ $settingName)
if ($current.Count -ne 1 -or
    ($current[0] | ConvertTo-Json -Depth 20 -Compress) -ne
    ($before | ConvertTo-Json -Depth 20 -Compress)) {
    throw 'Tenant setting changed after planning. Refresh inventory and review again.'
}
$settingPath = [Uri]::EscapeDataString($settingName)
$null = Invoke-Fabric -Method POST -Path "/admin/tenantsettings/$settingPath/update" -Body $update
$after = @(Get-FabricCollection -Path '/admin/tenantsettings' |
    Where-Object settingName -EQ $settingName)
$after | ConvertTo-Json -Depth 20 | Set-Content '.\local\tenant-setting-after.json'
if ($after.Count -ne 1 -or -not $after[0].enabled -or
    $groupId -notin @($after[0].enabledSecurityGroups.graphId)) {
    throw 'Updated setting does not show the intended enabled group; inspect before continuing.'
}
```

Compare all after-state fields to the approved plan, including exclusions/properties/delegation, and allow policy propagation before testing the scoped identity. There is no transaction or ETag guard here; a concurrent edit after the preflight read remains possible. Serialize policy changes through your administrator-owned workflow. If an API rejects or does not expose a setting, use the authorized admin portal rather than broadening permissions or silently skipping it. Honor `Retry-After` on `429`; admin setting APIs allow at most 25 requests/minute.

For rollback, an administrator must review current state and build an update containing only writable fields from the before snapshot. Do not blindly replay a stale snapshot or POST read-only fields such as `title` and `canSpecifySecurityGroups`. Clear the admin token and use a separate shell/identity for ordinary workspace/item deployment.

## 3. Discover capacity and create a workspace

Authenticate using [REST guide section 1](fabric-rest-deployment.md#1-authenticate-and-define-safe-request-helpers) as the **workspace creator**. Besides tenant permission to create workspaces, this identity needs Fabric capacity Contributor or Admin rights. Have the capacity administrator grant those in Fabric capacity settings; the ARM template above does not grant capacity-contributor rights to the deployment application.

Retrieve the Fabric capacity GUID from the capacities API, matching the approved capacity name/region/SKU. A new Azure resource might need time before it is visible; an empty list can also indicate missing Fabric permissions.

```powershell
$capacities = @(Get-FabricCollection -Path '/capacities')
$capacities | Select-Object id, displayName, sku, region, state
$capacityId = 'YOUR_VERIFIED_FABRIC_CAPACITY_GUID'
$selected = @($capacities | Where-Object id -EQ $capacityId)
if ($selected.Count -ne 1 -or $selected[0].state -ne 'Active') {
    throw 'Choose exactly one approved, accessible, active capacity.'
}
$workspaceBody = Get-Content '.\templates\fabric\workspace.json' -Raw | ConvertFrom-Json
$workspaceBody.capacityId = $capacityId
$existing = @(Get-FabricCollection -Path '/workspaces')
if ($existing | Where-Object displayName -EQ $workspaceBody.displayName) {
    throw 'An accessible workspace has that name. Inspect it instead of creating another.'
}
$created = Invoke-Fabric -Method POST -Path '/workspaces' -Body $workspaceBody
$workspace = $created.Content | ConvertFrom-Json
$workspaceId = $workspace.id
if (-not $workspaceId) { throw 'Workspace creation returned no ID.' }
Write-Host "Workspace ID: $workspaceId"
$deadline = [DateTime]::UtcNow.AddMinutes(10)
do {
    $info = (Invoke-Fabric -Path "/workspaces/$workspaceId").Content | ConvertFrom-Json
    if ($info.capacityAssignmentProgress -eq 'Completed' -and $info.capacityId -eq $capacityId) {
        break
    }
    if ([DateTime]::UtcNow -gt $deadline) {
        throw 'Capacity assignment did not complete as expected. Inspect workspace; do not repeat create.'
    }
    Start-Sleep -Seconds 10
} while ($true)
```

List APIs expose only resources accessible to the caller; name checks are not a complete tenant inventory. Record the returned workspace ID immediately. A timeout does not imply the workspace was not created. For an existing workspace, review the separate [assign-to-capacity API](https://learn.microsoft.com/rest/api/fabric/core/workspaces/assign-to-capacity) and its permissions rather than recreating it.

If a **different service principal** will deploy lakehouse/shortcut items, add its tenant-local **service principal object ID** (not application/client ID) with Contributor:

```powershell
$roleBody = Get-Content '.\templates\fabric\workspace-role-assignment.json' -Raw | ConvertFrom-Json
$roleBody.principal.id = 'YOUR_DEPLOYMENT_SERVICE_PRINCIPAL_OBJECT_ID'
if ($roleBody.principal.id -like 'YOUR_*') { throw 'Set the actual service principal object ID.' }
$roles = @(Get-FabricCollection -Path "/workspaces/$workspaceId/roleAssignments")
if ($roles | Where-Object { $_.principal.id -eq $roleBody.principal.id }) {
    throw 'A role assignment already exists; review its current role instead of adding another.'
}
$null = Invoke-Fabric -Method POST -Path "/workspaces/$workspaceId/roleAssignments" -Body $roleBody
$verifiedRoles = @(Get-FabricCollection -Path "/workspaces/$workspaceId/roleAssignments")
if (-not ($verifiedRoles | Where-Object {
    $_.principal.id -eq $roleBody.principal.id -and $_.role -eq 'Contributor'
})) { throw 'Workspace Contributor assignment was not verified.' }
```

Skip this extra grant if the intended deployer already has sufficient workspace access. Keep an approved human or group administrator for operational ownership; do not grant the whole tenant. Connection creation still requires its separate tenant setting.

## 4. Handoff, drift, and retirement

Pass the **workspace GUID** to the [lakehouse creation workflow](fabric-rest-deployment.md#2-create-the-lakehouse-and-handle-provisioning); authenticate as the item-deployment identity and confirm workspace access. Clear bearer headers and close administrator shells after use.

Keep the Azure resource ID, Fabric capacity GUID, workspace GUID, role assignments, approved tenant-setting snapshots, and ARM deployment name as protected deployment outputs. Reconcile changes through your normal IaC/change-control pipeline. Only the ARM resource has declarative Azure deployment behavior here; REST create examples are not a stateful IaC provider.

Pause/delete only dedicated, approved capacity resources after assessing all assigned workspaces and consumers. Pausing interrupts workloads and can involve outstanding usage charges; it is not a substitute for cost review. Deleting a capacity is not equivalent to deleting all workspace data. Remove unused workspace grants and revert tenant settings only after checking other users and concurrent changes.

## References

- [Stable ARM capacity schema](https://learn.microsoft.com/azure/templates/microsoft.fabric/2023-11-01/capacities)
- [Capacity purchase prerequisites, provider registration and quota](https://learn.microsoft.com/fabric/enterprise/buy-capacity)
- [Developer tenant settings](https://learn.microsoft.com/fabric/admin/service-admin-portal-developer)
- [Admin API tenant settings](https://learn.microsoft.com/fabric/admin/service-admin-portal-admin-api-settings)
- [List tenant settings](https://learn.microsoft.com/rest/api/fabric/admin/tenants/list-tenant-settings)
- [Update tenant setting](https://learn.microsoft.com/rest/api/fabric/admin/tenants/update-tenant-setting)
- [Enable external sharing in provider/recipient tenants](https://learn.microsoft.com/fabric/governance/external-data-sharing-enable)
- [List accessible capacities](https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities)
- [Create workspace](https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace)
- [Get workspace and assignment progress](https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-workspace)
- [Add workspace role assignment](https://learn.microsoft.com/rest/api/fabric/core/workspaces/add-workspace-role-assignment)
