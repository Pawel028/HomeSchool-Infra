output "environment_id" {
  description = "Container Apps environment ID."
  value       = azurerm_container_app_environment.this.id
}

output "environment_default_domain" {
  description = "Default domain of the Container Apps environment."
  value       = azurerm_container_app_environment.this.default_domain
}

output "api_app_id" {
  description = "API Container App resource ID."
  value       = azurerm_container_app.api.id
}

output "api_app_name" {
  description = "API Container App name (GitHub variable CONTAINER_APP_NAME)."
  value       = azurerm_container_app.api.name
}

output "api_fqdn" {
  description = "Public FQDN of the API."
  value       = azurerm_container_app.api.ingress[0].fqdn
}

output "release_job_name" {
  description = "Release job name (GitHub variable RELEASE_JOB_NAME)."
  value       = azurerm_container_app_job.release.name
}

output "release_job_id" {
  description = "Release job resource ID."
  value       = azurerm_container_app_job.release.id
}
