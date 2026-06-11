<#
.SYNOPSIS
    Time-based, one-shot drain-disable for AVD session hosts.

.DESCRIPTION
    Runbook 3 (manual / ad-hoc).

    For every session host in the host pool:
      1. If the underlying VM has a tag 'AVDDrainAutoDisabled', SKIP
         (this runbook has already taken action - we never touch it again).
      2. If the VM is younger than -MinAgeHours (default 2h) since
         TimeCreated, SKIP.
      3. If drain is already off, just stamp the marker tag and skip.
      4. Otherwise turn drain OFF (AllowNewSession = true) AND stamp the
         marker tag with the current UTC timestamp.

    The tag-once-then-never-again rule means an operator can manually
    re-enable drain at any time after this runbook has stamped a VM, and
    this runbook will not undo that drain on a later run. It is the
    inverse-pair of -Disable-DrainForEntraJoined-: that runbook clears
    drain only when Entra join is confirmed; this one clears drain after
    a fixed wait, regardless of join state, as a fallback for hosts where
    Entra registration takes longer than the rebuild flow allows.

    There is intentionally NO schedule for this runbook. It is started
    manually via Start-AzAutomationRunbook or the portal.

.PARAMETER HostpoolName
    Name of the AVD host pool to scan.

.PARAMETER HostpoolRG
    Resource group of the host pool.

.PARAMETER MinAgeHours
    Minimum VM age (hours since TimeCreated) before this runbook is
    allowed to disable drain on it. Default 2.

.PARAMETER MarkerTagName
    Name of the VM tag used as the "already handled" marker. Default
    'AVDDrainAutoDisabled'. Once present (any value), this runbook will
    skip the VM forever.

.PARAMETER WhatIf
    Standard PowerShell -WhatIf: log every action that WOULD be taken
    without actually changing drain state or stamping the tag.

.NOTES
    Required Managed Identity roles (already granted by the Bicep template):
      * Desktop Virtualization Contributor on the host pool (drain control)
      * Virtual Machine Contributor on the VM resource group
        (Get-AzVM, Update-AzTag - tag write requires Contributor; the
        rebuild runbook already needs this scope).

    Modules: Az.Accounts, Az.Compute, Az.DesktopVirtualization, Az.Resources.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)][string] $HostpoolName,
    [Parameter(Mandatory)][string] $HostpoolRG,

    # Pin the Az context to this exact subscription before any Get-Az* call.
    # Belt-and-suspenders: even though the Automation Account MI has its own
    # default subscription, a customer's MI could have role assignments in
    # other subs and Az would pick whichever happens to be the context default.
    # Empty string => keep whatever the MI's default subscription is.
    [string] $SubscriptionId = '',

    [int]    $MinAgeHours   = 2,
    [string] $MarkerTagName = 'AVDDrainAutoDisabled'
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

function Set-DrainMode {
    param([string] $SessionHostName, [bool] $Drain)
    $allow = -not $Drain
    Update-AzWvdSessionHost -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession:$allow | Out-Null
    Write-Log "[$SessionHostName] AllowNewSession=$allow"
}

function Add-MarkerTag {
    # Merges a single tag onto the VM resource. Update-AzTag -Operation Merge
    # preserves any other tags already on the VM.
    param([string] $ResourceId, [string] $TagName, [string] $TagValue)
    Update-AzTag -ResourceId $ResourceId -Operation Merge -Tag @{ $TagName = $TagValue } | Out-Null
}

#endregion ---------------------------------------------------------- helpers --

#region -------------------------------------------------------------- main ----

Connect-AzureAutomation

Write-Log "Enumerating session hosts in '$HostpoolName' (RG: $HostpoolRG)..."
$sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $HostpoolRG -HostPoolName $HostpoolName
Write-Log "Found $($sessionHosts.Count) session host(s)."
Write-Log "Threshold: VM age must be >= $MinAgeHours hour(s) since TimeCreated."
Write-Log "Marker tag: '$MarkerTagName' (any value present => permanently skip)."

$nowUtc  = (Get-Date).ToUniversalTime()
$results = @()

foreach ($sh in $sessionHosts) {
    $sessionHostName = ($sh.Name -split '/')[-1]
    $vmName          = $sessionHostName.Split('.')[0]

    try {
        # Resolve the underlying VM.
        $vm = $null
        if ($sh.ResourceId) {
            $vm = Get-AzVM -ResourceId $sh.ResourceId -ErrorAction SilentlyContinue
        }
        if (-not $vm) {
            $msg = "Could not resolve VM behind session host (ResourceId='$($sh.ResourceId)')."
            Write-Log "[$sessionHostName] $msg" 'WARN'
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; AgeHours=$null; Action='None'; Detail=$msg }
            continue
        }

        # Guard 1: marker tag already present => permanently skip.
        $existingMarker = $null
        if ($vm.Tags -and $vm.Tags.ContainsKey($MarkerTagName)) {
            $existingMarker = $vm.Tags[$MarkerTagName]
        }
        if ($existingMarker) {
            $msg = "Marker tag '$MarkerTagName=$existingMarker' already present - skipping (this runbook never touches a stamped VM)."
            Write-Log "[$sessionHostName] $msg"
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; AgeHours=$null; Action='None'; Detail='AlreadyStamped' }
            continue
        }

        # Guard 2: VM age must meet the threshold.
        $created = $null
        if ($vm.PSObject.Properties.Name -contains 'TimeCreated' -and $vm.TimeCreated) {
            $created = ([datetime] $vm.TimeCreated).ToUniversalTime()
        }
        if (-not $created) {
            $msg = "VM TimeCreated is not available - cannot evaluate age. Skipping."
            Write-Log "[$sessionHostName] $msg" 'WARN'
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; AgeHours=$null; Action='None'; Detail='NoTimeCreated' }
            continue
        }
        $ageHours = [math]::Round(($nowUtc - $created).TotalHours, 2)
        if ($ageHours -lt $MinAgeHours) {
            $msg = "VM age ${ageHours}h < threshold ${MinAgeHours}h - skipping."
            Write-Log "[$sessionHostName] $msg"
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; AgeHours=$ageHours; Action='None'; Detail='TooYoung' }
            continue
        }

        # Prefix with non-numeric text so Azure / Az PowerShell does NOT parse the
        # value back to a DateTime and reformat it in the local culture (which is
        # what turned 'AVDDrainAutoDisabled=2026-06-11T02:10:36Z' into the
        # en-US-formatted '06/11/2026 02:10:36' on read-back). Format is fixed
        # second-precision UTC ISO 8601 - no fractional seconds, no offset wiggle.
        $stampValue = 'utc@' + $nowUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")

        if ($sh.AllowNewSession) {
            # Drain is already off. Stamp the marker so this runbook never
            # second-guesses an operator who later re-drains the VM.
            if ($PSCmdlet.ShouldProcess($vmName, "Stamp tag '$MarkerTagName=$stampValue' (drain already off)")) {
                Add-MarkerTag -ResourceId $vm.Id -TagName $MarkerTagName -TagValue $stampValue
                Write-Log "[$sessionHostName] Drain already off; stamped marker tag '$MarkerTagName=$stampValue'."
            } else {
                Write-Log "[$sessionHostName] [WhatIf] Would stamp marker tag (drain already off)."
            }
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; AgeHours=$ageHours; Action='StampOnly'; Detail='AllowNewSession=true already' }
            continue
        }

        # Drain is on, age >= threshold, no marker tag -> disable drain and stamp.
        if ($PSCmdlet.ShouldProcess($sessionHostName, "Disable drain (AllowNewSession=true) and stamp '$MarkerTagName=$stampValue'")) {
            Set-DrainMode -SessionHostName $sessionHostName -Drain $false
            Add-MarkerTag -ResourceId $vm.Id -TagName $MarkerTagName -TagValue $stampValue
            Write-Log "[$sessionHostName] Drain disabled and marker stamped '$MarkerTagName=$stampValue'."
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; AgeHours=$ageHours; Action='DrainDisabled'; Detail="Stamped $MarkerTagName" }
        } else {
            Write-Log "[$sessionHostName] [WhatIf] Would disable drain and stamp marker (age=${ageHours}h)."
            $results += [pscustomobject]@{ SessionHost=$sessionHostName; AgeHours=$ageHours; Action='WhatIf'; Detail='Would disable drain' }
        }
    }
    catch {
        Write-Log "[$sessionHostName] ERROR: $($_.Exception.Message)" 'ERROR'
        $results += [pscustomobject]@{ SessionHost=$sessionHostName; AgeHours=$null; Action='Error'; Detail=$_.Exception.Message }
    }
}

Write-Log '--- Drain-after-age summary ---'
$results | Format-Table -AutoSize | Out-String | Write-Output

#endregion ---------------------------------------------------------- main -----
