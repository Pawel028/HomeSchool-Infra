# Remote state in an Azure Storage blob container created by scripts/bootstrap-state.ps1.
# The remaining settings (resource group, storage account, container, key) live in backend.hcl:
#
#   terraform init -backend-config=backend.hcl
#
# use_azuread_auth: state is read and written with Entra ID (Storage Blob Data Contributor), not storage account keys.
# In CI the identity comes from GitHub OIDC (ARM_USE_OIDC=true).
terraform {
  backend "azurerm" {
    use_azuread_auth = true
  }
}
