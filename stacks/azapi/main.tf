# Bypasses azurerm's client-side validation and sends the ARM payload directly,
# so the *service* decides whether a combination (e.g. Next-gen GP + zone redundancy) is allowed.

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

resource "azapi_resource" "mi" {
  type      = "Microsoft.Sql/managedInstances@${var.api_version}"
  name      = "${local.name_prefix}-${random_string.suffix.result}"
  parent_id = azurerm_resource_group.this.id
  location  = var.location
  tags      = local.tags

  # Skip local schema validation so preview-only properties aren't rejected before reaching Azure.
  schema_validation_enabled = false

  body = {
    sku = {
      name     = var.sku_name
      tier     = var.sku_tier
      family   = var.sku_family
      capacity = var.vcores
    }
    properties = merge(
      {
        # Entra-only auth (no SQL login/password), which policies requiring Entra-only auth expect.
        administrators = {
          administratorType         = "ActiveDirectory"
          principalType             = "User"
          login                     = var.entra_admin_login
          sid                       = data.azurerm_client_config.current.object_id
          tenantId                  = data.azurerm_client_config.current.tenant_id
          azureADOnlyAuthentication = true
        }
        subnetId                         = module.network.subnet_id
        vCores                           = var.vcores
        storageSizeInGB                  = var.storage_size_in_gb
        licenseType                      = var.license_type
        isGeneralPurposeV2               = var.is_general_purpose_v2
        zoneRedundant                    = var.zone_redundant
        requestedBackupStorageRedundancy = var.backup_storage_redundancy
      },
      var.storage_iops == null ? {} : { storageIOps = var.storage_iops }
    )
  }

  response_export_values = [
    "properties.isGeneralPurposeV2",
    "properties.zoneRedundant",
    "properties.storageIOps",
    "properties.memorySizeInGB",
    "properties.requestedBackupStorageRedundancy",
    "sku",
  ]

  timeouts {
    create = "24h"
    update = "24h"
    delete = "24h"
  }
}
