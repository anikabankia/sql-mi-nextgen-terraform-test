variable "subscription_id" {
  type    = string
  default = null
}

variable "scenario" {
  type = string
}

variable "location" {
  type    = string
  default = "centralus"
}

variable "address_space" {
  type    = string
  default = "10.60.4.0/24"
}

variable "api_version" {
  type        = string
  description = "Microsoft.Sql API version. Try a newer *-preview version if the service rejects preview features."
  default     = "2025-01-01"
}

variable "sku_name" {
  type    = string
  default = "GP_Gen5"
}

variable "sku_tier" {
  type    = string
  default = "GeneralPurpose"
}

variable "sku_family" {
  type    = string
  default = "Gen5"
}

variable "vcores" {
  type    = number
  default = 4
}

variable "storage_size_in_gb" {
  type    = number
  default = 256
}

variable "is_general_purpose_v2" {
  type    = bool
  default = true
}

variable "storage_iops" {
  type    = number
  default = null
}

variable "memory_size_in_gb" {
  type        = number
  description = "Flexible memory (Next-gen GP on premium-series hardware). Null keeps the default for the vCore count."
  default     = null
}

variable "zone_redundant" {
  type    = bool
  default = true
}

variable "backup_storage_redundancy" {
  type        = string
  description = "Local, Zone, Geo, GeoZone"
  default     = "Zone"
}

variable "license_type" {
  type    = string
  default = "LicenseIncluded"
}

variable "entra_admin_login" {
  type        = string
  description = "Display name/UPN for the Entra admin. Object ID comes from the signed-in identity."
  default     = "sqlmi-entra-admin"
}
