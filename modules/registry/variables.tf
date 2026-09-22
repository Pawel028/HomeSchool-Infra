variable "name" {
  description = "Registry name: 5-50 lowercase letters and digits, globally unique."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{5,50}$", var.name))
    error_message = "Registry names must be 5-50 lowercase letters and digits."
  }
}

variable "resource_group_name" {
  description = "Existing resource group."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "sku" {
  description = "Basic (dev/nonprod) or Standard (prod). Premium adds geo-replication and private endpoints and is not needed yet."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku)
    error_message = "sku must be Basic, Standard or Premium."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
}
