# Network for one environment: a VNet with two delegated subnets and the private DNS zone the database uses.
# Nothing here is reachable from the internet; the Container Apps environment is the only public entry point and it
# sits in its own subnet.

locals {
  container_apps_subnet_cidr = coalesce(var.container_apps_subnet_cidr, cidrsubnet(var.address_space, 8, 0))
  postgres_subnet_cidr       = coalesce(var.postgres_subnet_cidr, cidrsubnet(var.address_space, 8, 1))
}

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.address_space]
  tags                = var.tags
}

# Container Apps environment (workload profiles). The subnet must be delegated to Microsoft.App/environments and must
# not hold anything else. A /27 is the documented minimum for workload-profiles environments.
resource "azurerm_subnet" "container_apps" {
  name                 = "snet-container-apps"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.container_apps_subnet_cidr]

  delegation {
    name = "container-apps-environment"

    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# PostgreSQL Flexible Server (private access). The subnet is delegated to the flexible-server service.
resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.postgres_subnet_cidr]

  delegation {
    name = "postgres-flexible-server"

    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = var.postgres_private_dns_zone_name
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# The link is what lets resources in the VNet (the Container Apps) resolve <server>.<zone> to the private IP.
resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "link-${azurerm_virtual_network.this.name}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}
