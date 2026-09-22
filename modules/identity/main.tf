# One user-assigned managed identity shared by the API Container App and the release Job. It is created (and given its
# roles) BEFORE the apps so that the first revision can already pull the image and resolve the Key Vault references.
# A user-assigned identity (not system-assigned) is required for exactly this reason: a system identity only exists
# after the app does, which would make the first deployment fail.

resource "azurerm_user_assigned_identity" "apps" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_role_assignment" "key_vault_secrets_user" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.apps.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = var.registry_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.apps.principal_id
  principal_type       = "ServicePrincipal"
}

# Role assignments are eventually consistent; without this pause the Container App can be created before it is
# allowed to read the vault and the create fails.
resource "time_sleep" "rbac_propagation" {
  create_duration = "60s"

  depends_on = [
    azurerm_role_assignment.key_vault_secrets_user,
    azurerm_role_assignment.acr_pull,
  ]
}
