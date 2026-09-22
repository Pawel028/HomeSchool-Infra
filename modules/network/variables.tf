variable "name_prefix" {
  description = "Prefix for resource names, for example hs-dev."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group the network is created in."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "address_space" {
  description = "VNet address space (one CIDR, /20 or larger). dev 10.10.0.0/16, nonprod 10.20.0.0/16, prod 10.30.0.0/16 - must not overlap between environments."
  type        = string

  validation {
    condition     = can(cidrhost(var.address_space, 0)) && tonumber(split("/", var.address_space)[1]) <= 20
    error_message = "address_space must be a valid CIDR block with a prefix length of /20 or shorter (for example 10.10.0.0/16)."
  }
}

variable "container_apps_subnet_cidr" {
  description = "CIDR of the Container Apps environment subnet. Default: the first /24 of the address space. A workload-profiles environment needs at least /27; /24 leaves room to scale."
  type        = string
  default     = null
}

variable "postgres_subnet_cidr" {
  description = "CIDR of the PostgreSQL delegated subnet. Default: the second /24 of the address space."
  type        = string
  default     = null
}

variable "postgres_private_dns_zone_name" {
  description = "Private DNS zone for PostgreSQL Flexible Server. Must end with .postgres.database.azure.com."
  type        = string

  validation {
    condition     = endswith(var.postgres_private_dns_zone_name, ".postgres.database.azure.com")
    error_message = "The private DNS zone name must end with .postgres.database.azure.com."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
}
