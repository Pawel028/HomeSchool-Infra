output "vnet_id" {
  description = "VNet resource ID."
  value       = azurerm_virtual_network.this.id
}

output "container_apps_subnet_id" {
  description = "Subnet ID for the Container Apps environment."
  value       = azurerm_subnet.container_apps.id
}

output "postgres_subnet_id" {
  description = "Delegated subnet ID for PostgreSQL."
  value       = azurerm_subnet.postgres.id
}

output "postgres_private_dns_zone_id" {
  description = "Private DNS zone ID. The output depends on the VNet link on purpose: anything that consumes this ID (the database server) is created only after the link exists, as Azure requires."
  value       = azurerm_private_dns_zone.postgres.id
  depends_on  = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

output "postgres_private_dns_zone_link_id" {
  description = "ID of the VNet link (for explicit depends_on)."
  value       = azurerm_private_dns_zone_virtual_network_link.postgres.id
}
