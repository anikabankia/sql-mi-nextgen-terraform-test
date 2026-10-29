# Baseline: Business Critical + zone redundancy (no Next-gen). EXPECT: plan OK, apply OK. Costly - apply only if needed.
scenario                   = "s05"
address_space              = "10.60.5.0/24"
sku_name                   = "BC_Gen5"
general_purpose_v2_enabled = false
zone_redundant_enabled     = true
storage_account_type       = "ZRS"
