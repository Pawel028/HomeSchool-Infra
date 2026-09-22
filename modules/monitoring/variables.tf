variable "name_prefix" {
  description = "Prefix for resource names, for example hs-dev."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "retention_in_days" {
  description = "Log Analytics retention: 30 for dev/nonprod, 90 for prod."
  type        = number
  default     = 30

  validation {
    condition     = var.retention_in_days >= 30 && var.retention_in_days <= 730
    error_message = "retention_in_days must be between 30 and 730."
  }
}

variable "daily_quota_gb" {
  description = "Daily ingestion cap in GB (-1 = unlimited). A cap protects the bill in dev but silently drops logs once reached."
  type        = number
  default     = -1
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
}
