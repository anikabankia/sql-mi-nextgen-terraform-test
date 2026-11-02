# SQL Managed Instance Next-gen General Purpose with Terraform

Sample Terraform that answers two questions:

1. **Does Terraform support the Next-gen General Purpose tier?**
2. **Are there constraints around General Purpose vs. Business Critical, or zone redundancy?**

> [!WARNING]
> **azurerm bug found during testing:** with azurerm 4.78.0 and later, standard General Purpose and Business Critical
> Managed Instances can't be planned or destroyed **if the configuration lists `storage_iops` in `lifecycle.ignore_changes`**
> (`storage_iops` is stored as 0, and `ignore_changes` appears to feed it back into the provider's own validation).
> Without that line, upgrading the provider didn't break existing instances (s09, s10). Next-gen GP is not affected. Details, evidence and workaround: [docs/azurerm-storage-iops-bug.md](docs/azurerm-storage-iops-bug.md).
> Reported upstream: [hashicorp/terraform-provider-azurerm#33760](https://github.com/hashicorp/terraform-provider-azurerm/issues/33760).

The configurations were run in **Central US** (`centralus`) in October 2026 (s08 in Sweden Central) with Terraform 1.12.2, azurerm 5.11.0 and azapi 2.x.

> **This is a validation sample, not a production module.** Each scenario creates its own resource group and VNet,
> and two scenarios (s02, s03) are meant to fail. Use it to see what works, then copy the relevant pieces into your own code.

## Summary

| Question | Answer |
|---|---|
| Terraform support | **Yes.** Use `azurerm_mssql_managed_instance` with a `GP_*` SKU and `general_purpose_v2_enabled = true`. Next-gen isn't a separate SKU name. The argument is available from azurerm **4.68.0**, and `storage_iops` from **4.78.0**. Older provider versions can't deploy Next-gen. |
| General Purpose vs. Business Critical | Per the docs, Next-gen is an upgrade to **General Purpose only**, and billing still shows *General Purpose*. Tested: azurerm rejects `BC_*` with `general_purpose_v2_enabled` at plan time (s02). |
| Zone redundancy | Per the docs, Next-gen GP with zone redundancy is **in preview** and needs Elastic SAN ZRS, so it's not available in every region with zone redundancy. Tested: it works in Central US (s04). **azurerm currently blocks this combination at plan time** (s03), so deploy it with the **azapi** provider (s04). |
| Flexible memory | Not exposed by azurerm. The azapi stack can send `memorySizeInGB` (scenarios s06, s08), but this is **untested**: every create attempt, in Central US and in Sweden Central, failed with 500 InternalServerError, so no instance was ever created. |
| Changing IOPS after create | Works in place through **azapi**, about 1.3–1.4 minutes per change, with and without zone redundancy. Changing it through azurerm's `storage_iops` was never tested successfully (blocked by policy, see below). If your environment has an Azure Policy that requires Entra-only authentication, see [Entra-only authentication](#entra-only-authentication). |
| Existing standard GP / BC instances | Upgrading to azurerm 4.78.0+ worked for instances created with 4.77.0 (s09, s10). ⚠️ **Don't list `storage_iops` in `ignore_changes`**: with it, plan and destroy fail. See [docs/azurerm-storage-iops-bug.md](docs/azurerm-storage-iops-bug.md). |

## Results

| ID | Provider | Configuration | Result |
|---|---|---|---|
| s01 | azurerm | GP_Gen5 + Next-gen | ✅ Create → plan (no changes) → IOPS 768 → 1500 (azapi PATCH) → plan → destroy. The plan after the IOPS change proposed no changes to the instance, but exited 2: it reported the new IOPS as a change made outside Terraform and an output change. Default 768 IOPS (3 IOPS/GB × 256 GB). Ran with the earlier stack (`storage_iops` in `ignore_changes`) |
| s02 | azurerm | BC_Gen5 + Next-gen | ❌ Plan fails, as expected: `general_purpose_v2_enabled cannot be set to true on Business Critical SKUs` |
| s03 | azurerm | GP_Gen5 + Next-gen + zone redundant | ❌ Plan fails: `zone_redundant_enabled cannot be set to true when general_purpose_v2_enabled is true` |
| s04 | azapi | GP_Gen5 + Next-gen + zone redundant | ✅ Create → plan (no changes) → IOPS 768 → 1500 → plan → destroy, all clean (preview), with zone-redundant backups |
| s05 | azurerm | BC_Gen5 + zone redundant (no Next-gen) | ⚠️ Created, then plan and destroy fail: [azurerm `storage_iops` bug](docs/azurerm-storage-iops-bug.md), triggered by `storage_iops` in the stack's `ignore_changes` at the time |
| s06 | azapi | GP_G8IM + Next-gen + flexible memory (40 GB), Central US | ⏸️ Not tested: no premium-series quota; create attempts returned 500 InternalServerError |
| s07 | azurerm | GP_Gen5, standard (no Next-gen) | ⚠️ Created, then plan and destroy fail: same [azurerm `storage_iops` bug](docs/azurerm-storage-iops-bug.md) (same `ignore_changes` trigger) |
| s08 | azapi | GP_G8IM + Next-gen + flexible memory (40 GB), Sweden Central | ⏸️ Not tested: quota available, but every create attempt returned 500 InternalServerError (175 failed writes in the activity log over ~7 hours of Terraform retries); no instance was created |
| s09 | azurerm | GP_Gen5, standard: provider upgrade | ✅ Created with 4.77.0; plan clean on 4.78.0, 4.81.0, 5.0.0, 5.11.0, 5.12.0, also after a no-change apply; destroy on 5.11.0 clean. ❌ Plan fails only when `storage_iops` is added to `ignore_changes` |
| s10 | azurerm | BC_Gen5: provider upgrade | ✅ Same results as s09, including a clean destroy on 5.11.0. ❌ Plan fails only when `storage_iops` is added to `ignore_changes` |

Provider version checks (`terraform validate`): azurerm 4.67.0 rejects `general_purpose_v2_enabled`, 4.68.0 accepts it; 4.77.0 rejects `storage_iops`, 4.78.0 accepts it.

### Not tested

- **Flexible memory** (`memory_size_in_gb`): create and later resize. Every create attempt returned 500 InternalServerError (s06, s08).
- **IOPS updates through azurerm `storage_iops`**: every attempt was denied by an Entra-only Azure Policy (see [Entra-only authentication](#entra-only-authentication)). All IOPS changes above were made with the azapi PATCH.
- **This stack's IOPS PATCH flow since `storage_iops` was removed from `ignore_changes`.** s01 ran with it ignored; a plan after an azapi IOPS change hasn't been re-run with the current stack.
- **`terraform import` and zone-redundant BC without `ignore_changes`.**
- **Upgrading long-lived state.** s09/s10 upgraded state written by 4.77.0 minutes earlier, not state that went through many older provider versions.

Create times in these runs: 2–2.5 hours for Next-gen GP and zone-redundant Business Critical, about 20 minutes for Business Critical without zone redundancy, 7–8 minutes for standard GP. Destroy took about 20–25 minutes. Allow for that in pipeline timeouts.

## Entra-only authentication

Both stacks deploy with **Entra-only authentication**: the identity running Terraform becomes the Entra admin, and no SQL login or password is created.
Many organizations enforce this with an Azure Policy deny rule. If your deployments fail with `RequestDisallowedByPolicy`, check the policy named in the error;
the failure may be the policy rather than Next-gen.

**Updates through azurerm under such a policy.** azurerm updates a Managed Instance with a full PUT. In our subscription, a deny policy that requires
`administrators.azureADOnlyAuthentication = true` rejected every azurerm update with 403 `RequestDisallowedByPolicy`: changing `storage_iops`, and changing only tags.
We didn't capture the request body; most likely the PUT doesn't carry `azureADOnlyAuthentication = true` (the ARM reference says it can't be changed through this PUT),
so the policy treats it as missing. Other azurerm updates go through the same PUT and may be affected the same way.
Creation wasn't affected in our tests.

**Workaround:** send the change as a PATCH. The azurerm stack does this with `azapi_resource_action` through the `storage_iops_patch` variable:

```powershell
terraform apply -var-file=../../scenarios/s01-azurerm-nextgen-gp.tfvars -var storage_iops_patch=1500
```

The stack also sets `lifecycle.ignore_changes` on `azure_active_directory_administrator`, as a precaution: without it, a later apply (for example after `terraform import`)
may try to change the Entra-only setting, which can't be changed through this PUT. Not tested without it.

## Layout

```text
docs/                      write-ups of issues found while testing
modules/mi-network/        VNet + delegated subnet + NSG + route table (one per scenario)
stacks/azurerm/            Managed Instance via azurerm_mssql_managed_instance
stacks/azapi/              Managed Instance via the ARM API (azapi_resource), skipping azurerm's validation
scenarios/*.tfvars         one file per scenario
scripts/run-scenario.ps1   runs plan/apply/destroy, one Terraform workspace per scenario
```

## Running

```powershell
az login; az account set -s <subscription>
./scripts/run-scenario.ps1 -Scenario all -Action plan     # safe: plans every scenario, writes results/summary-plan.md
./scripts/run-scenario.ps1 -Scenario s01 -Action apply    # creates a real Managed Instance: takes hours and costs money
./scripts/run-scenario.ps1 -Scenario s04 -Action apply
./scripts/run-scenario.ps1 -Scenario s01 -Action destroy
```

Check what Azure actually stored:

```powershell
az sql mi show -g rg-sqlmi-ng-s01 -n <name> --query "{gpv2:isGeneralPurposeV2, zr:zoneRedundant, iops:storageIOps, mem:memorySizeInGb, sku:sku}"
```

Tips:
- If a long `terraform apply` is interrupted, the Managed Instance keeps provisioning in Azure. Bring it back under Terraform with `terraform import` once it finishes.
- In Git Bash on Windows, set `MSYS_NO_PATHCONV=1` before `terraform import`, or Git Bash rewrites the `/subscriptions/...` resource ID.
- If s04 is rejected because of the API version, set `api_version` to a newer preview version in the tfvars.
- State for s05 or s07 created by the earlier stack (with `storage_iops` in `ignore_changes`) can't be destroyed normally because of the [azurerm `storage_iops` bug](docs/azurerm-storage-iops-bug.md); use the workaround described there.
- The provider lock file isn't committed, so a fresh `terraform init` picks the newest azurerm 5.x (5.12.0 at the time of testing). The s02/s03 plan errors are the same on 5.12.0.

## References
- Next-gen General Purpose: https://learn.microsoft.com/azure/azure-sql/managed-instance/service-tiers-next-gen-general-purpose-use
- Local and zone redundancy: https://learn.microsoft.com/azure/azure-sql/managed-instance/high-availability-sla-local-zone-redundancy
- Resource limits (flexible memory, Next-gen IOPS): https://learn.microsoft.com/azure/azure-sql/managed-instance/resource-limits#flexible-memory
- Elastic SAN regions and ZRS: https://learn.microsoft.com/azure/storage/elastic-san/elastic-san-create#limitations
- Managed Instances REST API (2025-01-01): https://learn.microsoft.com/rest/api/sql/managed-instances/create-or-update?view=rest-sql-2025-01-01
- Microsoft.Sql/managedInstances template reference: https://learn.microsoft.com/azure/templates/microsoft.sql/managedinstances
- azurerm resource docs: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mssql_managed_instance
- azapi_resource / azapi_resource_action: https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/resource, https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/resource_action
- azurerm changelog (4.68.0 `general_purpose_v2_enabled`, 4.78.0 `storage_iops`): https://github.com/hashicorp/terraform-provider-azurerm/blob/main/CHANGELOG-v4.md
