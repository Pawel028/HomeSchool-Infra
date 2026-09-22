output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID."
  value       = azurerm_log_analytics_workspace.this.id
}

output "log_analytics_workspace_name" {
  description = "Log Analytics workspace name."
  value       = azurerm_log_analytics_workspace.this.name
}

output "application_insights_id" {
  description = "Application Insights resource ID."
  value       = azurerm_application_insights.this.id
}

output "application_insights_connection_string" {
  description = "Connection string for the Application Insights SDK / OpenTelemetry exporter. Not used by the API yet."
  value       = azurerm_application_insights.this.connection_string
  sensitive   = true
}
