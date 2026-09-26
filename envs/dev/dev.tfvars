# dev - cheapest possible: burstable database, API scales to zero, free Static Web Apps.
# No secrets in this file. Apply with:  terraform apply -var-file=dev.tfvars   (add -var api_bootstrap=true on the FIRST apply)

environment = "dev"
cost_center = "homeschool-engineering"

# CHANGE ME before the first apply: globally unique suffix (3-6 lowercase letters/digits) for registry, key vault
# and database server names. Never reuse one suffix for two environments in the same tenant.
unique_suffix = "x7k2"

vnet_address_space = "10.10.0.0/16"

registry_sku       = "Basic"
log_retention_days = 30
log_daily_quota_gb = 1 # dev cost guard: logs stop at 1 GB/day

postgres_sku_name              = "B_Standard_B1ms"
postgres_storage_mb            = 32768
postgres_backup_retention_days = 7

key_vault_purge_protection_enabled   = false
key_vault_soft_delete_retention_days = 7

api_min_replicas = 0 # scale to zero: the first request after idle takes a few seconds
api_max_replicas = 2
log_level        = "DEBUG"

otp_provider = "console" # the code is written to the log; read it in Log Analytics
otp_static_test_code = "482915" # every OTP is this fixed code while we finish the real SMS gateway; tell testers to use it
seed_publish = true

# Local web development against the Azure dev API (dev only).
extra_cors_origins = ["http://localhost:5173", "http://localhost:4173"]

static_web_app_sku = "Free"
