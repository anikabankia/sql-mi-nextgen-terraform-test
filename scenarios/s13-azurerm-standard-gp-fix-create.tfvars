# Standard GP created directly on the fixed version with storage_iops in ignore_changes: create, plan, destroy.
# Driven by scripts/storage-iops-fix-retest.ps1.
scenario                   = "s13"
address_space              = "10.60.13.0/24"
sku_name                   = "GP_Gen5"
general_purpose_v2_enabled = false
zone_redundant_enabled     = false
storage_account_type       = "LRS"
