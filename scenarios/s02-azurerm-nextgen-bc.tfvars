# Q2a: Next-gen + Business Critical?                          EXPECT: plan FAILS (azurerm validation - Next-gen is a GP-only upgrade)
scenario                   = "s02"
address_space              = "10.60.2.0/24"
sku_name                   = "BC_Gen5"
general_purpose_v2_enabled = true
zone_redundant_enabled     = false
storage_account_type       = "LRS"
