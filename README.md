# SQL Managed Instance Next-gen General Purpose with Terraform

Sample Terraform that answers two questions:

1. **Does Terraform support the Next-gen General Purpose tier?**
2. **Are there constraints around General Purpose vs. Business Critical, or zone redundancy?**

> [!NOTE]
> **azurerm bug fixed in 5.13.0:** with azurerm 4.78.0 through 5.12.0, standard General Purpose and Business Critical
> Managed Instances can't be planned or destroyed **if the configuration lists `storage_iops` in `lifecycle.ignore_changes`**.
> [PR #33778](https://github.com/hashicorp/terraform-provider-azurerm/pull/33778) fixes it in 5.13.0, confirmed by s11, s12 and s13. Next-gen GP wasn't affected, but use 5.13.0 or later.
> Details and workaround for older versions: [docs/azurerm-storage-iops-bug.md](docs/azurerm-storage-iops-bug.md). Upstream issue: [#33760](https://github.com/hashicorp/terraform-provider-azurerm/issues/33760).

The latest run (s11 to s27, November 2026) used Terraform 1.12.2, azurerm 5.13.0 and azapi 2.13.0 in **Central US** (`centralus`), with flexible memory in Sweden Central and UK South. s11 and s12 created their instances on azurerm 5.12.0 first. The earlier scenarios (s01 to s10, October 2026) used azurerm 5.11.0 and azapi 2.x, except for the provider versions listed in the s09 and s10 rows; s08 ran in Sweden Central.

> **This is a validation sample, not a production module.** Each scenario creates its own resource group and VNet,
> and two scenarios (s02, s03) are meant to fail. Use it to see what works, then copy the relevant pieces into your own code.

## Summary

| Question | Answer |
|---|---|
| Terraform support | **Yes.** Use `azurerm_mssql_managed_instance` with a `GP_*` SKU and `general_purpose_v2_enabled = true`. Next-gen isn't a separate SKU name. The argument is available from azurerm **4.68.0**, and `storage_iops` from **4.78.0**. Older provider versions can't deploy Next-gen. Tested on **5.13.0**: create, plan, import and destroy (s21); use 5.13.0 or later. |
| General Purpose vs. Business Critical | Per the docs, Next-gen is an upgrade to **General Purpose only**, and billing still shows *General Purpose*. Tested: azurerm rejects `BC_*` with `general_purpose_v2_enabled` at plan time (s02). |
| Zone redundancy | Per the docs, Next-gen GP with zone redundancy is **in preview** and needs Elastic SAN ZRS, so it's not available in every region with zone redundancy. **azurerm blocks this combination at plan time** (s03, s20), so Terraform can only deploy it through the **azapi** provider. Tested with azapi in Central US (s04, s23): that shows the preview works, not that it's ready for production. |
| Flexible memory | Not exposed by azurerm (checked on 5.13.0). Per the docs, it's generally available for locally redundant instances on Premium-series hardware. The azapi stack can send `memorySizeInGB`, but this is **untested**: every attempt to create a `GP_G8IM` Next-gen instance returned 500 InternalServerError, even with no memory setting (s06, s08, s25, s26, s27), so no instance was ever created. Cause unknown; it may be specific to our subscription. |
| Setting IOPS | At create, azurerm's `storage_iops` works (s22). After create, changes work in place through **azapi**, about 1.3–1.8 minutes each, with and without zone redundancy (s21, s23). Changing it through azurerm's `storage_iops` was never tested successfully (blocked by policy, see below). If your environment has an Azure Policy that requires Entra-only authentication, see [Entra-only authentication](#entra-only-authentication). |
| Existing standard GP / BC instances | Upgrading to azurerm 4.78.0+ worked for instances created with 4.77.0 (s09, s10). Listing `storage_iops` in `ignore_changes` makes plan and destroy fail before 5.13.0, and works on 5.13.0 (s11, s12, s13). See [docs/azurerm-storage-iops-bug.md](docs/azurerm-storage-iops-bug.md). |

## Results

| ID | Provider | Configuration | Result |
|---|---|---|---|
| s01 | azurerm | GP_Gen5 + Next-gen | ✅ Create → plan (no changes) → IOPS 768 → 1500 (azapi PATCH) → plan → destroy. The plan after the IOPS change proposed no changes to the instance, but exited 2: it reported the new IOPS as a change made outside Terraform and an output change. Default 768 IOPS (3 IOPS/GB × 256 GB). Ran with the earlier stack (`storage_iops` in `ignore_changes`) |
| s02 | azurerm | BC_Gen5 + Next-gen | ❌ Plan fails, as expected: `general_purpose_v2_enabled cannot be set to true on Business Critical SKUs` |
| s03 | azurerm | GP_Gen5 + Next-gen + zone redundant | ❌ Plan fails: `zone_redundant_enabled cannot be set to true when general_purpose_v2_enabled is true` |
| s04 | azapi | GP_Gen5 + Next-gen + zone redundant | ✅ Create → plan (no changes) → IOPS 768 → 1500 → plan → destroy, all clean (preview), with zone-redundant backups |
| s05 | azurerm | BC_Gen5 + zone redundant (no Next-gen) | ⚠️ Created, then plan and destroy fail: [azurerm `storage_iops` bug](docs/azurerm-storage-iops-bug.md), triggered by `storage_iops` in the stack's `ignore_changes` at the time. Fixed in 5.13.0, but zone-redundant BC wasn't retested |
| s06 | azapi | GP_G8IM + Next-gen + flexible memory (40 GB), Central US | ⏸️ Not tested: no premium-series quota; create attempts returned 500 InternalServerError |
| s07 | azurerm | GP_Gen5, standard (no Next-gen) | ⚠️ Created, then plan and destroy fail: same [azurerm `storage_iops` bug](docs/azurerm-storage-iops-bug.md) (same `ignore_changes` trigger). Fixed in 5.13.0 (s11, s13) |
| s08 | azapi | GP_G8IM + Next-gen + flexible memory (40 GB), Sweden Central | ⏸️ Not tested: quota available, but every create attempt returned 500 InternalServerError (175 failed writes in the activity log over ~7 hours of Terraform retries); no instance was created |
| s09 | azurerm | GP_Gen5, standard: provider upgrade | ✅ Created with 4.77.0; plan clean on 4.78.0, 4.81.0, 5.0.0, 5.11.0, 5.12.0, also after a no-change apply; destroy on 5.11.0 clean. ❌ Plan fails only when `storage_iops` is added to `ignore_changes` |
| s10 | azurerm | BC_Gen5: provider upgrade | ✅ Same results as s09, including a clean destroy on 5.11.0. ❌ Plan fails only when `storage_iops` is added to `ignore_changes` |
| s11 | azurerm | GP_Gen5, standard: bug fix retest | ✅ Created on 5.12.0 with `storage_iops` in `ignore_changes`; plan on 5.12.0 still fails. On 5.13.0: plans clean (three config variants), no-change apply, import, plan with no changes, destroy. `storage_iops = 1000` is still rejected. State still holds 0 |
| s12 | azurerm | BC_Gen5: bug fix retest | ✅ Same results as s11 |
| s13 | azurerm | GP_Gen5, standard: created on 5.13.0 | ✅ Create → plan (no changes) → destroy, with `storage_iops` in `ignore_changes` |
| s20 | none | Checks on 5.13.0 with no instance | ✅ s02 and s03 still rejected at plan; no memory argument in azurerm; minimum versions unchanged; azapi zone-redundant config plans |
| s21 | azurerm | GP_Gen5 + Next-gen | ✅ Create → plan (no changes) → plan with `storage_iops` in `ignore_changes` (no changes) → import → plan (no changes) → IOPS 768 → 1500 → 2000 (azapi PATCH) → destroy. Each plan after a PATCH proposed no changes to the instance, but exited 2: it reported the new IOPS as changed outside Terraform and an output change. ❌ azurerm IOPS and tags updates: 403 `RequestDisallowedByPolicy` |
| s22 | azurerm | GP_Gen5 + Next-gen, `storage_iops = 1500` at create | ✅ Azure reports 1500 IOPS → plan (no changes) → destroy. ❌ azurerm IOPS update: 403 `RequestDisallowedByPolicy` |
| s23 | azapi | GP_Gen5 + Next-gen + zone redundant | ✅ Create → plan (no changes) → IOPS 768 → 1500 → plan (no changes) → destroy (preview) |
| s25 | azapi | GP_G8IM + Next-gen, no memory setting, GA API, Sweden Central | ⏸️ Not tested: all 16 create attempts returned 500 InternalServerError; stopped early, no instance created |
| s26 | azapi | GP_G8IM + Next-gen, 40 GB, preview API, Sweden Central | ⏸️ Not tested: all 16 create attempts returned 500 InternalServerError; stopped early, no instance created |
| s27 | azapi | GP_G8IM + Next-gen, 40 GB, GA API, UK South | ⏸️ Not tested: all 15 create attempts returned 500 InternalServerError; stopped early, no instance created |

s11 to s13 are driven by `scripts/storage-iops-fix-retest.ps1`, and s20 to s29 by `scripts/full-retest.ps1`. s24, s28 and s29 are defined in that script but weren't run, because they aren't Next-gen.

Provider version checks (`terraform validate`, last run in s20): azurerm 4.67.0 rejects `general_purpose_v2_enabled`, 4.68.0 accepts it; 4.77.0 rejects `storage_iops`, 4.78.0 accepts it.

### Not tested

- **Flexible memory** (`memory_size_in_gb`): create and later resize. Every create attempt returned 500 InternalServerError (s06, s08, s25, s26, s27). Zone-redundant flexible memory, which the docs list as preview, wasn't tried.
- **IOPS updates through azurerm `storage_iops`**: every attempt was denied by an Entra-only Azure Policy, most recently on 5.13.0 (see [Entra-only authentication](#entra-only-authentication)). All IOPS changes above were made through azapi.
- **Zone-redundant BC on 5.13.0**, the original s05 failure. Non-zone-redundant BC passed (s12).
- **`terraform import` of standard GP or BC without `ignore_changes`.** Import on 5.13.0 was tested for Next-gen without it (s21), and for standard GP and BC with it (s11, s12).
- **Upgrading long-lived state.** s09, s10, s11 and s12 upgraded state written minutes earlier, not state that went through many older provider versions.

Create times in these runs: Next-gen GP took about 11 minutes through azurerm (s21, s22) and about 23 minutes with zone redundancy through azapi (s23) in November, but 2–2.5 hours in October (s01, s04). We don't know why they differ, so allow for the longer time in pipeline timeouts. Business Critical without zone redundancy took 20–36 minutes, zone-redundant Business Critical about 2.3 hours, and standard GP 7–8 minutes. Destroy took about 20–32 minutes.

## Entra-only authentication

Both stacks deploy with **Entra-only authentication**: the identity running Terraform becomes the Entra admin, and no SQL login or password is created.
Many organizations enforce this with an Azure Policy deny rule. If your deployments fail with `RequestDisallowedByPolicy`, check the policy named in the error;
the failure may be the policy rather than Next-gen.

**Updates through azurerm under such a policy.** azurerm updates a Managed Instance with a full PUT. In our subscription, a deny policy that requires
`administrators.azureADOnlyAuthentication = true` rejected every azurerm update with 403 `RequestDisallowedByPolicy`, most recently on 5.13.0 (s21, s22): changing `storage_iops`, and changing only tags.
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
scripts/*-test.ps1, *-retest.ps1   the provider upgrade and retest runs recorded above
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
- On azurerm 5.12.0 or earlier, an instance managed with `storage_iops` in `ignore_changes` can't be destroyed normally because of the [azurerm `storage_iops` bug](docs/azurerm-storage-iops-bug.md). Upgrade to 5.13.0 (s11, s12), or use the workaround described there.
- The provider lock file isn't committed, so a fresh `terraform init` picks the newest azurerm version (5.13.0 at the time of testing). The s02/s03 plan errors are the same on 5.13.0.

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
- azurerm 5.13.0 release notes (`storage_iops` fix): https://github.com/hashicorp/terraform-provider-azurerm/releases/tag/v5.13.0
