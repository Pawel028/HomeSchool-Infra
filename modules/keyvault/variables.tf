variable "name" {
  description = "Key Vault name, 3-24 characters, globally unique."
  type        = string

  validation {
    condition     = length(var.name) >= 3 && length(var.name) <= 24
    error_message = "Key Vault names must be 3-24 characters."
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

variable "tenant_id" {
  description = "Entra ID tenant ID."
  type        = string
}

variable "purge_protection_enabled" {
  description = "Purge protection (cannot be turned off once on). Required for prod."
  type        = bool
  default     = false
}

variable "soft_delete_retention_days" {
  description = "Soft-delete retention, 7-90 days. Can only be set when the vault is created."
  type        = number
  default     = 7

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "soft_delete_retention_days must be between 7 and 90."
  }
}

variable "public_network_access_enabled" {
  description = <<-EOT
    Whether the vault data plane is reachable over the public endpoint. It has to be true while a GitHub-hosted (or
    laptop) Terraform runner writes the secrets and while Container Apps resolves secret references, because neither
    reaches a private endpoint. Access is still authenticated (Entra ID) and authorised (RBAC); network rules only
    add a second layer. Set false only when Terraform runs from a self-hosted runner inside the VNet and a private
    endpoint exists for the vault (not created by this repo).
  EOT
  type        = bool
  default     = true
}

variable "network_acls_default_action" {
  description = "Allow or Deny for traffic that matches no rule. Deny + ip_rules = allow-list of runner/operator IPs (the Azure services bypass stays on). Verify that Container Apps can still resolve its secret references before using Deny in an environment that matters."
  type        = string
  default     = "Allow"

  validation {
    condition     = contains(["Allow", "Deny"], var.network_acls_default_action)
    error_message = "network_acls_default_action must be Allow or Deny."
  }
}

variable "network_acls_ip_rules" {
  description = "IPs or CIDRs allowed through the vault firewall when the default action is Deny."
  type        = list(string)
  default     = []
}

variable "secret_officer_principal_ids" {
  description = "Extra Entra object IDs (people) that get Key Vault Secrets Officer, for example the operator who overwrites otp-webhook-token. The identity running Terraform always gets it."
  type        = list(string)
  default     = []
}

variable "prevent_destroy" {
  description = "Adds lifecycle.prevent_destroy (true for prod). Same two-resource pattern as the postgres module; do not flip on an existing vault."
  type        = bool
  default     = false
}

variable "otp_webhook_token_placeholder" {
  description = "Initial value of the otp-webhook-token secret. The operator overwrites it in Key Vault (Terraform then ignores the value)."
  type        = string
  default     = "REPLACE-ME-overwrite-in-key-vault"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
}
