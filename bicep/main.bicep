// =============================================================================
//  RedeployAVDHostpool - Automation Account scaffold
//
//  Deploys an Azure Automation Account (System-Assigned Managed Identity) with
//  the PowerShell modules, schedules, state variable and RBAC role assignments
//  required by the two runbooks in this repo:
//
//      * Recreate-AVDSessionHosts.ps1
//      * Disable-DrainForEntraJoined.ps1
//      * Disable-DrainAfterAge.ps1  (manual / ad-hoc - no schedule)
//
//  Runbook content itself is uploaded after deployment by Deploy-Automation.ps1
//  (Import-AzAutomationRunbook).  The Bicep template intentionally does not
//  embed the .ps1 source so the runbooks can be edited locally without
//  re-running the template.
// =============================================================================

targetScope = 'resourceGroup'

// ----------------------------------------------------------------- parameters

@description('Subscription this template MUST be deployed into. Declared so main.bicepparam can record the intended target sub and Deploy-Automation.ps1 can switch the Az context to it before running anything that resolves resources. Customers commonly have many subscriptions; this guard prevents an accidental deploy into the wrong one.')
param subscriptionId string

@description('Azure region for the Automation Account (must match the AVD environment, e.g. usgovvirginia).')
param location string = resourceGroup().location

@description('Resource group that hosts the Automation Account. Used by Deploy-Automation.ps1 as the default deployment target so the operator does not need to pass -ResourceGroup. NOTE: the bicep deployment itself is RG-scoped, so this value must match the RG you deploy into.')
param targetResourceGroup string = 'rg-avd-automation'

@description('Automation Account name.')
param automationAccountName string = 'aa-avd-rebuild'

@description('Host pool name (used for default runbook parameters and the state variable name).')
param hostpoolName string

@description('Host pool resource group (target of Desktop Virtualization Contributor role assignment).')
param hostpoolRG string

@description('Resource group that contains the shared VNet/subnet the session host NICs attach to. Often differs from hostpoolRG. Network Contributor is granted here so the MI can create NICs that join the subnet.')
param vnetRG string = ''

@description('Compute Gallery name (source image).')
param imageGalleryName string

@description('Resource group of the Compute Gallery.')
param imageGalleryRG string

@description('Compute Gallery image definition name.')
param imageDefinitionName string

@description('Compute Gallery image version (use "latest" for newest).')
param imageVersionName string = 'latest'

@description('Domain to join new VMs to.')
param domainName string

@description('Domain-join account UPN.')
param domainJoinUserName string

@description('Name of the Key Vault secret holding the domain-join password.')
param domainJoinPasswordSecretName string = 'domainJoinPassword'

@description('OU distinguished name (optional).')
param domainJoinOUPath string = ''

@description('Local administrator username applied to every rebuilt session host VM.')
param vmAdminName string = 'azureadmin'

@description('Name of the Key Vault secret holding the VM local administrator password.')
param vmAdminPasswordSecretName string = 'vmAdminPassword'

@description('Tags to apply to all resources created by this template.')
param tags object = {
  workload: 'AVD-Rebuild-Automation'
}

@description('Internal use only - leave at default. Captures deployment-time UTC to seed schedule startTime.')
param deploymentTimeUtc string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

@description('Optional override for the weekly Saturday rebuild kickoff start time (UTC, ISO 8601). Leave empty to auto-compute the next Saturday 02:00 UTC after deployment. If set, it MUST be at least 5 minutes in the future (Azure Automation requirement).')
param weeklyStartTime string = ''

// ----------------------------------- VM-rebuilt email-alert parameters

@description('Email address to receive an alert every time a session host VM rebuild FAILS. Must be set in main.bicepparam.')
param alertEmailAddress string

@description('Log Analytics workspace dedicated to AVD-rebuild alerts. The Automation Account streams JobStreams here so the scheduled-query alert can fire on the [ALERT-VMREBUILDFAILED] marker line.')
param logAnalyticsWorkspaceName string = 'law-avd-rebuild-alerts'

@description('Retention (days) for the rebuild-alert Log Analytics workspace. 30 days is the free-tier default and is plenty for this low-volume alert log.')
@minValue(30)
@maxValue(730)
param logAnalyticsRetentionDays int = 30

@description('Display name for the AVD Rebuild Tracker workbook shown in the portal workbook gallery.')
param rebuildWorkbookDisplayName string = 'AVD Rebuild Tracker'

@description('Stable GUID for the rebuild-tracker workbook resource name. Keep this constant so redeploys upsert the same workbook instead of creating duplicates.')
param rebuildWorkbookName string = '7f7a3c52-1d4e-4c4d-9e7b-1a4b9b6e7c01'


// --------------------------------------------------------- built-in role IDs

var roleIds = {
  DesktopVirtualizationContributor: '082f0a83-3be5-4ba1-904c-961cca79b387'
  VirtualMachineContributor:        '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
  NetworkContributor:               '4d97b98b-1d4f-4787-a291-c67834d212e7'
  Reader:                           'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  KeyVaultSecretsUser:              '4633458b-17de-408a-b874-0445c86b69e6'
  MonitoringContributor:            '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
  DiskContributor:                  '60fc6e62-5479-42d4-8bf4-67625fcc2840'
  // Self-grants on the Automation Account itself:
  //  * AutomationJobOperator + AutomationRunbookOperator let the Stage runbook
  //    call Start-AzAutomationRunbook to spawn the first Process child job.
  //  * AutomationContributor lets the runbook CREATE and DELETE the per-VM
  //    snapshot Automation variables (Set-AutomationVariable can only update
  //    existing variables; New-AzAutomationVariable / Remove-AzAutomationVariable
  //    require Contributor-level write/delete on the Automation Account).
  AutomationJobOperator:            '4fe576fe-1146-4730-92eb-48519fa6bf9f'
  AutomationRunbookOperator:        '5fb5aef8-1081-4b8e-bb16-9d5d0385bab5'
  AutomationContributor:            'f353d9bd-d4a6-484e-a77a-8050b599b867'
}

// -------------------------------------------------------- Automation Account

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name:     automationAccountName
  location: location
  tags:     tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
  }
}

// ----------------------------------------------------------- module imports
//
//   PowerShell 7.2 runtime already ships the full Az 11.2.0 module set
//   (Az.Accounts, Az.Compute, Az.Network, Az.Resources, Az.KeyVault,
//   Az.Monitor, Az.DesktopVirtualization, Az.Automation, ...) so we MUST NOT
//   import duplicate Az.* versions - mixing them causes "module could not be
//   loaded" errors at runtime.
//
//   Both runbooks use only built-in Az modules; nothing extra to install.

// --------------------------------------------------------- state variable
//
// The rebuild state variable (AVDRebuildState_<hostpool>) is intentionally NOT
// declared as a Bicep resource: doing so would force its value back to '{}' on
// every redeploy and wipe the runbook's in-flight state.  Deploy-Automation.ps1
// creates the variable on first run only (idempotent: skipped if it exists).

// ------------------------------------------------------------ runbook shells
//
//   The runbook *resource* is created here so that schedules and role
//   assignments have something to bind to.  Deploy-Automation.ps1 then calls
//   Import-AzAutomationRunbook to upload the .ps1 content and Publish-AzAutomationRunbook
//   to publish it.

resource rbRecreate 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name:   'Recreate-AVDSessionHosts'
  location: location
  properties: {
    runbookType: 'PowerShell72'
    logProgress: false
    logVerbose:  false
    description: 'Recreates AVD session host VMs from the Compute Gallery image while preserving config, NICs, extensions and DCRs.'
  }
}

resource rbEntra 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name:   'Disable-DrainForEntraJoined'
  location: location
  properties: {
    runbookType: 'PowerShell72'
    logProgress: false
    logVerbose:  false
    description: 'Turns off drain mode on rebuilt session hosts once they appear in Entra ID with an accepted trust type.'
  }
}

// Manual / ad-hoc runbook. INTENTIONALLY no schedule - operator runs this
// from the portal or Start-AzAutomationRunbook when they want a time-based
// fallback (drain off after VM is N hours old, then never touch the VM
// again because of a marker tag).
resource rbDrainAge 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name:   'Disable-DrainAfterAge'
  location: location
  properties: {
    runbookType: 'PowerShell72'
    logProgress: false
    logVerbose:  false
    description: 'Manual: turns drain off on session hosts whose VM is older than the threshold, stamps a marker tag so the VM is never touched again.'
  }
}

// ----------------------------------------------------------------- schedules
//
//   Azure Automation does not allow recurrence faster than once per hour, so
//   the rebuild retry fires once per hour. The orchestrator is idempotent:
//   each run picks up any VM still in Pending/AwaitingUsers/Failed and
//   resumes from the persisted snapshot if the previous run was interrupted.
//   A WEEKLY schedule fires every Saturday and (via the runbook parameter
//   ResetCompletedState=true) resets all Completed VMs back to Pending so the
//   rebuild cycle restarts.
//
//   The Entra-check runbook also runs hourly.

// Pin the hourly retry schedule's minute-of-hour to :30 every hour. The
// schedule's first tick (startTime) must be MORE THAN 5 MIN in the future
// (Azure Automation requirement), so we compute the next :30 mark after the
// current deployment time using epoch math and skip a slot if the buffer is
// too small:
//   - floor(now/3600)*3600 = top-of-current-hour epoch
//   - + 1800              = :30 of current hour
//   - if that's less than 10 min away (safety buffer over the 5-min minimum),
//     add another hour so ARM can finish deploying before the start time hits
var nowEpoch              = dateTimeToEpoch(deploymentTimeUtc)
var currentHourEpoch      = (nowEpoch / 3600) * 3600
var thirtyMarkEpoch       = currentHourEpoch + 1800
var minStartBufferSeconds = 600
var hourlyStartEpoch      = (thirtyMarkEpoch - nowEpoch) > minStartBufferSeconds ? thirtyMarkEpoch : (thirtyMarkEpoch + 3600)
var hourlyRetryStartTime  = dateTimeFromEpoch(hourlyStartEpoch)

// Compute the next Saturday 02:00 UTC strictly in the future. A hardcoded
// startTime goes stale and, once in the past, Azure Automation rejects the
// schedule ("start time must be at least 5 minutes after creation"). Unix
// epoch day 0 (1970-01-01) was a Thursday, so (daysSinceEpoch % 7) gives
// 0=Thu, 1=Fri, 2=Sat. We snap to the next Saturday, set 02:00 (7200s), and
// roll forward a week if that instant isn't comfortably in the future.
var daysSinceEpoch        = nowEpoch / 86400
var saturdayDow           = 2
var daysUntilSaturday     = ((saturdayDow - (daysSinceEpoch % 7)) + 7) % 7
var saturdayMidnightEpoch = (daysSinceEpoch + daysUntilSaturday) * 86400
var saturday0200Epoch     = saturdayMidnightEpoch + 7200
var weeklyStartEpoch      = (saturday0200Epoch - nowEpoch) > minStartBufferSeconds ? saturday0200Epoch : (saturday0200Epoch + (7 * 86400))
var weeklyEffectiveStart  = empty(weeklyStartTime) ? dateTimeFromEpoch(weeklyStartEpoch) : weeklyStartTime


resource schedRetry 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name:   'sched-recreate-retry-hourly'
  properties: {
    description: 'Process-mode hourly worker. Claims one Pending VM at a time, rebuilds it, then loops. Multiple concurrent ticks rebuild different VMs in parallel.'
    startTime:   hourlyRetryStartTime
    frequency:   'Hour'
    interval:    1
    timeZone:    'Etc/UTC'
  }
}

// Weekly kickoff - Saturday 02:00 UTC.
// startTime just needs to be in the future; advancedSchedule.weekDays = Saturday
// constrains the recurrence so the first real run is the next Saturday at the
// hour/minute encoded in startTime (02:00 UTC by default).
resource schedWeekly 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name:   'sched-recreate-weekly-sat'
  properties: {
    description: 'Weekly kickoff every Saturday 02:00 UTC. Calls the runbook with ResetCompletedState=true.'
    startTime:   weeklyEffectiveStart
    frequency:   'Week'
    interval:    1
    timeZone:    'Etc/UTC'
    advancedSchedule: {
      weekDays: [ 'Saturday' ]
    }
  }
}

resource schedEntra 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name:   'sched-entra-hourly'
  properties: {
    description: 'Triggers the Entra-check runbook hourly.'
    startTime:   dateTimeAdd(deploymentTimeUtc, 'PT15M')
    frequency:   'Hour'
    interval:    1
    timeZone:    'Etc/UTC'
  }
}

// Hourly schedule for Disable-DrainAfterAge. Created here so it shows up
// in the portal and an operator can flip it on with a single click, but
// Deploy-Automation.ps1 immediately disables the schedule after binding
// (the ARM Schedules API has no isEnabled property on create) so this
// runbook stays manual unless someone explicitly turns the schedule on.
resource schedDrainAge 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name:   'sched-drainage-hourly'
  properties: {
    description: 'Hourly trigger for Disable-DrainAfterAge. Created DISABLED. Enable manually to allow time-based drain-off as a fallback.'
    startTime:   dateTimeAdd(deploymentTimeUtc, 'PT15M')
    frequency:   'Hour'
    interval:    1
    timeZone:    'Etc/UTC'
  }
}

// ----------------------------------------------------- runbook parameter map
// Job schedule resources are intentionally created from PowerShell after the
// runbooks have been published.  ARM rejects jobSchedules whose target runbook
// has not yet been published (it only sees the empty shell created above).

output retryScheduleName   string = schedRetry.name
output weeklyScheduleName  string = schedWeekly.name
output entraScheduleName   string = schedEntra.name
output drainAgeScheduleName string = schedDrainAge.name
output rebuildRunbookName  string = rbRecreate.name
output entraRunbookName    string = rbEntra.name

// =============================================================================
//  VM-rebuild-FAILED email alert
//
//  The Recreate-AVDSessionHosts runbook writes a parseable marker line every
//  time a session host transitions to status=Failed (via Set-VmStatus):
//
//      [ALERT-VMREBUILDFAILED] Hostpool=<HP> VmName=<VM> Time=<UTC> Reason=<msg>
//
//  Pipeline:
//      runbook Write-Output  ->  Automation JobStreams
//                            ->  Diagnostic Setting
//                            ->  Log Analytics workspace (AzureDiagnostics)
//                            ->  Scheduled-query alert (every 5 min)
//                            ->  Action Group  ->  Email
//
//  Each unique (Hostpool, VmName) match in a 5-minute window fires its own
//  alert (dimensions split the result set), so per-VM emails are guaranteed
//  even when several VMs finish in the same window.
// =============================================================================

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name:     logAnalyticsWorkspaceName
  location: location
  tags:     tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays:                 logAnalyticsRetentionDays
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery:     'Enabled'
  }
}

// Stream the Automation Account's JobStreams (which carry every Write-Output
// line from the runbook) into the dedicated workspace.  JobLogs is included
// so failure investigations have full context, not just successful rebuilds.
resource diagSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name:  'send-jobstreams-to-law'
  scope: automationAccount
  properties: {
    workspaceId: law.id
    logs: [
      {
        category: 'JobStreams'
        enabled:  true
      }
      {
        category: 'JobLogs'
        enabled:  true
      }
    ]
  }
}

// Single email recipient.  Add more emailReceivers entries (or other receiver
// types - SMS, webhook, Teams, etc.) here as needed.
resource alertActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name:     'ag-avd-rebuild-email'
  location: 'global'
  tags:     tags
  properties: {
    groupShortName: 'AvdRebuild'
    enabled:        true
    emailReceivers: [
      {
        name:                 'PrimaryRecipient'
        emailAddress:         alertEmailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

// Scheduled query alert: fires (Sev 2 / Warning) for every rebuild FAILURE.
// The 5-min window matches the evaluation frequency so each failure row falls
// in exactly one evaluation window (no duplicate emails). Hostpool and VmName
// are split dimensions, so if multiple VMs fail in the same window the alert
// fires once per (Hostpool, VmName) - one email per failed VM.
resource rebuildAlertRule 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name:     'alert-avd-vm-rebuild-failed'
  location: location
  tags:     tags
  properties: {
    displayName:         'AVD session host rebuild FAILED'
    description:         'Fires when Recreate-AVDSessionHosts marks a session host VM as Failed (creation, domain-join, agent registration, or any other rebuild step failed). One email per (Hostpool, VmName).'
    severity:            2
    enabled:             true
    scopes:              [ law.id ]
    evaluationFrequency: 'PT5M'
    windowSize:          'PT5M'
    autoMitigate:        false
    criteria: {
      allOf: [
        {
          query: '''
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where RunbookName_s == "Recreate-AVDSessionHosts"
| where ResultDescription has "[ALERT-VMREBUILDFAILED]"
| extend Hostpool       = extract(@"Hostpool=([^\\s]+)", 1, ResultDescription)
| extend VmName         = extract(@"VmName=([^\\s]+)",   1, ResultDescription)
| extend FailureTimeUtc = extract(@"Time=([^\\s]+)",     1, ResultDescription)
| extend Reason         = extract(@"Reason=(.*)$",        1, ResultDescription)
| where isnotempty(Hostpool) and isnotempty(VmName)
| project TimeGenerated, Hostpool, VmName, FailureTimeUtc, Reason, JobId_g
'''
          timeAggregation: 'Count'
          operator:        'GreaterThan'
          threshold:       0
          dimensions: [
            {
              name:     'Hostpool'
              operator: 'Include'
              values:   [ '*' ]
            }
            {
              name:     'VmName'
              operator: 'Include'
              values:   [ '*' ]
            }
          ]
          failingPeriods: {
            minFailingPeriodsToAlert:  1
            numberOfEvaluationPeriods: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [ alertActionGroup.id ]
    }
  }
}

// =============================================================================
//  AVD Rebuild Tracker workbook
//
//  Visualizes per-VM phase progress, timeline, throughput, and failures from
//  the same AzureDiagnostics rows the email alert reads. The workbook body
//  lives in ./workbook-content.json so it can be hand-edited without
//  touching this template; redeploys upsert because the resource name is a
//  stable GUID.
// =============================================================================
resource rebuildWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name:     rebuildWorkbookName
  location: location
  tags:     tags
  kind:     'shared'
  properties: {
    displayName:    rebuildWorkbookDisplayName
    serializedData: loadTextContent('./workbook-content.json')
    version:        '1.0'
    category:       'workbook'
    sourceId:       law.id
  }
}

output logAnalyticsWorkspaceId   string = law.id
output logAnalyticsWorkspaceName string = law.name
output actionGroupId             string = alertActionGroup.id
output rebuildAlertRuleId        string = rebuildAlertRule.id
output alertEmailRecipient       string = alertEmailAddress
output rebuildWorkbookId         string = rebuildWorkbook.id


// ---------------------------------------------------- role assignments (MI)
//
//   AVD / VM / Network / Monitoring roles are assigned at the HOSTPOOL RG
//   (where the host pool, VMs, NICs and DCRs live), not at the deployment RG.

var hostpoolRoles = [
  roleIds.DesktopVirtualizationContributor
  roleIds.VirtualMachineContributor
  roleIds.NetworkContributor
  roleIds.MonitoringContributor
  roleIds.DiskContributor
]

module raHostpool 'modules/role-assignment-rg.bicep' = [for r in hostpoolRoles: {
  name: 'raHostpool-${uniqueString(r)}'
  scope: resourceGroup(hostpoolRG)
  params: {
    principalId:      automationAccount.identity.principalId
    roleDefinitionId: r
    assignmentName:   guid(subscription().id, hostpoolRG, automationAccount.id, r)
  }
}]

// VNet RG: Network Contributor so the MI can join NICs to the subnet.
// Only deployed when vnetRG is set AND differs from hostpoolRG (otherwise the
// hostpool-RG Network Contributor grant above already covers it).
module raVnet 'modules/role-assignment-rg.bicep' = if (!empty(vnetRG) && vnetRG != hostpoolRG) {
  name: 'raVnetNetworkContributor'
  scope: resourceGroup(vnetRG)
  params: {
    principalId:      automationAccount.identity.principalId
    roleDefinitionId: roleIds.NetworkContributor
    assignmentName:   guid(subscription().id, vnetRG, automationAccount.id, roleIds.NetworkContributor)
  }
}

// Image Gallery RG: Reader so the MI can resolve image versions.
module raImage 'modules/role-assignment-rg.bicep' = {
  name: 'raImageGalleryReader'
  scope: resourceGroup(imageGalleryRG)
  params: {
    principalId:      automationAccount.identity.principalId
    roleDefinitionId: roleIds.Reader
    assignmentName:   guid(subscription().id, imageGalleryRG, automationAccount.id, roleIds.Reader)
  }
}

// Key Vault: deployed alongside the Automation Account in the same RG. The
// vault name is derived deterministically from the RG id so it stays stable
// across redeploys but is globally unique per environment (KV names must be
// globally unique, 3-24 chars). RBAC mode is on so the AA's MI can read
// secrets via the 'Key Vault Secrets User' role assignment below; no access
// policies are used.
// NOTE: secrets are NOT created here - the operator must populate
//   '<domainJoinPasswordSecretName>' and '<vmAdminPasswordSecretName>'
// after deploy (see README post-deploy steps).
var keyVaultName = 'kv-avd-rebuild-${take(uniqueString(resourceGroup().id), 8)}'

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name:     keyVaultName
  location: location
  tags:     tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name:   'standard'
    }
    enableRbacAuthorization:   true
    enableSoftDelete:          true
    softDeleteRetentionInDays: 7
    enablePurgeProtection:     null
    publicNetworkAccess:       'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass:        'AzureServices'
    }
  }
}

// Key Vault: Secrets User for the AA's MI (scoped to the vault itself).
resource raKv 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(keyVault.id, automationAccount.id, roleIds.KeyVaultSecretsUser)
  scope: keyVault
  properties: {
    principalId:      automationAccount.identity.principalId
    principalType:    'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.KeyVaultSecretsUser)
  }
}

// Self-grants on the Automation Account so the Stage runbook (running under
// the AA's MI) can call Start-AzAutomationRunbook to spawn Process child jobs,
// and so Process runbooks can create / delete per-VM snapshot variables.
var selfAaRoles = [
  roleIds.AutomationJobOperator
  roleIds.AutomationRunbookOperator
  roleIds.AutomationContributor
]

resource raSelfAa 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for r in selfAaRoles: {
  // Name seed cannot include automationAccount.identity.principalId because that
  // property is only known after the AA is deployed; newer Bicep CLIs reject
  // it (BCP120). The (AA id, role) pair is unique and stable per assignment.
  name: guid(automationAccount.id, r)
  scope: automationAccount
  properties: {
    principalId:      automationAccount.identity.principalId
    principalType:    'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', r)
  }
}]

// ------------------------------------------------------------------- outputs

output automationAccountName    string = automationAccount.name
output keyVaultName             string = keyVault.name
output keyVaultResourceGroup    string = resourceGroup().name
output automationAccountId      string = automationAccount.id
output managedIdentityPrincipal string = automationAccount.identity.principalId
output stateVariableName        string = 'AVDRebuildState_${hostpoolName}'
output runbookNames             array  = [ rbRecreate.name, rbEntra.name ]
output targetResourceGroup      string = targetResourceGroup
// Echo the target subscription back so every deployment record shows the
// sub that was approved in main.bicepparam (the PowerShell wrapper compares
// it against the live Az context before submitting the deployment).
output deployedToSubscriptionId string = subscriptionId
