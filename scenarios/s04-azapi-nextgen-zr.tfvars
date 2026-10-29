# Q2b workaround: Next-gen GP + zone redundancy via azapi.    EXPECT: apply OK if the ZR preview is available to the subscription in Central US
scenario                  = "s04"
address_space             = "10.60.4.0/24"
sku_name                  = "GP_Gen5"
sku_tier                  = "GeneralPurpose"
sku_family                = "Gen5"
is_general_purpose_v2     = true
zone_redundant            = true
backup_storage_redundancy = "Zone"
