# RedeployAVDHostpool

Two Azure Automation runbooks that rebuild every session host in an AVD host
pool from a Shared Image Gallery image — preserving each VM's size, NIC/IP,
extensions, monitoring, and DCR associations — then verify the Entra ID join
before re-enabling user connections.

| Runbook | Purpose |
| --- | --- |
| [Recreate-AVDSessionHosts.ps1](Recreate-AVDSessionHosts.ps1) | Drains, snapshots, deletes, and rebuilds each session host. Re-joins the domain, re-registers with the host pool, re-applies extensions and DCRs. Leaves drain mode ON. |
| [Disable-DrainForEntraJoined.ps1](Disable-DrainForEntraJoined.ps1) | After rebuild, verifies the device is hybrid/Entra-joined and turns drain mode OFF. **Only acts on VMs Runbook 1 marked `Completed`** — operator-set drain on other hosts is left alone. |

## What to expect

* **Weekly rebuild**: every Saturday 02:00 UTC the orchestrator snapshots
  every session host, marks all of them `Pending`, and starts rebuilding in
  parallel.
* **Per-VM time**: ~13 minutes end-to-end (snapshot → delete → recreate →
  domain join → AVD register → DSC → DCR).
* **Throughput**: up to 3 VMs rebuilt simultaneously by default
  (`MaxParallelProcessJobs`). Hourly retries add more parallelism if needed.
* **Recoverable**: each VM's config snapshot is persisted to a dedicated
  Automation variable **before** delete, so a failed rebuild — or even a
  total worker crash — can resume without losing spec data.
* **Self-healing**: stale claims, transient failures, and active user
  sessions are all handled automatically with cooldowns and retries.
* **User safety**: drain mode is set before delete, only cleared after the
  rebuild reaches `Completed` AND Runbook 2 verifies the Entra join.

## Deploy

```powershell
# Preview only
.\Deploy-Automation.ps1 -ResourceGroup rg-avd-automation -Mode WhatIf

# Deploy + import + publish both runbooks
.\Deploy-Automation.ps1 -ResourceGroup rg-avd-automation -Mode Deploy
```

No tenant-scoped permissions required. Runbook 2 verifies Entra join state
by running `dsregcmd /status` on each VM via Azure Run-Command, so the
managed identity needs only the subscription-scoped roles granted by the
Bicep template.

## How it works (one paragraph)

`Recreate-AVDSessionHosts` runs in two modes. **Stage** (weekly) snapshots
every VM into per-VM Automation variables, flips state to `Pending`, and
spawns parallel **Process** workers. Each Process worker atomically claims
one VM under a state lock, rebuilds it end-to-end, then loops. When a worker
exits with eligible work remaining, it spawns one successor (capped at
`MaxSuccessorChainDepth = 4`) so progress doesn't have to wait for the next
hourly tick. An hourly schedule also runs Process independently as a
catch-all. All concurrent jobs claim DIFFERENT VMs via the state lock.

## Knobs

Defaults work for typical hostpools. Override per-run or by editing the
schedule parameters.

| Parameter | Default | Effect |
| --- | --- | --- |
| `MaxParallelProcessJobs` | `3` | Parallel rebuilds spawned by Stage |
| `MaxSuccessorChainDepth` | `4` | Max sequential jobs in one chain (~52 VMs of capacity) |
| `FailureRetryMinutes` | `60` | Cooldown before a `Failed` VM is retried |
| `StaleClaimMinutes` | `90` | Auto-reclaim a VM stuck mid-rebuild |
| `ProcessJobBudgetMinutes` | `170` | Per-job runtime budget (Automation cap is 180) |

Identity defaults (placeholders shown - real values live in your local `bicep/main.bicepparam`, which is gitignored):

```text
HostpoolName/HostpoolRG = <HOSTPOOL_NAME> / <HOSTPOOL_RG>
Location                = <AZURE_REGION>
DomainName / User       = <DOMAIN_FQDN> / <DOMAIN_JOIN_UPN>
KeyVault                = kv-avd-rebuild-<hash>  (auto-created in Automation RG)
ImageGallery            = <IMAGE_GALLERY_NAME> / <IMAGE_GALLERY_RG> / <IMAGE_DEFINITION_NAME> / latest
```

### First-time setup

The environment-specific parameter file is gitignored so the repo can be
shared without exposing your hostpool / domain / email values. Before the
first deploy:

```powershell
Copy-Item .\bicep\main.bicepparam.example .\bicep\main.bicepparam
# Edit main.bicepparam and replace every <PLACEHOLDER> with values for
# YOUR environment, then:
.\Deploy-Automation.ps1 -Mode WhatIf
.\Deploy-Automation.ps1 -Mode Deploy
```

`Deploy-Automation.ps1` fails fast with this exact message if the real file
is missing.

### Post-deploy: populate Key Vault secrets

The bicep template creates a new RBAC-mode Key Vault next to the Automation
Account (`kv-avd-rebuild-<hash>` in the AA's RG) but does **not** put any
secrets in it. After the first deploy, set the two passwords the rebuild
runbook needs:

```powershell
$kv = (Get-AzKeyVault -ResourceGroupName 'rg-avd-automation' |
        Where-Object VaultName -like 'kv-avd-rebuild-*').VaultName
Set-AzKeyVaultSecret -VaultName $kv -Name 'domainJoinPassword' -SecretValue (Read-Host -AsSecureString)
Set-AzKeyVaultSecret -VaultName $kv -Name 'vmAdminPassword'    -SecretValue (Read-Host -AsSecureString)
```

`Deploy-Automation.ps1` prints the exact commands above if either secret is
missing at the end of a deploy.

## Operator commands

```powershell
$rg='rg-avd-automation'; $aa='aa-avd-rebuild'
$pf = '.\bicep\main.bicepparam'
function Get-P($n) { (Select-String -Path $pf -Pattern "^\s*param\s+$n\s*=\s*'([^']+)'").Matches.Groups[1].Value }
$hp = Get-P 'hostpoolName'

# Live state
(Get-AzAutomationVariable -ResourceGroupName $rg -AutomationAccountName $aa `
    -Name "AVDRebuildState_$hp").Value | ConvertFrom-Json | Format-Table

# Manually trigger the weekly Stage job (snapshot every VM, mark Pending,
# spawn first Process child). Reads all required parameters from
# bicep/main.bicepparam so this stays in sync with the deployed config.
Start-AzAutomationRunbook -ResourceGroupName $rg -AutomationAccountName $aa `
    -Name 'Recreate-AVDSessionHosts' -Parameters @{
        Mode                           = 'Stage'
        ResetCompletedState            = $true
        HostpoolName                   = $hp
        HostpoolRG                     = Get-P 'hostpoolRG'
        DomainName                     = Get-P 'domainName'
        DomainJoinUserName             = Get-P 'domainJoinUserName'
        DomainJoinPasswordSecretName   = Get-P 'domainJoinPasswordSecretName'
        VmAdminUserName                = Get-P 'vmAdminName'
        VmAdminPasswordSecretName      = Get-P 'vmAdminPasswordSecretName'
        KeyVaultName                   = (Get-AzKeyVault -ResourceGroupName $rg | Where-Object VaultName -like 'kv-avd-rebuild-*').VaultName
        KeyVaultRG                     = $rg
        ImageGalleryName               = Get-P 'imageGalleryName'
        ImageGalleryRG                 = Get-P 'imageGalleryRG'
        ImageDefinitionName            = Get-P 'imageDefinitionName'
        ImageVersionName               = Get-P 'imageVersionName'
        AutomationAccountResourceGroup = $rg
        AutomationAccountName          = $aa
    }

# Force-retry a Failed VM immediately
Start-AzAutomationRunbook -ResourceGroupName $rg -AutomationAccountName $aa `
    -Name 'Recreate-AVDSessionHosts' -Parameters @{
        Mode='Process'; FailureRetryMinutes=0
        AutomationAccountResourceGroup=$rg; AutomationAccountName=$aa }

# Break a stuck lock (only if you've verified no job is running)
Set-AzAutomationVariable -ResourceGroupName $rg -AutomationAccountName $aa `
    -Name "AVDRebuildLock_$hp" -Value '' -Encrypted $false | Out-Null
```

## State

Three Automation variables per hostpool:

| Variable | Purpose |
| --- | --- |
| `AVDRebuildState_<Hostpool>` | JSON map of per-VM status (`Pending`, `Claimed`, `Creating`, …, `Completed`, `Failed`, `AwaitingUsers`). Inspect anytime. |
| `AVDRebuildLock_<Hostpool>` | Cross-job mutex. Held milliseconds. Auto-broken after `StaleClaimMinutes`. |
| `AVDRebuildSnapshots_<Hostpool>_<VmName>` | One per VM. Holds the JSON spec needed to rebuild. Written before delete, removed on `Completed`. |

Snapshots are also echoed between `===== SNAPSHOT_BEGIN/END =====` markers
in Automation job output as a last-resort recovery source.

## Required modules & roles

Modules (Az 11.x or newer): `Az.Accounts`, `Az.Compute`, `Az.Network`,
`Az.Resources`, `Az.KeyVault`, `Az.Monitor`, `Az.DesktopVirtualization`,
`Az.Automation`. All ship with the PowerShell 7.2 Automation runtime - no
extra module imports required.

Managed identity roles (granted by the Bicep template):

| Scope | Role |
| --- | --- |
| Hostpool RG | `Desktop Virtualization Contributor`, `Virtual Machine Contributor`, `Network Contributor`, `Reader`, `Contributor` (for disk delete) |
| Key Vault | `Key Vault Secrets User` |
| DCR / workspace | `Monitoring Contributor` |
| Automation Account itself | `Automation Job Operator`, `Automation Runbook Operator`, `Automation Contributor` (for spawning child jobs and managing per-VM snapshot variables) |

## Limitations

* **Data disks are not handled** — pooled AVD hosts typically have none.
  Extend `Get-VmSnapshot` / `New-SessionHostVm` if you use them.
* **Extension `ProtectedSettings` cannot be read back from ARM** — only
  DomainJoin and AVD DSC protected settings are re-applied; others restore
  with public settings only.
* **NIC is kept** — IP reservation, NSG, and subnet remain intact across
  rebuild. Only the VM resource and its OS disk are recreated.
