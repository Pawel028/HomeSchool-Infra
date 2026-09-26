<#
.SYNOPSIS
    Lets GitHub Actions deploy to one environment with NO stored secrets (OpenID Connect federation). Safe to re-run.

.DESCRIPTION
    For the given environment this script creates (or reuses):
      * the environment resource group   rg-<ShortName>-<Environment>   (Terraform looks it up; the CI identity only
        has rights inside it, so it cannot create it)
      * TWO Entra ID app registrations + service principals (least privilege, so a compromised app pipeline cannot
        change infrastructure or grant itself roles):
            sp-<ShortName>-github-infra-<Environment>    used by the infra repo (Terraform)
                federated credentials: environment:<env> and pull_request of the infra repo
                roles on the environment resource group: Contributor + User Access Administrator
                                                        (or, with -NarrowRbac, Contributor + RBAC Administrator limited
                                                        to AcrPull / Key Vault Secrets User / Key Vault Secrets Officer)
                role on the Terraform state storage account: Storage Blob Data Contributor
            sp-<ShortName>-github-deploy-<Environment>   used by backend-api, web and mobile-app
                federated credentials: environment:<env> of each of those repos
                role on the environment resource group: Contributor (deploy images and static content only)
    and prints the GitHub variables to set. Nothing secret is created or printed: OIDC issues short-lived tokens.

    Requires: Azure CLI logged in as someone who can create app registrations in Entra ID and assign roles
    (Owner, or Contributor + User Access Administrator, on the subscription). Uses az only. Works in Windows PowerShell
    5.1 and PowerShell 7.

    The GitHub environments (dev / nonprod / prod) must exist in each repository. For nonprod and prod add
    "Required reviewers" (Settings > Environments) so that deployments wait for a human approval; because the
    federated credential is tied to the environment, a run that has not been approved cannot obtain an Azure token.

.EXAMPLE
    .\setup-github-oidc.ps1 -Environment dev -SubscriptionId 0000... -GitHubOwner my-org -UniqueSuffix x7k2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('dev', 'nonprod', 'prod')][string]$Environment,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$GitHubOwner,
    [string]$UniqueSuffix,
    [string]$Location = 'centralindia',
    [ValidatePattern('^[a-z0-9]{2,5}$')][string]$ShortName = 'hs',
    [string]$ResourceGroupName,
    [string]$InfraRepo = 'infra',
    [string[]]$DeployRepos = @('backend-api', 'web', 'mobile-app'),
    [string]$StateResourceGroupName,
    [string]$StateStorageAccountName,
    [string]$CostCenter = 'homeschool-engineering',
    [switch]$NarrowRbac
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & az @AzArgs --only-show-errors 2>&1 } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) {
        throw ("az {0} failed (exit {1}):`n{2}" -f ($AzArgs -join ' '), $LASTEXITCODE, (($output | ForEach-Object { "$_" }) -join "`n"))
    }
    (($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n").Trim()
}

function Invoke-AzRetry {
    # Newly created service principals need a little time to replicate before role assignments accept them.
    param([Parameter(Mandatory)][string[]]$AzArgs, [int]$Attempts = 8)
    for ($i = 1; $i -le $Attempts; $i++) {
        try { return (Invoke-Az $AzArgs) }
        catch {
            if ($i -eq $Attempts -or $_.Exception.Message -notmatch 'PrincipalNotFound|does not exist in the directory|replication') { throw }
            Write-Host "  waiting for Entra ID replication ($i/$Attempts)..."
            Start-Sleep -Seconds 10
        }
    }
}

function Get-OrCreate-AppRegistration {
    param([Parameter(Mandatory)][string]$DisplayName)
    # NOTE: using '-o json' + ConvertFrom-Json rather than a bracket/pipe JMESPath '--query' string.
    # az on Windows resolves to az.cmd, a batch-file wrapper; an unquoted argument containing
    # '(' ')' '[' ']' '|' '@' can be misparsed by cmd.exe before Azure CLI ever sees it (this is what
    # broke Set-RoleAssignment's 'length(@)' query below). Filtering in PowerShell avoids the whole class of bug.
    $apps = @()
    $appsJson = Invoke-Az @('ad', 'app', 'list', '--display-name', $DisplayName, '-o', 'json')
    if ($appsJson) { $apps = @($appsJson | ConvertFrom-Json) }
    # Under Set-StrictMode, ".appId" on a $null (no match) throws "property cannot be found" -
    # guard with .Count before indexing, same pattern as the service-principal lookup below.
    $matchingApps = @($apps | Where-Object { $_.displayName -eq $DisplayName })
    $appId = if ($matchingApps.Count -gt 0) { $matchingApps[0].appId } else { $null }
    if (-not $appId) {
        Write-Host "  creating app registration $DisplayName"
        $appId = Invoke-Az @('ad', 'app', 'create', '--display-name', $DisplayName, '--sign-in-audience', 'AzureADMyOrg', '--query', 'appId', '-o', 'tsv')
    }
    else { Write-Host "  app registration $DisplayName exists" }

    $sps = @()
    $spsJson = Invoke-Az @('ad', 'sp', 'list', '--filter', "appId eq '$appId'", '-o', 'json')
    if ($spsJson) { $sps = @($spsJson | ConvertFrom-Json) }
    $spId = if ($sps.Count -gt 0) { $sps[0].id } else { $null }
    if (-not $spId) {
        Write-Host '  creating service principal'
        $spId = Invoke-Az @('ad', 'sp', 'create', '--id', $appId, '--query', 'id', '-o', 'tsv')
    }
    [pscustomobject]@{ DisplayName = $DisplayName; AppId = $appId; ServicePrincipalObjectId = $spId }
}

function Set-FederatedCredential {
    param([Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Subject)
    $creds = @()
    $credsJson = Invoke-Az @('ad', 'app', 'federated-credential', 'list', '--id', $AppId, '-o', 'json')
    if ($credsJson) { $creds = @($credsJson | ConvertFrom-Json) }
    # Same StrictMode guard as above: check .Count before indexing/property access.
    $matchingCreds = @($creds | Where-Object { $_.name -eq $Name })
    $existing = if ($matchingCreds.Count -gt 0) { $matchingCreds[0].name } else { $null }
    if ($existing) { Write-Host "  federated credential $Name exists ($Subject)"; return }
    $body = [ordered]@{
        name        = $Name
        issuer      = 'https://token.actions.githubusercontent.com'
        subject     = $Subject
        description = 'GitHub Actions OIDC (managed by setup-github-oidc.ps1)'
        audiences   = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress
    $file = [System.IO.Path]::GetTempFileName()
    try {
        # A file avoids the JSON quoting problems of passing JSON on a Windows command line.
        Set-Content -Path $file -Value $body -Encoding ascii
        Invoke-Az @('ad', 'app', 'federated-credential', 'create', '--id', $AppId, '--parameters', "@$file") | Out-Null
    }
    finally { Remove-Item $file -ErrorAction SilentlyContinue }
    Write-Host "  federated credential $Name created ($Subject)"
}

function Set-RoleAssignment {
    param(
        [Parameter(Mandatory)][string]$ObjectId, [Parameter(Mandatory)][string]$Role, [Parameter(Mandatory)][string]$Scope,
        [string]$Condition
    )
    $existingAssignments = @()
    $existingAssignmentsJson = Invoke-Az @('role', 'assignment', 'list', '--assignee', $ObjectId, '--role', $Role, '--scope', $Scope, '-o', 'json')
    if ($existingAssignmentsJson) { $existingAssignments = @($existingAssignmentsJson | ConvertFrom-Json) }
    if ($existingAssignments.Count -gt 0) { Write-Host "  role '$Role' already assigned"; return }
    $args2 = @('role', 'assignment', 'create', '--assignee-object-id', $ObjectId, '--assignee-principal-type', 'ServicePrincipal', '--role', $Role, '--scope', $Scope)
    if ($Condition) { $args2 += @('--condition', $Condition, '--condition-version', '2.0') }
    Invoke-AzRetry $args2 | Out-Null
    Write-Host "  role '$Role' assigned"
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) was not found. Install it and run az login.' }
if (-not $ResourceGroupName) { $ResourceGroupName = "rg-$ShortName-$Environment" }
if (-not $StateResourceGroupName) { $StateResourceGroupName = "rg-$ShortName-tfstate-$Environment" }
if (-not $StateStorageAccountName -and $UniqueSuffix) { $StateStorageAccountName = "st${ShortName}tf${Environment}${UniqueSuffix}" }

Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$tenantId = Invoke-Az @('account', 'show', '--query', 'tenantId', '-o', 'tsv')
$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

Write-Host "`n[1/4] Environment resource group $ResourceGroupName"
Invoke-Az @('group', 'create', '--name', $ResourceGroupName, '--location', $Location, '--tags',
    'project=homeschool', "env=$Environment", 'managed_by=setup-github-oidc.ps1', "cost_center=$CostCenter") | Out-Null

# ---------------------------------------------------------------------------------------------------------------
Write-Host "`n[2/4] Infra identity (Terraform)"
$infra = Get-OrCreate-AppRegistration "sp-$ShortName-github-infra-$Environment"
Set-FederatedCredential -AppId $infra.AppId -Name "$InfraRepo-environment-$Environment" -Subject "repo:${GitHubOwner}/${InfraRepo}:environment:$Environment"
Set-FederatedCredential -AppId $infra.AppId -Name "$InfraRepo-pull-request" -Subject "repo:${GitHubOwner}/${InfraRepo}:pull_request"

Set-RoleAssignment -ObjectId $infra.ServicePrincipalObjectId -Role 'Contributor' -Scope $rgScope
if ($NarrowRbac) {
    # Role Based Access Control Administrator, restricted by an ABAC condition to the three roles this repo assigns:
    # AcrPull, Key Vault Secrets User, Key Vault Secrets Officer. (Not exercised in the authoring environment.)
    $ids = '7f951dda-4ed3-4680-a7ca-43fe172d538d, 4633458b-17de-408a-b874-0d1eb2a0e6e2, b86a8fe4-44ce-4948-aee5-eccb2d63f9ee'
    $condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$ids})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$ids}))"
    Set-RoleAssignment -ObjectId $infra.ServicePrincipalObjectId -Role 'Role Based Access Control Administrator' -Scope $rgScope -Condition $condition
}
else {
    Set-RoleAssignment -ObjectId $infra.ServicePrincipalObjectId -Role 'User Access Administrator' -Scope $rgScope
}

if ($StateStorageAccountName) {
    $stateId = $null
    try { $stateId = Invoke-Az @('storage', 'account', 'show', '--name', $StateStorageAccountName, '--resource-group', $StateResourceGroupName, '--query', 'id', '-o', 'tsv') } catch { $stateId = $null }
    if ($stateId) { Set-RoleAssignment -ObjectId $infra.ServicePrincipalObjectId -Role 'Storage Blob Data Contributor' -Scope $stateId }
    else { Write-Warning "State storage account $StateStorageAccountName not found in $StateResourceGroupName. Run bootstrap-state.ps1 first, then re-run this script." }
}
else { Write-Warning 'No -UniqueSuffix / -StateStorageAccountName given: skipped the Storage Blob Data Contributor role on the state account. Re-run with -UniqueSuffix.' }

# ---------------------------------------------------------------------------------------------------------------
Write-Host "`n[3/4] Deploy identity (backend-api, web, mobile-app)"
$deploy = Get-OrCreate-AppRegistration "sp-$ShortName-github-deploy-$Environment"
foreach ($repo in $DeployRepos) {
    Set-FederatedCredential -AppId $deploy.AppId -Name "$repo-environment-$Environment" -Subject "repo:${GitHubOwner}/${repo}:environment:$Environment"
}
Set-RoleAssignment -ObjectId $deploy.ServicePrincipalObjectId -Role 'Contributor' -Scope $rgScope

# ---------------------------------------------------------------------------------------------------------------
Write-Host "`n[4/4] GitHub configuration"
$upper = $Environment.ToUpper()
Write-Host @"

=== Repository '$InfraRepo' (Settings > Secrets and variables > Actions > Variables > Repository variables) ===
  AZURE_TENANT_ID            = $tenantId
  AZURE_SUBSCRIPTION_ID      = $SubscriptionId
  AZURE_CLIENT_ID_$upper$(' ' * [Math]::Max(1, 15 - $upper.Length))= $($infra.AppId)
  Create the GitHub environment '$Environment' in this repository ($(if ($Environment -eq 'dev') { 'no reviewers needed' } else { 'add Required reviewers' })).

=== Repositories $($DeployRepos -join ', ') (Environment variables of the GitHub environment '$Environment') ===
  AZURE_TENANT_ID            = $tenantId
  AZURE_SUBSCRIPTION_ID      = $SubscriptionId
  AZURE_CLIENT_ID            = $($deploy.AppId)
  After the first terraform apply also set (values: terraform output github_environment_variables):
  ACR_NAME, CONTAINER_APP_NAME, RELEASE_JOB_NAME, AZURE_RESOURCE_GROUP = $ResourceGroupName

With the GitHub CLI (gh auth login first), for example:
  gh variable set AZURE_CLIENT_ID_$upper --repo $GitHubOwner/$InfraRepo --body $($infra.AppId)
  gh variable set AZURE_CLIENT_ID --repo $GitHubOwner/backend-api --env $Environment --body $($deploy.AppId)
"@
