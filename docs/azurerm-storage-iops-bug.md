# azurerm bug: non-Next-gen Managed Instances can't be planned or destroyed

**Affected:** `azurerm_mssql_managed_instance`, azurerm **4.78.0 and later** (tested through 5.12.0)
**Affected instances:** standard General Purpose and Business Critical (anything with `general_purpose_v2_enabled = false`)
**Not affected:** Next-gen General Purpose (`general_purpose_v2_enabled = true`)
**Status:** reported upstream as [hashicorp/terraform-provider-azurerm#33760](https://github.com/hashicorp/terraform-provider-azurerm/issues/33760)

## What happens

1. `terraform apply` creates a standard GP or Business Critical Managed Instance successfully.
2. Every later `terraform plan` fails, and so does `terraform destroy`:

   ```text
   Error: `storage_iops` can only be set when `general_purpose_v2_enabled` is `true`

     with azurerm_mssql_managed_instance.this,
     on main.tf line 32, in resource "azurerm_mssql_managed_instance" "this":
   ```

3. This happens even though `storage_iops` is **not set** in the configuration.

The same thing happens after `terraform import` of an existing non-Next-gen instance.

## Why

- Configurable IOPS only exists on Next-gen GP. For standard GP and Business Critical, Azure returns no IOPS value: `az sql mi show` reports `storageIops: null`.
- When the provider reads the instance, it stores `storage_iops = 0` in Terraform state instead of leaving it empty.
- The provider's own validation says `storage_iops` may only be set when `general_purpose_v2_enabled` is true. It sees `0`, treats it as set, and rejects the plan.

In short, the provider rejects a value it wrote itself. Azure is behaving correctly; the bug is in the provider.
(The read-path explanation fits all the evidence below but hasn't been confirmed in the provider source.)

`storage_iops` was added in 4.78.0 ([#32250](https://github.com/hashicorp/terraform-provider-azurerm/pull/32250)). 4.77.0 rejects the argument outright, so 4.78.0 is the earliest version that can be affected.

## Why it matters

To manage IOPS on Next-gen GP you need azurerm 4.78.0 or later. If the same Terraform configuration or state also manages existing standard GP or Business Critical instances, upgrading the provider can make `terraform plan` fail for those instances. That blocks every change in that configuration, not just changes to the MI.

**Before upgrading azurerm past 4.77, run `terraform plan` against your existing non-Next-gen instances on the new version.**

## What we tested

All tests in Central US, Terraform 1.12.2, using the `stacks/azurerm` configuration in this repo.

| Instance | How it got into state | Provider | plan after create | destroy |
|---|---|---|---|---|
| Business Critical, zone redundant (s05) | created by Terraform | 5.11.0 | ❌ error above | ❌ error above |
| Business Critical, zone redundant | `terraform import` | 5.11.0 | ❌ | ❌ |
| Business Critical (same instance, plan only) | state from 5.11.0 | 4.78.0, 4.81.0, 5.0.0, 5.12.0 | ❌ on every version | not run |
| Standard GP, `GP_Gen5`, no zone redundancy (s07) | created by Terraform | 5.11.0 | ❌ | ❌ |
| Next-gen GP (s01) | created by Terraform | 5.11.0 | ✅ no changes | ✅ |
| Next-gen GP, zone redundant, via azapi (s04) | created by Terraform | azapi | ✅ no changes | ✅ |

Things we tried that **don't** help:

- `lifecycle { ignore_changes = [storage_iops] }` (the stack already has it)
- Setting `storage_iops` to null in state: plan refreshes from Azure and fails again (tested on 4.78.0, 5.11.0 and 5.12.0)
- Leaving `storage_iops` unset (`null`) in configuration

Not tested: standard GP on provider versions other than 5.11.0; regions other than Central US.

## Workaround

You can still **destroy** an affected instance:

```powershell
# 1. Clear storage_iops in state
terraform state pull > state.json
#    edit state.json: in the azurerm_mssql_managed_instance resource, set "storage_iops": null
#    and increase the top-level "serial" by 1
terraform state push state.json

# 2. Destroy without refreshing (refresh would read the 0 back)
terraform destroy -refresh=false
```

This worked for both the Business Critical and the standard GP instance. If an earlier delete of the instance is still running, the destroy can fail with a subnet error
(`NetworkSecurityGroupCannotBeRemovedDueToNipOnSubnet`). Wait until the Managed Instance and its virtual cluster are gone from the resource group, then run `terraform destroy` again.

We haven't found a workaround that lets you keep **managing** an affected instance (plan/apply) on 4.78.0 or later. Options until it's fixed:

- Keep non-Next-gen instances in a separate configuration pinned to azurerm `< 4.78.0` (4.68.0+ still supports `general_purpose_v2_enabled`).
- Manage Next-gen IOPS through `azapi` instead of azurerm's `storage_iops`.

Neither option has been tested end to end here.

## Likely fix

On read, leave `storage_iops` unset when the API returns no value (or when `isGeneralPurposeV2` is false), instead of storing `0`.
