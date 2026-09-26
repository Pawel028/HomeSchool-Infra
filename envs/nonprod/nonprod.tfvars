# nonprod - shared test environment: production-like topology, small and cheap.
# No secrets in this file. Apply with:  terraform apply -var-file=nonprod.tfvars   (add -var api_bootstrap=true on the FIRST apply)

environment = "nonprod"
cost_center = "homeschool-engineering"

# CHANGE ME before the first apply (see dev.tfvars).
unique_suffix = "x7k2"

vnet_address_space = "10.20.0.0/16"

registry_sku       = "Basic"
log_retention_days = 30
log_daily_quota_gb = 2

postgres_sku_name              = "B_Standard_B2s"
postgres_storage_mb            = 32768
postgres_backup_retention_days = 7

key_vault_purge_protection_enabled   = false
key_vault_soft_delete_retention_days = 7

api_min_replicas = 1
api_max_replicas = 3
log_level        = "INFO"

otp_provider = "console" # testers read the code from the log; never use real phone numbers here
otp_static_test_code = "482915" # every OTP is this fixed code while we finish the real SMS gateway; tell testers to use it
seed_publish = true

static_web_app_sku = "Free"
