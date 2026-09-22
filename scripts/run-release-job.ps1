<#
.SYNOPSIS
    Starts the `release` Container App Job of an environment (migrations + least-privilege DB role + seed) and waits
    for it to finish, streaming the status. Exit code 0 = Succeeded, 1 = failed, 2 = timed out.

.DESCRIPTION
    The job runs `python -m app.cli release` from the image currently configured on the job, connecting with the
    database administrator login. The backend deploy workflow does the same automatically before every API rollout;
    use this script for the very first release (after the first deployment has put a real image on the job) or to
    re-run it by hand.

    Log lines reach Log Analytics with a delay of a few minutes, so failure logs may be missing straight away; the
    execution status is authoritative.

.EXAMPLE
    .\run-release-job.ps1 -Environment dev
    .\run-release-job.ps1 -Environment nonprod -Image acrhsnonprodx7k2.azurecr.io/homeschool-api:3f2a1c9
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('dev', 'nonprod', 'prod')][string]$Environment,
    [string]$SubscriptionId,
    [ValidatePattern('^[a-z0-9]{2,5}$')][string]$ShortName = 'hs',
    [string]$ResourceGroup,
    [string]$JobName,
    [string]$Image,
    [int]$TimeoutMinutes = 20,
    [int]$PollSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgs, [switch]$AllowFailure)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & az @AzArgs --only-show-errors 2>&1 } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw ("az {0} failed (exit {1}):`n{2}" -f ($AzArgs -join ' '), $LASTEXITCODE, (($output | ForEach-Object { "$_" }) -join "`n"))
    }
    (($output | ForEach-Object { "$_" }) -join "`n").Trim()
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) was not found. Install it and run az login.' }
if (-not $ResourceGroup) { $ResourceGroup = "rg-$ShortName-$Environment" }
if (-not $JobName) { $JobName = "caj-$ShortName-$Environment-release" }
if ($SubscriptionId) { Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null }

if ($Image) {
    Write-Host "Setting job image to $Image"
    Invoke-Az @('containerapp', 'job', 'update', '--name', $JobName, '--resource-group', $ResourceGroup, '--image', $Image) | Out-Null
}

Write-Host "Starting job $JobName in $ResourceGroup"
$execution = Invoke-Az @('containerapp', 'job', 'start', '--name', $JobName, '--resource-group', $ResourceGroup, '--query', 'name', '-o', 'tsv')
if (-not $execution) { throw 'The job did not return an execution name.' }
Write-Host "Execution: $execution"

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$last = ''
$final = $null
while ((Get-Date) -lt $deadline) {
    $status = Invoke-Az @('containerapp', 'job', 'execution', 'show', '--name', $JobName, '--resource-group', $ResourceGroup,
        '--job-execution-name', $execution, '--query', 'properties.status', '-o', 'tsv') -AllowFailure
    if ($status -ne $last) { Write-Host ("{0:HH:mm:ss}  {1}" -f (Get-Date), $status); $last = $status }
    if ($status -in @('Succeeded', 'Failed', 'Stopped', 'Degraded')) { $final = $status; break }
    Start-Sleep -Seconds $PollSeconds
}

if ($final -eq 'Succeeded') {
    Write-Host 'Release job succeeded.'
    exit 0
}

Write-Host ''
if ($final) { Write-Host "Release job ended with status $final. Recent log lines:" } else { Write-Host "Timed out after $TimeoutMinutes minutes (last status: $last). Recent log lines:" }
$logs = Invoke-Az @('containerapp', 'job', 'logs', 'show', '--name', $JobName, '--resource-group', $ResourceGroup,
    '--execution', $execution, '--container', 'release', '--format', 'text', '--tail', '200') -AllowFailure
if ($logs) { Write-Host $logs } else { Write-Host '(no log lines yet - Log Analytics ingestion is delayed by a few minutes; try again shortly)' }
if ($final) { exit 1 } else { exit 2 }
