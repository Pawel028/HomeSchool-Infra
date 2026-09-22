terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Only for time_sleep (waiting for Azure RBAC role assignments to propagate before they are used).
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
