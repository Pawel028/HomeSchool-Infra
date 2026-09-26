# One environment of the HomeSchooling platform. Identical in envs/dev, envs/nonprod and envs/prod;
# everything that differs between environments is a variable (see <env>.tfvars).
#
# Module order (arrows = "needs"):
#   network, monitoring, registry, keyvault
#   postgres        -> network, keyvault (admin password)
#   identity        -> keyvault, registry (role assignments)
#   static_web_apps
#   container_apps  -> everything above (CORS origins come from static_web_apps)
#   alerts (prod)   -> container_apps

data "azurerm_client_config" "current" {}

locals {
  prefix              = "${var.short_name}-${var.environment}"
  resource_group_name = coalesce(var.resource_group_name, "rg-${var.short_name}-${var.environment}")

  tags = merge(
    {
      project     = var.project
      env         = var.environment
      managed_by  = "terraform"
      cost_center = var.cost_center
    },
    var.extra_tags,
  )
}

# The resource group is created by scripts/setup-github-oidc.ps1 (the CI identity only has rights inside it), so it is
# looked up here, not managed. `terraform destroy` therefore leaves the empty group behind on purpose.
data "azurerm_resource_group" "this" {
  name = local.resource_group_name
}

module "network" {
  source = "../../modules/network"

  name_prefix                    = local.prefix
  resource_group_name            = data.azurerm_resource_group.this.name
  location                       = var.location
  address_space                  = var.vnet_address_space
  postgres_private_dns_zone_name = "${var.environment}.postgres.database.azure.com"
  tags                           = local.tags
}

module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix         = local.prefix
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  retention_in_days   = var.log_retention_days
  daily_quota_gb      = var.log_daily_quota_gb
  tags                = local.tags
}

module "registry" {
  source = "../../modules/registry"

  name                = "acr${var.short_name}${var.environment}${var.unique_suffix}"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  sku                 = var.registry_sku
  tags                = local.tags
}

module "keyvault" {
  source = "../../modules/keyvault"

  name                          = "kv-${local.prefix}-${var.unique_suffix}"
  resource_group_name           = data.azurerm_resource_group.this.name
  location                      = var.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  purge_protection_enabled      = var.key_vault_purge_protection_enabled
  soft_delete_retention_days    = var.key_vault_soft_delete_retention_days
  public_network_access_enabled = var.key_vault_public_network_access_enabled
  network_acls_default_action   = var.key_vault_network_acls_default_action
  network_acls_ip_rules         = var.key_vault_allowed_ip_ranges
  secret_officer_principal_ids  = var.key_vault_secret_officer_principal_ids
  prevent_destroy               = var.environment == "prod"
  tags                          = local.tags
}

module "postgres" {
  source = "../../modules/postgres"

  name                   = "psql-${local.prefix}-${var.unique_suffix}"
  resource_group_name    = data.azurerm_resource_group.this.name
  location               = var.location
  sku_name               = var.postgres_sku_name
  storage_mb             = var.postgres_storage_mb
  administrator_password = module.keyvault.db_admin_password

  delegated_subnet_id = module.network.postgres_subnet_id
  # This output only becomes known after the private DNS zone is linked to the VNet, which Azure requires
  # before the server can be created. The explicit depends_on below states the same thing for the reader.
  private_dns_zone_id = module.network.postgres_private_dns_zone_id

  backup_retention_days        = var.postgres_backup_retention_days
  geo_redundant_backup_enabled = var.postgres_geo_redundant_backup
  high_availability_mode       = var.postgres_high_availability_mode
  prevent_destroy              = var.environment == "prod"
  tags                         = local.tags

  depends_on = [module.network]
}

module "identity" {
  source = "../../modules/identity"

  name                = "id-${local.prefix}-apps"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  key_vault_id        = module.keyvault.key_vault_id
  registry_id         = module.registry.id
  tags                = local.tags
}

module "static_web_apps" {
  source = "../../modules/static_web_apps"

  name_prefix                  = local.prefix
  resource_group_name          = data.azurerm_resource_group.this.name
  location                     = var.static_web_app_location
  sku                          = var.static_web_app_sku
  preview_environments_enabled = var.static_web_app_preview_environments
  tags                         = local.tags
}

module "container_apps" {
  source = "../../modules/container_apps"

  name_prefix                = local.prefix
  resource_group_name        = data.azurerm_resource_group.this.name
  location                   = var.location
  infrastructure_subnet_id   = module.network.container_apps_subnet_id
  zone_redundancy_enabled    = var.container_apps_zone_redundant
  log_analytics_workspace_id = module.monitoring.log_analytics_workspace_id

  identity_id           = module.identity.id
  registry_login_server = module.registry.login_server
  key_vault_secret_ids  = module.keyvault.secret_ids

  api_image                = var.api_image
  target_port              = var.api_target_port
  bootstrap_mode           = var.api_bootstrap
  cpu                      = var.api_cpu
  memory                   = var.api_memory
  min_replicas             = var.api_min_replicas
  max_replicas             = var.api_max_replicas
  http_concurrent_requests = var.api_http_concurrent_requests

  app_env                    = var.environment
  log_level                  = var.log_level
  db_host                    = module.postgres.fqdn
  db_name                    = module.postgres.database_name
  db_admin_user              = module.postgres.administrator_login
  cors_origins               = join(",", concat(["https://${module.static_web_apps.default_hostnames["admin"]}", "https://${module.static_web_apps.default_hostnames["site"]}"], var.extra_cors_origins))
  otp_provider               = var.otp_provider
  otp_webhook_url            = var.otp_webhook_url
  otp_static_test_code       = var.otp_static_test_code
  declaration_notice_version = var.declaration_notice_version
  min_app_version            = var.min_app_version
  seed_publish               = var.seed_publish

  tags = local.tags

  # The identity module's roles (AcrPull, Key Vault Secrets User) must be usable before the first revision starts;
  # the database must exist before the API points at it.
  depends_on = [module.identity, module.postgres]
}

module "alerts" {
  count  = var.enable_alerts ? 1 : 0
  source = "../../modules/alerts"

  name_prefix         = local.prefix
  resource_group_name = data.azurerm_resource_group.this.name
  container_app_id    = module.container_apps.api_app_id
  alert_email         = var.alert_email
  tags                = local.tags
}
