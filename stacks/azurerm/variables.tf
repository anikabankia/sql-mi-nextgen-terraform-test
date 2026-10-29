variable "subscription_id" {
  type        = string
  description = "Target subscription. Defaults to ARM_SUBSCRIPTION_ID / az CLI context when null."
  default     = null
}

variable "scenario" {
  type        = string
  description = "Short scenario id, used in resource names (e.g. s01)."
}

variable "location" {
  type    = string
  default = "centralus"
}

variable "address_space" {
  type    = string
  default = "10.60.0.0/24"
}

variable "sku_name" {
  type        = string
  description = "GP_Gen5, GP_Gen8IM, GP_Gen8IH, BC_Gen5, BC_Gen8IM, BC_Gen8IH"
  default     = "GP_Gen5"
}

variable "vcores" {
  type    = number
  default = 4
}

variable "storage_size_in_gb" {
  type    = number
  default = 256
}

variable "general_purpose_v2_enabled" {
  type        = bool
  description = "Next-gen General Purpose (isGeneralPurposeV2 in the ARM API)."
  default     = false
}

variable "storage_iops" {
  type        = number
  description = "Next-gen GP only (300-80000). Null lets Azure calculate the default (3 IOPS/GB)."
  default     = null
}

variable "storage_iops_patch" {
  type        = number
  description = <<-EOT
    Post-create IOPS change sent as a PATCH (azapi_resource_action). Use this instead of storage_iops
    when a deny policy requires Entra-only auth: azurerm updates PUT the whole MI with administrators
    cleared, which that policy rejects.
  EOT
  default     = null
}

variable "zone_redundant_enabled" {
  type    = bool
  default = false
}

variable "storage_account_type" {
  type        = string
  description = "Backup storage redundancy: LRS, ZRS, GRS, GZRS."
  default     = "LRS"
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
