output "managed_instance_name" {
  value = azurerm_mssql_managed_instance.this.name
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "general_purpose_v2_enabled" {
  value = azurerm_mssql_managed_instance.this.general_purpose_v2_enabled
}

output "storage_iops" {
  value = azurerm_mssql_managed_instance.this.storage_iops
}

output "zone_redundant_enabled" {
  value = azurerm_mssql_managed_instance.this.zone_redundant_enabled
}
