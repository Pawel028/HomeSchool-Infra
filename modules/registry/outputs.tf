output "id" {
  description = "Registry resource ID."
  value       = azurerm_container_registry.this.id
}

output "name" {
  description = "Registry name."
  value       = azurerm_container_registry.this.name
}

output "login_server" {
  description = "Registry login server, for example acrhsdevx7k2.azurecr.io."
  value       = azurerm_container_registry.this.login_server
}
