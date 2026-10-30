# Flexible memory on Next-gen GP via azapi (not exposed by azurerm).  EXPECT: apply OK if premium-series quota is available
# Premium-series (G8IM), 4 vCores: default 28 GB; supported values 28, 32, 40, 48.
scenario                  = "s06"
address_space             = "10.60.6.0/24"
sku_name                  = "GP_G8IM"
sku_tier                  = "GeneralPurpose"
sku_family                = "G8IM"
is_general_purpose_v2     = true
zone_redundant            = false
backup_storage_redundancy = "Local"
memory_size_in_gb         = 40
