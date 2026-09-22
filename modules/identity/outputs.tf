output "id" {
  description = "Managed identity resource ID."
  value       = azurerm_user_assigned_identity.apps.id
  depends_on  = [time_sleep.rbac_propagation]
}

output "client_id" {
  description = "Managed identity client ID."
  value       = azurerm_user_assigned_identity.apps.client_id
}

output "principal_id" {
  description = "Managed identity principal (object) ID."
  value       = azurerm_user_assigned_identity.apps.principal_id
}
