# Provider upgrade on an existing standard GP instance: create with azurerm 4.77.0 (before storage_iops existed),
# then plan the same config and state with 4.78.0, 4.81.0, 5.0.0, 5.11.0 and 5.12.0. Driven by scripts/provider-upgrade-test.ps1,
# which uses a copy of stacks/azurerm without storage_iops (4.77.0 doesn't know the argument).
scenario                   = "s09"
address_space              = "10.60.9.0/24"
sku_name                   = "GP_Gen5"
general_purpose_v2_enabled = false
zone_redundant_enabled     = false
storage_account_type       = "LRS"
