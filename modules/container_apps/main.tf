# Container Apps: environment (workload profiles, Consumption), the API app, and the `release` job.
#
# HOW THE IMAGE IS HANDLED (read this before changing anything)
#   * The first `terraform apply` runs before any image exists, so api_image defaults to a public placeholder.
#   * Both the app and the job have `lifecycle { ignore_changes = [template[0].container[0].image] }`. From then on the
#     backend pipeline owns the image: it builds into ACR, updates the job image, runs the job, then runs
#     `az containerapp update --image`. Terraform never sees that as drift and never reverts it.
#   * Everything else in the template (env vars, probes, scale rules, secrets) stays under Terraform control, and a
#     Terraform change that creates a new revision keeps the image CI last deployed (the ignored attribute keeps the
#     value from the refreshed state).
#
# SECRETS
#   No secret value is ever passed to Container Apps by Terraform. Each secret is a Key Vault reference
#   (key_vault_secret_id + identity); environment variables point at the secret name (secret_name). The platform
#   resolves the current secret version when a revision starts, so after rotating a secret in Key Vault restart the
#   revision (az containerapp revision restart) to pick it up.

locals {
  # Non-secret settings shared by the API and the release job. Every name must be a field of app/config.py Settings
  # (tools/check-consistency.py checks this). The release job needs the same set because `app.cli release` builds
  # Settings first, and the strict production validation applies to it as well.
  common_env = {
    APP_ENV                    = var.app_env
    LOG_LEVEL                  = var.log_level
    LOG_JSON                   = "true"
    DB_HOST                    = var.db_host
    DB_PORT                    = tostring(var.db_port)
    DB_NAME                    = var.db_name
    DB_SSLMODE                 = "require"
    CORS_ORIGINS               = var.cors_origins
    TRUSTED_HOSTS              = var.trusted_hosts
    OTP_PROVIDER               = var.otp_provider
    OTP_WEBHOOK_URL            = var.otp_webhook_url
    DECLARATION_NOTICE_VERSION = var.declaration_notice_version
    MIN_APP_VERSION            = var.min_app_version
    # .env.dev sets EXPOSE_DEV_OTP=true for laptops; in Azure it is always off (the API refuses it in nonprod/prod).
    EXPOSE_DEV_OTP = "false"
  }

  api_env = merge(local.common_env, {
    DB_USER = var.db_app_user
    # .env.dev seeds on startup; deployed environments seed only through the release job.
    SEED_ON_STARTUP = "false"
  })

  # Environment variable -> Container App secret (which is a Key Vault reference of the same name).
  api_secret_env = {
    DB_PASSWORD       = "db-app-password"
    JWT_SECRET        = "jwt-secret"
    OTP_WEBHOOK_TOKEN = "otp-webhook-token"
  }

  # The release job connects as the ADMIN login (migrations, role creation) and hands the app password to
  # `app.cli release`, which creates/refreshes the homeschool_app role.
  job_env = merge(local.common_env, {
    DB_USER          = var.db_admin_user
    APP_DB_USER      = var.db_app_user
    SEED_BUNDLE_PATH = var.seed_bundle_path
    SEED_PUBLISH     = tostring(var.seed_publish)
  })

  job_secret_env = {
    DB_PASSWORD     = "db-admin-password"
    APP_DB_PASSWORD = "db-app-password"
    JWT_SECRET      = "jwt-secret"
  }

  api_secrets = { for name in distinct(values(local.api_secret_env)) : name => var.key_vault_secret_ids[name] }
  job_secrets = { for name in distinct(values(local.job_secret_env)) : name => var.key_vault_secret_ids[name] }

  # Bootstrap mode (placeholder image) runs no replicas at all, see variable bootstrap_mode.
  effective_min_replicas = var.bootstrap_mode ? 0 : var.min_replicas
}

resource "azurerm_container_app_environment" "this" {
  name                = "cae-${var.name_prefix}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  infrastructure_subnet_id       = var.infrastructure_subnet_id
  internal_load_balancer_enabled = false
  zone_redundancy_enabled        = var.zone_redundancy_enabled

  logs_destination           = "log-analytics"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # Workload-profiles environment with the pay-per-use Consumption profile (no dedicated nodes to pay for).
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_container_app" "api" {
  name                         = "ca-${var.name_prefix}-api"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single" # a new revision only takes traffic once it passes its probes
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity_id]
  }

  registry {
    server   = var.registry_login_server
    identity = var.identity_id
  }

  dynamic "secret" {
    for_each = local.api_secrets

    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = var.identity_id
    }
  }

  ingress {
    external_enabled           = true
    target_port                = var.target_port
    transport                  = "auto"
    allow_insecure_connections = false # plain HTTP is redirected to HTTPS

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = local.effective_min_replicas
    max_replicas = var.max_replicas

    http_scale_rule {
      name                = "http-concurrency"
      concurrent_requests = tostring(var.http_concurrent_requests)
    }

    container {
      name   = "api"
      image  = var.api_image
      cpu    = var.cpu
      memory = var.memory

      dynamic "env" {
        for_each = { for k, v in local.api_env : k => v if v != "" }

        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.api_secret_env

        content {
          name        = env.key
          secret_name = env.value
        }
      }

      # Startup: gives a cold start up to 2 minutes (24 x 5 s) before the revision is declared failed.
      startup_probe {
        transport               = "HTTP"
        port                    = var.target_port
        path                    = "/healthz"
        interval_seconds        = 5
        timeout                 = 3
        failure_count_threshold = 24
      }

      # Liveness: the process is up (no dependencies touched) - a failure restarts the container.
      liveness_probe {
        transport               = "HTTP"
        port                    = var.target_port
        path                    = "/healthz"
        interval_seconds        = 30
        timeout                 = 3
        failure_count_threshold = 3
      }

      # Readiness: the database answers - a failure takes the replica out of rotation without restarting it.
      readiness_probe {
        transport               = "HTTP"
        port                    = var.target_port
        path                    = "/readyz"
        interval_seconds        = 10
        timeout                 = 5
        failure_count_threshold = 3
        success_count_threshold = 1
      }
    }
  }

  lifecycle {
    # CI deploys new images with `az containerapp update --image`; do not treat that as drift.
    ignore_changes = [template[0].container[0].image]
  }
}

# Manual-trigger job: `python -m app.cli release` (migrations + least-privilege role + seed). CI updates its image
# to the new build and starts it BEFORE switching the API to that image.
resource "azurerm_container_app_job" "release" {
  name                         = "caj-${var.name_prefix}-release"
  location                     = var.location
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  replica_timeout_in_seconds   = var.job_timeout_seconds
  replica_retry_limit          = 0 # a failed migration is not retried blindly
  tags                         = var.tags

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity_id]
  }

  registry {
    server   = var.registry_login_server
    identity = var.identity_id
  }

  dynamic "secret" {
    for_each = local.job_secrets

    content {
      name                = secret.key
      key_vault_secret_id = secret.value
      identity            = var.identity_id
    }
  }

  template {
    container {
      name    = "release"
      image   = var.api_image
      cpu     = var.job_cpu
      memory  = var.job_memory
      command = ["python", "-m", "app.cli", "release"]

      dynamic "env" {
        for_each = { for k, v in local.job_env : k => v if v != "" }

        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.job_secret_env

        content {
          name        = env.key
          secret_name = env.value
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }
}
