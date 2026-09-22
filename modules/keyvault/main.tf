# Key Vault (RBAC authorization) plus the application secrets.
#
# Secrets created here:
#   jwt-secret          random, 64 characters
#   db-admin-password   random, used by the database server and by the release job only
#   db-app-password     random, the password of the least-privilege role the API connects as
#   otp-webhook-token   placeholder - the operator overwrites it; Terraform never touches the value again
#
# The random values are stored in Terraform state as well as in Key Vault. Treat the state as sensitive (see README):
# the state storage account must be locked down (Entra-only access, no public blob access, restricted RBAC).
#
# azurerm_key_vault.protected and .unprotected are identical except for count and lifecycle (see the postgres module
# for why); tools/check-consistency.py verifies that.

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "protected" {
  count = var.prevent_destroy ? 1 : 0

  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = var.soft_delete_retention_days

  public_network_access_enabled = var.public_network_access_enabled

  network_acls {
    bypass         = "AzureServices"
    default_action = var.network_acls_default_action
    ip_rules       = var.network_acls_ip_rules
  }

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_key_vault" "unprotected" {
  count = var.prevent_destroy ? 0 : 1

  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = var.soft_delete_retention_days

  public_network_access_enabled = var.public_network_access_enabled

  network_acls {
    bypass         = "AzureServices"
    default_action = var.network_acls_default_action
    ip_rules       = var.network_acls_ip_rules
  }

  tags = var.tags
}

locals {
  key_vault_id   = one(concat(azurerm_key_vault.protected[*].id, azurerm_key_vault.unprotected[*].id))
  key_vault_name = one(concat(azurerm_key_vault.protected[*].name, azurerm_key_vault.unprotected[*].name))
  key_vault_uri  = one(concat(azurerm_key_vault.protected[*].vault_uri, azurerm_key_vault.unprotected[*].vault_uri))

  secret_officers = toset(concat([data.azurerm_client_config.current.object_id], var.secret_officer_principal_ids))
}

# With RBAC authorization even the creator of the vault has no data-plane access until a role is assigned.
resource "azurerm_role_assignment" "secrets_officer" {
  for_each = local.secret_officers

  scope                = local.key_vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

# New role assignments take a while to propagate; writing a secret straight away often fails with 403 on a first apply.
resource "time_sleep" "rbac_propagation" {
  create_duration = "60s"

  depends_on = [azurerm_role_assignment.secrets_officer]
}

resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "random_password" "db_admin" {
  length      = 32
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

resource "random_password" "db_app" {
  length      = 32
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

resource "azurerm_key_vault_secret" "jwt_secret" {
  name         = "jwt-secret"
  value        = random_password.jwt_secret.result
  key_vault_id = local.key_vault_id
  content_type = "text/plain"
  tags         = var.tags

  depends_on = [time_sleep.rbac_propagation]
}

resource "azurerm_key_vault_secret" "db_admin_password" {
  name         = "db-admin-password"
  value        = random_password.db_admin.result
  key_vault_id = local.key_vault_id
  content_type = "text/plain"
  tags         = var.tags

  depends_on = [time_sleep.rbac_propagation]
}

resource "azurerm_key_vault_secret" "db_app_password" {
  name         = "db-app-password"
  value        = random_password.db_app.result
  key_vault_id = local.key_vault_id
  content_type = "text/plain"
  tags         = var.tags

  depends_on = [time_sleep.rbac_propagation]
}

resource "azurerm_key_vault_secret" "otp_webhook_token" {
  name         = "otp-webhook-token"
  value        = var.otp_webhook_token_placeholder
  key_vault_id = local.key_vault_id
  content_type = "text/plain"
  tags         = var.tags

  depends_on = [time_sleep.rbac_propagation]

  lifecycle {
    # The operator overwrites this secret in Key Vault (new version); Terraform must not put the placeholder back.
    ignore_changes = [value]
  }
}
