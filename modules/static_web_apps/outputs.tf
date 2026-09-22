output "default_hostnames" {
  description = "Default hostname of each app, keyed by site / admin (no scheme)."
  value       = { for k, v in azurerm_static_web_app.this : k => v.default_host_name }
}

output "names" {
  description = "Resource names, keyed by site / admin."
  value       = { for k, v in azurerm_static_web_app.this : k => v.name }
}

output "ids" {
  description = "Resource IDs, keyed by site / admin."
  value       = { for k, v in azurerm_static_web_app.this : k => v.id }
}
