output "key_vault_id" {
  description = "Key Vault resource ID."
  value       = local.key_vault_id
}

output "key_vault_name" {
  description = "Key Vault name."
  value       = local.key_vault_name
}

output "key_vault_uri" {
  description = "Key Vault URI."
  value       = local.key_vault_uri
}

output "secret_ids" {
  description = "Version-less secret IDs keyed by secret name. Container Apps resolves the latest version when a revision starts."
  value = {
    "jwt-secret"        = azurerm_key_vault_secret.jwt_secret.versionless_id
    "db-admin-password" = azurerm_key_vault_secret.db_admin_password.versionless_id
    "db-app-password"   = azurerm_key_vault_secret.db_app_password.versionless_id
    "otp-webhook-token" = azurerm_key_vault_secret.otp_webhook_token.versionless_id
  }
}

output "db_admin_password" {
  description = "Generated database administrator password, handed to the postgres module."
  value       = random_password.db_admin.result
  sensitive   = true
}
