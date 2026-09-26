variable "name_prefix" {
  description = "Prefix for resource names, for example hs-dev."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "infrastructure_subnet_id" {
  description = "Subnet delegated to Microsoft.App/environments."
  type        = string
}

variable "zone_redundancy_enabled" {
  description = "Spread the environment over availability zones (needs the VNet integration used here). Cannot be changed later."
  type        = bool
  default     = false
}

variable "log_analytics_workspace_id" {
  description = "Workspace that receives console and system logs."
  type        = string
}

variable "identity_id" {
  description = "User-assigned managed identity (AcrPull + Key Vault Secrets User). Pass the identity module's id output: it only becomes known after the role assignments have propagated."
  type        = string
}

variable "registry_login_server" {
  description = "Container registry login server."
  type        = string
}

variable "key_vault_secret_ids" {
  description = "Version-less Key Vault secret IDs keyed by secret name: jwt-secret, db-admin-password, db-app-password, otp-webhook-token."
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["jwt-secret", "db-admin-password", "db-app-password", "otp-webhook-token"] : contains(keys(var.key_vault_secret_ids), k)])
    error_message = "key_vault_secret_ids must contain jwt-secret, db-admin-password, db-app-password and otp-webhook-token."
  }
}

# ---- image ------------------------------------------------------------------------------------------------------

variable "api_image" {
  description = <<-EOT
    Image for the API app AND the release job. The default is a public placeholder so the first `terraform apply` works
    before any image exists. After the first apply CI owns the image: both resources use
    lifecycle.ignore_changes on the image, so `az containerapp update --image ...` never shows up as drift and
    Terraform never rolls a deployment back. Changing this value later has no effect on running resources.
  EOT
  type        = string
  default     = "mcr.microsoft.com/k8se/quickstart:latest"
}

variable "target_port" {
  description = "Port the API container listens on (the backend Dockerfile exposes 8000). Probes use the same port."
  type        = number
  default     = 8000
}

variable "bootstrap_mode" {
  description = <<-EOT
    First-apply switch. The placeholder image listens on port 80 and has no /healthz or /readyz, so with real probes it
    could never become ready. In bootstrap mode the API runs with 0 replicas (scale to zero): nothing starts, nothing
    fails, and the apply succeeds. CI's first deployment then creates a healthy revision from the real image. After
    that, apply again with bootstrap_mode = false to get the real min_replicas.
  EOT
  type        = bool
  default     = false
}

# ---- sizing -----------------------------------------------------------------------------------------------------

variable "cpu" {
  description = "vCPU per replica. On the Consumption profile cpu/memory must be a valid pair, for example 0.5 / 1Gi, 1.0 / 2Gi."
  type        = number
  default     = 0.5
}

variable "memory" {
  description = "Memory per replica, for example 1Gi."
  type        = string
  default     = "1Gi"
}

variable "min_replicas" {
  description = "Minimum API replicas (dev 0, nonprod 1, prod 2)."
  type        = number
}

variable "max_replicas" {
  description = "Maximum API replicas."
  type        = number
}

variable "http_concurrent_requests" {
  description = "Scale out when a replica has more than this many concurrent HTTP requests (KEDA http rule)."
  type        = number
  default     = 50
}

variable "job_cpu" {
  description = "vCPU of the release job container."
  type        = number
  default     = 0.5
}

variable "job_memory" {
  description = "Memory of the release job container."
  type        = string
  default     = "1Gi"
}

variable "job_timeout_seconds" {
  description = "Maximum run time of one release job execution."
  type        = number
  default     = 1800
}

# ---- application settings (non-secret) --------------------------------------------------------------------------

variable "app_env" {
  description = "APP_ENV: dev, nonprod or prod. Selects .env.<APP_ENV> inside the image; the variables below override it."
  type        = string

  validation {
    condition     = contains(["dev", "nonprod", "prod"], var.app_env)
    error_message = "app_env must be dev, nonprod or prod."
  }
}

variable "log_level" {
  description = "LOG_LEVEL."
  type        = string
  default     = "INFO"
}

variable "db_host" {
  description = "DB_HOST: private FQDN of the PostgreSQL server."
  type        = string
}

variable "db_port" {
  description = "DB_PORT."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "DB_NAME."
  type        = string
  default     = "homeschool"
}

variable "db_app_user" {
  description = "DB_USER of the API and APP_DB_USER of the release job: the least-privilege role created by `app.cli release`."
  type        = string
  default     = "homeschool_app"
}

variable "db_admin_user" {
  description = "Database administrator login. Used only by the release job."
  type        = string
  default     = "hsadmin"
}

variable "cors_origins" {
  description = "CORS_ORIGINS: comma separated explicit origins (never *)."
  type        = string

  validation {
    condition     = !can(regex("\\*", var.cors_origins))
    error_message = "cors_origins must list explicit origins; * is refused by the API in nonprod/prod."
  }
}

variable "trusted_hosts" {
  description = "TRUSTED_HOSTS."
  type        = string
  default     = "*"
}

variable "otp_provider" {
  description = "OTP_PROVIDER: console (dev/nonprod) or webhook (required in prod)."
  type        = string

  validation {
    condition     = contains(["console", "webhook"], var.otp_provider)
    error_message = "otp_provider must be console or webhook."
  }
}

variable "otp_webhook_url" {
  description = "OTP_WEBHOOK_URL (https) of the SMS gateway. Required when otp_provider is webhook."
  type        = string
  default     = ""
}

variable "otp_static_test_code" {
  description = "TESTING ONLY: forces every generated OTP to this fixed value instead of a random one. Must be empty in prod (the API refuses to start otherwise)."
  type        = string
  default     = ""
}

variable "declaration_notice_version" {
  description = "DECLARATION_NOTICE_VERSION."
  type        = string
  default     = "2026-09-draft"
}

variable "min_app_version" {
  description = "MIN_APP_VERSION: oldest mobile app version the API accepts."
  type        = string
  default     = "0.1.0"
}

variable "seed_bundle_path" {
  description = "SEED_BUNDLE_PATH for the release job (relative to the image's /srv)."
  type        = string
  default     = "seed/launch-bundle.json"
}

variable "seed_publish" {
  description = "SEED_PUBLISH for the release job: publish imported activities immediately (true for dev/nonprod, false for prod)."
  type        = bool
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
}
