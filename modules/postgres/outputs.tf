output "server_id" {
  description = "Server resource ID."
  value       = local.server_id
}

output "server_name" {
  description = "Server name."
  value       = local.server_name
}

output "fqdn" {
  description = "Private FQDN of the server (resolves only inside the VNet). Used as DB_HOST."
  value       = local.server_fqdn
}

output "database_name" {
  description = "Application database name (DB_NAME)."
  value       = azurerm_postgresql_flexible_server_database.app.name
}

output "administrator_login" {
  description = "Administrator login (used only by the release job)."
  value       = var.administrator_login
}
