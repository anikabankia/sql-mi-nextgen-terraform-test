# azurerm bug: `ignore_changes = [storage_iops]` breaks non-Next-gen Managed Instances

**Affected:** `azurerm_mssql_managed_instance`, azurerm **4.78.0 and later** (tested through 5.12.0), **only when the configuration lists `storage_iops` in `lifecycle.ignore_changes`**
**Affected instances:** standard General Purpose and Business Critical (anything with `general_purpose_v2_enabled = false`)
**Not affected:** Next-gen General Purpose (`general_purpose_v2_enabled = true`), and configurations that don't ignore `storage_iops`
**Status:** reported upstream as [hashicorp/terraform-provider-azurerm#33760](https://github.com/hashicorp/terraform-provider-azurerm/issues/33760)

> An earlier version of this page said every non-Next-gen instance was affected after create, import or a provider upgrade.
> Tests s09 and s10 showed that only configurations with `storage_iops` in `ignore_changes` fail. This repo's own stack had that line, which is why s05 and s07 failed.

## What happens

With `storage_iops` in `ignore_changes`, a standard GP or Business Critical instance is created successfully, but every later `terraform plan` fails, and so does `terraform destroy`:

```text
Error: `storage_iops` can only be set when `general_purpose_v2_enabled` is `true`
```

This happens even though `storage_iops` is not set in the configuration. The same happens after `terraform import`.

## Why

- Configurable IOPS only exists on Next-gen GP. For standard GP and Business Critical, Azure returns no IOPS value (`az sql mi show` reports `storageIops: null`).
- From 4.78.0, the provider stores `storage_iops = 0` in state when it reads such an instance, instead of leaving it empty.
- Without `ignore_changes`, that 0 is harmless: the configuration value stays null and the provider's validation passes.
- With `ignore_changes = [storage_iops]`, Terraform copies the prior state value (0) into the configuration before the provider plans. The provider's validation sees `storage_iops = 0` with `general_purpose_v2_enabled = false`, treats it as set, and rejects the plan.

So the provider rejects a value it wrote itself, but only when `ignore_changes` feeds it back. (This explanation fits every result below but hasn't been confirmed in the provider source.)

`storage_iops` was added in 4.78.0 ([#32250](https://github.com/hashicorp/terraform-provider-azurerm/pull/32250)). 4.77.0 rejects the argument, so a configuration written for 4.77.0 or earlier can't list it in `ignore_changes`.

## What we tested

Central US, Terraform 1.12.2.

**Upgrade tests (s09 standard GP `GP_Gen5`, s10 Business Critical `BC_Gen5`).** Instance created with azurerm 4.77.0 from a configuration without `storage_iops`; the same configuration and state were then used with newer versions. Results were identical for both instance types:

| Step | Provider | Result |
|---|---|---|
| plan | 4.77.0 | ✅ no changes |
| plan (state from 4.77.0) | 4.78.0, 4.81.0, 5.0.0, 5.11.0, 5.12.0 | ✅ no changes on every version |
| no-change `apply` (writes `storage_iops = 0` to state), then plan | 4.78.0, 5.11.0 | ✅ no changes |
| plan, `storage_iops = null` in config, no `ignore_changes` | 5.11.0 | ✅ no changes |
| plan, `ignore_changes` includes `storage_iops` | 5.11.0 | ❌ error above |
| plan, `storage_iops = null` + `ignore_changes` includes `storage_iops` | 5.11.0 | ❌ error above |
| destroy, no `ignore_changes`, state has `storage_iops = 0` | 5.11.0 | ✅ both (s09, s10) |

**Earlier tests, with this repo's stack as it was then (`storage_iops = var.storage_iops` plus `ignore_changes = [..., storage_iops]`):**

| Instance | How it got into state | Provider | plan | destroy |
|---|---|---|---|---|
| Business Critical, zone redundant (s05) | created by Terraform | 5.11.0 | ❌ | ❌ |
| Business Critical, zone redundant | `terraform import` | 5.11.0 | ❌ | ❌ |
| Business Critical (same instance, plan only) | state from 5.11.0 | 4.78.0, 4.81.0, 5.0.0, 5.12.0 | ❌ | not run |
| Standard GP (s07) | created by Terraform | 5.11.0 | ❌ | ❌ |
| Next-gen GP (s01) | created by Terraform | 5.11.0 | ✅ | ✅ |

Not tested: `terraform import` without `ignore_changes`; zone-redundant BC without `ignore_changes`; regions other than Central US.

## What to do

- **Don't list `storage_iops` in `ignore_changes`** for configurations that manage standard GP or Business Critical instances. Removing it is enough; `storage_iops` can stay unset or `null`.
- Before upgrading azurerm past 4.77, run `terraform plan` against existing instances on the new version as a precaution.

**Destroying an affected instance without changing the configuration:**

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

## Likely fix

On read, leave `storage_iops` unset when the API returns no value (or when `isGeneralPurposeV2` is false), instead of storing `0`.
