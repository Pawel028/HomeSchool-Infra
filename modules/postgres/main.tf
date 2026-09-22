# PostgreSQL Flexible Server, private access only (VNet-injected, no public endpoint), TLS required.
#
# IMPORTANT: azurerm_postgresql_flexible_server.protected and .unprotected are intentionally identical except for
# `count` and `lifecycle`. lifecycle.prevent_destroy must be a literal, so this is the only way to protect prod
# and leave dev/nonprod destroyable. tools/check-consistency.py fails if the two blocks drift apart.
#
# storage_mb is ignored after creation because storage auto-grow changes it outside Terraform; without this a later
# plan would try to shrink the disk, which forces a NEW server (data loss).

resource "azurerm_postgresql_flexible_server" "protected" {
  count = var.prevent_destroy ? 1 : 0

  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.postgres_version
  sku_name            = var.sku_name
  storage_mb          = var.storage_mb
  auto_grow_enabled   = true

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  delegated_subnet_id           = var.delegated_subnet_id
  private_dns_zone_id           = var.private_dns_zone_id
  public_network_access_enabled = false

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  authentication {
    active_directory_auth_enabled = false
    password_auth_enabled         = true
  }

  dynamic "high_availability" {
    for_each = var.high_availability_mode == null ? [] : [var.high_availability_mode]

    content {
      mode = high_availability.value
    }
  }

  maintenance_window {
    day_of_week  = var.maintenance_window_day_of_week
    start_hour   = var.maintenance_window_start_hour
    start_minute = var.maintenance_window_start_minute
  }

  tags = var.tags

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [storage_mb]
  }
}

resource "azurerm_postgresql_flexible_server" "unprotected" {
  count = var.prevent_destroy ? 0 : 1

  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = var.postgres_version
  sku_name            = var.sku_name
  storage_mb          = var.storage_mb
  auto_grow_enabled   = true

  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password

  delegated_subnet_id           = var.delegated_subnet_id
  private_dns_zone_id           = var.private_dns_zone_id
  public_network_access_enabled = false

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup_enabled

  authentication {
    active_directory_auth_enabled = false
    password_auth_enabled         = true
  }

  dynamic "high_availability" {
    for_each = var.high_availability_mode == null ? [] : [var.high_availability_mode]

    content {
      mode = high_availability.value
    }
  }

  maintenance_window {
    day_of_week  = var.maintenance_window_day_of_week
    start_hour   = var.maintenance_window_start_hour
    start_minute = var.maintenance_window_start_minute
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [storage_mb]
  }
}

locals {
  server_id   = one(concat(azurerm_postgresql_flexible_server.protected[*].id, azurerm_postgresql_flexible_server.unprotected[*].id))
  server_name = one(concat(azurerm_postgresql_flexible_server.protected[*].name, azurerm_postgresql_flexible_server.unprotected[*].name))
  server_fqdn = one(concat(azurerm_postgresql_flexible_server.protected[*].fqdn, azurerm_postgresql_flexible_server.unprotected[*].fqdn))
}

# TLS is already required by default on Flexible Server; setting it explicitly keeps it from being switched off
# silently (the API also refuses DB_SSLMODE below "require" in nonprod/prod).
resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  name      = "require_secure_transport"
  server_id = local.server_id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = var.database_name
  server_id = local.server_id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
