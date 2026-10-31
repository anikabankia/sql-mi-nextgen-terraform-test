# Flexible memory on Next-gen GP via azapi, in Sweden Central (premium-series quota is 0 in US regions for the test subscription).
# Premium-series (G8IM), 4 vCores: default 28 GB; supported values 28, 32, 40, 48. Change after create with -var memory_size_in_gb=48.
scenario                  = "s08"
location                  = "swedencentral"
address_space             = "10.60.8.0/24"
sku_name                  = "GP_G8IM"
sku_tier                  = "GeneralPurpose"
sku_family                = "G8IM"
is_general_purpose_v2     = true
zone_redundant            = false
backup_storage_redundancy = "Local"
memory_size_in_gb         = 40
