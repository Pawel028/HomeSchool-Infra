provider "azurerm" {
  # azurerm 4.x requires the subscription. Leave var.subscription_id null and export ARM_SUBSCRIPTION_ID instead if you
  # prefer (the CI workflows do).
  subscription_id = var.subscription_id

  # The identity that runs Terraform is scoped to one resource group and cannot register providers on the
  # subscription. The required providers are registered once by scripts/bootstrap-state.ps1.
  resource_provider_registrations = "none"

  features {
    key_vault {
      # Non-prod vaults are purged on destroy so the name can be reused; prod vaults are never purged
      # (and have purge protection anyway).
      purge_soft_delete_on_destroy    = var.environment != "prod"
      recover_soft_deleted_key_vaults = true
    }
  }
}
