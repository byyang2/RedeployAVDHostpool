<#
.SYNOPSIS
    Deploys the AVD-rebuild Automation Account (via bicep/main.bicep), imports
    the two runbooks from local .ps1 files, and (optionally) starts a
    non-destructive smoke-test job.

.PARAMETER ResourceGroup
    Resource group that will hold the Automation Account.  Created if it
    doesn't exist.

.PARAMETER Subscription
    Subscription to deploy into.  If omitted, the current context is used.

.PARAMETER Environment
    Azure cloud.  Defaults to AzureUSGovernment to match the runbook defaults.

.PARAMETER Mode
    WhatIf  - prints the bicep what-if and stops (no resources changed).
    Deploy  - deploys the bicep, imports + publishes the runbooks.
    Test    - performs Deploy, then starts Recreate-AVDSessionHosts with
              MaxVmsPerRun=0 (discovery only, never deletes a VM) and waits
              for it to finish.

.EXAMPLE
    .\Deploy-Automation.ps1 -ResourceGroup rg-avd-automation -Mode WhatIf

.EXAMPLE
    .\Deploy-Automation.ps1 -ResourceGroup rg-avd-automation -Mode Test
#>

[CmdletBinding()]
param(
    [string] $ResourceGroup,
    [string] $Subscription,
    [ValidateSet('AzureCloud','AzureUSGovernment','AzureChinaCloud','AzureGermanCloud')]
    [string] $Environment = 'AzureUSGovernment',
    [ValidateSet('WhatIf','Deploy','Test')]
    [string] $Mode = 'WhatIf',
    [string] $BicepFile        = (Join-Path $PSScriptRoot 'bicep\main.bicep'),
    [string] $BicepParamFile   = (Join-Path $PSScriptRoot 'bicep\main.bicepparam'),
    [string] $RebuildRunbook   = (Join-Path $PSScriptRoot 'Recreate-AVDSessionHosts.ps1'),
    [string] $EntraRunbook     = (Join-Path $PSScriptRoot 'Disable-DrainForEntraJoined.ps1'),
    [string] $DrainAgeRunbook  = (Join-Path $PSScriptRoot 'Disable-DrainAfterAge.ps1'),
    [int]    $TestTimeoutMin   = 15
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-BicepParamValue {
    param([string] $File, [string] $Name)
    $m = (Select-String -Path $File -Pattern "^\s*param\s+$Name\s*=\s*'([^']+)'").Matches
    if ($m.Count -eq 0) { return $null }
    return $m[0].Groups[1].Value
}

# ---------------------------------------------------------------- pre-checks

# The .bicepparam file is gitignored (holds env-specific values like hostpool
# name, alert email, etc.). On a fresh clone the operator must copy the
# .example template first - fail fast with a clear message rather than letting
# bicep error out on missing 'using main.bicep'.
if (-not (Test-Path $BicepParamFile)) {
    $example = "$BicepParamFile.example"
    if (Test-Path $example) {
        Write-Host ''
        Write-Host "ERROR: $BicepParamFile does not exist." -ForegroundColor Red
        Write-Host "First-time setup: copy the example template and fill in your environment values:" -ForegroundColor Yellow
        Write-Host ''
        Write-Host "  Copy-Item '$example' '$BicepParamFile'" -ForegroundColor Cyan
        Write-Host "  notepad '$BicepParamFile'   # replace every <PLACEHOLDER>" -ForegroundColor Cyan
        Write-Host ''
        throw "Missing parameter file: $BicepParamFile"
    }
    throw "Required file missing: $BicepParamFile (and no .example template found)."
}

foreach ($f in @($BicepFile, $RebuildRunbook, $EntraRunbook)) {
    if (-not (Test-Path $f)) { throw "Required file missing: $f" }
}

# Resolve -ResourceGroup from main.bicepparam when not supplied so the
# default deploy target lives in source control, not in muscle memory.
if (-not $ResourceGroup) {
    $ResourceGroup = Get-BicepParamValue -File $BicepParamFile -Name 'targetResourceGroup'
    if (-not $ResourceGroup) { throw "No -ResourceGroup supplied and 'targetResourceGroup' is not set in $BicepParamFile." }
    Write-Host "Using ResourceGroup from bicepparam: $ResourceGroup" -ForegroundColor DarkGray
}

foreach ($mod in 'Az.Accounts','Az.Resources','Az.Automation','Az.KeyVault') {
    if (-not (Get-Module -ListAvailable $mod)) {
        Write-Step "Installing PowerShell module $mod (CurrentUser)"
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber | Out-Null
    }
    Import-Module $mod -ErrorAction Stop
}

# ---------------------------------------------------------------- auth

Write-Step "Connecting to $Environment"
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx -or $ctx.Environment.Name -ne $Environment) {
    Connect-AzAccount -Environment $Environment | Out-Null
}
if ($Subscription) {
    Set-AzContext -Subscription $Subscription | Out-Null
}
$ctx = Get-AzContext
Write-Host "Tenant       : $($ctx.Tenant.Id)"
Write-Host "Subscription : $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
Write-Host "Account      : $($ctx.Account.Id)"

# ---------------------------------------------------------------- RG

if (-not (Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue)) {
    Write-Step "Creating resource group $ResourceGroup"
    # Read location from bicepparam so the RG matches the AVD region.
    $loc = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+location\s*=\s*'([^']+)'").Matches.Groups[1].Value
    if (-not $loc) { $loc = 'usgovvirginia' }
    New-AzResourceGroup -Name $ResourceGroup -Location $loc -Tag @{ workload = 'AVD-Rebuild-Automation' } | Out-Null
}

# ---------------------------------------------------------------- what-if / deploy

$deployName = "avd-rebuild-aa-$(Get-Date -Format yyyyMMddHHmmss)"

# Auto-discover the VNet resource group from an existing session host NIC so the
# operator doesn't have to specify it. The MI needs Network Contributor on the
# VNet's RG (often different from the hostpool RG) to create NICs that join the
# subnet. If no NICs exist yet (greenfield), this stays empty and Bicep simply
# skips that role assignment - re-run Deploy after the first VM is built.
$hpRG = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+hostpoolRG\s*=\s*'([^']+)'").Matches.Groups[1].Value
$discoveredVnetRG = ''
if ($hpRG) {
    $nic = Get-AzNetworkInterface -ResourceGroupName $hpRG -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nic -and $nic.IpConfigurations[0].Subnet.Id) {
        # Subnet ID format: /subscriptions/.../resourceGroups/<vnetRG>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>
        if ($nic.IpConfigurations[0].Subnet.Id -match '/resourceGroups/([^/]+)/providers/Microsoft\.Network/virtualNetworks/') {
            $discoveredVnetRG = $Matches[1]
            Write-Host "Discovered VNet resource group from NIC '$($nic.Name)' in '$hpRG': $discoveredVnetRG" -ForegroundColor Cyan
        }
    } else {
        Write-Host "No existing NICs in hostpool RG '$hpRG' - skipping VNet RG auto-discovery (greenfield deploy)." -ForegroundColor Yellow
    }
}

# Build a parameter override hashtable so the bicepparam file no longer needs vnetRG.
$paramOverrides = @{}
if ($discoveredVnetRG) { $paramOverrides['vnetRG'] = $discoveredVnetRG }

Write-Step "Running bicep what-if ($deployName)"
$whatIfArgs = @{
    ResourceGroupName     = $ResourceGroup
    TemplateFile          = $BicepFile
    TemplateParameterFile = $BicepParamFile
    Name                  = $deployName
}
foreach ($k in $paramOverrides.Keys) { $whatIfArgs[$k] = $paramOverrides[$k] }
Get-AzResourceGroupDeploymentWhatIfResult @whatIfArgs | Out-Host

if ($Mode -eq 'WhatIf') {
    Write-Host ''
    Write-Host 'WhatIf complete - no changes made. Re-run with -Mode Deploy or -Mode Test to apply.' -ForegroundColor Yellow
    return
}

Write-Step "Deploying Automation Account ($deployName)"

# Pre-deploy cleanup #1: orphaned role assignments at scopes our MI needs.
# When the Automation Account is deleted, its system-assigned MI's principalId
# disappears, but role assignments at external scopes (KV, hostpool RG, VNet
# RG, image gallery RG) stay behind referencing the now-dead principal. The
# bicep modules use a guid-stable assignmentName (principalId can't seed it -
# BCP120), so on a clean redeploy ARM tries to update the stale assignment's
# principalId, which it refuses ("RoleAssignmentUpdateNotPermitted"). We
# DETECT orphaned (principal no longer resolves) ServicePrincipal assignments
# at those scopes and fail fast with copy-paste cleanup commands rather than
# silently deleting them - the operator should confirm each removal because
# in rare cases (cross-tenant B2B SPs) an "unresolved" principal can still be
# valid in its home tenant.
function Find-OrphanedRoleAssignments {
    param([string[]] $Scopes)
    $orphans = @()
    foreach ($scope in $Scopes) {
        if (-not $scope) { continue }
        $assignments = Get-AzRoleAssignment -Scope $scope -ErrorAction SilentlyContinue |
            Where-Object { $_.Scope -eq $scope }
        foreach ($a in $assignments) {
            # An orphaned MI assignment shows empty DisplayName. Confirm with
            # a directory lookup so live assignments whose display name simply
            # hasn't propagated are not flagged.
            if ([string]::IsNullOrEmpty($a.DisplayName)) {
                $sp = Get-AzADServicePrincipal -ObjectId $a.ObjectId -ErrorAction SilentlyContinue
                if (-not $sp) {
                    $orphans += [pscustomobject]@{
                        Scope            = $scope
                        ObjectId         = $a.ObjectId
                        RoleDefinitionName = $a.RoleDefinitionName
                    }
                }
            }
        }
    }
    return ,$orphans
}

Write-Step "Scanning for orphaned role assignments from prior deployments"
$subId = $ctx.Subscription.Id
$imgRG  = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+imageGalleryRG\s*=\s*'([^']+)'").Matches.Groups[1].Value
# Key Vault is co-located with the Automation Account; scope-scan only when an
# existing vault is already there (i.e. we are redeploying into a populated RG).
$existingKv = Get-AzKeyVault -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue |
    Where-Object { $_.VaultName -like 'kv-avd-rebuild-*' } | Select-Object -First 1
$scopesToScan = @()
if ($hpRG)  { $scopesToScan += "/subscriptions/$subId/resourceGroups/$hpRG" }
if ($imgRG) { $scopesToScan += "/subscriptions/$subId/resourceGroups/$imgRG" }
if ($discoveredVnetRG -and $discoveredVnetRG -ne $hpRG) {
    $scopesToScan += "/subscriptions/$subId/resourceGroups/$discoveredVnetRG"
}
if ($existingKv) {
    $scopesToScan += $existingKv.ResourceId
}
$orphans = Find-OrphanedRoleAssignments -Scopes $scopesToScan
if ($orphans.Count -gt 0) {
    Write-Host ''
    Write-Host "ERROR: Found $($orphans.Count) orphaned role assignment(s) at scopes this deployment will reuse." -ForegroundColor Red
    Write-Host "These reference principal IDs that no longer exist in AAD (typically a deleted Automation Account's MI)." -ForegroundColor Red
    Write-Host "Bicep will fail with 'RoleAssignmentUpdateNotPermitted' if these are not removed first." -ForegroundColor Red
    Write-Host ''
    Write-Host "Orphaned assignments:" -ForegroundColor Yellow
    $orphans | Format-Table -AutoSize | Out-Host
    Write-Host "To clean up, review each assignment then run:" -ForegroundColor Yellow
    Write-Host ''
    foreach ($o in $orphans) {
        Write-Host ("  Remove-AzRoleAssignment -ObjectId '{0}' -RoleDefinitionName '{1}' -Scope '{2}'" -f $o.ObjectId, $o.RoleDefinitionName, $o.Scope) -ForegroundColor Cyan
    }
    Write-Host ''
    Write-Host "After cleanup, re-run this script." -ForegroundColor Yellow
    throw "Aborting deployment: orphaned role assignments must be removed first."
}

# Pre-deploy cleanup: the hourly retry schedule's startTime is recomputed
# each deploy (it must be in the future). Azure Automation rejects startTime
# updates on a schedule that has already been triggered, so we delete it first
# and let Bicep recreate it with the freshly computed :30 mark.
$existingAaName = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+automationAccountName\s*=\s*'([^']+)'").Matches.Groups[1].Value
if (-not $existingAaName) { $existingAaName = 'aa-avd-rebuild' }
$existingHourly = Get-AzAutomationSchedule -ResourceGroupName $ResourceGroup `
    -AutomationAccountName $existingAaName `
    -Name 'sched-recreate-retry-hourly' -ErrorAction SilentlyContinue
if ($existingHourly) {
    # Also unregister any job bindings first, otherwise Remove-AzAutomationSchedule errors.
    Get-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $existingAaName -ErrorAction SilentlyContinue |
        Where-Object ScheduleName -eq 'sched-recreate-retry-hourly' | ForEach-Object {
            Unregister-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroup `
                -AutomationAccountName $existingAaName `
                -JobScheduleId $_.JobScheduleId -Force | Out-Null
        }
    Remove-AzAutomationSchedule -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $existingAaName -Name 'sched-recreate-retry-hourly' -Force | Out-Null
    Write-Host "Removed existing sched-recreate-retry-hourly (will be recreated by bicep with fresh :30 startTime)."
}

$deployment = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroup `
    -Name $deployName `
    -TemplateFile $BicepFile `
    -TemplateParameterFile $BicepParamFile `
    -Mode Incremental `
    @paramOverrides `
    -Verbose

$aaName = $deployment.Outputs.automationAccountName.Value
Write-Host "Automation Account: $aaName"

# Key Vault is created by bicep alongside the AA. Verify the two required
# secrets exist (domain-join + VM admin); if either is missing, print the
# exact Set-AzKeyVaultSecret commands so the operator can populate them.
$kvDeployedName = $deployment.Outputs.keyVaultName.Value
$djSecretName   = (Get-BicepParamValue -File $BicepParamFile -Name 'domainJoinPasswordSecretName')
if (-not $djSecretName) { $djSecretName = 'domainJoinPassword' }
$vmSecretName   = (Get-BicepParamValue -File $BicepParamFile -Name 'vmAdminPasswordSecretName')
if (-not $vmSecretName) { $vmSecretName = 'vmAdminPassword' }
Write-Host "Key Vault: $kvDeployedName (in $ResourceGroup)"
$missingSecrets = @()
foreach ($s in @($djSecretName, $vmSecretName)) {
    $exists = Get-AzKeyVaultSecret -VaultName $kvDeployedName -Name $s -ErrorAction SilentlyContinue
    if (-not $exists) { $missingSecrets += $s }
}
if ($missingSecrets.Count -gt 0) {
    Write-Host ''
    Write-Host "WARNING: Key Vault '$kvDeployedName' is missing required secret(s): $($missingSecrets -join ', ')" -ForegroundColor Yellow
    Write-Host "The rebuild runbook will fail until they are populated. Run:" -ForegroundColor Yellow
    foreach ($s in $missingSecrets) {
        Write-Host ("  Set-AzKeyVaultSecret -VaultName '{0}' -Name '{1}' -SecretValue (Read-Host -AsSecureString)" -f $kvDeployedName, $s) -ForegroundColor Cyan
    }
    Write-Host ''
}

# ---------------------------------------------------------------- runbook import

function Import-Runbook {
    param([string] $Name, [string] $Path, [string] $Description)
    Write-Step "Importing $Name from $Path"
    Import-AzAutomationRunbook -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $aaName `
        -Name  $Name `
        -Path  $Path `
        -Type  'PowerShell72' `
        -Description $Description `
        -Force | Out-Null
    Publish-AzAutomationRunbook -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $aaName `
        -Name  $Name | Out-Null
    Write-Host "Published: $Name"
}

Import-Runbook -Name 'Recreate-AVDSessionHosts'    -Path $RebuildRunbook -Description 'Recreates AVD session host VMs.'
Import-Runbook -Name 'Disable-DrainForEntraJoined' -Path $EntraRunbook   -Description 'Turns drain off for Entra-joined hosts.'
Import-Runbook -Name 'Disable-DrainAfterAge'       -Path $DrainAgeRunbook -Description 'Manual: turns drain off on session hosts older than threshold; tags VM to prevent re-action.'

# ---------------------------------------------------------------- job schedules
#
#   Bind the published runbooks to the schedules that the Bicep template
#   created.  Done from PowerShell because ARM rejects jobSchedules whose
#   target runbook has no published version yet.

function Register-AvdJobSchedule {
    param(
        [string]    $RunbookName,
        [string]    $ScheduleName,
        [hashtable] $Parameters
    )
    # NOTE: We used to call Register-AzAutomationScheduledRunbook here, but in
    # Az.Automation 11.x the -Parameters hashtable is silently dropped on the
    # wire (verified: API returns "parameters": null on the resulting
    # jobSchedule). We work around the regression by:
    #   1. Unregistering any pre-existing binding via the cmdlet
    #   2. Issuing a raw PUT to /jobSchedules/{newGuid} with parameters in body
    #
    # This is the same API the cmdlet hits, but we control the payload directly.
    $existing = Get-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $aaName `
        -RunbookName $RunbookName -ErrorAction SilentlyContinue |
        Where-Object ScheduleName -eq $ScheduleName
    if ($existing) {
        Unregister-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroup `
            -AutomationAccountName $aaName `
            -JobScheduleId $existing.JobScheduleId -Force | Out-Null
        Write-Host "Re-binding $RunbookName <- $ScheduleName (parameters refreshed)"
    } else {
        Write-Host "Binding $RunbookName <- $ScheduleName"
    }

    # Azure Automation requires all parameter values to be strings (the API
    # serializes the parameters dictionary into typed cmdlet arguments at job
    # start, casting strings back to int/bool as needed).
    $stringParams = @{}
    foreach ($k in $Parameters.Keys) {
        $v = $Parameters[$k]
        if ($null -eq $v)      { continue }
        elseif ($v -is [bool]) { $stringParams[$k] = if ($v) { 'True' } else { 'False' } }
        else                   { $stringParams[$k] = "$v" }
    }

    $sub = (Get-AzContext).Subscription.Id
    $jobScheduleId = [guid]::NewGuid().ToString()
    $path = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$aaName/jobSchedules/$jobScheduleId" + "?api-version=2023-11-01"
    $body = @{
        properties = @{
            schedule   = @{ name = $ScheduleName }
            runbook    = @{ name = $RunbookName }
            parameters = $stringParams
        }
    } | ConvertTo-Json -Depth 6

    $resp = Invoke-AzRestMethod -Method PUT -Path $path -Payload $body
    if ($resp.StatusCode -ge 400) {
        throw "Job-schedule PUT for $RunbookName <- $ScheduleName failed: HTTP $($resp.StatusCode) $($resp.Content)"
    }
    Write-Host ("  bound with parameters: " + ($stringParams.Keys -join ', '))
}

$rebuildHpName = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+hostpoolName\s*=\s*'([^']+)'").Matches.Groups[1].Value
$rebuildHpRG   = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+hostpoolRG\s*=\s*'([^']+)'").Matches.Groups[1].Value

# ---- Build the shared parameter map for the rebuild runbook ----
$rebuildBase = @{
    HostpoolName                 = $rebuildHpName
    HostpoolRG                   = $rebuildHpRG
    Location                     = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+location\s*=\s*'([^']+)'").Matches.Groups[1].Value
    DomainName                   = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+domainName\s*=\s*'([^']+)'").Matches.Groups[1].Value
    DomainJoinUserName           = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+domainJoinUserName\s*=\s*'([^']+)'").Matches.Groups[1].Value
    DomainJoinPasswordSecretName = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+domainJoinPasswordSecretName\s*=\s*'([^']+)'").Matches.Groups[1].Value
    VmAdminUserName              = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+vmAdminName\s*=\s*'([^']+)'").Matches.Groups[1].Value
    VmAdminPasswordSecretName    = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+vmAdminPasswordSecretName\s*=\s*'([^']+)'").Matches.Groups[1].Value
    KeyVaultName                 = $deployment.Outputs.keyVaultName.Value
    KeyVaultRG                   = $deployment.Outputs.keyVaultResourceGroup.Value
    ImageGalleryName             = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+imageGalleryName\s*=\s*'([^']+)'").Matches.Groups[1].Value
    ImageGalleryRG               = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+imageGalleryRG\s*=\s*'([^']+)'").Matches.Groups[1].Value
    ImageDefinitionName          = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+imageDefinitionName\s*=\s*'([^']+)'").Matches.Groups[1].Value
    ImageVersionName             = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+imageVersionName\s*=\s*'([^']+)'").Matches.Groups[1].Value
    # Identity of THIS Automation Account, so Stage mode can call
    # Start-AzAutomationRunbook to spawn its first Process child job.
    AutomationAccountResourceGroup = $ResourceGroup
    AutomationAccountName          = $aaName
}

# ---- Ensure the rebuild state variable exists (created once; never overwritten) ----
$stateVarName = "AVDRebuildState_$rebuildHpName"
$existingStateVar = Get-AzAutomationVariable -ResourceGroupName $ResourceGroup `
    -AutomationAccountName $aaName -Name $stateVarName -ErrorAction SilentlyContinue
if (-not $existingStateVar) {
    Write-Host "Creating state variable $stateVarName (initial value '{}')"
    New-AzAutomationVariable -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $aaName -Name $stateVarName `
        -Value '{}' -Encrypted $false `
        -Description 'JSON state map for the AVD session host rebuild runbook.' | Out-Null
} else {
    Write-Host "State variable $stateVarName already exists - leaving current value intact."
}

# ---- Ensure the cross-job lock variable exists (created once; never overwritten) ----
# Holds JSON {Holder, At} while a Process or Stage job is performing a
# read-modify-write on the state/snapshot variables. Stale locks (>5 min) are
# automatically broken by the runbook.
$lockVarName = "AVDRebuildLock_$rebuildHpName"
$existingLockVar = Get-AzAutomationVariable -ResourceGroupName $ResourceGroup `
    -AutomationAccountName $aaName -Name $lockVarName -ErrorAction SilentlyContinue
if (-not $existingLockVar) {
    Write-Host "Creating lock variable $lockVarName (initial value '')"
    New-AzAutomationVariable -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $aaName -Name $lockVarName `
        -Value '' -Encrypted $false `
        -Description 'Cross-job mutex for state/snapshot variable RMW. Empty = free; stale > 5 min is auto-broken.' | Out-Null
} else {
    Write-Host "Lock variable $lockVarName already exists - leaving current value intact."
}

# ---- Cleanup: remove legacy schedules (single-hourly + the 6 staggered ones) ----
$legacyNames = @('sched-recreate-hourly') + (0,10,20,30,40,50 | ForEach-Object { 'sched-recreate-retry-{0:D2}' -f $_ })
foreach ($legacy in $legacyNames) {
    $legacySched = Get-AzAutomationSchedule -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $aaName `
        -Name $legacy -ErrorAction SilentlyContinue
    if ($legacySched) {
        Write-Host "Removing legacy schedule $legacy ..."
        Remove-AzAutomationSchedule -ResourceGroupName $ResourceGroup `
            -AutomationAccountName $aaName -Name $legacy -Force | Out-Null
    }
}

# ---- Single hourly retry schedule (Process mode: claim one Pending VM, rebuild, loop) ----
Register-AvdJobSchedule -RunbookName 'Recreate-AVDSessionHosts' -ScheduleName 'sched-recreate-retry-hourly' -Parameters ($rebuildBase + @{ Mode = 'Process' })

# ---- Weekly Saturday kickoff (Stage mode: snapshot all VMs, mark all Pending, kick off first Process job) ----
Register-AvdJobSchedule -RunbookName 'Recreate-AVDSessionHosts' -ScheduleName 'sched-recreate-weekly-sat' -Parameters ($rebuildBase + @{ Mode = 'Stage' })

Register-AvdJobSchedule -RunbookName 'Disable-DrainForEntraJoined' -ScheduleName 'sched-entra-hourly' -Parameters @{
    HostpoolName = $rebuildHpName
    HostpoolRG   = $rebuildHpRG
}

if ($Mode -ne 'Test') {
    Write-Host ''
    Write-Host 'Deploy complete. Schedules will trigger the runbooks on the next interval.' -ForegroundColor Green
    return
}

# ---------------------------------------------------------------- smoke test
#
#   MaxVmsPerRun=0 forces the candidate loop to select zero VMs, so the
#   runbook only authenticates, enumerates session hosts and seeds the state
#   variable.  Nothing is deleted or created.

Write-Step 'Starting smoke-test job: Recreate-AVDSessionHosts (MaxVmsPerRun=0)'
$testParams = @{
    HostpoolName  = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+hostpoolName\s*=\s*'([^']+)'").Matches.Groups[1].Value
    HostpoolRG    = (Select-String -Path $BicepParamFile -Pattern "^\s*param\s+hostpoolRG\s*=\s*'([^']+)'").Matches.Groups[1].Value
    MaxVmsPerRun  = 0
}

$job = Start-AzAutomationRunbook -ResourceGroupName $ResourceGroup `
    -AutomationAccountName $aaName `
    -Name 'Recreate-AVDSessionHosts' `
    -Parameters $testParams

Write-Host "Job started: $($job.JobId)"

$deadline = (Get-Date).AddMinutes($TestTimeoutMin)
do {
    Start-Sleep -Seconds 20
    $job = Get-AzAutomationJob -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $aaName `
        -Id $job.JobId
    Write-Host "  status=$($job.Status)"
} while ($job.Status -in @('Queued','Starting','Running','Activating','New') -and (Get-Date) -lt $deadline)

Write-Step "Job output ($($job.Status))"
$streams = Get-AzAutomationJobOutput -ResourceGroupName $ResourceGroup `
    -AutomationAccountName $aaName `
    -Id $job.JobId -Stream Any
foreach ($s in $streams) {
    $detail = Get-AzAutomationJobOutputRecord -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $aaName `
        -JobId $job.JobId `
        -Id    $s.StreamRecordId
    "[$($s.Type)] $($detail.Value.Values -join ' ')"
}

if ($job.Status -ne 'Completed') {
    throw "Smoke-test job did not complete successfully (status=$($job.Status))."
}

Write-Host ''
Write-Host 'Smoke test PASSED. Discovery-only run completed without modifying any VM.' -ForegroundColor Green
Write-Host 'Inspect Automation variable AVDRebuildState_<HostpoolName> in the portal to verify the seeded state.'
