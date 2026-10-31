locals {
  name_prefix = "sqlmi-ng-${var.scenario}"
  tags = {
    purpose  = "nextgen-gp-terraform-sample"
    scenario = var.scenario
  }
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.tags
}

module "network" {
  source              = "../../modules/mi-network"
  name_prefix         = local.name_prefix
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = var.address_space
  tags                = local.tags
}

resource "azurerm_mssql_managed_instance" "this" {
  name                = "${local.name_prefix}-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  subnet_id           = module.network.subnet_id

  sku_name           = var.sku_name
  vcores             = var.vcores
  storage_size_in_gb = var.storage_size_in_gb
  license_type       = var.license_type

  # --- the properties under test ---
  general_purpose_v2_enabled = var.general_purpose_v2_enabled
  storage_iops               = var.storage_iops
  zone_redundant_enabled     = var.zone_redundant_enabled
  storage_account_type       = var.storage_account_type

  # Entra-only auth (no SQL login/password), which policies requiring Entra-only auth expect.
  azure_active_directory_administrator {
    login_username                      = var.entra_admin_login
    object_id                           = data.azurerm_client_config.current.object_id
    tenant_id                           = data.azurerm_client_config.current.tenant_id
    principal_type                      = "User"
    azuread_authentication_only_enabled = true
  }

  tags = local.tags

  # azure_active_directory_administrator: any diff makes azurerm disable Entra-only auth first, which Azure
  # rejects (no SQL admin to fall back to). Import never reads it back, so it always diffs after import.
  # Don't add storage_iops here: azurerm 4.78+ stores 0 for non-Next-gen instances and ignore_changes feeds that 0 back
  # into its own validation, breaking plan/destroy (docs/azurerm-storage-iops-bug.md). With storage_iops left null,
  # IOPS changed later through azapi_resource_action.iops below shouldn't show as a diff (not yet re-tested on Next-gen).
  lifecycle {
    ignore_changes = [azure_active_directory_administrator]
  }

  timeouts {
    create = "24h"
    update = "24h"
    delete = "24h"
  }
}

# azurerm updates PUT the whole MI with `administrators` cleared, so a deny policy requiring Entra-only auth
# rejects them. A PATCH carrying only the changed property passes.
resource "azapi_resource_action" "iops" {
  count       = var.storage_iops_patch == null ? 0 : 1
  type        = "Microsoft.Sql/managedInstances@2025-01-01"
  resource_id = azurerm_mssql_managed_instance.this.id
  method      = "PATCH"
  body = {
    properties = { storageIOps = var.storage_iops_patch }
  }

  timeouts {
    create = "6h"
  }
}
