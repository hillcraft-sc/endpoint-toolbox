# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Requests an Intune sync for a list of managed devices, with optional confirmation polling.

.DESCRIPTION
    Connects to Microsoft Graph and requests a management agent sync (Sync-MgDeviceManagementManagedDevice)
    for each device name provided. Device names come from an Entra ID group (-EntraGroup), a text
    file (-DeviceListPath), or directly on the command line (-Devices). Devices not found in Intune
    are reported as warnings and skipped. Device names are processed in batches of up to 100, with
    a 90-second pause between batches. When
    -VerifySync is specified, the script polls each synced device until its LastSyncDateTime
    advances past the time the sync was requested, or until -VerifyTimeoutMinutes elapses, then
    prints a confirmed/not-confirmed summary for every device.

.PARAMETER EntraGroup
    The Entra ID group object ID or display name to pull device names from. Transitive members are
    used, so devices in nested groups are included. Cannot be combined with -DeviceListPath or -Devices.

.PARAMETER DeviceListPath
    Path to a text file containing one device name per line. Blank lines and lines starting with
    '#' are ignored. Cannot be combined with -EntraGroup or -Devices.

.PARAMETER Devices
    One or more device names supplied directly. Accepts a single name, an array, or a
    comma-separated string. Cannot be combined with -EntraGroup or -DeviceListPath.

.PARAMETER VerifySync
    After requesting syncs, poll each device until its LastSyncDateTime advances or the timeout
    is reached.

.PARAMETER VerifyTimeoutMinutes
    How long (in minutes) to keep polling for sync confirmation before giving up. Defaults to 10.

.PARAMETER VerifyIntervalSeconds
    How long (in seconds) to wait between polling attempts. Defaults to 30.

.EXAMPLE
    .\Invoke-IntuneSync.ps1 -EntraGroup "Contoso-Pilot-Devices"

    Requests a sync for every device member of the named Entra group.

.EXAMPLE
    .\Invoke-IntuneSync.ps1 -DeviceListPath "C:\temp\devices.txt" -VerifySync

    Requests a sync for each device listed in devices.txt and polls for confirmation.

.EXAMPLE
    .\Invoke-IntuneSync.ps1 -Devices "PCUSAVDAPP-1","PCUSAVDAPP-2"

    Requests a sync for the two named devices. "PCUSAVDAPP-1,PCUSAVDAPP-2" works as well.

.NOTES
    Requires an active Microsoft Graph connection with permissions to read and manage Intune
    devices (e.g. DeviceManagementManagedDevices.PrivilegedOperations.All,
    DeviceManagementManagedDevices.ReadWrite.All) and, when using -EntraGroup, to read groups and
    directory objects (Group.Read.All, Directory.Read.All).

    Author:         eric@hillcraft.email
    Created:        2026-09-11
    Last Modified:  2026-09-15
#>
[CmdletBinding(DefaultParameterSetName = 'ByGroup')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByGroup')]
    [ValidateNotNullOrEmpty()]
    [string]$EntraGroup,

    [Parameter(Mandatory, ParameterSetName = 'ByFile')]
    [ValidateNotNullOrEmpty()]
    [string]$DeviceListPath,

    [Parameter(Mandatory, ParameterSetName = 'ByDevice')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Devices,

    # After requesting syncs, poll each device until its LastSyncDateTime advances or the timeout is reached.
    [switch]$VerifySync,

    # How long to keep polling for confirmation before giving up.
    [int]$VerifyTimeoutMinutes = 10,

    # How long to wait between polling attempts.
    [int]$VerifyIntervalSeconds = 30
)

if (Get-MgContext) {
    Write-Host "Connected to MgGraph..."
}
else {
    Write-Host "Not connected to MgGraph. Connecting..."
    Connect-MgGraph -NoWelcome | Out-Null
}

function Get-GraphCollection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [hashtable]$Headers = @{}
    )

    $items = @()
    $next = $Uri

    do {
        if ($Headers.Count -gt 0) {
            $response = Invoke-MgGraphRequest -Method GET -Uri $next -Headers $Headers
        }
        else {
            $response = Invoke-MgGraphRequest -Method GET -Uri $next
        }

        if ($response.value) {
            $items += $response.value
        }
        $next = $response.'@odata.nextLink'
    }
    while ($next)

    return $items
}
`
if ($EntraGroup) {
    Write-Host "Resolving Entra group: $EntraGroup" -ForegroundColor Cyan

    if ($EntraGroup -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        $group = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$EntraGroup"
    }
    else {
        $groupFilter = "displayName eq '$($EntraGroup -replace "'", "''")'"
        $groupUri = "https://graph.microsoft.com/v1.0/groups?`$filter=$([System.Uri]::EscapeDataString($groupFilter))&`$top=999"
        $foundGroups = @(Get-GraphCollection -Uri $groupUri)

        if ($foundGroups.Count -eq 0) {
            # Retry on the leading portion of the name so spacing differences around suffixes still resolve
            $prefix = (($EntraGroup -split '[(\[{]')[0]).Trim()
            $prefixFilter = "startsWith(displayName,'$($prefix -replace "'", "''")')"
            $prefixUri = "https://graph.microsoft.com/v1.0/groups?`$filter=$([System.Uri]::EscapeDataString($prefixFilter))&`$top=999"
            $candidates = @(Get-GraphCollection -Uri $prefixUri)

            $normalizedName = $EntraGroup -replace '\s', ''
            $foundGroups = @($candidates | Where-Object { ($_.displayName -replace '\s', '') -eq $normalizedName })

            if ($foundGroups.Count -eq 0) {
                if ($candidates.Count -gt 0) {
                    Write-Host "`nGroups starting with '$prefix':" -ForegroundColor Yellow
                    $candidates | ForEach-Object { Write-Host "  $($_.displayName)" }
                }
                throw "Entra group not found: $EntraGroup"
            }
        }

        if ($foundGroups.Count -gt 1) {
            throw "Multiple Entra groups are named '$EntraGroup'. Re-run using the group object ID."
        }

        $group = $foundGroups[0]
    }

    Write-Host "Group: $($group.displayName) [$($group.id)]" -ForegroundColor Green

    $memberUri = "https://graph.microsoft.com/beta/groups/$($group.id)/transitiveMembers?`$select=id,displayName,deviceId&`$top=999"
    $members = @(Get-GraphCollection -Uri $memberUri -Headers @{ "ConsistencyLevel" = "eventual" })

    $DeviceNames = @($members | Where-Object { $_.deviceId } | ForEach-Object { $_.displayName })

    if ($DeviceNames.Count -eq 0) {
        throw "The group '$($group.displayName)' contains no device members."
    }
}
elseif ($DeviceListPath) {
    if (-not (Test-Path -Path $DeviceListPath)) {
        throw "Device list file not found: $DeviceListPath"
    }
    $DeviceNames = Get-Content -Path $DeviceListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
}
else {
    # Also accept a single comma-separated string, not just a real array
    $DeviceNames = $Devices | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

$DeviceNames = $DeviceNames | Sort-Object -Unique
$DeviceCount = @($DeviceNames).Count

Write-Host "Devices to sync: $DeviceCount" -ForegroundColor Yellow

$RequestedSyncs = @()
$syncResults = @(
    foreach ($Name in $DeviceNames) { [pscustomobject]@{ Name = $Name; Status = 'NotProcessed' } }
)
$syncOutcomesByName = @{}
foreach ($syncOutcome in $syncResults) { $syncOutcomesByName[$syncOutcome.Name] = $syncOutcome }

$DeviceIndex = 0
foreach ($Name in $DeviceNames) {
    $syncOutcome = $syncOutcomesByName[$Name]
    $Device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$Name'"

    if ($Device) {
        try {
            Sync-MgDeviceManagementManagedDevice -ManagedDeviceId $Device.Id -ErrorAction Stop
            $RequestedAtUtc = (Get-Date).ToUniversalTime()
            $syncOutcome.Status = 'Requested'
            Write-Host "Sync requested for $Name (previous sync: $($Device.LastSyncDateTime))"
            $RequestedSyncs += [PSCustomObject]@{
                Name            = $Name
                DeviceId        = $Device.Id
                RequestedAtUtc  = $RequestedAtUtc
                Confirmed       = $false
            }
        }
        catch {
            $syncOutcome.Status = 'Failed'
            Write-Warning "Failed to sync $Name : $_"
        }
    }
    else {
        $syncOutcome.Status = 'NotFound'
        Write-Warning "Device not found: $Name"
    }

    $DeviceIndex++
    if (($DeviceIndex % 100 -eq 0) -and ($DeviceIndex -lt $DeviceCount)) {
        Write-Host "Processed $DeviceIndex of $DeviceCount devices. Pausing 90 seconds before the next batch..."
        Start-Sleep -Seconds 90
    }
}

if ($VerifySync -and $RequestedSyncs.Count -gt 0) {
    Write-Host "`nVerifying sync completion (timeout: $VerifyTimeoutMinutes minute(s))..."
    $Deadline = (Get-Date).AddMinutes($VerifyTimeoutMinutes)
    $Pending = $RequestedSyncs

    while ($Pending.Count -gt 0 -and (Get-Date) -lt $Deadline) {
        Start-Sleep -Seconds $VerifyIntervalSeconds

        foreach ($Item in $Pending) {
            $Current = Get-MgDeviceManagementManagedDevice -ManagedDeviceId $Item.DeviceId
            $CurrentSyncTime = [datetime]$Current.LastSyncDateTime
            # Only count as confirmed if the device actually checked in after we requested the sync, not just later than its old (possibly noisy) timestamp.
            if ($CurrentSyncTime -ge $Item.RequestedAtUtc) {
                $Item.Confirmed = $true
                Write-Host "Confirmed sync for $($Item.Name) (new sync time: $CurrentSyncTime)"
            }
        }

        $Pending = $Pending | Where-Object { -not $_.Confirmed }
    }

    Write-Host "`nSync verification summary:"
    foreach ($Item in $RequestedSyncs) {
        $Status = if ($Item.Confirmed) { "Confirmed" } else { "Not confirmed (still pending or device offline)" }
        Write-Host "$($Item.Name): $Status"
    }
}