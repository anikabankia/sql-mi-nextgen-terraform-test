# Same retest as s11, on Business Critical. Driven by scripts/storage-iops-fix-retest.ps1.
scenario                   = "s12"
address_space              = "10.60.12.0/24"
sku_name                   = "BC_Gen5"
general_purpose_v2_enabled = false
zone_redundant_enabled     = false
storage_account_type       = "LRS"
