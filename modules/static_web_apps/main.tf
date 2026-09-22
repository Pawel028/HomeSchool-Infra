# Two static front-ends per environment:
#   site  - public website
#   admin - admin console
#
# Only the hosting resources are created here. Content is deployed by the web repository's pipeline (deployment token
# from `az staticwebapp secrets list`); no repository is linked, so no GitHub token is stored in Terraform.
# The resource location is eastasia (not centralindia) because Static Web Apps is only offered in five regions; the
# content itself is served from the global edge, so this is the location of the management resource only.

resource "azurerm_static_web_app" "this" {
  for_each = toset(["site", "admin"])

  name                         = "swa-${var.name_prefix}-${each.key}"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  sku_tier                     = var.sku
  sku_size                     = var.sku
  preview_environments_enabled = var.preview_environments_enabled
  tags                         = var.tags
}
