# Provider upgrade on an existing Business Critical instance (same test as s09, BC instead of standard GP): create with
# azurerm 4.77.0, plan with newer versions, persist state with a no-change apply, compare ignore_changes variants,
# destroy with 5.11.0 without ignore_changes. Driven by scripts/provider-upgrade-test.ps1.
scenario                   = "s10"
address_space              = "10.60.10.0/24"
sku_name                   = "BC_Gen5"
general_purpose_v2_enabled = false
zone_redundant_enabled     = false
storage_account_type       = "LRS"
