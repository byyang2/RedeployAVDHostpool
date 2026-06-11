<#
.SYNOPSIS
    For every session host in an AVD host pool that has been re-created by
    Runbook 1, verify the device has registered in Entra ID (hybrid-joined
    or Entra-joined) and, if so, turn drain mode OFF.

.DESCRIPTION
    Runbook 2 of 2.

    SCOPE: by default this runbook only touches session hosts that
    Runbook 1 (Recreate-AVDSessionHosts) has marked Status='Completed' in
    the AVDRebuildState_<Hostpool> variable. Session hosts that are NOT
    tracked in that state - or are tracked but in a non-'Completed' status -
    are intentionally skipped so an operator-set drain (manual maintenance,
    patching, troubleshooting) is never cleared by this runbook.

    Pass -ProcessUntrackedHosts to override that guard (legacy behavior).

    Workflow per eligible session host:
      1. Look up the VM resource behind the session host.
      2. Invoke 'dsregcmd /status' on the VM via Azure Run-Command and
         parse the AzureAdJoined / DomainJoined / WorkplaceJoined flags.
      3. If the device reports a hybrid join (AzureAdJoined + DomainJoined)
         or pure Entra join (AzureAdJoined only), set AllowNewSession = true
         (drain off). Otherwise leave drain ON and report status.

    Schedule on a recurring interval (for example every 15 minutes).  Each
    invocation is idempotent.

.NOTES
    * The runbook's Managed Identity must have:
        - Desktop Virtualization Contributor on the host pool.
        - Virtual Machine Contributor on the VM resource group (already
          granted by the Bicep template - required for Run-Command).
    * No tenant-scoped Graph permissions are needed; the VM is the source
      of truth for its own Entra join state.
    * Requires Az.Accounts, Az.Compute, and Az.DesktopVirtualization in
      the Automation Account.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $HostpoolName,
    [Parameter(Mandatory)][string] $HostpoolRG,

    # Pin the Az context to this exact subscription before any Get-Az* call.
    # Belt-and-suspenders: even though the Automation Account MI has its own
    # default subscription, a customer's MI could have role assignments in
    # other subs and Az would pick whichever happens to be the context default.
    # Empty string => keep whatever the MI's default subscription is.
    [string] $SubscriptionId = '',

    # Accepted join states that count as "joined" (derived from dsregcmd /status).
    #   ServerAd  = Hybrid Azure AD-joined (AzureAdJoined + DomainJoined)
    #   AzureAd   = Entra ID-joined (cloud only) (AzureAdJoined, not DomainJoined)
    #   Workplace = Entra-registered only - usually NOT what we want
    [string[]] $AcceptedTrustTypes = @('ServerAd','AzureAd'),

    # If true, the runbook will also clear the rebuild state entry for any
    # session host whose drain was successfully turned off.
    [bool] $ClearStateOnSuccess = $true,
    [string] $StateVariableName = "AVDRebuildState_${HostpoolName}",

    # Statuses set by Runbook 1 that mean "this VM is ready for the Entra
    # check + drain-off". Runbook 1 writes 'Completed' with message
    # 'Awaiting Entra check by Runbook 2' when a rebuild finishes.
    [string[]] $EligibleStatuses = @('Completed'),

    # Freshness window: once a VM has been in 'Completed' longer than this,
    # treat it as stale (Entra registration never succeeded, or Graph keeps
    # failing) and stop trying to clear its drain. This protects an operator
    # who manually re-drains a VM after rebuild from having that drain
    # silently undone by a stuck-Completed entry. Set to 0 to disable.
    [int] $MaxCompletedAgeMinutes = 180,

    # SAFETY: by default we only act on session hosts whose VM name appears
    # in the rebuild state map with an eligible status. This keeps the
    # runbook from clearing drain mode that an operator set manually on a
    # session host that was NOT recently rebuilt. Set to $true ONLY for the
    # legacy behavior of evaluating every session host in the pool.
    [switch] $ProcessUntrackedHosts
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region ------------------------------------------------------------- helpers --

function Write-Log {
    param([string] $Message, [string] $Level = 'INFO')
    $ts = (Get-Date).ToString('s')
    Write-Output "[$ts][$Level] $Message"
}

function Connect-AzureAutomation {
    Write-Log 'Connecting to Azure with System-Assigned Managed Identity...'
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

function Get-VmEntraJoinState {
    # Queries the VM itself for its Entra/AD join state by running
    # 'dsregcmd /status' through Azure Run-Command. Returns the same
    # TrustType vocabulary the rest of the script expects:
    #     ServerAd  = AzureAdJoined + DomainJoined  (hybrid)
    #     AzureAd   = AzureAdJoined only            (Entra-joined)
    #     Workplace = WorkplaceJoined only          (Entra-registered)
    #     None      = device has not joined anything yet
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $VmName
    )
    try {
        $rc = Invoke-AzVMRunCommand `
                -ResourceGroupName $ResourceGroup `
                -VMName            $VmName `
                -CommandId         'RunPowerShellScript' `
                -ScriptString      'dsregcmd /status' `
                -ErrorAction       Stop
    } catch {
        Write-Log "[$VmName] dsregcmd Run-Command failed: $($_.Exception.Message)" 'WARN'
        return $null
    }

    $stdout = ($rc.Value | Where-Object { $_.Code -like '*StdOut*' } | Select-Object -First 1).Message
    if ([string]::IsNullOrWhiteSpace($stdout)) {
        Write-Log "[$VmName] dsregcmd returned empty stdout" 'WARN'
        return $null
    }

    $readFlag = {
        param($name)
        if ($stdout -match "(?im)^\s*$name\s*:\s*(YES|NO)\s*$") { return $Matches[1] -eq 'YES' }
        return $false
    }
    $aad = & $readFlag 'AzureAdJoined'
    $dj  = & $readFlag 'DomainJoined'
    $wp  = & $readFlag 'WorkplaceJoined'

    $trustType =
        if ($aad -and $dj) { 'ServerAd' }
        elseif ($aad)      { 'AzureAd' }
        elseif ($wp)       { 'Workplace' }
        else               { 'None' }

    [pscustomobject]@{
        TrustType       = $trustType
        AzureAdJoined   = [bool] $aad
        DomainJoined    = [bool] $dj
        WorkplaceJoined = [bool] $wp
    }
}

function Get-RebuildState {
    param([string] $Name)
    try {
        $raw = Get-AutomationVariable -Name $Name -ErrorAction Stop
    } catch { return @{} }
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    return ($raw | ConvertFrom-Json -AsHashtable)
}

function Save-RebuildState {
    param([string] $Name, [hashtable] $State)
    $json = ($State | ConvertTo-Json -Depth 8 -Compress)
    Set-AutomationVariable -Name $Name -Value $json
}

function Set-DrainMode {
    param([string] $SessionHostName, [bool] $Drain)
    $allow = -not $Drain
    Update-AzWvdSessionHost -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$allow | Out-Null
    Write-Log "[$SessionHostName] AllowNewSession=$allow"
}

#endregion ---------------------------------------------------------- helpers --

#region -------------------------------------------------------------- main ----

Connect-AzureAutomation

Write-Log "Enumerating session hosts in '$HostpoolName' (RG: $HostpoolRG)..."
$sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName

$state = Get-RebuildState -Name $StateVariableName

if ($ProcessUntrackedHosts) {
    Write-Log "-ProcessUntrackedHosts is set. Evaluating ALL $($sessionHosts.Count) session host(s) regardless of rebuild state." 'WARN'
} else {
    $eligibleKeys = @($state.Keys | Where-Object { $EligibleStatuses -contains $state[$_].Status })
    Write-Log "Rebuild state contains $($state.Keys.Count) tracked VM(s); $($eligibleKeys.Count) in eligible status [$($EligibleStatuses -join ',')]: $($eligibleKeys -join ', ')"
    if ($MaxCompletedAgeMinutes -gt 0) {
        Write-Log "Freshness window: only acting on entries whose LastUpdated is within $MaxCompletedAgeMinutes minute(s)."
    }
}

$results = @()

foreach ($sh in $sessionHosts) {
    $sessionHostName = ($sh.Name -split '/')[-1]
    $vmName          = $sessionHostName.Split('.')[0]

    # Scope guard: only act on VMs Runbook 1 has handed off to us.
    if (-not $ProcessUntrackedHosts) {
        if (-not $state.ContainsKey($vmName)) {
            $msg = 'Not tracked in rebuild state - assuming operator-managed drain. Skipping.'
            Write-Log "[$sessionHostName] $msg"
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; Status='Untracked'; TrustType=$null; Action='None'; Detail=$msg }
            continue
        }
        $trackedStatus = $state[$vmName].Status
        if ($EligibleStatuses -notcontains $trackedStatus) {
            $msg = "Tracked but rebuild status='$trackedStatus' is not eligible. Skipping."
            Write-Log "[$sessionHostName] $msg"
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; Status="NotEligible:$trackedStatus"; TrustType=$null; Action='None'; Detail=$msg }
            continue
        }
        if ($MaxCompletedAgeMinutes -gt 0) {
            $lastUpdated = $null
            try { $lastUpdated = [datetime]::Parse($state[$vmName].LastUpdated, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { }
            if ($lastUpdated) {
                $ageMin = [int]((Get-Date).ToUniversalTime() - $lastUpdated).TotalMinutes
                if ($ageMin -gt $MaxCompletedAgeMinutes) {
                    $msg = "Stale '$trackedStatus' (age ${ageMin}m > ${MaxCompletedAgeMinutes}m). Treating as operator-managed - skipping."
                    Write-Log "[$sessionHostName] $msg" 'WARN'
                    $results += [pscustomobject]@{ SessionHost=$sessionHostName; Status='Stale'; TrustType=$null; Action='None'; Detail=$msg }
                    continue
                }
            }
        }
    }

    try {
        # Resolve the underlying VM so we can target Run-Command at the correct RG/name.
        $vm = $null
        if ($sh.ResourceId) {
            $vm = Get-AzVM -ResourceId $sh.ResourceId -ErrorAction SilentlyContinue
        }
        if (-not $vm) {
            $msg = "Could not resolve VM behind session host (ResourceId='$($sh.ResourceId)') - leaving drain ON"
            Write-Log "[$sessionHostName] $msg" 'WARN'
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; Status='NoVm'; TrustType=$null; Action='None'; Detail=$msg }
            continue
        }

        $joinState = Get-VmEntraJoinState -ResourceGroup $vm.ResourceGroupName -VmName $vm.Name
        if (-not $joinState) {
            $msg = 'dsregcmd Run-Command failed or returned no data - leaving drain ON'
            Write-Log "[$sessionHostName] $msg" 'WARN'
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; Status='NotJoined'; TrustType=$null; Action='None'; Detail=$msg }
            continue
        }

        $trust = $joinState.TrustType
        if ($AcceptedTrustTypes -notcontains $trust) {
            $msg = "dsregcmd reports trustType='$trust' (AAD=$($joinState.AzureAdJoined) DJ=$($joinState.DomainJoined) WP=$($joinState.WorkplaceJoined)) - not accepted"
            Write-Log "[$sessionHostName] $msg" 'WARN'
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; Status='WrongTrust'; TrustType=$trust; Action='None'; Detail=$msg }
            continue
        }

        # Already serving new sessions?  Nothing to do.
        if ($sh.AllowNewSession) {
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; Status='AlreadyEnabled'; TrustType=$trust; Action='None'; Detail='Drain already off' }
        } else {
            Set-DrainMode -SessionHostName $sessionHostName -Drain $false
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; Status='DrainDisabled'; TrustType=$trust; Action='AllowNewSession=true'; Detail="AAD=$($joinState.AzureAdJoined) DJ=$($joinState.DomainJoined)" }
        }

        if ($ClearStateOnSuccess -and $state.ContainsKey($vmName)) {
            $state.Remove($vmName) | Out-Null
        }
    }
    catch {
        Write-Log "[$sessionHostName] ERROR: $($_.Exception.Message)" 'ERROR'
        $results += [pscustomobject]@{ SessionHost=$sessionHostName; Status='Error'; TrustType=$null; Action='None'; Detail=$_.Exception.Message }
    }
}

if ($ClearStateOnSuccess) {
    try { Save-RebuildState -Name $StateVariableName -State $state } catch { Write-Log "Could not update state variable: $($_.Exception.Message)" 'WARN' }
}

Write-Log '--- Drain evaluation summary ---'
$results | Format-Table -AutoSize | Out-String | Write-Output

#endregion ---------------------------------------------------------- main -----
