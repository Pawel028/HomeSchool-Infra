# ------------------------------------------------------------------------------------------------------------------
# Inputs of one environment. This file, main.tf, outputs.tf, providers.tf, versions.tf and backend.tf are IDENTICAL in
# envs/dev, envs/nonprod and envs/prod (tools/check-consistency.py enforces it); only <env>.tfvars differs.
# Validation blocks make prod impossible to deploy with settings the API would refuse, or with weak sizing.
# ------------------------------------------------------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID. Null = use ARM_SUBSCRIPTION_ID."
  type        = string
  default     = null
}

variable "environment" {
  description = "dev, nonprod or prod. Also the APP_ENV of the API."
  type        = string

  validation {
    condition     = contains(["dev", "nonprod", "prod"], var.environment)
    error_message = "environment must be dev, nonprod or prod."
  }
}

variable "project" {
  description = "Project name (tag)."
  type        = string
  default     = "homeschool"
}

variable "short_name" {
  description = "Short prefix used in resource names."
  type        = string
  default     = "hs"

  validation {
    condition     = can(regex("^[a-z0-9]{2,5}$", var.short_name))
    error_message = "short_name must be 2-5 lowercase letters or digits."
  }
}

variable "unique_suffix" {
  description = "3-6 lowercase letters/digits that make globally unique names (registry, key vault, database server). Pick your own; the value in the committed tfvars is an example."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,6}$", var.unique_suffix))
    error_message = "unique_suffix must be 3-6 lowercase letters or digits."
  }
}

variable "cost_center" {
  description = "Value of the cost_center tag."
  type        = string
}

variable "extra_tags" {
  description = "Additional tags."
  type        = map(string)
  default     = {}
}

variable "location" {
  description = "Region of everything except the Static Web Apps."
  type        = string
  default     = "centralindia"
}

variable "static_web_app_location" {
  description = "Static Web Apps are only offered in westus2, centralus, eastus2, westeurope and eastasia."
  type        = string
  default     = "eastasia"
}

variable "resource_group_name" {
  description = "Existing resource group of this environment (created by scripts/setup-github-oidc.ps1). Null = rg-<short_name>-<environment>."
  type        = string
  default     = null
}

# ---- network ----------------------------------------------------------------------------------------------------

variable "vnet_address_space" {
  description = "VNet CIDR: dev 10.10.0.0/16, nonprod 10.20.0.0/16, prod 10.30.0.0/16."
  type        = string
}

# ---- registry / monitoring ---------------------------------------------------------------------------------------

variable "registry_sku" {
  description = "Basic for dev/nonprod, Standard for prod."
  type        = string

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.registry_sku) && (var.environment != "prod" || var.registry_sku != "Basic")
    error_message = "registry_sku must be Basic, Standard or Premium, and prod needs Standard or better."
  }
}

variable "log_retention_days" {
  description = "Log Analytics retention: 30 for dev/nonprod, 90 for prod."
  type        = number

  validation {
    condition     = var.log_retention_days >= 30 && (var.environment != "prod" || var.log_retention_days >= 90)
    error_message = "log_retention_days must be at least 30, and at least 90 in prod."
  }
}

variable "log_daily_quota_gb" {
  description = "Log Analytics daily ingestion cap in GB; -1 = unlimited."
  type        = number
  default     = -1
}

variable "enable_alerts" {
  description = "Metric alerts (5xx, restarts) with an email action group. Required in prod."
  type        = bool
  default     = false

  validation {
    condition     = var.environment != "prod" || var.enable_alerts
    error_message = "Alerts must be enabled in prod (enable_alerts = true)."
  }
}

variable "alert_email" {
  description = "Recipient of alert emails. Required when enable_alerts is true."
  type        = string
  default     = ""

  validation {
    condition = (
      !var.enable_alerts
      || (
        can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
        && !can(regex("(?i)replace-me|\\.invalid$", var.alert_email))
      )
    )
    error_message = "alert_email must be a real email address when enable_alerts is true (replace the placeholder in the tfvars file)."
  }
}

# ---- PostgreSQL --------------------------------------------------------------------------------------------------

variable "postgres_sku_name" {
  description = "B_Standard_B1ms (dev), B_Standard_B2s (nonprod), GP_Standard_D2ds_v5 (prod)."
  type        = string

  validation {
    condition     = var.environment != "prod" || !startswith(var.postgres_sku_name, "B_")
    error_message = "Prod must not use a Burstable (B_) database SKU; use GP_ or MO_ (for example GP_Standard_D2ds_v5)."
  }
}

variable "postgres_storage_mb" {
  description = "Initial storage in MB (32768 = 32 GB). Auto-grow is enabled."
  type        = number
  default     = 32768
}

variable "postgres_backup_retention_days" {
  description = "7 for dev/nonprod, 35 for prod."
  type        = number

  validation {
    condition     = var.postgres_backup_retention_days >= 7 && var.postgres_backup_retention_days <= 35 && (var.environment != "prod" || var.postgres_backup_retention_days >= 35)
    error_message = "Backup retention must be 7-35 days, and 35 in prod."
  }
}

variable "postgres_geo_redundant_backup" {
  description = "Copy backups to the paired region (extra cost; cannot be changed after creation). Recommended for prod once budget allows."
  type        = bool
  default     = false
}

variable "postgres_high_availability_mode" {
  description = "null (default, no standby, cheapest), ZoneRedundant or SameZone. Needs a General Purpose SKU. Roughly doubles the database compute cost. Off by default to control cost; RPO/RTO in that case rely on backups (point-in-time restore)."
  type        = string
  default     = null

  validation {
    condition     = var.postgres_high_availability_mode == null || (contains(["ZoneRedundant", "SameZone"], coalesce(var.postgres_high_availability_mode, "x")) && !startswith(var.postgres_sku_name, "B_"))
    error_message = "postgres_high_availability_mode must be null, ZoneRedundant or SameZone, and needs a General Purpose (GP_) or Memory Optimized (MO_) SKU."
  }
}

# ---- Key Vault ---------------------------------------------------------------------------------------------------

variable "key_vault_purge_protection_enabled" {
  description = "Purge protection. Must be true in prod. Irreversible once enabled."
  type        = bool
  default     = false

  validation {
    condition     = var.environment != "prod" || var.key_vault_purge_protection_enabled
    error_message = "Purge protection must be enabled for the prod Key Vault."
  }
}

variable "key_vault_soft_delete_retention_days" {
  description = "Soft-delete retention (7-90). Fixed when the vault is created."
  type        = number
  default     = 7
}

variable "key_vault_public_network_access_enabled" {
  description = "Data-plane reachability over the public endpoint. True lets a GitHub-hosted runner write secrets and lets Container Apps resolve references; false requires a self-hosted runner in the VNet plus a private endpoint (not part of this repo). See modules/keyvault."
  type        = bool
  default     = true
}

variable "key_vault_network_acls_default_action" {
  description = "Allow or Deny when no rule matches. Deny + key_vault_allowed_ip_ranges is a firewall allow-list."
  type        = string
  default     = "Allow"
}

variable "key_vault_allowed_ip_ranges" {
  description = "IPs/CIDRs allowed when the default action is Deny."
  type        = list(string)
  default     = []
}

variable "key_vault_secret_officer_principal_ids" {
  description = "Entra object IDs of people who may overwrite secrets (for example otp-webhook-token)."
  type        = list(string)
  default     = []
}

# ---- API (Container Apps) ---------------------------------------------------------------------------------------

variable "api_image" {
  description = "Placeholder image for the first apply. CI owns the image afterwards (lifecycle.ignore_changes)."
  type        = string
  default     = "mcr.microsoft.com/k8se/quickstart:latest"
}

variable "api_target_port" {
  description = "Port the API container listens on."
  type        = number
  default     = 8000
}

variable "api_bootstrap" {
  description = "Set to true ONLY for the first apply (placeholder image, API scaled to zero). Pass it on the command line: -var api_bootstrap=true. Apply again with false after CI has deployed the first image."
  type        = bool
  default     = false
}

variable "api_cpu" {
  description = "vCPU per API replica (Consumption profile: valid cpu/memory pairs only)."
  type        = number
  default     = 0.5
}

variable "api_memory" {
  description = "Memory per API replica."
  type        = string
  default     = "1Gi"
}

variable "api_min_replicas" {
  description = "dev 0, nonprod 1, prod 2 (at least 2 in prod so a restart or revision change never takes the API down)."
  type        = number

  validation {
    condition     = var.api_min_replicas >= 0 && (var.environment != "prod" || var.api_min_replicas >= 2)
    error_message = "api_min_replicas must be at least 2 in prod."
  }
}

variable "api_max_replicas" {
  description = "Upper bound for scale-out."
  type        = number

  validation {
    condition     = var.api_max_replicas >= 1 && var.api_max_replicas >= var.api_min_replicas
    error_message = "api_max_replicas must be at least 1 and at least api_min_replicas."
  }
}

variable "api_http_concurrent_requests" {
  description = "HTTP concurrency per replica that triggers scale-out."
  type        = number
  default     = 50
}

variable "container_apps_zone_redundant" {
  description = "Zone-redundant Container Apps environment (fixed at creation)."
  type        = bool
  default     = false
}

variable "log_level" {
  description = "LOG_LEVEL of the API."
  type        = string
  default     = "INFO"
}

variable "otp_provider" {
  description = "console (dev/nonprod: the code is written to the log) or webhook (prod: real SMS gateway)."
  type        = string

  validation {
    condition     = contains(["console", "webhook"], var.otp_provider) && (var.environment != "prod" || var.otp_provider == "webhook")
    error_message = "otp_provider must be console or webhook, and must be webhook in prod (the API refuses to start otherwise)."
  }
}

variable "otp_webhook_url" {
  description = "https URL of the SMS gateway (OTP_WEBHOOK_URL). Required when otp_provider is webhook. The token is NOT set here: overwrite the otp-webhook-token secret in Key Vault."
  type        = string
  default     = ""

  validation {
    condition = (
      var.otp_provider != "webhook"
      || (
        startswith(var.otp_webhook_url, "https://")
        && !can(regex("(?i)replace-me|\\.invalid(/|$)", var.otp_webhook_url))
      )
    )
    error_message = "otp_webhook_url must be a real https URL when otp_provider is webhook (replace the placeholder in the tfvars file)."
  }
}

variable "otp_static_test_code" {
  description = "TESTING ONLY: every generated OTP becomes this fixed value so testers can share one known code instead of each needing real SMS delivery. Leave empty for normal random codes."
  type        = string
  default     = ""
}

variable "declaration_notice_version" {
  description = "DECLARATION_NOTICE_VERSION."
  type        = string
  default     = "2026-09-draft"
}

variable "min_app_version" {
  description = "MIN_APP_VERSION."
  type        = string
  default     = "0.1.0"
}

variable "extra_cors_origins" {
  description = "Custom domains (and, in dev only, localhost origins) added to CORS_ORIGINS next to the two Static Web App hostnames. Explicit origins only."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for o in var.extra_cors_origins :
      can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?$", o))
      || (var.environment == "dev" && can(regex("^http://localhost(:[0-9]+)?$", o)))
    ])
    error_message = "extra_cors_origins entries must be explicit https:// origins without a path or wildcard (http://localhost[:port] is allowed in dev only)."
  }
}

variable "seed_publish" {
  description = "SEED_PUBLISH of the release job: publish seeded activities immediately (true dev/nonprod, false prod)."
  type        = bool
}

# ---- Static Web Apps ---------------------------------------------------------------------------------------------

variable "static_web_app_sku" {
  description = "Free for dev/nonprod, Standard for prod."
  type        = string

  validation {
    condition     = contains(["Free", "Standard"], var.static_web_app_sku) && (var.environment != "prod" || var.static_web_app_sku == "Standard")
    error_message = "static_web_app_sku must be Free or Standard, and Standard in prod."
  }
}

variable "static_web_app_preview_environments" {
  description = "Pull-request preview environments of the Static Web Apps."
  type        = bool
  default     = true
}
