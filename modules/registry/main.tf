# Container registry for the API image. The admin user stays disabled: CI pushes with its Entra identity
# (az acr build) and the Container App / Job pull with the user-assigned managed identity (AcrPull, see identity module).
resource "azurerm_container_registry" "this" {
  name                          = var.name
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = var.sku
  admin_enabled                 = false
  public_network_access_enabled = true
  tags                          = var.tags
}
