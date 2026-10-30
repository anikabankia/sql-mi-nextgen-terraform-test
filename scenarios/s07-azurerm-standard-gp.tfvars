# Standard (non-Next-gen) GP via azurerm: is it hit by the storage_iops=0 read-back bug seen on BC (s05)? RESULT: create OK, plan/destroy fail (docs/azurerm-storage-iops-bug.md)
scenario                   = "s07"
address_space              = "10.60.7.0/24"
sku_name                   = "GP_Gen5"
general_purpose_v2_enabled = false
zone_redundant_enabled     = false
storage_account_type       = "LRS"
