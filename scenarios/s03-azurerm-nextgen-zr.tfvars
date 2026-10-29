# Q2b: Next-gen GP + zone redundancy via azurerm?             EXPECT: plan FAILS (azurerm validation blocks ZR + GPv2)
# NOTE: the service supports this combination in PREVIEW (requires Elastic SAN ZRS; Central US is supported) - see s04.
scenario                   = "s03"
address_space              = "10.60.3.0/24"
sku_name                   = "GP_Gen5"
general_purpose_v2_enabled = true
zone_redundant_enabled     = true
storage_account_type       = "ZRS"
