<#
.SYNOPSIS
    Creates the Terraform remote-state resources for one environment (run once per environment, safe to re-run).

.DESCRIPTION
    Creates, or brings back to the required settings if they already exist:
      * resource group   rg-<ShortName>-tfstate-<Environment>
      * storage account  st<ShortName>tf<Environment><UniqueSuffix>
            - TLS 1.2 minimum, HTTPS only, no public blob access, SHARED KEY ACCESS DISABLED (Entra ID only)
            - blob versioning + 30 day soft delete for blobs and containers
      * blob container   tfstate
      * CanNotDelete lock on the state resource group (skip with -SkipLock)
      * Storage Blob Data Contributor for the signed-in user on the storage account
    Registers the Azure resource providers the platform needs (skip with -SkipProviderRegistration); the Terraform
    provider is configured with resource_provider_registrations = "none" because the CI identity cannot do it.
    Writes envs/<Environment>/backend.hcl for `terraform init -backend-config=backend.hcl`.

    WHY LOCKED DOWN: Terraform state contains generated secrets (database admin password, JWT secret) in clear text.
    Anyone who can read the state can read production secrets. Keep the number of principals with Storage Blob Data
    roles on this account small and never grant Reader-with-keys style access.

    Requires: Azure CLI (`az login` done) and Owner (or Contributor + User Access Administrator) on the subscription.
    Works in Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
    .\bootstrap-state.ps1 -Environment dev -SubscriptionId 00000000-0000-0000-0000-000000000000 -UniqueSuffix x7k2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('dev', 'nonprod', 'prod')][string]$Environment,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{3,6}$')][string]$UniqueSuffix,
    [string]$Location = 'centralindia',
    [ValidatePattern('^[a-z0-9]{2,5}$')][string]$ShortName = 'hs',
    [string]$ResourceGroupName,
    [string]$StorageAccountName,
    [string]$ContainerName = 'tfstate',
    [string]$StorageSku,
    [string]$CostCenter = 'homeschool-engineering',
    [string]$BackendConfigPath,
    [switch]$SkipProviderRegistration,
    [switch]$SkipLock
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Az {
    # Runs az, returns stdout as one string, throws (with az's stderr) on a non-zero exit code.
    # Warnings on stderr must not become terminating errors in Windows PowerShell 5.1.
    param([Parameter(Mandatory)][string[]]$AzArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & az @AzArgs --only-show-errors 2>&1 } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) {
        throw ("az {0} failed (exit {1}):`n{2}" -f ($AzArgs -join ' '), $LASTEXITCODE, (($output | ForEach-Object { "$_" }) -join "`n"))
    }
    (($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
}

function Test-Az {
    # $true when the az command succeeds (used for "does it exist" probes).
    param([Parameter(Mandatory)][string[]]$AzArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & az @AzArgs --only-show-errors 2>&1 } finally { $ErrorActionPreference = $previous }
    return ($LASTEXITCODE -eq 0)
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) was not found. Install it from https://aka.ms/installazurecliwindows and run az login.' }

if (-not $ResourceGroupName) { $ResourceGroupName = "rg-$ShortName-tfstate-$Environment" }
if (-not $StorageAccountName) { $StorageAccountName = "st${ShortName}tf${Environment}${UniqueSuffix}" }
if ($StorageAccountName -notmatch '^[a-z0-9]{3,24}$') { throw "Storage account name '$StorageAccountName' must be 3-24 lowercase letters/digits. Use a shorter -UniqueSuffix or pass -StorageAccountName." }
if (-not $StorageSku) { $StorageSku = if ($Environment -eq 'prod') { 'Standard_GRS' } else { 'Standard_LRS' } }
if (-not $BackendConfigPath) { $BackendConfigPath = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') "envs\$Environment") 'backend.hcl' }

$tags = @('project=homeschool', "env=$Environment", 'managed_by=bootstrap-state.ps1', "cost_center=$CostCenter")

Write-Host "Subscription : $SubscriptionId"
Write-Host "Environment  : $Environment"
Write-Host "State RG     : $ResourceGroupName ($Location)"
Write-Host "Storage acct : $StorageAccountName ($StorageSku)"

Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null

# --- 1. Resource providers ---------------------------------------------------------------------------------------
$providers = @(
    'Microsoft.App', 'Microsoft.OperationalInsights', 'Microsoft.Insights', 'Microsoft.Network',
    'Microsoft.DBforPostgreSQL', 'Microsoft.KeyVault', 'Microsoft.ContainerRegistry', 'Microsoft.ManagedIdentity',
    'Microsoft.Web', 'Microsoft.Storage', 'Microsoft.Authorization'
)
if (-not $SkipProviderRegistration) {
    Write-Host "`n[1/6] Registering resource providers (asynchronous, can take a few minutes)"
    foreach ($p in $providers) {
        $state = Invoke-Az @('provider', 'show', '--namespace', $p, '--query', 'registrationState', '-o', 'tsv')
        if ($state -ne 'Registered') {
            Write-Host "  registering $p (was $state)"
            Invoke-Az @('provider', 'register', '--namespace', $p) | Out-Null
        }
    }
}
else { Write-Host "`n[1/6] Skipping provider registration" }

# --- 2. Resource group -------------------------------------------------------------------------------------------
Write-Host "`n[2/6] Resource group"
Invoke-Az (@('group', 'create', '--name', $ResourceGroupName, '--location', $Location, '--tags') + $tags) | Out-Null

# --- 3. Storage account (create or re-apply the hardened settings) -----------------------------------------------
Write-Host "`n[3/6] Storage account"
$hardening = @('--min-tls-version', 'TLS1_2', '--https-only', 'true', '--allow-blob-public-access', 'false', '--allow-shared-key-access', 'false')
if (Test-Az @('storage', 'account', 'show', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName)) {
    Write-Host "  exists, re-applying settings"
    Invoke-Az (@('storage', 'account', 'update', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName) + $hardening) | Out-Null
}
else {
    Write-Host "  creating"
    Invoke-Az (@('storage', 'account', 'create', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName,
            '--location', $Location, '--sku', $StorageSku, '--kind', 'StorageV2', '--access-tier', 'Hot', '--tags') + $tags + $hardening) | Out-Null
}
Invoke-Az @('storage', 'account', 'blob-service-properties', 'update', '--account-name', $StorageAccountName,
    '--resource-group', $ResourceGroupName, '--enable-versioning', 'true',
    '--enable-delete-retention', 'true', '--delete-retention-days', '30',
    '--enable-container-delete-retention', 'true', '--container-delete-retention-days', '30') | Out-Null
$storageId = Invoke-Az @('storage', 'account', 'show', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName, '--query', 'id', '-o', 'tsv')

# --- 4. Data-plane access for the person running this script -------------------------------------------------------
Write-Host "`n[4/6] Storage Blob Data Contributor for the signed-in user"
$userId = $null
try { $userId = Invoke-Az @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv') } catch { $userId = $null }
if ($userId) {
    # NOTE: deliberately using '-o json' + ConvertFrom-Json here instead of a '--query length(@)'
    # JMESPath expression. az on Windows resolves to az.cmd, a batch-file wrapper; when PowerShell
    # forwards an argument containing '(' ')' '@' to a .cmd file, cmd.exe's own line parsing can
    # choke on those characters before Azure CLI ever sees them (surfaces as a bogus
    # "'-o' was unexpected at this time" cmd.exe error). Counting in PowerShell avoids that class of bug.
    $existingAssignmentsJson = Invoke-Az @('role', 'assignment', 'list', '--assignee', $userId, '--role', 'Storage Blob Data Contributor', '--scope', $storageId, '-o', 'json')
    $existingAssignments = @()
    if ($existingAssignmentsJson) { $existingAssignments = @($existingAssignmentsJson | ConvertFrom-Json) }
    if ($existingAssignments.Count -eq 0) {
        Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $userId, '--assignee-principal-type', 'User',
            '--role', 'Storage Blob Data Contributor', '--scope', $storageId) | Out-Null
        Write-Host '  assigned'
    }
    else { Write-Host '  already assigned' }
}
else {
    Write-Warning 'Could not resolve the signed-in user (service principal login?). Make sure this identity has Storage Blob Data Contributor on the storage account.'
}

# --- 5. Container (role assignments need a moment to propagate: retry) -------------------------------------------
Write-Host "`n[5/6] Blob container '$ContainerName'"
$created = $false
for ($i = 1; $i -le 20 -and -not $created; $i++) {
    try {
        Invoke-Az @('storage', 'container', 'create', '--name', $ContainerName, '--account-name', $StorageAccountName, '--auth-mode', 'login') | Out-Null
        $created = $true
    }
    catch {
        if ($i -eq 20) { throw }
        Write-Host "  waiting for the role assignment to propagate ($i/20)..."
        Start-Sleep -Seconds 15
    }
}
Write-Host '  ready'

# --- 6. Lock -----------------------------------------------------------------------------------------------------
if (-not $SkipLock) {
    Write-Host "`n[6/6] CanNotDelete lock on $ResourceGroupName"
    # Same reasoning as step 4: avoid a parens/brackets-laden '--query' JMESPath expression going
    # through PowerShell -> az.cmd -> cmd.exe, and count in PowerShell instead.
    $existingLocksJson = Invoke-Az @('lock', 'list', '--resource-group', $ResourceGroupName, '-o', 'json')
    $existingLocks = @()
    if ($existingLocksJson) { $existingLocks = @($existingLocksJson | ConvertFrom-Json) }
    $lockCount = @($existingLocks | Where-Object { $_.name -eq 'lock-tfstate' }).Count
    if ($lockCount -eq 0) {
        Invoke-Az @('lock', 'create', '--name', 'lock-tfstate', '--lock-type', 'CanNotDelete', '--resource-group', $ResourceGroupName) | Out-Null
        Write-Host '  created'
    }
    else { Write-Host '  already present' }
}
else { Write-Host "`n[6/6] Skipping lock" }

# --- backend.hcl -------------------------------------------------------------------------------------------------
$backend = @"
resource_group_name  = "$ResourceGroupName"
storage_account_name = "$StorageAccountName"
container_name       = "$ContainerName"
key                  = "$Environment.tfstate"
"@
$backendDir = Split-Path -Parent $BackendConfigPath
if (Test-Path $backendDir) {
    Set-Content -Path $BackendConfigPath -Value $backend -Encoding ascii
    Write-Host "`nWrote $BackendConfigPath (names only, no secrets - commit it so CI can initialise the backend)."
}
else {
    Write-Warning "Directory $backendDir not found; create backend.hcl by hand with:`n$backend"
}

Write-Host "`nDone. Next: scripts\setup-github-oidc.ps1 -Environment $Environment ..., then in envs\$Environment run:"
Write-Host "  terraform init -backend-config=backend.hcl"
if (-not $SkipProviderRegistration) {
    Write-Host "Provider registration continues in the background; check with:  az provider list --query ""[?registrationState!='Registered' && starts_with(namespace,'Microsoft.')].namespace"" -o tsv"
}
