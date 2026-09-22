variable "name_prefix" {
  description = "Prefix for resource names, for example hs-dev."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group."
  type        = string
}

variable "location" {
  description = "Static Web Apps are offered in only a few regions (westus2, centralus, eastus2, westeurope, eastasia). eastasia is the closest to India."
  type        = string
  default     = "eastasia"

  validation {
    condition     = contains(["westus2", "centralus", "eastus2", "westeurope", "eastasia"], var.location)
    error_message = "Static Web Apps are available in westus2, centralus, eastus2, westeurope and eastasia only."
  }
}

variable "sku" {
  description = "Free (dev/nonprod) or Standard (prod: SLA, custom auth, more staging environments)."
  type        = string
  default     = "Free"

  validation {
    condition     = contains(["Free", "Standard"], var.sku)
    error_message = "sku must be Free or Standard."
  }
}

variable "preview_environments_enabled" {
  description = "Pull-request preview environments. Turn off for prod."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
}
