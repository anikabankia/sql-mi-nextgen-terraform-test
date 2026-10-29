# SQL Managed Instance Next-gen General Purpose with Terraform

Sample Terraform that answers two questions:

1. **Does Terraform support the Next-gen General Purpose tier?**
2. **Are there constraints around General Purpose vs. Business Critical, or zone redundancy?**

The configurations were run in **Central US** (`centralus`) in October 2026 with Terraform 1.12.2, azurerm 5.11.0 and azapi 2.x.

> **This is a validation sample, not a production module.** Each scenario creates its own resource group and VNet,
> and two scenarios (s02, s03) are meant to fail. Use it to see what works, then copy the relevant pieces into your own code.

## Summary

| Question | Answer |
|---|---|
| Terraform support | **Yes.** Use `azurerm_mssql_managed_instance` with a `GP_*` SKU and `general_purpose_v2_enabled = true`. Next-gen isn't a separate SKU name. The argument is available from azurerm **4.68.0**, and `storage_iops` from **4.78.0**. Older provider versions can't deploy Next-gen. |
| General Purpose vs. Business Critical | Next-gen is an upgrade to **General Purpose only**. There's no Next-gen Business Critical. azurerm rejects `BC_*` with `general_purpose_v2_enabled` at plan time. Billing still shows *General Purpose*. |
| Zone redundancy | Next-gen GP with zone redundancy is supported by the service **in preview**. It needs Elastic SAN ZRS, so it's not available in every region with zone redundancy; Central US has it. **azurerm currently blocks this combination at plan time**, so deploy it with the **azapi** provider (scenario s04). |
| Flexible memory | Not exposed by azurerm. Set `memorySizeInGB` through azapi if you need it. |
| Changing IOPS after create | Works in place. If your environment has an Azure Policy that requires Entra-only authentication, see [Entra-only authentication](#entra-only-authentication). |

## Results

| ID | Provider | Configuration | Result |
|---|---|---|---|
| s01 | azurerm | GP_Gen5 + Next-gen | ✅ Deployed. Default 768 IOPS (3 IOPS/GB × 256 GB). IOPS later changed in place to 1500 and 2000 |
| s02 | azurerm | BC_Gen5 + Next-gen | ❌ Plan fails, as expected: `general_purpose_v2_enabled cannot be set to true on Business Critical SKUs` |
| s03 | azurerm | GP_Gen5 + Next-gen + zone redundant | ❌ Plan fails: `zone_redundant_enabled cannot be set to true when general_purpose_v2_enabled is true` |
| s04 | azapi | GP_Gen5 + Next-gen + zone redundant | ✅ Deployed (preview), with zone-redundant backups |
| s05 | azurerm | BC_Gen5 + zone redundant (no Next-gen) | ✅ Deployed. Comparison case |

Creating a Managed Instance can take several hours, so allow for that in pipeline timeouts.

## Entra-only authentication

Both stacks deploy with **Entra-only authentication**: the identity running Terraform becomes the Entra admin, and no SQL login or password is created.
Many organizations enforce this with an Azure Policy deny rule. If your deployments fail with `RequestDisallowedByPolicy`, check the policy named in the error;
the failure may be the policy rather than Next-gen.

**Updates through azurerm under such a policy.** When azurerm updates a Managed Instance, it sends the whole resource as a PUT with the
`administrators` block left empty. A deny policy that checks `administrators.azureADOnlyAuthentication` can reject that request.
We saw this when changing `storage_iops` (403 `RequestDisallowedByPolicy`). We only tested IOPS, but other azurerm updates go through the same PUT and may be affected the same way.
Creation isn't affected, because the create request includes the administrator.

**Workaround:** send the change as a PATCH. The azurerm stack does this with `azapi_resource_action` through the `storage_iops_patch` variable:

```powershell
terraform apply -var-file=../../scenarios/s01-azurerm-nextgen-gp.tfvars -var storage_iops_patch=1500
```

The stack also sets `lifecycle.ignore_changes` on `azure_active_directory_administrator`. Without it, a later apply (for example after `terraform import`)
tries to turn Entra-only authentication off first, which Azure rejects.

## Layout

```
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

## References
- Next-gen General Purpose: https://learn.microsoft.com/azure/azure-sql/managed-instance/service-tiers-next-gen-general-purpose-use
- Elastic SAN regions and ZRS: https://learn.microsoft.com/azure/storage/elastic-san/elastic-san-create#limitations
- azurerm resource docs: https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mssql_managed_instance
