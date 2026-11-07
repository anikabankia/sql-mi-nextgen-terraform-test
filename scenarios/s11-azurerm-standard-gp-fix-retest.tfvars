# Retest of the azurerm storage_iops fix on standard GP: create with 5.12.0 and storage_iops in ignore_changes, confirm the
# failure on 5.12.0, then plan and destroy the same state on the fixed version. Driven by scripts/storage-iops-fix-retest.ps1.
scenario                   = "s11"
address_space              = "10.60.11.0/24"
sku_name                   = "GP_Gen5"
general_purpose_v2_enabled = false
zone_redundant_enabled     = false
storage_account_type       = "LRS"
