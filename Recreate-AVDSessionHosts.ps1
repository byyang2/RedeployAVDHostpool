<#
.SYNOPSIS
    Recreates all session host VMs in an Azure Virtual Desktop host pool, preserving
    configuration (size, network, identity, tags, extensions, DCR associations) and
    re-joining them to AD with drain mode enabled.

.DESCRIPTION
    Runbook 1 of 2.

    Behavior:
      * Discovers every session host registered to the host pool.
      * Maintains per-VM rebuild state in an Azure Automation variable so the
        runbook is idempotent and can be re-scheduled until every VM is rebuilt.
      * Skips (re-queues) any session host that currently has active user
        connections.  Drains and force-logs-off disconnected sessions before
        rebuild.
      * Captures the original VM's hardware profile, NIC(s), OS disk SKU,
        tags, identity, availability options, extensions, and any associated
        Data Collection Rules (DCRA) before deletion.
      * Deletes the old VM + OS disk, then re-creates a new VM with the same
        name from the specified Shared Image Gallery image.
      * Re-applies domain-join (JsonADDomainExtension), AVD agent installation
        (Microsoft.Powershell.DSC), the original monitoring extensions, and
        re-associates every Data Collection Rule that was attached.
      * Sets the session host to drain mode (AllowNewSession = false) when done.
        Runbook 2 turns drain off after verifying the device is in Entra ID.

.NOTES
    * Designed to be executed by a System-Assigned or User-Assigned Managed
      Identity that has, at minimum:
        - Contributor (or Virtual Machine Contributor + Network Contributor)
          on the hostpool RG and on the VM, NIC and disk RGs.
        - Desktop Virtualization Contributor on the host pool.
        - Key Vault Secrets User on the Key Vault holding the domain join
          password.
        - Monitoring Contributor (for DCR re-association).
    * Schedule this runbook on a recurring basis (for example every 30 min).
      Each run picks up any session host in state 'Pending' or 'AwaitingUsers'
      and either rebuilds it or re-queues it.
    * Requires Az.Accounts, Az.Compute, Az.Network, Az.Resources,
      Az.DesktopVirtualization, Az.KeyVault, Az.Monitor modules in the
      Automation Account.
#>

[CmdletBinding()]
param(
    # ---------- Host pool ----------
    [Parameter(Mandatory)][string] $HostpoolName,
    [Parameter(Mandatory)][string] $HostpoolRG,
    # Region used only when starting Process child jobs and when the snapshot
    # path doesn't already supply a location. VM placement always uses
    # $Snapshot.Location from the source VM, so this is just a fallback. Left
    # empty so the runbook stays region-neutral; the bicep schedule binding
    # passes the right value at job-start time.
    [string] $Location     = '',

    # ---------- Subscription pin ----------
    # Pin the Az context to this exact subscription before any Get-Az* call.
    # Belt-and-suspenders: even though the Automation Account MI has its own
    # default subscription, a customer's MI could have role assignments in
    # other subs and Az would pick whichever happens to be the context
    # default - resolving HostpoolRG / ImageGalleryRG / KeyVaultRG in the
    # wrong sub. Empty string => keep whatever the MI's default sub is.
    [string] $SubscriptionId = '',

    # ---------- Domain join ----------
    [Parameter(Mandatory)][string] $DomainName,
    [Parameter(Mandatory)][string] $DomainJoinUserName,
    [string] $DomainJoinPasswordSecretName = 'domainJoinPassword',
    [string] $DomainJoinOUPath            = '',

    # ---------- VM local administrator ----------
    # The local admin account written into every rebuilt VM. The password
    # is read at rebuild time from $KeyVaultName / $VmAdminPasswordSecretName
    # so it is rotatable and never stored in a runbook variable.
    [string] $VmAdminUserName             = 'azureadmin',
    [string] $VmAdminPasswordSecretName   = 'vmAdminPassword',

    # ---------- Key Vault ----------
    [Parameter(Mandatory)][string] $KeyVaultName,
    [Parameter(Mandatory)][string] $KeyVaultRG,

    # ---------- Image source ----------
    [Parameter(Mandatory)][string] $ImageGalleryName,
    [Parameter(Mandatory)][string] $ImageGalleryRG,
    [Parameter(Mandatory)][string] $ImageDefinitionName,
    [string] $ImageVersionName    = 'latest',

    # ---------- Behavior ----------
    # Maximum VMs to attempt per run; remaining ones are picked up on the next run.
    [int]    $MaxVmsPerRun = 5,

    # If $true, a session host with active connections is left alone and re-tried
    # on a future run.  If $false the runbook will WAIT (up to $WaitMinutes) for
    # the active sessions to disconnect before giving up.
    [bool]   $SkipIfUsersActive = $true,
    [int]    $WaitMinutes       = 30,

    # AVD DSC artifact (used to install + register the AVD agent).
    [string] $AvdAgentDscUrl = 'https://wvdportalstorageblob.blob.core.usgovcloudapi.net/galleryartifacts/Configuration_1.0.02990.697.zip',

    # DEPRECATED. Retained for backward compatibility only - no longer read by
    # the orchestrator.  Use -Mode Stage on the weekly kickoff schedule instead;
    # the Stage path snapshots every VM and resets every state to Pending.
    [bool]   $ResetCompletedState = $false,

    # Execution mode.
    #   Stage   - weekly kickoff: lock state, snapshot every session host VM,
    #             mark every VM 'Pending', release lock, kick off one Process
    #             job, and exit.  Does NOT rebuild any VM.
    #   Process - hourly worker: claim one Pending VM under the lock, rebuild
    #             it end-to-end (without holding the lock), then loop to claim
    #             the next one until none are left or the job deadline nears.
    #             Multiple Process jobs running concurrently each claim a
    #             different VM, so rebuilds run in parallel.
    [ValidateSet('Stage','Process')]
    [string] $Mode = 'Process',

    # How long a Process job is willing to keep claiming new VMs before exiting
    # gracefully. Azure Automation hard-caps a job at 3 hours, so leave buffer.
    [int]    $ProcessJobBudgetMinutes = 170,

    # If a VM's state is non-terminal but has not been updated in this many
    # minutes, a Process job will reclaim it (assume the previous worker died).
    [int]    $StaleClaimMinutes = 90,

    # If a VM's status is 'Failed', no Process job will re-claim it until this
    # many minutes have elapsed since the failure. This stops a broken VM
    # (e.g. domain join consistently failing) from causing every concurrent
    # job to delete-recreate it in a tight loop and burning compute quota.
    [int]    $FailureRetryMinutes = 60,

    # After the AVD DSC extension reports Succeeded the AVD agent must still
    # complete its asynchronous self-registration with the AVD broker before
    # the new session host record appears in the host pool. Poll for that
    # registration for up to this many minutes; if the session host never
    # appears, mark the rebuild Failed instead of silently completing.
    [int]    $SessionHostRegistrationTimeoutMinutes = 10,

    # How long Lock-State will wait for the mutex before throwing.
    [int]    $LockWaitSeconds = 300,

    # Name of the Automation variable used to track rebuild progress.
    [string] $StateVariableName = "AVDRebuildState_${HostpoolName}",

    # Name of the Automation variable used to persist per-VM snapshots so a
    # failed rebuild can resume after the original VM has been deleted.
    [string] $SnapshotVariableName = "AVDRebuildSnapshots_${HostpoolName}",

    # Name of the Automation variable used as a cross-job mutex protecting
    # read-modify-write access to the state and snapshot variables.
    [string] $LockVariableName = "AVDRebuildLock_${HostpoolName}",

    # Optional second-tier backup: if both of these are supplied, every
    # snapshot is also written to a blob in the given storage account before
    # the source VM is deleted. The Automation MI must have 'Storage Blob
    # Data Contributor' on the container.
    [string] $SnapshotBackupStorageAccount = '',
    [string] $SnapshotBackupContainer     = 'avd-rebuild-snapshots',

    # Identity of THIS Automation Account, used by Stage mode to kick off the
    # first Process child job via Start-AzAutomationRunbook. The deploy script
    # binds these on both schedules. Get-AzAutomationAccount alone cannot
    # discover them from within a runbook running under a System MI.
    [string] $AutomationAccountResourceGroup = '',
    [string] $AutomationAccountName          = '',

    # ---------- Parallelism / successor chaining ----------
    # At the end of Stage, spawn this many parallel Process children
    # (bounded above by the number of Pending VMs). Each child runs in its
    # own Automation sandbox with its own independent runtime budget, so
    # spawning more children does NOT consume the parent job's budget.
    [int]    $MaxParallelProcessJobs = 3,

    # When a Process job is about to exit, if it made any progress this run
    # AND eligible work still remains, spawn ONE successor Process job to
    # take over. The successor runs in its own sandbox with a fresh budget.
    # Refuses to spawn past $MaxSuccessorChainDepth to prevent any runaway
    # chain (belt-and-suspenders behind the "must have progressed" gate).
    # Default 4 = up to ~4 sequential jobs * ~13 VMs/job = ~52 VMs of
    # capacity per chain before falling back to the next hourly tick.
    [int]    $SuccessorDepth         = 0,
    [int]    $MaxSuccessorChainDepth = 4
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region ---------------------------------------------------------- helpers ----

function Write-Log {
    param([string] $Message, [string] $Level = 'INFO')
    $ts = (Get-Date).ToString('s')
    Write-Output "[$ts][$Level] $Message"
}

# Safe dotted property accessor for use under Set-StrictMode -Version Latest.
# Returns $null instead of throwing when any segment is missing. Works on
# both PSCustomObject/.NET objects (PSObject.Properties) and hashtables /
# OrderedDictionary (Contains/lookup).
function Get-SafeProperty {
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Path
    )
    $current = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $null }
            $current = $current[$segment]
        } else {
            try {
                $member = $current.PSObject.Properties[$segment]
            } catch { return $null }
            if (-not $member) { return $null }
            $current = $member.Value
        }
    }
    return $current
}

function Connect-AzureAutomation {
    Write-Log 'Connecting with System-Assigned Managed Identity...'
    Disable-AzContextAutosave -Scope Process | Out-Null
    $ctx = (Connect-AzAccount -Identity -Environment AzureUSGovernment).Context
    Set-AzContext -Context $ctx | Out-Null
    if ($SubscriptionId) {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        $ctx = Get-AzContext
        if ($ctx.Subscription.Id -ne $SubscriptionId) {
            throw "Failed to pin Az context to subscription '$SubscriptionId' (current: '$($ctx.Subscription.Id)'). Confirm the Automation Account's Managed Identity has access to that subscription."
        }
        Write-Log "Connected as $($ctx.Account.Id) in subscription $($ctx.Subscription.Id) (pinned)."
    } else {
        Write-Log "Connected as $($ctx.Account.Id) in subscription $($ctx.Subscription.Id) (default)."
    }
}

function Get-RebuildState {
    param([string] $Name)
    try {
        $raw = Get-AutomationVariable -Name $Name -ErrorAction Stop
    } catch {
        $raw = $null
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    return ($raw | ConvertFrom-Json -AsHashtable)
}

function Save-RebuildState {
    param([string] $Name, $State)
    $json = ($State | ConvertTo-Json -Depth 12 -Compress)
    try {
        Set-AutomationVariable -Name $Name -Value $json
    } catch {
        # First run: create the variable inside the current Automation Account.
        $aa = (Get-AzAutomationAccount | Select-Object -First 1)
        if (-not $aa) { throw "Cannot persist state - no Automation Account in current context." }
        New-AzAutomationVariable -ResourceGroupName $aa.ResourceGroupName `
            -AutomationAccountName $aa.AutomationAccountName `
            -Name $Name -Value $json -Encrypted $false | Out-Null
    }
}

# ----------------------------------------------------------------------------
# Snapshot persistence
# ----------------------------------------------------------------------------
# Each VM's snapshot is stored in its OWN Automation variable named
# "<SnapshotVariableName>_<VmName>" so corruption / overwrite of one VM's
# snapshot can never lose snapshots for the others, snapshot writes don't need
# the cross-job state lock (different keys never collide), and each VM gets
# its own ~10 KB Automation-variable size budget.
#
# Reads transparently fall back to the legacy combined variable
# ("<SnapshotVariableName>", which used to hold a JSON dict of every VM)
# so any pre-existing data still resolves until the next Stage refreshes it.
# ----------------------------------------------------------------------------

function Get-AutomationAccountContext {
    # Cached resolution of the AA's RG/Name for control-plane calls
    # (creating / deleting per-VM snapshot variables, enumerating them).
    # Uses Get-Variable so that Set-StrictMode -Version Latest doesn't throw
    # on the very first invocation when the script-scope cache is unset.
    $cached = Get-Variable -Name '__AaCtx' -Scope Script -ErrorAction SilentlyContinue
    if ($cached -and $cached.Value) { return $cached.Value }
    $rg   = $AutomationAccountResourceGroup
    $name = $AutomationAccountName
    if (-not $rg -or -not $name) {
        $aa = (Get-AzAutomationAccount -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($aa) { $rg = $aa.ResourceGroupName; $name = $aa.AutomationAccountName }
    }
    if (-not $rg -or -not $name) { return $null }
    Set-Variable -Name '__AaCtx' -Scope Script -Value @{ ResourceGroup = $rg; Name = $name }
    return (Get-Variable -Name '__AaCtx' -Scope Script).Value
}

function Get-PerVmSnapshotVarName {
    param(
        [Parameter(Mandatory)] [string] $Base,
        [Parameter(Mandatory)] [string] $VmName
    )
    # Automation variable names allow alphanumerics, dash and underscore.
    $safe = ($VmName -replace '[^A-Za-z0-9_\-]', '_')
    return "${Base}_${safe}"
}

function Get-PersistedSnapshot {
    # Returns one VM's snapshot (or $null). Per-VM variable first, legacy
    # combined variable second.
    param(
        [Parameter(Mandatory)] [string] $Base,
        [Parameter(Mandatory)] [string] $VmName
    )
    $perVmName = Get-PerVmSnapshotVarName -Base $Base -VmName $VmName
    $raw = $null
    try { $raw = Get-AutomationVariable -Name $perVmName -ErrorAction Stop } catch { }
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try { return ($raw | ConvertFrom-Json -AsHashtable) } catch { }
    }
    # Legacy fallback.
    try { $raw = Get-AutomationVariable -Name $Base -ErrorAction Stop } catch { $raw = $null }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try {
        $combined = $raw | ConvertFrom-Json -AsHashtable
        if ($combined.ContainsKey($VmName)) { return $combined[$VmName] }
    } catch { }
    return $null
}

function Get-PersistedSnapshots {
    # Returns a hashtable of ALL known snapshots keyed by VM name. Merges
    # per-VM variables with the legacy combined variable (per-VM wins).
    param([string] $Name)
    $all = @{}
    $aa  = Get-AutomationAccountContext
    if ($aa) {
        $vars = @()
        try {
            $vars = Get-AzAutomationVariable -ResourceGroupName $aa.ResourceGroup -AutomationAccountName $aa.Name -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "${Name}_*" -and $_.Name -ne $Name }
        } catch { }
        foreach ($v in $vars) {
            $vmKey = $v.Name.Substring($Name.Length + 1)
            $raw = $null
            try { $raw = Get-AutomationVariable -Name $v.Name -ErrorAction Stop } catch { }
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                try { $all[$vmKey] = ($raw | ConvertFrom-Json -AsHashtable) } catch { }
            }
        }
    }
    # Merge legacy combined entries that aren't already represented.
    $rawCombined = $null
    try { $rawCombined = Get-AutomationVariable -Name $Name -ErrorAction Stop } catch { }
    if (-not [string]::IsNullOrWhiteSpace($rawCombined)) {
        try {
            $combinedObj = $rawCombined | ConvertFrom-Json -AsHashtable
            foreach ($k in $combinedObj.Keys) {
                if (-not $all.ContainsKey($k)) { $all[$k] = $combinedObj[$k] }
            }
        } catch { }
    }
    return $all
}

function Save-PersistedSnapshot {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] $Snapshot
    )
    $perVmName = Get-PerVmSnapshotVarName -Base $Name -VmName $VmName
    $json = ($Snapshot | ConvertTo-Json -Depth 20 -Compress)

    # Write to the per-VM variable (no cross-job lock needed - different
    # VMs use different variables and never collide).
    try {
        Set-AutomationVariable -Name $perVmName -Value $json -ErrorAction Stop
    } catch {
        $aa = Get-AutomationAccountContext
        if (-not $aa) { throw "Cannot create snapshot variable '$perVmName' - no Automation Account context." }
        New-AzAutomationVariable -ResourceGroupName $aa.ResourceGroup `
            -AutomationAccountName $aa.Name `
            -Name $perVmName -Value $json -Encrypted $false | Out-Null
    }

    # Belt-and-suspenders: re-read the per-VM variable and confirm it has
    # content before the caller proceeds to destroy anything.
    $verify = $null
    try { $verify = Get-AutomationVariable -Name $perVmName -ErrorAction Stop } catch { }
    if ([string]::IsNullOrWhiteSpace($verify)) {
        throw "Snapshot persistence verification FAILED: variable '$perVmName' is empty/missing after write. Aborting to avoid data loss."
    }
}

function Save-SnapshotToBlob {
    param(
        [Parameter(Mandatory)] [string] $StorageAccount,
        [Parameter(Mandatory)] [string] $Container,
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] $Snapshot
    )
    # Storage account is resolved across the whole subscription so the caller
    # doesn't need to know the RG.
    $sa = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $StorageAccount } | Select-Object -First 1
    if (-not $sa) { throw "Storage account '$StorageAccount' not found in current subscription." }
    $ctx = $sa.Context

    # Ensure container exists.
    $existing = Get-AzStorageContainer -Context $ctx -Name $Container -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Log "Creating snapshot backup container '$Container' in $StorageAccount..."
        New-AzStorageContainer -Context $ctx -Name $Container -Permission Off | Out-Null
    }

    $ts   = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $blob = "$VmName/$ts.json"
    $tmp  = Join-Path $env:TEMP "$VmName-$ts.json"
    ($Snapshot | ConvertTo-Json -Depth 20) | Set-Content -Path $tmp -Encoding utf8
    try {
        Set-AzStorageBlobContent -File $tmp -Container $Container -Blob $blob -Context $ctx -Force | Out-Null
        Write-Log "[$VmName] snapshot backup written to blob '$Container/$blob' in $StorageAccount."
    } finally {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Remove-PersistedSnapshot {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $VmName
    )
    $perVmName = Get-PerVmSnapshotVarName -Base $Name -VmName $VmName
    $aa = Get-AutomationAccountContext
    if ($aa) {
        try {
            Remove-AzAutomationVariable -ResourceGroupName $aa.ResourceGroup `
                -AutomationAccountName $aa.Name -Name $perVmName -ErrorAction SilentlyContinue | Out-Null
        } catch { }
    } else {
        # No AA context - blank the value so a future Stage can replace it.
        try { Set-AutomationVariable -Name $perVmName -Value '' } catch { }
    }

    # Also evict from legacy combined variable if it still carries this VM.
    Invoke-WithStateLock {
        $raw = $null
        try { $raw = Get-AutomationVariable -Name $Name -ErrorAction Stop } catch { }
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        try {
            $combined = $raw | ConvertFrom-Json -AsHashtable
            if ($combined.ContainsKey($VmName)) {
                $combined.Remove($VmName) | Out-Null
                Save-RebuildState -Name $Name -State $combined
            }
        } catch { }
    } | Out-Null
}

function Set-VmStatus {
    # Lock-aware merge-on-write of one VM's status into the shared state map.
    # Always re-reads the live state, mutates ONLY the VmName key, and writes
    # back under the cross-job mutex so concurrent Process jobs cannot clobber
    # each other's keys.
    param(
        [Parameter(Mandatory)] [string] $VmName,
        [Parameter(Mandatory)] [string] $Status,
        [string]                       $Message = ''
    )
    Invoke-WithStateLock {
        $live = Get-RebuildState -Name $StateVariableName
        $live[$VmName] = [ordered]@{
            Status      = $Status
            Message     = $Message
            LastUpdated = (Get-Date).ToUniversalTime().ToString('s')
        }
        Save-RebuildState -Name $StateVariableName -State $live
    } | Out-Null
    Write-Log "[$VmName] status=$Status $Message"

    # Marker line consumed by the 'alert-avd-vm-rebuild-failed' Azure Monitor
    # scheduled-query alert (see bicep/main.bicep). Emitted exactly once per
    # transition to Failed, so each rebuild failure produces one email.
    # Reason is sanitized to a single line for the alert payload. A 5s pause
    # ahead of the marker spaces it apart from the preceding status=Failed
    # log line so Log Analytics' burst-drop behavior at end-of-job does not
    # swallow both lines in the same ingestion window.
    if ($Status -eq 'Failed') {
        Start-Sleep -Seconds 5
        $reason = ($Message -replace "[`r`n]+", ' ').Trim()
        if ($reason.Length -gt 240) { $reason = $reason.Substring(0, 240) + '...' }
        $alertTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Write-Output "[ALERT-VMREBUILDFAILED] Hostpool=$HostpoolName VmName=$VmName Time=$alertTime Reason=$reason"
    }
}

# ============================================================================
# Cross-job mutex (AVDRebuildLock_<hostpool>) protecting state + snapshot RMW.
# ============================================================================
#
#   Azure Automation variables have no compare-and-swap. We approximate a
#   mutex with read-write-reread on a shared variable plus randomized retry
#   jitter. The lock payload is a JSON object {Holder, At}; any holder older
#   than $StaleClaimSeconds is considered dead and broken.
#
#   The lock is held for milliseconds (just long enough for one Get + one Set
#   of the state/snapshot variable), so contention windows are tiny.

function Get-CurrentJobId {
    # Inside Azure Automation, $PSPrivateMetadata.JobId is the live job's GUID.
    # When run interactively this falls back to a per-session GUID.
    try {
        if ($PSPrivateMetadata -and $PSPrivateMetadata.JobId) {
            return ([string]$PSPrivateMetadata.JobId)
        }
    } catch { }
    if (-not $script:__InteractiveLockId) {
        $script:__InteractiveLockId = "local-$([guid]::NewGuid().ToString().Substring(0,8))"
    }
    return $script:__InteractiveLockId
}

function Lock-State {
    param(
        [int] $TimeoutSeconds = 300,
        [int] $StaleSeconds   = 300
    )
    $holder   = Get-CurrentJobId
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $current = $null
        try { $current = Get-AutomationVariable -Name $LockVariableName -ErrorAction Stop } catch { }
        $canTake = $false
        if ([string]::IsNullOrWhiteSpace($current)) {
            $canTake = $true
        } else {
            try {
                $obj = $current | ConvertFrom-Json -ErrorAction Stop
                $ageSec = ((Get-Date).ToUniversalTime() - ([datetime]$obj.At).ToUniversalTime()).TotalSeconds
                if ($obj.Holder -eq $holder) {
                    # We somehow already own it (re-entry); treat as success.
                    return $true
                }
                if ($ageSec -gt $StaleSeconds) {
                    Write-Log "Lock '$LockVariableName' is stale (age $([int]$ageSec)s, holder=$($obj.Holder)) - breaking." 'WARN'
                    $canTake = $true
                }
            } catch {
                # Corrupt value - take it.
                $canTake = $true
            }
        }
        if ($canTake) {
            $payload = @{
                Holder = $holder
                At     = (Get-Date).ToUniversalTime().ToString('o')
            } | ConvertTo-Json -Compress
            try {
                Set-AutomationVariable -Name $LockVariableName -Value $payload
            } catch {
                # Variable missing - create then write.
                $aa = (Get-AzAutomationAccount | Select-Object -First 1)
                if (-not $aa) { throw "Cannot create lock variable - no Automation Account in context." }
                New-AzAutomationVariable -ResourceGroupName $aa.ResourceGroupName `
                    -AutomationAccountName $aa.AutomationAccountName `
                    -Name $LockVariableName -Value $payload -Encrypted $false | Out-Null
            }
            # Verify we actually won the race.
            Start-Sleep -Milliseconds (Get-Random -Minimum 200 -Maximum 800)
            $verify = $null
            try { $verify = Get-AutomationVariable -Name $LockVariableName -ErrorAction Stop } catch { }
            if ($verify) {
                try {
                    $verifyObj = $verify | ConvertFrom-Json -ErrorAction Stop
                    if ($verifyObj.Holder -eq $holder) { return $true }
                } catch { }
            }
            Write-Log "Lock contention on '$LockVariableName' - another job won the race. Backing off." 'WARN'
        }
        Start-Sleep -Seconds (Get-Random -Minimum 5 -Maximum 16)
    }
    throw "Timed out waiting for lock '$LockVariableName' (waited ${TimeoutSeconds}s)."
}

function Unlock-State {
    $holder = Get-CurrentJobId
    try {
        $cur = Get-AutomationVariable -Name $LockVariableName -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($cur)) {
            $obj = $cur | ConvertFrom-Json -ErrorAction Stop
            if ($obj.Holder -ne $holder) {
                Write-Log "Unlock skipped - '$LockVariableName' is now held by '$($obj.Holder)' (not us)." 'WARN'
                return
            }
        }
    } catch { }
    try { Set-AutomationVariable -Name $LockVariableName -Value '' } catch { }
}

function Invoke-WithStateLock {
    param(
        [Parameter(Mandatory)] [scriptblock] $Action,
        [int] $TimeoutSeconds = 0
    )
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = $LockWaitSeconds }
    $owned = $false
    try {
        $owned = Lock-State -TimeoutSeconds $TimeoutSeconds
        & $Action
    } finally {
        if ($owned) { Unlock-State }
    }
}

# ============================================================================
# Process job dispatch + eligibility helpers (used by Stage parallel spawn
# and by Process successor-on-exit chaining).
# ============================================================================

function Start-ProcessJob {
    # Starts ONE Process child runbook with the same parameters this job was
    # invoked with, plus the supplied SuccessorDepth. Returns the started job
    # object. Each spawned job runs in its own Automation sandbox with its
    # own independent 3-hour fair-share budget - spawning a child does NOT
    # extend the parent job's runtime.
    param(
        [int] $SuccessorDepth = 0
    )
    $aa = Get-AutomationAccountContext
    if (-not $aa) {
        throw "Cannot start Process job - AutomationAccount context is not resolvable. Pass -AutomationAccountResourceGroup/-AutomationAccountName."
    }
    $procParams = @{
        HostpoolName                   = $HostpoolName
        HostpoolRG                     = $HostpoolRG
        Location                       = $Location
        SubscriptionId                 = $SubscriptionId
        DomainName                     = $DomainName
        DomainJoinUserName             = $DomainJoinUserName
        DomainJoinPasswordSecretName   = $DomainJoinPasswordSecretName
        VmAdminUserName                = $VmAdminUserName
        VmAdminPasswordSecretName      = $VmAdminPasswordSecretName
        KeyVaultName                   = $KeyVaultName
        KeyVaultRG                     = $KeyVaultRG
        ImageGalleryName               = $ImageGalleryName
        ImageGalleryRG                 = $ImageGalleryRG
        ImageDefinitionName            = $ImageDefinitionName
        ImageVersionName               = $ImageVersionName
        Mode                           = 'Process'
        MaxParallelProcessJobs         = $MaxParallelProcessJobs
        MaxSuccessorChainDepth         = $MaxSuccessorChainDepth
        SuccessorDepth                 = $SuccessorDepth
        AutomationAccountResourceGroup = $aa.ResourceGroup
        AutomationAccountName          = $aa.Name
    }
    return Start-AzAutomationRunbook -ResourceGroupName $aa.ResourceGroup `
        -AutomationAccountName $aa.Name `
        -Name 'Recreate-AVDSessionHosts' -Parameters $procParams
}

function Test-EligibleWorkExists {
    # Returns $true if at least one VM in the live state map is eligible for
    # a Process job to claim: Status in {Pending, AwaitingUsers}, or Status
    # Failed older than FailureRetryMinutes. Uses the live state, not a
    # cached copy, so successor-spawn decisions reflect reality.
    $live = Get-RebuildState -Name $StateVariableName
    $now  = (Get-Date).ToUniversalTime()
    foreach ($entry in $live.GetEnumerator()) {
        $s = $entry.Value.Status
        if ($s -in @('Pending','AwaitingUsers')) { return $true }
        if ($s -eq 'Failed') {
            $age = $null
            try { $age = ($now - ([datetime]$entry.Value.LastUpdated).ToUniversalTime()).TotalMinutes } catch { }
            if ($null -ne $age -and $age -ge $FailureRetryMinutes) { return $true }
        }
    }
    return $false
}

#endregion --------------------------------------------------------- helpers --

#region ------------------------------------------------------ capture / build

function Get-VmSnapshot {
    param([Parameter(Mandatory)] $Vm)

    $nics = @()
    foreach ($nicRef in $Vm.NetworkProfile.NetworkInterfaces) {
        $nic = Get-AzNetworkInterface -ResourceId $nicRef.Id
        $ipConfigs = @()
        if ($nic.IpConfigurations) {
            foreach ($ipc in $nic.IpConfigurations) {
                $ipConfigs += [pscustomobject]@{
                    Name                      = $ipc.Name
                    Primary                   = (Get-SafeProperty $ipc 'Primary')
                    SubnetId                  = (Get-SafeProperty $ipc 'Subnet.Id')
                    PrivateIpAddress          = (Get-SafeProperty $ipc 'PrivateIpAddress')
                    PrivateIpAllocationMethod = (Get-SafeProperty $ipc 'PrivateIpAllocationMethod')
                    PrivateIpAddressVersion   = (Get-SafeProperty $ipc 'PrivateIpAddressVersion')
                    PublicIpAddressId         = (Get-SafeProperty $ipc 'PublicIpAddress.Id')
                }
            }
        } else {
            Write-Log "[$($Vm.Name)] NIC '$($nic.Name)' has no IP configurations - snapshot will store empty IpConfigs." 'WARN'
        }
        $nics += [pscustomobject]@{
            Id             = $nic.Id
            Name           = $nic.Name
            Rg             = $nic.ResourceGroupName
            Location       = $nic.Location
            Primary        = (Get-SafeProperty $nicRef 'Primary')
            IpConfigs      = $ipConfigs
            DnsServers     = (Get-SafeProperty $nic 'DnsSettings.DnsServers')
            NsgId          = (Get-SafeProperty $nic 'NetworkSecurityGroup.Id')
            EnableAccelNet = (Get-SafeProperty $nic 'EnableAcceleratedNetworking')
            Tags           = (Get-SafeProperty $nic 'Tag')
        }
    }

    # Capture extensions (we'll skip the JsonADDomainExtension + DSC since the
    # runbook re-applies them deterministically; everything else - especially
    # AzureMonitorWindowsAgent / MicrosoftMonitoringAgent / DependencyAgent -
    # is preserved).
    $extensions = @()
    foreach ($ext in (Get-AzVMExtension -ResourceGroupName $Vm.ResourceGroupName -VMName $Vm.Name -ErrorAction SilentlyContinue)) {
        $extensions += [pscustomobject]@{
            Name               = $ext.Name
            Publisher          = $ext.Publisher
            Type               = $ext.ExtensionType
            TypeHandlerVersion = $ext.TypeHandlerVersion
            AutoUpgradeMinor   = (Get-SafeProperty $ext 'AutoUpgradeMinorVersion')
            Settings           = (Get-SafeProperty $ext 'PublicSettings')
            ProtectedSettings  = $null   # cannot be read back
        }
    }

    # Data Collection Rule associations on the VM resource.
    $dcra = @()
    try {
        $dcra = Get-AzDataCollectionRuleAssociation -ResourceUri $Vm.Id -ErrorAction Stop |
                Select-Object Name, DataCollectionRuleId, DataCollectionEndpointId
    } catch {
        Write-Log "[$($Vm.Name)] No DCR associations or unable to read: $($_.Exception.Message)" 'WARN'
    }

    return [pscustomobject]@{
        Name              = $Vm.Name
        Rg                = $Vm.ResourceGroupName
        Location          = $Vm.Location
        Size              = $Vm.HardwareProfile.VmSize
        Zones             = (Get-SafeProperty $Vm 'Zones')
        LicenseType       = (Get-SafeProperty $Vm 'LicenseType')
        Identity          = (Get-SafeProperty $Vm 'Identity')
        Tags              = (Get-SafeProperty $Vm 'Tags')
        ComputerName      = $Vm.OSProfile.ComputerName
        AdminUsername     = $Vm.OSProfile.AdminUsername
        OsDiskName        = $Vm.StorageProfile.OsDisk.Name
        OsDiskSku         = (Get-SafeProperty $Vm 'StorageProfile.OsDisk.ManagedDisk.StorageAccountType')
        OsDiskSizeGb      = (Get-SafeProperty $Vm 'StorageProfile.OsDisk.DiskSizeGB')
        OsDiskCaching     = (Get-SafeProperty $Vm 'StorageProfile.OsDisk.Caching')
        AvailabilitySetId = (Get-SafeProperty $Vm 'AvailabilitySetReference.Id')
        SecurityProfile   = (Get-SafeProperty $Vm 'SecurityProfile')
        DiagnosticsProfile = (Get-SafeProperty $Vm 'DiagnosticsProfile')
        Nics              = $nics
        Extensions        = $extensions
        DcrAssociations   = $dcra
    }
}

function Wait-ForNoActiveSessions {
    param(
        [string] $SessionHostName,
        [int]    $TimeoutMinutes
    )

    if ($SkipIfUsersActive) {
        $sh = Get-AzWvdSessionHost -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -Name $SessionHostName
        return (($sh.Session -as [int]) -le 0 -and -not (Get-ActiveSessions $SessionHostName))
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-ActiveSessions $SessionHostName)) { return $true }
        Write-Log "[$SessionHostName] active sessions detected - sleeping 2 minutes..."
        Start-Sleep -Seconds 120
    }
    return $false
}

function Get-ActiveSessions {
    param([string] $SessionHostName)
    $sessions = Get-AzWvdUserSession -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -SessionHostName $SessionHostName -ErrorAction SilentlyContinue
    return @($sessions | Where-Object { $_.SessionState -eq 'Active' })
}

function Disconnect-IdleSessions {
    param([string] $SessionHostName)
    $sessions = Get-AzWvdUserSession -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -SessionHostName $SessionHostName -ErrorAction SilentlyContinue
    foreach ($s in $sessions) {
        $id = ($s.Name -split '/')[-1]
        Write-Log "[$SessionHostName] logging off $($s.UserPrincipalName) (state=$($s.SessionState))"
        try {
            Remove-AzWvdUserSession -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -SessionHostName $SessionHostName -Id $id -Force
        } catch {
            Write-Log "[$SessionHostName] failed to log off session $id : $($_.Exception.Message)" 'WARN'
        }
    }
}

function Set-DrainMode {
    param(
        [string] $SessionHostName,
        [bool]   $Drain
    )
    $allow = -not $Drain
    Update-AzWvdSessionHost -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$allow | Out-Null
    Write-Log "[$SessionHostName] AllowNewSession=$allow (drain=$Drain)"
}

function Remove-VmKeepNic {
    param([Parameter(Mandatory)] $Snapshot)

    $vm = Get-AzVM -ResourceGroupName $Snapshot.Rg -Name $Snapshot.Name -ErrorAction SilentlyContinue
    if ($vm) {
        Write-Log "[$($Snapshot.Name)] removing VM..."
        Remove-AzVM -ResourceGroupName $Snapshot.Rg -Name $Snapshot.Name -Force | Out-Null
    }

    # Old OS disk - delete so the new VM can use the same name pattern.
    $disk = Get-AzDisk -ResourceGroupName $Snapshot.Rg -DiskName $Snapshot.OsDiskName -ErrorAction SilentlyContinue
    if ($disk) {
        Write-Log "[$($Snapshot.Name)] removing OS disk $($Snapshot.OsDiskName)..."
        Remove-AzDisk -ResourceGroupName $Snapshot.Rg -DiskName $Snapshot.OsDiskName -Force | Out-Null
    }
}

function New-SessionHostVm {
    param([Parameter(Mandatory)] $Snapshot)

    $vmName = $Snapshot.Name
    Write-Log "[$vmName] building new VM via REST..."

    # Ensure every NIC exists (recreate from snapshot if missing).
    $nicRefs = @()
    foreach ($nicSnap in $Snapshot.Nics) {
        $nicObj = Get-AzNetworkInterface -ResourceGroupName $nicSnap.Rg -Name $nicSnap.Name -ErrorAction SilentlyContinue
        if (-not $nicObj) {
            Write-Log "[$vmName] NIC '$($nicSnap.Name)' missing - recreating from snapshot..."
            $nicObj = New-NicFromSnapshot -NicSnap $nicSnap
        }
        $nicRefs += @{
            id         = $nicObj.Id
            properties = @{ primary = [bool]$nicSnap.Primary }
        }
    }

    $subId = (Get-AzContext).Subscription.Id
    $imageDefId = "/subscriptions/$subId/resourceGroups/$ImageGalleryRG/providers/Microsoft.Compute/galleries/$ImageGalleryName/images/$ImageDefinitionName"
    if (-not $ImageVersionName -or $ImageVersionName -eq 'latest') {
        $imageRef = @{ id = $imageDefId }
    } else {
        $imageRef = @{ id = "$imageDefId/versions/$ImageVersionName" }
    }

    # Local administrator credentials. The username comes from the parameter
    # (falls back to whatever was on the snapshot if the param was left empty).
    # The password is read from Key Vault on every rebuild so the secret can be
    # rotated without redeploying the runbook.
    $adminUser = if ($VmAdminUserName) { $VmAdminUserName } else { $Snapshot.AdminUsername }
    Write-Log "[$vmName] reading local admin password from Key Vault secret '$VmAdminPasswordSecretName'..."
    $adminPwd  = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $VmAdminPasswordSecretName -AsPlainText
    if ([string]::IsNullOrWhiteSpace($adminPwd)) {
        throw "Key Vault secret '$VmAdminPasswordSecretName' in vault '$KeyVaultName' is empty or missing."
    }

    $vmProperties = @{
        hardwareProfile = @{ vmSize = $Snapshot.Size }
        storageProfile  = @{
            imageReference = $imageRef
            osDisk         = @{
                name         = $Snapshot.OsDiskName
                caching      = "$($Snapshot.OsDiskCaching)"
                createOption = 'FromImage'
                managedDisk  = @{ storageAccountType = "$($Snapshot.OsDiskSku)" }
            }
        }
        osProfile = @{
            computerName  = $Snapshot.ComputerName
            adminUsername = $adminUser
            adminPassword = $adminPwd
            windowsConfiguration = @{
                provisionVMAgent       = $true
                enableAutomaticUpdates = $true
            }
            allowExtensionOperations = $true
        }
        networkProfile = @{ networkInterfaces = $nicRefs }
        diagnosticsProfile = @{ bootDiagnostics = @{ enabled = $false } }
    }

    if ($Snapshot.LicenseType)       { $vmProperties.licenseType = "$($Snapshot.LicenseType)" }
    if ($Snapshot.AvailabilitySetId) { $vmProperties.availabilitySet = @{ id = $Snapshot.AvailabilitySetId } }
    if ($Snapshot.SecurityProfile) {
        $secType = (Get-SafeProperty $Snapshot.SecurityProfile 'SecurityType')
        if ($secType) {
            $vmProperties.securityProfile = @{
                securityType = "$secType"
                uefiSettings = @{
                    secureBootEnabled = [bool](Get-SafeProperty $Snapshot.SecurityProfile 'UefiSettings.SecureBootEnabled')
                    vTpmEnabled       = [bool](Get-SafeProperty $Snapshot.SecurityProfile 'UefiSettings.VTpmEnabled')
                }
            }
        }
    }

    $vmBody = @{
        location   = $Snapshot.Location
        properties = $vmProperties
    }

    # Always stamp the VM with the last auto-rebuild timestamp (UTC, ISO-8601),
    # merging with any tags preserved from the snapshot.
    $rebuildTimestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $mergedTags = @{}
    if ($Snapshot.Tags) {
        if ($Snapshot.Tags -is [System.Collections.IDictionary]) {
            foreach ($k in $Snapshot.Tags.Keys) { $mergedTags[$k] = "$($Snapshot.Tags[$k])" }
        } else {
            foreach ($p in $Snapshot.Tags.PSObject.Properties) { $mergedTags[$p.Name] = "$($p.Value)" }
        }
    }
    # The new VM is a brand-new install and starts with drain ON. Strip any
    # drain-related marker carried over from the snapshot so the companion
    # Disable-DrainAfterAge runbook will (after the age threshold) re-evaluate
    # this host, disable drain once, and re-stamp the tag. Without this purge
    # the marker tag survives the rebuild and DrainAfterAge skips the VM
    # forever (treating it as "already handled").
    foreach ($staleTag in @('AVDDrainAutoDisabled')) {
        if ($mergedTags.ContainsKey($staleTag)) {
            Write-Log "[$vmName] clearing stale tag '$staleTag' from snapshot so post-rebuild runbooks can re-evaluate."
            $mergedTags.Remove($staleTag) | Out-Null
        }
    }
    $mergedTags['AVDLastRebuildUtc'] = $rebuildTimestamp
    $vmBody.tags = $mergedTags
    if ($Snapshot.Zones) {
        $zonesArr = @($Snapshot.Zones)
        if ($zonesArr.Count -gt 0) { $vmBody.zones = $zonesArr }
    }
    # AVD session hosts need a managed identity so the Azure Monitor Agent
    # (and other extensions like MDE) can authenticate to the DCR / LAW used
    # by AVD Insights. If the snapshot has no identity recorded (e.g. a
    # previous rebuild dropped it, leaving AVD Insights blind), default to
    # SystemAssigned so the rebuilt VM is self-healing instead of perpetuating
    # the missing-identity state.
    $idType = $null
    if ($Snapshot.Identity -and $Snapshot.Identity.Type) {
        $idType = "$($Snapshot.Identity.Type)"
    }
    if (-not $idType -or $idType -eq 'None') {
        $idType = 'SystemAssigned'
        Write-Log "[$vmName] Snapshot had no managed identity; defaulting to SystemAssigned so AMA / AVD Insights can authenticate."
    }
    $idBlock = @{ type = $idType }
    if ($idType -match 'UserAssigned' -and $Snapshot.Identity -and (Get-SafeProperty $Snapshot.Identity 'UserAssignedIdentities')) {
        $uaMap = @{}
        foreach ($k in $Snapshot.Identity.UserAssignedIdentities.Keys) { $uaMap[$k] = @{} }
        $idBlock.userAssignedIdentities = $uaMap
    }
    $vmBody.identity = $idBlock

    $jsonBody = $vmBody | ConvertTo-Json -Depth 20
    $jsonForLog = $jsonBody -replace '("adminPassword"\s*:\s*)"[^"]*"', '$1"<redacted>"'
    Write-Log "[$vmName] PUT VM body (truncated): $($jsonForLog.Substring(0, [Math]::Min(2500, $jsonForLog.Length)))"

    $apiVersion = '2024-03-01'
    $path = "/subscriptions/$subId/resourceGroups/$($Snapshot.Rg)/providers/Microsoft.Compute/virtualMachines/$vmName" + "?api-version=$apiVersion"
    Write-Log "[$vmName] PUT $path"

    $resp = Invoke-AzRestMethod -Method PUT -Path $path -Payload $jsonBody
    if ($resp.StatusCode -ge 400) {
        Write-Log "[$vmName] PUT failed: HTTP $($resp.StatusCode)  $($resp.Content)" 'ERROR'
        throw "VM PUT returned HTTP $($resp.StatusCode): $($resp.Content)"
    }
    Write-Log "[$vmName] PUT accepted (HTTP $($resp.StatusCode)). Polling provisioning..."

    # Poll provisioningState until succeeded/failed/timeout (~15 min).
    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        $getResp = Invoke-AzRestMethod -Method GET -Path ("/subscriptions/$subId/resourceGroups/$($Snapshot.Rg)/providers/Microsoft.Compute/virtualMachines/$vmName" + "?api-version=$apiVersion")
        if ($getResp.StatusCode -ge 400) {
            throw "VM GET returned HTTP $($getResp.StatusCode): $($getResp.Content)"
        }
        $obj = $getResp.Content | ConvertFrom-Json
        $ps = $obj.properties.provisioningState
        Write-Log "[$vmName] provisioningState=$ps"
        if ($ps -eq 'Succeeded') { Write-Log "[$vmName] VM created."; return }
        if ($ps -eq 'Failed') { throw "VM provisioning failed." }
    }
    throw "VM provisioning timed out."
}

function New-NicFromSnapshot {
    param([Parameter(Mandatory)] $NicSnap)

    if (-not $NicSnap.IpConfigs -or $NicSnap.IpConfigs.Count -eq 0) {
        throw "Cannot recreate NIC '$($NicSnap.Name)' - snapshot has no IP configurations."
    }

    $ipConfigObjs = @()
    foreach ($ipc in $NicSnap.IpConfigs) {
        $ipParams = @{
            Name     = $ipc.Name
            SubnetId = $ipc.SubnetId
        }
        if ($ipc.PrivateIpAddress -and $ipc.PrivateIpAllocationMethod -eq 'Static') {
            $ipParams.PrivateIpAddress = $ipc.PrivateIpAddress
        }
        if ($ipc.Primary) { $ipParams.Primary = $true }
        $ipConfigObjs += New-AzNetworkInterfaceIpConfig @ipParams
    }

    $nicParams = @{
        Name                       = $NicSnap.Name
        ResourceGroupName          = $NicSnap.Rg
        Location                   = $NicSnap.Location
        IpConfiguration            = $ipConfigObjs
        EnableAcceleratedNetworking = [bool]$NicSnap.EnableAccelNet
        Force                      = $true
    }
    if ($NicSnap.NsgId) { $nicParams.NetworkSecurityGroupId = $NicSnap.NsgId }
    if ($NicSnap.Tags)  { $nicParams.Tag = $NicSnap.Tags }

    $nic = New-AzNetworkInterface @nicParams

    if ($NicSnap.DnsServers -and $NicSnap.DnsServers.Count -gt 0) {
        foreach ($dns in $NicSnap.DnsServers) {
            $nic.DnsSettings.DnsServers.Add($dns) | Out-Null
        }
        $nic = Set-AzNetworkInterface -NetworkInterface $nic
    }
    return $nic
}

function Set-VmExtensionViaRest {
    param(
        [Parameter(Mandatory)] [string]   $VmRg,
        [Parameter(Mandatory)] [string]   $VmName,
        [Parameter(Mandatory)] [string]   $Location,
        [Parameter(Mandatory)] [string]   $ExtensionName,
        [Parameter(Mandatory)] [string]   $Publisher,
        [Parameter(Mandatory)] [string]   $Type,
        [Parameter(Mandatory)] [string]   $TypeHandlerVersion,
        [hashtable]                       $Settings,
        [hashtable]                       $ProtectedSettings,
        [string]                          $ApiVersion = '2024-03-01',
        [int]                             $TimeoutMin = 20
    )

    $subId = (Get-AzContext).Subscription.Id
    $body = @{
        location   = $Location
        properties = @{
            publisher               = $Publisher
            type                    = $Type
            typeHandlerVersion      = $TypeHandlerVersion
            autoUpgradeMinorVersion = $true
        }
    }
    if ($Settings)          { $body.properties.settings          = $Settings }
    if ($ProtectedSettings) { $body.properties.protectedSettings = $ProtectedSettings }

    $jsonBody = $body | ConvertTo-Json -Depth 10
    $path = "/subscriptions/$subId/resourceGroups/$VmRg/providers/Microsoft.Compute/virtualMachines/$VmName/extensions/$ExtensionName" + "?api-version=$ApiVersion"

    # Log a redacted version (no protected settings; sensitive keys in
    # settings are scrubbed too) for diagnostics.
    $logSettings = $null
    if ($Settings) {
        $logSettings = @{}
        foreach ($k in $Settings.Keys) {
            if ($k -match '(?i)token|password|secret|credential|key$|sastoken') {
                $logSettings[$k] = '<redacted>'
            } else {
                $logSettings[$k] = $Settings[$k]
            }
        }
    }
    $logBody = @{
        location   = $Location
        properties = @{
            publisher               = $Publisher
            type                    = $Type
            typeHandlerVersion      = $TypeHandlerVersion
            autoUpgradeMinorVersion = $true
            settings                = $logSettings
        }
    }
    if ($ProtectedSettings) { $logBody.properties.protectedSettings = '<redacted>' }
    Write-Log "[$VmName] PUT extension '$ExtensionName' ($Publisher/$Type) body: $(($logBody | ConvertTo-Json -Depth 8 -Compress))"

    $resp = Invoke-AzRestMethod -Method PUT -Path $path -Payload $jsonBody
    if ($resp.StatusCode -ge 400) {
        throw "Extension PUT '$ExtensionName' returned HTTP $($resp.StatusCode): $($resp.Content)"
    }

    # Poll provisioningState until succeeded/failed/timeout.
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        $getResp = Invoke-AzRestMethod -Method GET -Path $path
        if ($getResp.StatusCode -ge 400) {
            throw "Extension GET '$ExtensionName' returned HTTP $($getResp.StatusCode): $($getResp.Content)"
        }
        $obj = $getResp.Content | ConvertFrom-Json
        $ps = (Get-SafeProperty $obj 'properties.provisioningState')
        Write-Log "[$VmName] extension '$ExtensionName' provisioningState=$ps"
        if ($ps -eq 'Succeeded') { return }
        if ($ps -eq 'Failed') {
            $statuses = (Get-SafeProperty $obj 'properties.instanceView.statuses')
            $detail = if ($statuses) { ($statuses | ConvertTo-Json -Depth 5 -Compress) } else { '' }
            throw "Extension '$ExtensionName' provisioning failed. Details: $detail"
        }
    }
    throw "Extension '$ExtensionName' provisioning timed out."
}

function Join-VmToDomain {
    param([Parameter(Mandatory)] $Snapshot)

    Write-Log "[$($Snapshot.Name)] reading domain-join password from Key Vault..."
    $pwdSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $DomainJoinPasswordSecretName -AsPlainText

    $settings = @{
        Name    = $DomainName
        User    = $DomainJoinUserName
        Restart = 'true'
        Options = 3
    }
    if ($DomainJoinOUPath) { $settings.OUPath = $DomainJoinOUPath }
    $protected = @{ Password = $pwdSecret }

    Write-Log "[$($Snapshot.Name)] applying JsonADDomainExtension via REST..."
    Set-VmExtensionViaRest `
        -VmRg              $Snapshot.Rg `
        -VmName            $Snapshot.Name `
        -Location          $Snapshot.Location `
        -ExtensionName     'DomainJoin' `
        -Publisher         'Microsoft.Compute' `
        -Type              'JsonADDomainExtension' `
        -TypeHandlerVersion '1.3' `
        -Settings          $settings `
        -ProtectedSettings $protected
}

function Register-WithHostPool {
    param([Parameter(Mandatory)] $Snapshot)

    # A host pool only ever has ONE active registration token. Calling
    # New-AzWvdRegistrationInfo overwrites the existing one, which would
    # invalidate tokens already handed to other in-flight DSC extensions
    # running in parallel sibling jobs. Instead, reuse the current token
    # if it has comfortable lifetime left (>= 30 min); only mint a new
    # one (4-hour TTL, plenty for several VMs to register sequentially)
    # when no token exists or the existing one is near expiry.
    $minRemaining = [TimeSpan]::FromMinutes(30)
    $newTtl       = [TimeSpan]::FromHours(4)

    $existing = $null
    try {
        $existing = Get-AzWvdRegistrationInfo -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -ErrorAction Stop
    } catch {
        Write-Log "[$($Snapshot.Name)] no existing registration info readable ($($_.Exception.Message)); a new token will be created."
    }

    $token = $null
    if ($existing -and $existing.Token -and $existing.ExpirationTime) {
        $remaining = ([DateTime]$existing.ExpirationTime).ToUniversalTime() - [DateTime]::UtcNow
        if ($remaining -ge $minRemaining) {
            Write-Log ("[{0}] reusing existing host pool registration token (expires in {1:hh\:mm\:ss})." -f $Snapshot.Name, $remaining)
            $token = $existing.Token
        } else {
            Write-Log ("[{0}] existing registration token expires in {1:hh\:mm\:ss} (< 30m); minting new {2}h token." -f $Snapshot.Name, $remaining, $newTtl.TotalHours)
        }
    } else {
        Write-Log "[$($Snapshot.Name)] no existing registration token found; minting new $($newTtl.TotalHours)h token."
    }

    if (-not $token) {
        $token = (New-AzWvdRegistrationInfo -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -ExpirationTime (Get-Date).Add($newTtl).ToUniversalTime()).Token
    }

    # NOTE: RegistrationInfoToken is treated as a secret and goes into
    # protectedSettings (encrypted on the wire and never persisted in the
    # VM extension status / Azure Automation job logs).  The DSC extension
    # merges properties from both settings and protectedSettings before
    # invoking the configuration, so AddSessionHost still receives all four
    # values (HostPoolName, AadJoin, UseAgentDownloadEndpoint, and the token).
    $dscSettings = @{
        modulesUrl            = $AvdAgentDscUrl
        configurationFunction = 'Configuration.ps1\AddSessionHost'
        properties            = @{
            HostPoolName             = $HostpoolName
            AadJoin                  = $false
            UseAgentDownloadEndpoint = $true
        }
    }
    $dscProtectedSettings = @{
        properties = @{
            RegistrationInfoToken = $token
        }
    }

    Write-Log "[$($Snapshot.Name)] applying AVD DSC extension via REST..."
    Set-VmExtensionViaRest `
        -VmRg              $Snapshot.Rg `
        -VmName            $Snapshot.Name `
        -Location          $Snapshot.Location `
        -ExtensionName     'Microsoft.PowerShell.DSC' `
        -Publisher         'Microsoft.Powershell' `
        -Type              'DSC' `
        -TypeHandlerVersion '2.73' `
        -Settings          $dscSettings `
        -ProtectedSettings $dscProtectedSettings `
        -TimeoutMin        30
}

function Restore-Extensions {
    param([Parameter(Mandatory)] $Snapshot)

    $skip = @('JsonADDomainExtension', 'DSC', 'AADLoginForWindows')
    foreach ($ext in $Snapshot.Extensions) {
        if ($skip -contains $ext.Type) { continue }
        Write-Log "[$($Snapshot.Name)] re-applying extension $($ext.Name) ($($ext.Publisher)/$($ext.Type)) via REST..."
        try {
            $settingsHt = $null
            if ($ext.Settings) {
                # $ext.Settings may be a PSObject or an OrderedDictionary depending on
                # whether the snapshot is in-memory or freshly deserialized. Coerce
                # to a plain hashtable for ConvertTo-Json safety.
                $settingsHt = @{}
                if ($ext.Settings -is [System.Collections.IDictionary]) {
                    foreach ($k in $ext.Settings.Keys) { $settingsHt[$k] = $ext.Settings[$k] }
                } else {
                    foreach ($p in $ext.Settings.PSObject.Properties) { $settingsHt[$p.Name] = $p.Value }
                }
            }
            Set-VmExtensionViaRest `
                -VmRg              $Snapshot.Rg `
                -VmName            $Snapshot.Name `
                -Location          $Snapshot.Location `
                -ExtensionName     $ext.Name `
                -Publisher         $ext.Publisher `
                -Type              $ext.Type `
                -TypeHandlerVersion $ext.TypeHandlerVersion `
                -Settings          $settingsHt
        } catch {
            Write-Log "[$($Snapshot.Name)] failed to re-apply $($ext.Name): $($_.Exception.Message)" 'WARN'
        }
    }
}

function Restore-DcrAssociations {
    param([Parameter(Mandatory)] $Snapshot)

    if (-not $Snapshot.DcrAssociations) { return }
    $newVm = Get-AzVM -ResourceGroupName $Snapshot.Rg -Name $Snapshot.Name -ErrorAction SilentlyContinue
    if (-not $newVm) {
        Write-Log "[$($Snapshot.Name)] VM not found after rebuild - DCR restore skipped." 'WARN'
        return
    }
    foreach ($a in $Snapshot.DcrAssociations) {
        Write-Log "[$($Snapshot.Name)] re-associating DCR $($a.Name)..."
        try {
            $params = @{
                TargetResourceId        = $newVm.Id
                AssociationName         = $a.Name
            }
            if ($a.DataCollectionRuleId)     { $params.RuleId     = $a.DataCollectionRuleId }
            if ($a.DataCollectionEndpointId) { $params.EndpointId = $a.DataCollectionEndpointId }
            New-AzDataCollectionRuleAssociation @params | Out-Null
        } catch {
            Write-Log "[$($Snapshot.Name)] failed to re-associate DCR $($a.Name): $($_.Exception.Message)" 'WARN'
        }
    }
}

#endregion ----------------------------------------------- capture / build ----

#region ------------------------------------------------------ per-VM rebuild

function Invoke-VmRebuild {
    # Performs the full rebuild of a single VM end-to-end.  Called by the
    # Process-mode loop AFTER the VM has been atomically claimed under the
    # state lock (Status='Claimed').  All status transitions inside this
    # function use Set-VmStatus, which performs lock-protected merge-on-write,
    # so multiple Invoke-VmRebuild invocations in parallel jobs never clobber
    # one another's keys in the shared state map.
    #
    # Sets $script:__LastRebuildCompleted to $true iff this call drove the VM
    # to Status='Completed'. Early-exit paths (AwaitingUsers, missing VM with
    # no snapshot) leave it $false so the successor-spawn progress gate is
    # never satisfied by non-productive work. This is a script-scope flag
    # rather than a pipeline return so we don't accidentally emit $true into
    # the runbook output stream.
    param([Parameter(Mandatory)] [string] $VmName)
    Set-Variable -Name '__LastRebuildCompleted' -Scope Script -Value $false

    $sh = Get-AzWvdSessionHost -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -ErrorAction SilentlyContinue |
          Where-Object { ($_.Name -split '/')[-1].Split('.')[0] -eq $VmName } | Select-Object -First 1

    $persistedSnapshot = Get-PersistedSnapshot -Base $SnapshotVariableName -VmName $VmName

    # If there's no session host registration AND no persisted snapshot, check
    # whether an orphan VM exists in the host pool RG with this name (the
    # VM was rebuilt successfully but never registered with AVD - the bug
    # this runbook recovers from). If so we can still rebuild it by
    # snapshotting the live VM fresh.
    if (-not $sh -and -not $persistedSnapshot) {
        $orphanVm = Get-AzVM -ResourceGroupName $HostpoolRG -Name $VmName -ErrorAction SilentlyContinue
        if (-not $orphanVm) {
            Set-VmStatus -VmName $VmName -Status 'Failed' -Message 'Not in host pool, no persisted snapshot, and no VM resource in host pool RG'
            return
        }
        Write-Log "[$VmName] No session host registration and no persisted snapshot, but VM resource exists in '$HostpoolRG'. Treating as orphan and rebuilding from live VM."
    }

    $sessionHostName = if ($sh) { ($sh.Name -split '/')[-1] } else { $null }

    # ----- 1. drain + wait for sessions (only if session host registration still exists) -----
    if ($sh) {
        try {
            Set-DrainMode -SessionHostName $sessionHostName -Drain $true
        } catch {
            # 404 is expected if the session host vanished between enumeration
            # and the drain call (e.g., a parallel job already deleted it, or
            # the AVD agent garbage-collected an orphaned registration).
            if ("$($_.Exception.Message)" -match '404' -or "$($_.Exception.Message)" -match 'SessionHost does not exist') {
                Write-Log "[$VmName] Session host '$sessionHostName' disappeared before drain (404). Continuing from persisted snapshot." 'WARN'
                $sh = $null
                $sessionHostName = $null
            } else {
                throw
            }
        }

        if ($sh -and -not (Wait-ForNoActiveSessions -SessionHostName $sessionHostName -TimeoutMinutes $WaitMinutes)) {
            Set-VmStatus -VmName $VmName -Status 'AwaitingUsers' -Message 'Active sessions present'
            return
        }
        if ($sh) { Disconnect-IdleSessions -SessionHostName $sessionHostName }
    } else {
        Write-Log "[$VmName] Session host registration is missing - resuming rebuild from persisted snapshot."
    }

    # ----- 2. find the underlying VM (may be missing if a prior run deleted it) -----
    # Az.Compute 7.1.1 in the Automation PowerShell 7.2 runtime has been
    # observed to return $null from Get-AzVM -ResourceId even for VMs that
    # clearly exist. Parse the ResourceId and use the -ResourceGroupName /
    # -Name overload, which is reliable.
    $vmResourceId = if ($sh) { (Get-SafeProperty $sh 'ResourceId') } else { $null }
    $vm = $null
    if ($vmResourceId) {
        if ($vmResourceId -match '/resourceGroups/([^/]+)/providers/Microsoft\.Compute/virtualMachines/([^/]+)$') {
            $vmRg    = $Matches[1]
            $vmName2 = $Matches[2]
            $vm = Get-AzVM -ResourceGroupName $vmRg -Name $vmName2 -ErrorAction SilentlyContinue
            if (-not $vm) {
                Write-Log "[$VmName] Get-AzVM returned null for $vmResourceId (will fall back to persisted snapshot if any)."
            }
        } else {
            Write-Log "[$VmName] Could not parse VM ResourceId '$vmResourceId'." 'WARN'
        }
    } elseif (-not $persistedSnapshot) {
        # Orphan path: no session host, no snapshot, but we already verified
        # above that a VM resource exists in $HostpoolRG by the same name.
        $vm = Get-AzVM -ResourceGroupName $HostpoolRG -Name $VmName -ErrorAction SilentlyContinue
        if ($vm) { Write-Log "[$VmName] Orphan VM resolved at $($vm.Id)." }
    }

    if ($vm) {
        Set-VmStatus -VmName $VmName -Status 'Capturing' -Message 'Snapshotting config'
        $snapshot = Get-VmSnapshot -Vm $vm

        # ---- snapshot durability: 3 layers of protection BEFORE delete ----
        # 1) Automation variable (primary; used to resume failed rebuilds).
        Save-PersistedSnapshot -Name $SnapshotVariableName -VmName $VmName -Snapshot $snapshot
        Write-Log "[$VmName] snapshot persisted to Automation variable '$SnapshotVariableName' (verified)."

        # 2) Echo full snapshot JSON to job output - survives in Automation
        #    job history for the retention window even if the variable is
        #    later overwritten or deleted.
        $snapJson = $snapshot | ConvertTo-Json -Depth 20
        Write-Output "===== SNAPSHOT_BEGIN $VmName =====`n$snapJson`n===== SNAPSHOT_END $VmName ====="

        # 3) Optional blob backup for long-term archive.
        if ($SnapshotBackupStorageAccount) {
            try {
                Save-SnapshotToBlob -StorageAccount $SnapshotBackupStorageAccount `
                                    -Container     $SnapshotBackupContainer `
                                    -VmName        $VmName `
                                    -Snapshot      $snapshot
            } catch {
                # Blob backup is best-effort - we already have the primary +
                # job-output copies, so a failure here shouldn't block the
                # rebuild. Log loudly and continue.
                Write-Log "[$VmName] WARN: snapshot blob backup failed: $($_.Exception.Message)" 'WARN'
            }
        }
    }
    elseif ($persistedSnapshot) {
        Write-Log "[$VmName] VM not found - resuming from persisted snapshot."
        $snapshot = $persistedSnapshot
    }
    else {
        Set-VmStatus -VmName $VmName -Status 'Failed' -Message 'VM is missing and no persisted snapshot exists'
        return
    }

    # ----- 3. remove old session host registration + VM (only if still present) -----
    Set-VmStatus -VmName $VmName -Status 'Deleting' -Message ''
    if ($sh) {
        Remove-AzWvdSessionHost -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -Name $sessionHostName -Force -ErrorAction SilentlyContinue | Out-Null
    }
    if ($vm) { Remove-VmKeepNic -Snapshot $snapshot }

    # ----- 5. recreate VM + extensions -----
    Set-VmStatus -VmName $VmName -Status 'Creating' -Message ''
    New-SessionHostVm -Snapshot $snapshot

    Set-VmStatus -VmName $VmName -Status 'DomainJoining' -Message ''
    Join-VmToDomain -Snapshot $snapshot

    Set-VmStatus -VmName $VmName -Status 'RegisteringAvd' -Message ''
    Register-WithHostPool -Snapshot $snapshot

    Set-VmStatus -VmName $VmName -Status 'RestoringExtensions' -Message ''
    Restore-Extensions -Snapshot $snapshot

    Set-VmStatus -VmName $VmName -Status 'RestoringDcr' -Message ''
    Restore-DcrAssociations -Snapshot $snapshot

    # ----- 6. ensure drain mode is ON (Runbook 2 turns it off) -----
    # The AVD DSC extension reports Succeeded as soon as its install script
    # finishes, but the AVD agent's self-registration with the AVD broker is
    # asynchronous. Poll the host pool until the new session host appears
    # before declaring the rebuild complete - otherwise we'd mark Completed
    # for a VM that never actually joined the pool, and Runbook 2 (which
    # only acts on Completed VMs) would then have nothing to drain-off.
    Set-VmStatus -VmName $VmName -Status 'WaitingForRegistration' -Message "Waiting up to ${SessionHostRegistrationTimeoutMinutes}m for AVD agent to register session host"
    $regDeadline = (Get-Date).AddMinutes($SessionHostRegistrationTimeoutMinutes)
    $newSh = $null
    while ((Get-Date) -lt $regDeadline) {
        $newSh = Get-AzWvdSessionHost -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -ErrorAction SilentlyContinue |
                 Where-Object { ($_.Name -split '/')[-1].Split('.')[0] -eq $VmName } | Select-Object -First 1
        if ($newSh) { break }
        Write-Log "[$VmName] session host not yet registered with host pool - sleeping 20s..."
        Start-Sleep -Seconds 20
    }
    if (-not $newSh) {
        Set-VmStatus -VmName $VmName -Status 'Failed' -Message "AVD agent did not register session host within ${SessionHostRegistrationTimeoutMinutes}m. VM exists but is not in the host pool."
        Write-Log "[$VmName] FAILED: VM rebuilt successfully but AVD agent never registered with host pool '$HostpoolName' within ${SessionHostRegistrationTimeoutMinutes}m. Check the AVD agent on the VM (Get-Service 'Remote Desktop Agent Loader' / 'Remote Desktop Services'). The rebuild will be retried after FailureRetryMinutes (${FailureRetryMinutes}m)." 'ERROR'
        return
    }
    $newShName = ($newSh.Name -split '/')[-1]
    Set-DrainMode -SessionHostName $newShName -Drain $true

    Set-VmStatus -VmName $VmName -Status 'Completed' -Message 'Awaiting Entra check by Runbook 2'

    # Space the success marker out from the preceding status=Completed line by
    # a few seconds. Log Analytics' diagnostic-settings ingestion has been
    # observed to drop bursts at end-of-job (Stage closing all jobs at once,
    # multiple Process jobs finishing in the same window), and both the
    # status=Completed line and this marker land in the same dropped batch
    # when emitted back-to-back. A 5s gap puts them in separate ingestion
    # windows so at least one survives - the workbook live-grid unions the
    # status= rows with this marker and treats either as a terminal Completed.
    Start-Sleep -Seconds 5

    # Marker line consumed by the 'alert-avd-vm-rebuild-failed' alert's
    # success counterpart and the workbook 'VMs rebuilt (hourly)' chart and
    # live-grid Option-1 fallback. Do NOT change the bracketed token or the
    # Hostpool=/VmName=/Time= keys without also updating the workbook KQL.
    $alertTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Output "[ALERT-VMREBUILDCOMPLETED] Hostpool=$HostpoolName VmName=$VmName Time=$alertTime"

    Remove-PersistedSnapshot -Name $SnapshotVariableName -VmName $VmName

    # Signal real progress to the Process loop's successor-spawn gate.
    Set-Variable -Name '__LastRebuildCompleted' -Scope Script -Value $true
}

#endregion ------------------------------------------------ per-VM rebuild ---

#region ------------------------------------------------------ main orchestration

Connect-AzureAutomation
$jobId = Get-CurrentJobId
Write-Log "Mode=$Mode  JobId=$jobId  Hostpool=$HostpoolName"

# ============================================================================
# STAGE MODE - weekly kickoff: snapshot all VMs, mark all Pending, kick off
# Process job, exit.  Does NOT rebuild any VM directly.
# ============================================================================
if ($Mode -eq 'Stage') {
    Write-Log "STAGE: enumerating session hosts in host pool '$HostpoolName' (RG: $HostpoolRG)..."
    $sessionHosts = @(Get-AzWvdSessionHost -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -ErrorAction SilentlyContinue)
    Write-Log "STAGE: $($sessionHosts.Count) session host(s) discovered."

    # Capture fresh snapshots OUTSIDE the lock (expensive Az calls).
    $newSnaps = @{}
    foreach ($sh in $sessionHosts) {
        $shortName = ($sh.Name -split '/')[-1]
        $vmName    = $shortName.Split('.')[0]
        $vmResourceId = (Get-SafeProperty $sh 'ResourceId')
        if (-not $vmResourceId -or $vmResourceId -notmatch '/resourceGroups/([^/]+)/providers/Microsoft\.Compute/virtualMachines/([^/]+)$') {
            Write-Log "[$vmName] STAGE: could not parse VM ResourceId - skipping snapshot." 'WARN'
            continue
        }
        $vmRg = $Matches[1]; $vmName2 = $Matches[2]
        $vm = Get-AzVM -ResourceGroupName $vmRg -Name $vmName2 -ErrorAction SilentlyContinue
        if (-not $vm) {
            Write-Log "[$vmName] STAGE: VM not found at $vmResourceId. Existing persisted snapshot (if any) will be reused on rebuild." 'WARN'
            continue
        }
        Write-Log "[$vmName] STAGE: capturing snapshot."
        $newSnaps[$vmName] = Get-VmSnapshot -Vm $vm
    }

    # Persist each fresh snapshot to its own per-VM Automation variable.
    # Per-VM variables don't collide, so no cross-job lock is required for
    # the writes; the state-variable flip below still uses the lock.
    foreach ($k in $newSnaps.Keys) {
        Save-PersistedSnapshot -Name $SnapshotVariableName -VmName $k -Snapshot $newSnaps[$k]
    }
    if ($newSnaps.Count -gt 0) {
        Write-Log "STAGE: persisted $($newSnaps.Count) per-VM snapshot variable(s) under base '$SnapshotVariableName'."
    }

    # Flip every known VM (existing or newly discovered) to Pending under the lock.
    Invoke-WithStateLock {
        $live = Get-RebuildState -Name $StateVariableName
        $now  = (Get-Date).ToUniversalTime().ToString('s')
        $staged = 0
        # Seed any newly discovered session host that isn't in state yet.
        foreach ($sh in $sessionHosts) {
            $shortName = ($sh.Name -split '/')[-1]
            $vmName    = $shortName.Split('.')[0]
            $live[$vmName] = [ordered]@{ Status='Pending'; Message='Weekly stage'; LastUpdated=$now }
            $staged++
        }
        # Also reset any state-only entries whose session host registration is gone
        # but whose snapshot we still hold (lets us rebuild deleted VMs).
        foreach ($k in @($live.Keys)) {
            if ($live[$k].Status -ne 'Pending') {
                $live[$k] = [ordered]@{ Status='Pending'; Message='Weekly stage (reset)'; LastUpdated=$now }
                $staged++
            }
        }
        Save-RebuildState -Name $StateVariableName -State $live
        Write-Log "STAGE: $staged VM state entries set to Pending."
    } | Out-Null

    # Kick off Process children immediately so we don't wait up to an hour
    # for the next scheduled tick. Spawn up to $MaxParallelProcessJobs in
    # parallel (bounded by the number of Pending VMs we just staged) so a
    # large hostpool isn't serialized through a single worker. Each child
    # runs in its own Automation sandbox with its own independent runtime
    # budget - spawning more children does NOT consume Stage's budget.
    $pendingCount = ($newSnaps.Keys | Measure-Object).Count
    if ($pendingCount -le 0) {
        Write-Log "STAGE: no Pending VMs to dispatch. Skipping Process kickoff."
    } else {
        $childCount = [Math]::Min($MaxParallelProcessJobs, $pendingCount)
        if ($childCount -lt 1) { $childCount = 1 }
        Write-Log "STAGE: dispatching $childCount parallel Process job(s) for $pendingCount Pending VM(s)..."
        for ($i = 0; $i -lt $childCount; $i++) {
            try {
                $kicked = Start-ProcessJob -SuccessorDepth 0
                Write-Log ("STAGE: kicked off Process job [{0}/{1}] = {2}" -f ($i + 1), $childCount, $kicked.JobId)
            } catch {
                Write-Log "STAGE: failed to kick off Process job $($i + 1)/$childCount : $($_.Exception.Message)" 'WARN'
            }
        }
    }

    Write-Log "STAGE complete."
    return
}

# ============================================================================
# PROCESS MODE - hourly worker: claim one VM, rebuild it, loop.
# ============================================================================
$jobDeadline = (Get-Date).AddMinutes($ProcessJobBudgetMinutes)
$processed   = 0
# VMs this particular job has already attempted. Once a job has tried (and
# either completed or failed) a VM, it must NOT pick it up again in the same
# run — otherwise a consistently-failing VM (e.g. domain join broken) makes
# this job loop forever deleting and recreating it.
$attemptedThisJob = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

while ((Get-Date) -lt $jobDeadline) {

    # ---- claim one Pending VM under the lock ----
    $claimedVmName = Invoke-WithStateLock {
        $live = Get-RebuildState -Name $StateVariableName
        $now  = Get-Date

        # Stale-claim recovery: any VM stuck in a non-terminal state for
        # > StaleClaimMinutes is assumed to have lost its worker and is
        # flipped back to Pending so this (or a future) job can retry.
        # A VM whose LastUpdated cannot be parsed is also treated as stale
        # (otherwise a corrupted timestamp would strand the VM forever).
        $inProgress = @('Claimed','Capturing','Deleting','Creating','DomainJoining','RegisteringAvd','RestoringExtensions','RestoringDcr','WaitingForRegistration')
        $reclaimed = 0
        foreach ($k in @($live.Keys)) {
            $entry = $live[$k]
            if ($entry.Status -in $inProgress) {
                $age = $null
                try { $age = ($now.ToUniversalTime() - ([datetime]$entry.LastUpdated).ToUniversalTime()).TotalMinutes } catch { }
                $forceReclaim = $false
                if ($null -eq $age) {
                    Write-Log "[$k] PROCESS: LastUpdated unparseable ('$($entry.LastUpdated)') - forcing reclaim of stale '$($entry.Status)'." 'WARN'
                    $forceReclaim = $true
                }
                if ($forceReclaim -or $age -gt $StaleClaimMinutes) {
                    $ageDesc = if ($null -eq $age) { 'unknown' } else { "$([int]$age) min" }
                    Write-Log "[$k] PROCESS: reclaiming stale '$($entry.Status)' (age $ageDesc, last holder='$($entry.Message)')." 'WARN'
                    $live[$k] = [ordered]@{
                        Status      = 'Pending'
                        Message     = "Reclaimed from stale '$($entry.Status)' after $ageDesc"
                        LastUpdated = $now.ToUniversalTime().ToString('s')
                    }
                    $reclaimed++
                }
            }
        }

        # Find next Pending / AwaitingUsers / Failed entry.
        # Failed entries are eligible only after $FailureRetryMinutes have
        # elapsed since the failure (lets the operator/DC recover) AND only
        # if this particular job has not already attempted that VM this run.
        $next = $live.GetEnumerator() | Where-Object {
            if ($attemptedThisJob.Contains($_.Key)) { return $false }
            $status = $_.Value.Status
            if ($status -in @('Pending','AwaitingUsers')) { return $true }
            if ($status -eq 'Failed') {
                $failedAge = $null
                try { $failedAge = ($now.ToUniversalTime() - ([datetime]$_.Value.LastUpdated).ToUniversalTime()).TotalMinutes } catch { }
                return ($failedAge -ne $null -and $failedAge -ge $FailureRetryMinutes)
            }
            return $false
        } | Select-Object -First 1

        if ($next) {
            $name = $next.Key
            $live[$name] = [ordered]@{
                Status      = 'Claimed'
                Message     = "Claimed by job $jobId"
                LastUpdated = $now.ToUniversalTime().ToString('s')
            }
            Save-RebuildState -Name $StateVariableName -State $live
            $name
        } elseif ($reclaimed -gt 0) {
            Save-RebuildState -Name $StateVariableName -State $live
            $null
        } else {
            $null
        }
    }

    if (-not $claimedVmName) {
        Write-Log "PROCESS: no Pending VMs left. Job exiting cleanly (processed=$processed this run)."
        break
    }

    Write-Log "[$claimedVmName] PROCESS: claimed by job $jobId. Starting rebuild."
    [void]$attemptedThisJob.Add($claimedVmName)
    try {
        Invoke-VmRebuild -VmName $claimedVmName
        # $processed counts only TRUE Completed rebuilds, signalled via the
        # script-scope flag. Early-exit paths (AwaitingUsers, missing VM
        # with no snapshot) must NOT count as progress - otherwise the
        # successor-spawn gate below would create an infinite chain when a
        # session host has chronically-connected users.
        $completedFlag = $false
        $f = Get-Variable -Name '__LastRebuildCompleted' -Scope Script -ErrorAction SilentlyContinue
        if ($f -and $f.Value) { $completedFlag = $true }
        if ($completedFlag) { $processed++ }
    } catch {
        Write-Log "[$claimedVmName] PROCESS: rebuild FAILED: $($_.Exception.Message)" 'ERROR'
        Set-VmStatus -VmName $claimedVmName -Status 'Failed' -Message $_.Exception.Message
    }
}

# Final progress summary.
$finalState = Get-RebuildState -Name $StateVariableName
$summary = $finalState.GetEnumerator() |
    Group-Object { $_.Value.Status } |
    Select-Object Name, Count

Write-Log "--- Rebuild progress for host pool '$HostpoolName' ---"
$summary | ForEach-Object { Write-Log ("  {0,-22} {1}" -f $_.Name, $_.Count) }
Write-Log "PROCESS: this job rebuilt $processed VM(s) this run (depth=$SuccessorDepth)."

# ============================================================================
# Successor-on-exit: spawn ONE successor Process job iff
#   1) we made REAL progress (>= 1 VM Completed) - this is the loop guard,
#      because a fresh successor gets a fresh $attemptedThisJob HashSet and
#      would otherwise loop forever on chronic AwaitingUsers / Failed VMs;
#   2) eligible work still remains (Pending, AwaitingUsers, or stale Failed);
#   3) chain depth has not yet hit the cap - belt-and-suspenders backstop.
# ============================================================================
if ($processed -ge 1) {
    if ($SuccessorDepth -lt $MaxSuccessorChainDepth) {
        try {
            if (Test-EligibleWorkExists) {
                $nextDepth = $SuccessorDepth + 1
                $kicked = Start-ProcessJob -SuccessorDepth $nextDepth
                Write-Log "PROCESS: spawned successor Process job $($kicked.JobId) (depth $nextDepth/$MaxSuccessorChainDepth)."
            } else {
                Write-Log "PROCESS: no eligible work remains. Successor chain ending at depth $SuccessorDepth."
            }
        } catch {
            Write-Log "PROCESS: failed to spawn successor job: $($_.Exception.Message). Next hourly tick will catch up." 'WARN'
        }
    } else {
        Write-Log "PROCESS: chain depth $SuccessorDepth >= cap $MaxSuccessorChainDepth - not spawning successor. Next hourly tick will resume." 'WARN'
    }
} else {
    Write-Log "PROCESS: no VMs Completed this run - not spawning successor (progress gate prevents AwaitingUsers/Failed infinite loop)."
}

#endregion ----------------------------------------- main orchestration --------
