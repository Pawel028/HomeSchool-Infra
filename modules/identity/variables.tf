variable "name" {
  description = "Managed identity name."
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

variable "key_vault_id" {
  description = "Key Vault the identity may read secrets from."
  type        = string
}

variable "registry_id" {
  description = "Container registry the identity may pull images from."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
}
