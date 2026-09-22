output "resource_group_name" {
  description = "Resource group of this environment (GitHub variable AZURE_RESOURCE_GROUP)."
  value       = data.azurerm_resource_group.this.name
}

output "api_url" {
  description = "Public HTTPS URL of the API."
  value       = "https://${module.container_apps.api_fqdn}"
}

output "api_fqdn" {
  description = "Public FQDN of the API."
  value       = module.container_apps.api_fqdn
}

output "container_app_name" {
  description = "API Container App (GitHub variable CONTAINER_APP_NAME)."
  value       = module.container_apps.api_app_name
}

output "release_job_name" {
  description = "Release job (GitHub variable RELEASE_JOB_NAME)."
  value       = module.container_apps.release_job_name
}

output "acr_name" {
  description = "Container registry name (GitHub variable ACR_NAME)."
  value       = module.registry.name
}

output "acr_login_server" {
  description = "Container registry login server."
  value       = module.registry.login_server
}

output "key_vault_name" {
  description = "Key Vault name. Overwrite the otp-webhook-token secret here."
  value       = module.keyvault.key_vault_name
}

output "key_vault_uri" {
  description = "Key Vault URI."
  value       = module.keyvault.key_vault_uri
}

output "postgres_server_name" {
  description = "PostgreSQL server name."
  value       = module.postgres.server_name
}

output "postgres_fqdn" {
  description = "Private FQDN of the PostgreSQL server (reachable only inside the VNet)."
  value       = module.postgres.fqdn
}

output "site_hostname" {
  description = "Default hostname of the public site Static Web App."
  value       = module.static_web_apps.default_hostnames["site"]
}

output "admin_hostname" {
  description = "Default hostname of the admin console Static Web App."
  value       = module.static_web_apps.default_hostnames["admin"]
}

output "static_web_app_names" {
  description = "Static Web App resource names (site, admin), for the web repository's deployment pipeline."
  value       = module.static_web_apps.names
}

output "managed_identity_client_id" {
  description = "Client ID of the identity used by the API and the release job."
  value       = module.identity.client_id
}

output "log_analytics_workspace_name" {
  description = "Log Analytics workspace (Container Apps logs)."
  value       = module.monitoring.log_analytics_workspace_name
}

output "application_insights_connection_string" {
  description = "Application Insights connection string. The API does not send telemetry yet; this is ready for when it does."
  value       = module.monitoring.application_insights_connection_string
  sensitive   = true
}

output "github_environment_variables" {
  description = "Values to set as GitHub environment variables in the backend-api repository for this environment."
  value = {
    ACR_NAME             = module.registry.name
    CONTAINER_APP_NAME   = module.container_apps.api_app_name
    RELEASE_JOB_NAME     = module.container_apps.release_job_name
    AZURE_RESOURCE_GROUP = data.azurerm_resource_group.this.name
  }
}
