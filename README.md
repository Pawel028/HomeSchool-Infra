# infra

Terraform (Azure) for the HomeSchoolingApp platform: one Container Apps-based backend API, its PostgreSQL Flexible
Server, Key Vault, Container Registry, networking and two Static Web Apps, replicated identically across three
environments (`dev`, `nonprod`, `prod`). Deployment of the API *image* is not done by this repo - it is owned by
`backend-api`'s `.github/workflows/deploy.yml`, which reads the names this repo outputs.

> **This Terraform has never been applied.** No Azure resource described here exists. Everything below was built
> and checked by static analysis only - see [What was actually verified](#what-was-actually-verified) for exactly
> which checks ran in this authoring environment, and which were skipped and why.

## Layout

```
modules/            One module per concern: network, postgres, keyvault, registry, monitoring, identity,
                     static_web_apps, container_apps, alerts.
envs/<env>/          dev, nonprod, prod. main.tf/variables.tf/outputs.tf/providers.tf/versions.tf/backend.tf are
                     byte-identical across the three (tools/check-consistency.py enforces it) - only <env>.tfvars
                     and backend.hcl.example differ. This is where you run terraform.
scripts/             Windows PowerShell operator scripts (bootstrap, OIDC setup, running the release job by hand,
                     creating the first admin).
tools/               tools/check-consistency.py - repository-specific static checks (see below).
.github/workflows/   terraform-plan.yml (PRs: fmt/validate/consistency + plan comment) and terraform-apply.yml
                     (push to main -> apply dev; workflow_dispatch -> apply the chosen environment).
```

### Module wiring (envs/*/main.tf)

```
network, monitoring, registry, keyvault      (independent)
postgres        -> network (subnet/DNS), keyvault (admin password)
identity        -> keyvault, registry        (role assignments: Key Vault Secrets User, AcrPull)
static_web_apps                              (independent; CORS origins for the API come from here)
container_apps  -> identity, registry, keyvault, postgres, static_web_apps
alerts (prod)   -> container_apps
```

The resource group itself is **looked up, not created** (`data "azurerm_resource_group"`) - it is created by
`scripts/setup-github-oidc.ps1`, because the CI identity that runs Terraform only has rights *inside* that group
and cannot create it. `terraform destroy` therefore never removes the resource group.

## Order of operations (per environment)

Run this once per environment (`dev`, `nonprod`, `prod`). All commands are Windows PowerShell; `az login` first.

1. **Azure resource providers.** Handled automatically by step 2 below (`bootstrap-state.ps1` registers
   `Microsoft.App`, `Microsoft.OperationalInsights`, `Microsoft.Insights`, `Microsoft.Network`,
   `Microsoft.DBforPostgreSQL`, `Microsoft.KeyVault`, `Microsoft.ContainerRegistry`, `Microsoft.ManagedIdentity`,
   `Microsoft.Web`, `Microsoft.Storage`, `Microsoft.Authorization`). Registration is asynchronous and can take a
   few minutes; the script prints how to check progress. Do this first because the Terraform provider itself is
   configured with `resource_provider_registrations = "none"` (the scoped CI identity cannot register providers).

   ```powershell
   .\scripts\bootstrap-state.ps1 -Environment dev -SubscriptionId <sub-id> -UniqueSuffix x7k2
   ```

2. **`bootstrap-state.ps1`** (above) also creates the Terraform remote-state storage (hardened: TLS 1.2+,
   HTTPS-only, no public blob access, **shared-key access disabled** - state is read/written with Entra ID only),
   a `tfstate` blob container, a `CanNotDelete` lock on the state resource group, and writes
   `envs\<env>\backend.hcl`. **Commit `backend.hcl`** - it holds only resource names, no secrets, and CI needs it
   to run `terraform init -backend-config=backend.hcl`.

3. **`setup-github-oidc.ps1`** - creates the environment resource group and two Entra app registrations/service
   principals with OIDC federated credentials (no stored secrets): one for this repo (Terraform: Contributor +
   User Access Administrator on the resource group, Storage Blob Data Contributor on the state account), one for
   the deploy repos (`backend-api`, `web`, `mobile-app`: Contributor on the resource group only).

   ```powershell
   .\scripts\setup-github-oidc.ps1 -Environment dev -SubscriptionId <sub-id> -GitHubOwner <org> -UniqueSuffix x7k2
   ```

   Create the GitHub **environment** named `dev`/`nonprod`/`prod` in each repository that needs one (this repo,
   plus `backend-api`); add **Required reviewers** on `nonprod` and `prod` (Settings > Environments) - the OIDC
   federated credential is bound to the environment, so an unapproved run cannot even obtain an Azure token.
   Restrict `prod`'s deployment branch to `main` too.

4. **Set GitHub variables** the script prints, for example with the GitHub CLI:

   - This repo (`infra`), **repository** variables: `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
     `AZURE_CLIENT_ID_DEV`, `AZURE_CLIENT_ID_NONPROD`, `AZURE_CLIENT_ID_PROD` (one client ID per environment,
     because `terraform-plan.yml`'s matrix job plans all three environments from a single workflow run).
   - `backend-api` (and `web`, `mobile-app` when they exist), **environment** variables, once per GitHub
     environment (`dev`/`nonprod`/`prod`): `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`.

5. **`terraform init` / `plan` / `apply`**, from `envs\<env>`:

   ```powershell
   cd envs\dev
   terraform init -backend-config=backend.hcl
   terraform plan  -var-file=dev.tfvars -var api_bootstrap=true   # FIRST apply only, see below
   terraform apply -var-file=dev.tfvars -var api_bootstrap=true
   ```

   `api_bootstrap=true` is required on the very first apply of an environment - see
   [The placeholder-image pattern](#the-placeholder-image--lifecycleignore_changes-pattern) below. `prod.tfvars`
   ships with two deliberate placeholders (`otp_webhook_url`, `alert_email`) whose validation blocks make `plan`
   **fail on purpose** until an operator replaces them with real values; `dev`/`nonprod` are unaffected.

   From here on, either run Terraform locally the same way, or push to `main` (auto-applies `dev`) / dispatch
   `.github/workflows/terraform-apply.yml` choosing the environment (`nonprod`/`prod` wait for their Required
   reviewers).

6. **Set the deploy pipeline's GitHub environment variables** in `backend-api` (and `web`/`mobile-app` once they
   exist), from this environment's Terraform outputs:

   ```powershell
   terraform output -json github_environment_variables
   # ACR_NAME, CONTAINER_APP_NAME, RELEASE_JOB_NAME, AZURE_RESOURCE_GROUP
   ```

7. **Deploy the first real image.** Push to `backend-api`'s `main` (or dispatch its `deploy.yml`), which builds
   the image, runs the release job (migrations + least-privilege DB role + seed) against it, waits for that to
   succeed, and only then points the live API at the new image. The very first run replaces the placeholder image
   that `api_bootstrap=true` scaled to zero.

8. **Re-apply Terraform with `api_bootstrap=false`** (or the default, i.e. just drop `-var api_bootstrap=true`) so
   `min_replicas` goes back to its real value (dev 0, nonprod 1, prod 2). The image itself is untouched either way
   (`lifecycle.ignore_changes`, see below).

9. If you need to run the release job by hand instead of through CI (first bring-up troubleshooting, or a manual
   re-seed):

   ```powershell
   .\scripts\run-release-job.ps1 -Environment dev
   ```

10. **Create the first platform admin** - see `scripts/create-first-admin.md`. In short:
    `az containerapp exec` into the running API (wakes it first in `dev`, which scales to zero) and run
    `python -m app.cli create-admin --email ... --name ... --role super_admin` with a hidden password prompt. The
    password never touches a file, pipeline or state.

11. **prod only, before the first prod apply:** replace the two placeholders in `envs/prod/prod.tfvars`
    (`otp_webhook_url` - a real `https://` SMS gateway URL, `alert_email` - a real recipient), then after the
    first apply overwrite the `otp-webhook-token` secret in Key Vault with the gateway's real token and restart
    the API revision (`az containerapp revision restart`) so it picks it up.

## The placeholder-image + `lifecycle.ignore_changes` pattern

The API Container App and the release Job both default `api_image` to a public placeholder
(`mcr.microsoft.com/k8se/quickstart:latest`), because the very first `terraform apply` of an environment runs
before any real image has ever been built. Both resources also carry:

```hcl
lifecycle {
  ignore_changes = [template[0].container[0].image]
}
```

so **Terraform never looks at the image again after creation**. From the first apply onward, the image is owned
entirely by the CI/CD pipeline (`backend-api`'s `deploy.yml`): it builds into ACR tagged with the git SHA, updates
+ runs the release job with that image, then runs `az containerapp update --image ...` on the live API. None of
that ever shows up as Terraform drift, and a later `terraform apply` (say, to change CPU/memory or an env var)
creates a new revision that **keeps whatever image CI last deployed** - the ignored attribute is read back from
the refreshed state, not from `var.api_image`.

The placeholder image also has no `/healthz`/`/readyz` and listens on the wrong port, so on a first apply the API
would never pass its real probes. `api_bootstrap = true` works around that by setting `min_replicas = 0`
(`bootstrap_mode` in `modules/container_apps`): nothing starts, nothing fails its probes, and the apply succeeds
cleanly. Once CI has deployed the first real image, re-apply with `api_bootstrap = false` (or omit the flag) to
get the environment's real `min_replicas`.

## Secrets

No secret value is ever passed to Container Apps as a plain string. `modules/keyvault` generates
`jwt-secret` (64 random chars), `db-admin-password` and `db-app-password` (32 random chars each), plus an
`otp-webhook-token` placeholder that an operator overwrites by hand (Terraform's `lifecycle.ignore_changes` on
that secret's `value` means it is never put back). `modules/container_apps` wires `DB_PASSWORD`, `JWT_SECRET`,
`OTP_WEBHOOK_TOKEN` (API) and `DB_PASSWORD`/`APP_DB_PASSWORD`/`JWT_SECRET` (release job) as Container Apps
`secret { key_vault_secret_id = ... }` references resolved by the platform at revision start - never a literal
`value`. After rotating a secret in Key Vault, restart the revision (`az containerapp revision restart`) to pick
up the new version. `tools/check-consistency.py` checks this wiring mechanically (see below).

Terraform state itself contains the generated secrets in clear text (this is normal for `random_password` +
`azurerm_key_vault_secret`). That is exactly why the state storage account from `bootstrap-state.ps1` disables
shared-key access and grants only Entra RBAC (`Storage Blob Data Contributor`) to a small set of principals -
treat access to that storage account as equivalent to production secret access.

## Cost notes (rough estimate only - do not treat as a quote)

Ballpark, `centralindia`/`eastasia` list pricing at authoring time, ignoring the Free/Basic tiers' burstable
credits and any regional or negotiated discount. **Actual cost depends heavily on traffic and log volume - check
the [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) before committing to a budget.**

| Environment | Postgres | Container Apps (baseline) | ACR | Static Web Apps | Log Analytics | Rough total/mo |
|---|---|---|---|---|---|---|
| `dev`     | B1ms burstable, ~$15-20 | scale-to-zero, ~$0-10 | Basic, ~$5 | Free, $0 | 1 GB/day cap, ~$5-15 | **~$30-50** |
| `nonprod` | B2s burstable, ~$35-45 | 1 replica always on, ~$30-40 | Basic, ~$5 | Free, $0 | 2 GB/day cap, ~$10-30 | **~$90-120** |
| `prod`    | GP D2ds_v5, ~$140-160  | 2 replicas always on, ~$60-80 | Standard, ~$20 | Standard x2, ~$18 | 90-day retention, unlimited quota, ~$50-150 | **~$300-450+** |

Levers that change this materially: `postgres_high_availability_mode` (roughly doubles database compute when set),
`postgres_geo_redundant_backup`, `container_apps_zone_redundant`, `api_max_replicas` under real load, and
`log_daily_quota_gb` (`-1` = unlimited, which is the biggest single source of surprise cost if the app gets noisy).

## Destroy notes

`terraform destroy -var-file=<env>.tfvars` from `envs/<env>`. Things it will **not** do:

- **The resource group is not destroyed** (it is a data source, looked up not managed) - it is left behind
  (probably empty) and needs `az group delete` by hand if you are fully decommissioning the environment.
- **`prod`'s Key Vault and PostgreSQL server refuse to be destroyed** (`lifecycle.prevent_destroy = true`, driven
  by `var.environment == "prod"` in both modules). You must first edit the tfvars/module to turn protection off (or
  `terraform state rm` + delete by hand, understanding that means real data loss) before a destroy can proceed.
  `dev`/`nonprod` have no such protection.
- **Key Vault purge**: in `prod`, `key_vault_purge_protection_enabled = true` means even after the vault resource
  is deleted, Azure keeps it in a soft-deleted state for `key_vault_soft_delete_retention_days` and it **cannot be
  purged early by anyone, including Owner** - this is irreversible by design. Non-prod vaults are purged
  automatically on destroy (`purge_soft_delete_on_destroy` in `providers.tf`, keyed off `var.environment`).
- **The Terraform state storage account is untouched** - it was created by `bootstrap-state.ps1`, not by this
  Terraform, and its resource group carries a `CanNotDelete` lock. Remove the lock (`az lock delete`) yourself if
  you intend to delete the state account too.
- **The OIDC app registrations/service principals from `setup-github-oidc.ps1` are untouched** - delete them with
  `az ad app delete` by hand if the environment is being retired for good.

## What was actually verified

This Terraform was **not applied** anywhere - no Azure subscription was used. What *was* run, in this authoring
environment:

1. **`python-hcl2` syntax parse of every `.tf` file** (`pip install python-hcl2`, then `hcl2.load()` on each file
   found under the repo): **54/54 files parsed without error.**
2. **OpenTofu (`tofu init -backend=false` + `tofu validate`) per environment: SKIPPED.** `github.com` and
   `api.github.com` both returned `403 "GitHub access to this repository is not enabled for this session"` for
   this sandbox (confirmed with `curl -v` - a real HTTP 403 from a completed TLS connection through the egress
   proxy, not a network failure), and no tool to grant that access (`add_repo`) was available in this session. Per
   the task's own fallback, this was not routed around; OpenTofu validation was not run at all. (`releases
   .hashicorp.com` and `storage.googleapis.com`, needed for real Terraform provider downloads, are separately
   policy-denied in this sandbox regardless.)
3. **All workflow YAML parses with PyYAML**: `terraform-plan.yml`, `terraform-apply.yml` (this repo) and
   `backend-api/.github/workflows/deploy.yml` - **3/3 parsed without error.**
4. **PowerShell parser check on every `.ps1` script: SKIPPED.** `pwsh` is not installed in this environment, and
   installing it was not attempted because its GitHub releases (the task's suggested install source) are blocked
   by the same `add_repo` gate as point 2. The three scripts were instead reviewed by hand for balanced
   quoting/braces and correct parameter usage.
5. **`tools/check-consistency.py`**, both modes:
   - `python tools/check-consistency.py --no-backend` (what `terraform-plan.yml`'s CI job actually runs): **0
     errors, 3 notes** (the two intentional `prod.tfvars` placeholders, plus "backend cross-check skipped" since
     `--no-backend` was passed).
   - `python tools/check-consistency.py --backend ../backend-api` (what a local run with both repos checked out
     side by side does, including the Container-Apps-env-vars-vs-`Settings` cross-check): **0 errors, 2 notes**
     (the same two intentional placeholders). All seven checks passed: environment parity, protected/unprotected
     resource twins, Key Vault secret wiring, `github_environment_variables` output wiring, every non-secret
     Container App/Job env var mapping to an `app.config.Settings` field, every secret env var being sourced from
     Key Vault rather than a plain value, and `prod.tfvars` against `app.config.py`'s production guard.
   - The tool's detection logic was also sanity-checked by deliberately injecting a bogus env var and a divergent
     `protected`/`unprotected` resource twin: both were caught and reported as errors, then the injected changes
     were reverted (confirmed clean again afterward).

**No real bugs were found in the pre-existing Terraform, scripts or workflows** during this review - the wiring
between modules, the KV secret references, the env-var names and the prod tfvars all checked out. See
[tools/check-consistency.py](tools/check-consistency.py)'s own docstring for exactly what each of its seven checks
covers and why.

## Remaining gaps / what a human still needs to do

- Nothing here has ever touched a real Azure subscription - the entire happy path above (provider registration
  through first admin creation) needs to be walked end-to-end by a human with real Azure credentials before this
  is trustworthy in production.
- OpenTofu/Terraform `validate`/`plan` against the real `azurerm`/`random`/`time` providers has never run (see
  point 2 above) - `python-hcl2` only confirms the files are syntactically well-formed HCL, not that the provider
  schema is satisfied (attribute names, block nesting, required arguments for each resource type).
- The `.ps1` scripts were never executed or parsed by PowerShell itself (see point 4 above).
- `prod.tfvars`' two placeholders (`otp_webhook_url`, `alert_email`) must be replaced with real values before
  `prod` can ever successfully plan.
- `web` and `mobile-app` repositories (referenced by `setup-github-oidc.ps1`'s `-DeployRepos` default and by the
  Static Web Apps' deployment story) are outside this repo's scope and were not touched.
- Application Insights is wired up (`modules/monitoring`) but the API does not yet emit OpenTelemetry/App Insights
  telemetry - the connection string output exists for when it does.
