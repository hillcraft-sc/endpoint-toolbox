# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Exports the device members of an Entra ID group to a CSV.

.DESCRIPTION
    Connects to Microsoft Graph, resolves the target group by object ID or display name, and pages
    through its transitive members so devices nested in child groups are included. Non-device members
    are dropped, duplicates introduced by nested membership are removed, and the result is saved as a
    CSV to -OutputPath with a summary printed to the console.

    The exported DeviceId is the Entra device ID, not the Intune managed device ID. Scripts that match
    against Intune reporting data must translate it through managedDevices.azureADDeviceId first.

.PARAMETER EntraGroup
    The Entra ID group object ID or display name to export devices from.

.PARAMETER OutputPath
    The folder to save the final CSV report to. Defaults to the current user's temp folder.
    Created automatically if it doesn't already exist.

.PARAMETER OpenReport
    Open the finished CSV in its default application once the export completes.

.EXAMPLE
    .\Get-EntraGroupDevices.ps1 -EntraGroup "Contoso-Pilot-Devices"

    Resolves the group by display name and saves its device members to %TEMP%.

.EXAMPLE
    .\Get-EntraGroupDevices.ps1 -EntraGroup "00000000-0000-0000-0000-000000000000" -OutputPath "$env:USERPROFILE\Desktop"

    Exports the device members of a group by object ID to the desktop instead.

.NOTES
    Requires an active Microsoft Graph connection with permissions to read groups and directory
    objects (e.g. Group.Read.All, Directory.Read.All, Device.Read.All). Uses the beta Graph endpoint
    for groups/transitiveMembers.

    Author:         eric@hillcraft.email
    Created:        2026-08-20
    Last Modified:  2026-09-15
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$EntraGroup,

    [string]$OutputPath = "$env:TEMP",

    # Open the finished CSV once the export completes.
    [switch]$OpenReport
)

$ErrorActionPreference = "Stop"

if (Get-MgContext) {
    Write-Host "Connected to MgGraph..."
}
else {
    Write-Host "Not connected to MgGraph. Connecting..."
    Connect-MgGraph -NoWelcome | Out-Null
    #-Scopes "Group.Read.All","Directory.Read.All","Device.Read.All" -NoWelcome
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

Write-Host "Retrieving transitive members..." -ForegroundColor Cyan

$memberUri = "https://graph.microsoft.com/beta/groups/$($group.id)/transitiveMembers?`$select=id,displayName,deviceId,operatingSystem,operatingSystemVersion,accountEnabled,trustType&`$top=999"
$members = @(Get-GraphCollection -Uri $memberUri -Headers @{ "ConsistencyLevel" = "eventual" })

Write-Host "Total objects retrieved: $($members.Count)" -ForegroundColor DarkGray

# Nested membership can surface the same device more than once
$devices = @(
    $members |
    Where-Object { $_.deviceId } |
    Sort-Object -Property id -Unique
)

Write-Host "Device members: $($devices.Count)" -ForegroundColor DarkGray

if ($devices.Count -eq 0) {
    Write-Warning "The group '$($group.displayName)' contains no device members."
    return
}

$results = @(
    $devices | ForEach-Object {
        [PSCustomObject]@{
            GroupDisplayName       = $group.displayName
            GroupId                = $group.id
            DeviceObjectId         = $_.id
            DeviceId               = $_.deviceId
            DeviceName             = $_.displayName
            OperatingSystem        = $_.operatingSystem
            OperatingSystemVersion = $_.operatingSystemVersion
            AccountEnabled         = $_.accountEnabled
            TrustType              = $_.trustType
        }
    }
)

# Prepare output locations
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

$safeGroupName = $group.displayName -replace '[\\/:*?"<>|]', '_'
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$finalCsv = Join-Path $OutputPath "EntraGroupDevices-$safeGroupName-$timestamp.csv"

$results |
Sort-Object DeviceName |
Export-Csv `
    -Path $finalCsv `
    -NoTypeInformation `
    -Encoding UTF8

Write-Host "`nDevices by operating system:" -ForegroundColor Cyan

$results |
Group-Object -Property OperatingSystem |
Sort-Object Count -Descending |
Select-Object Name, Count |
Format-Table -AutoSize

Write-Host "Total devices: $($results.Count)" -ForegroundColor Green

Write-Host "`nReport saved to:" -ForegroundColor Green
Write-Host $finalCsv

if ($OpenReport -and (Test-Path $finalCsv)) {
    Invoke-Item -Path $finalCsv
}
