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
    [int]    $TestTimeoutMin   = 15,
    # When set, orphaned role assignments (ServicePrincipal entries at the KV /
    # hostpool RG / VNet RG / image gallery RG scopes whose principalId no
    # longer resolves in AAD) are auto-deleted instead of causing the script
    # to abort with copy-paste cleanup commands. Use this on redeploys after
    # the Automation Account was deleted and recreated, where the leftover
    # assignments are known-safe to remove (they point at a dead MI).
    [switch] $RemoveOrphanedRoleAssignments
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

# Subscription guard.
#
# main.bicepparam carries 'subscriptionId' as the SOURCE OF TRUTH for which
# subscription this solution is approved to deploy into. Many customers run
# multiple subs in one tenant and the bicep template is RG-scoped (so ARM
# itself will not error if you point it at the wrong sub - it would just
# happily build everything in the wrong place). We therefore:
#   1. Read subscriptionId from the bicepparam file.
#   2. If the operator also passed -Subscription, require it to MATCH;
#      otherwise abort with a clear error rather than silently overriding
#      the file.
#   3. Set the Az context to that sub BEFORE any Get-Az* call so every
#      pre-deploy probe (orphan-role scan, NIC discovery, KV existence
#      check) runs against the right sub.
#   4. Re-read the context and verify the active sub matches.
$paramSubscriptionId = Get-BicepParamValue -File $BicepParamFile -Name 'subscriptionId'
if (-not $paramSubscriptionId) {
    throw "main.bicepparam is missing 'subscriptionId'. Add the line ""param subscriptionId = '<sub-guid>'"" near the top so this script can guard against deploying into the wrong subscription."
}
if ($paramSubscriptionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw "subscriptionId in $BicepParamFile is not a valid GUID: '$paramSubscriptionId'."
}
if ($Subscription -and $Subscription -ne $paramSubscriptionId) {
    throw "Subscription mismatch: -Subscription '$Subscription' was passed, but $BicepParamFile pins subscriptionId='$paramSubscriptionId'. Either drop the -Subscription argument (it is redundant) or update the bicepparam file. Refusing to deploy into the wrong subscription."
}
Write-Host "Subscription pinned by main.bicepparam: $paramSubscriptionId"
Set-AzContext -Subscription $paramSubscriptionId | Out-Null
$ctx = Get-AzContext
if ($ctx.Subscription.Id -ne $paramSubscriptionId) {
    throw "Failed to set Az context to $paramSubscriptionId (current sub is $($ctx.Subscription.Id)). Confirm your account has access to that subscription in tenant $($ctx.Tenant.Id)."
}
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
$whatIfResult = Get-AzResourceGroupDeploymentWhatIfResult @whatIfArgs
$whatIfResult | Out-Host

# Extract the EXACT colliding role assignments from the WhatIf result. ARM
# flags any role-assignment whose principalId would change with ChangeType
# 'Modify' on a resource of type Microsoft.Authorization/roleAssignments.
# Those are the only ones our deploy is going to fight with - everything
# else (unrelated tenant orphans, our own live assignments, role assignments
# on resources we don't touch) is correctly classified by ARM as 'Create',
# 'Ignore', or 'NoChange' and we leave them alone.
function Get-CollidingRoleAssignmentIdsFromWhatIf {
    param($WhatIfResult)
    $ids = @()
    if (-not $WhatIfResult -or -not $WhatIfResult.Changes) { return ,$ids }
    foreach ($c in $WhatIfResult.Changes) {
        if ($c.ChangeType -ne 'Modify') { continue }
        if ($c.ResourceId -notmatch '/providers/Microsoft\.Authorization/roleAssignments/[0-9a-fA-F-]+$') { continue }
        $ids += $c.ResourceId
    }
    return ,$ids
}
$collidingAssignmentIds = Get-CollidingRoleAssignmentIdsFromWhatIf -WhatIfResult $whatIfResult

if ($Mode -eq 'WhatIf') {
    if ($collidingAssignmentIds.Count -gt 0) {
        Write-Host ''
        Write-Host "WhatIf detected $($collidingAssignmentIds.Count) role assignment(s) that would FAIL with RoleAssignmentUpdateNotPermitted:" -ForegroundColor Yellow
        $collidingAssignmentIds | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Write-Host "Re-run with -Mode Deploy -RemoveOrphanedRoleAssignments to auto-clean these and proceed." -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'WhatIf complete - no changes made. Re-run with -Mode Deploy or -Mode Test to apply.' -ForegroundColor Yellow
    return
}

Write-Step "Deploying Automation Account ($deployName)"

# Pre-deploy cleanup #1 (opt-in): role assignments whose principalId would
# need to change. When the Automation Account is deleted and redeployed
# under the SAME name, the new MI gets a new principalId but bicep computes
# the same assignmentName GUID seed (uses the AA's ARM id, which is name-
# stable). ARM refuses to mutate principalId on an existing role assignment
# ("RoleAssignmentUpdateNotPermitted"), and the deploy fails.
#
# We use the WhatIf result to determine the EXACT set of assignments that
# would collide - this is precise and minimum-impact:
#   * Renaming the AA (or any first-time deploy) -> WhatIf shows 'Create'
#     on every role assignment. NOTHING is removed by the switch, because
#     no collision exists.
#   * Same-name redeploy after delete -> WhatIf shows 'Modify' on each
#     stale assignment. ONLY those exact assignment IDs are removed.
#   * Unrelated tenant orphans (deleted function apps, retired MIs, etc.)
#     at the same scopes are never touched - WhatIf doesn't flag them
#     because our bicep doesn't reference them.
#
# Default behavior (no switch): skip cleanup. If a collision exists, bicep
# fails with RoleAssignmentUpdateNotPermitted and we surface a hint pointing
# to the switch.
if ($RemoveOrphanedRoleAssignments) {
    if ($collidingAssignmentIds.Count -eq 0) {
        Write-Host "No role-assignment collisions detected by WhatIf - nothing to remove." -ForegroundColor DarkGray
    } else {
        Write-Step "Removing $($collidingAssignmentIds.Count) colliding role assignment(s) (-RemoveOrphanedRoleAssignments set)"
        foreach ($raId in $collidingAssignmentIds) {
            # Re-fetch by ID so we can show role + principal for the audit
            # log line and confirm the principal is genuinely dead before
            # deleting (defense-in-depth - don't blow away an assignment
            # for a live SP just because WhatIf wanted to update it).
            $existing = Get-AzRoleAssignment -Scope ($raId -replace '/providers/Microsoft\.Authorization/roleAssignments/.*$','') -ErrorAction SilentlyContinue |
                Where-Object { $_.RoleAssignmentId -eq $raId } | Select-Object -First 1
            if (-not $existing) {
                Write-Host "  Skipped (already gone): $raId" -ForegroundColor DarkGray
                continue
            }
            $isDead = $false
            if ([string]::IsNullOrEmpty($existing.DisplayName)) {
                $sp = Get-AzADServicePrincipal -ObjectId $existing.ObjectId -ErrorAction SilentlyContinue
                if (-not $sp) { $isDead = $true }
            }
            if (-not $isDead) {
                Write-Host ("  Skipped (principal {0} is still live): {1} on {2}" -f $existing.ObjectId, $existing.RoleDefinitionName, $raId) -ForegroundColor DarkGray
                continue
            }
            try {
                Remove-AzRoleAssignment -InputObject $existing -ErrorAction Stop | Out-Null
                Write-Host ("  Removed: {0} (principal {1}) at {2}" -f $existing.RoleDefinitionName, $existing.ObjectId, $existing.Scope) -ForegroundColor DarkGray
            } catch {
                Write-Host ("  Failed to remove {0}: {1}" -f $raId, $_.Exception.Message) -ForegroundColor Red
                throw "Aborting: could not auto-remove colliding role assignment. Resolve manually and re-run."
            }
        }
        Write-Host "Collision cleanup complete; continuing deployment." -ForegroundColor Green
    }
} else {
    if ($collidingAssignmentIds.Count -gt 0) {
        Write-Host "WhatIf detected $($collidingAssignmentIds.Count) colliding role assignment(s) - bicep will likely fail. Re-run with -RemoveOrphanedRoleAssignments to auto-clean." -ForegroundColor Yellow
    } else {
        Write-Host "No role-assignment collisions detected by WhatIf - skipping cleanup." -ForegroundColor DarkGray
    }
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

$deployment = $null
try {
    $deployment = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroup `
        -Name $deployName `
        -TemplateFile $BicepFile `
        -TemplateParameterFile $BicepParamFile `
        -Mode Incremental `
        @paramOverrides `
        -Verbose `
        -ErrorAction Stop
} catch {
    $err = $_.Exception.Message
    # Surface the most common redeploy failure (stale role assignment pointing
    # at a deleted MI) with a precise next-step hint, rather than letting the
    # raw ARM error scroll off-screen.
    if ($err -match 'RoleAssignmentUpdateNotPermitted' -or $err -match 'cannot perform an update.*principalId') {
        Write-Host ''
        Write-Host "Bicep deployment failed with RoleAssignmentUpdateNotPermitted." -ForegroundColor Red
        Write-Host "An existing role assignment at one of our target scopes points at a deleted MI from a prior deployment of this solution." -ForegroundColor Red
        Write-Host ''
        if ($collidingAssignmentIds -and $collidingAssignmentIds.Count -gt 0) {
            Write-Host "The following $($collidingAssignmentIds.Count) role assignment(s) need to be removed before redeploy will succeed:" -ForegroundColor Yellow
            foreach ($raId in $collidingAssignmentIds) {
                $existing = $null
                try {
                    $scopeOnly = $raId -replace '/providers/Microsoft\.Authorization/roleAssignments/.*$',''
                    $existing = Get-AzRoleAssignment -Scope $scopeOnly -ErrorAction SilentlyContinue |
                        Where-Object { $_.RoleAssignmentId -eq $raId } | Select-Object -First 1
                } catch { }
                if ($existing) {
                    Write-Host ("  Role : {0}" -f $existing.RoleDefinitionName) -ForegroundColor Yellow
                    Write-Host ("  Scope: {0}" -f $existing.Scope) -ForegroundColor Yellow
                    Write-Host ("  PrincipalId (dead): {0}" -f $existing.ObjectId) -ForegroundColor Yellow
                    Write-Host ("  Id   : {0}" -f $raId) -ForegroundColor DarkGray
                } else {
                    Write-Host ("  Id   : {0}" -f $raId) -ForegroundColor Yellow
                }
                Write-Host ''
            }
            Write-Host "Auto-fix:  Re-run this script with -RemoveOrphanedRoleAssignments to delete exactly these assignments and retry." -ForegroundColor Yellow
            Write-Host "Manual fix: Remove-AzRoleAssignment -Scope <scope> -ObjectId <principalId> -RoleDefinitionName '<role>'" -ForegroundColor DarkGray
        } else {
            Write-Host "Re-run this script with -RemoveOrphanedRoleAssignments to auto-delete the stale assignments and try again." -ForegroundColor Yellow
            Write-Host "(WhatIf did not flag any colliding assignments earlier - the conflict may have appeared between WhatIf and Deploy. Inspect the raw ARM error above for the offending assignment ID.)" -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    throw
}

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
    # Subscription pin - bind on every schedule so the scheduled runbook
    # invocation calls Set-AzContext -SubscriptionId before any Get-Az* probe,
    # regardless of which sub the MI happens to default to.
    SubscriptionId               = $paramSubscriptionId
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
    HostpoolName   = $rebuildHpName
    HostpoolRG     = $rebuildHpRG
    SubscriptionId = $paramSubscriptionId
}

# ---- Hourly schedule for Disable-DrainAfterAge: bind, then DISABLE.
# Why disabled by default: this runbook is the time-based fallback path
# for hosts where Entra registration takes longer than the rebuild flow
# allows. Operators usually want to invoke it manually after looking at
# specific hosts, not on every tick. We bind it so the schedule is
# preconfigured and ready to go, but flip isEnabled=false so it does NOT
# fire until someone explicitly enables it in the portal or via
# Set-AzAutomationSchedule -IsEnabled $true.
Register-AvdJobSchedule -RunbookName 'Disable-DrainAfterAge' -ScheduleName 'sched-drainage-hourly' -Parameters @{
    HostpoolName   = $rebuildHpName
    HostpoolRG     = $rebuildHpRG
    SubscriptionId = $paramSubscriptionId
}
Write-Host "Disabling schedule sched-drainage-hourly (manual-only by design)..."
Set-AzAutomationSchedule -ResourceGroupName $ResourceGroup `
    -AutomationAccountName $aaName `
    -Name 'sched-drainage-hourly' `
    -IsEnabled $false | Out-Null

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
