output "managed_instance_name" {
  value = azapi_resource.mi.name
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "service_reported" {
  description = "What Azure actually stored for the properties under test."
  value       = azapi_resource.mi.output
}
