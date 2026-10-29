# Q1: Does Terraform (azurerm) deploy Next-gen GP?            EXPECT: plan OK, apply OK
# To change IOPS after create, set storage_iops_patch (e.g. -var storage_iops_patch=1500) and re-apply.
scenario                   = "s01"
address_space              = "10.60.1.0/24"
sku_name                   = "GP_Gen5"
general_purpose_v2_enabled = true
storage_iops               = null
zone_redundant_enabled     = false
storage_account_type       = "LRS"
