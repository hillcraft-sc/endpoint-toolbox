# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Adds one primary Windows device per user to an Entra ID group.

.DESCRIPTION
    Reads user principal names from a text file and matches them to the primary user recorded on
    Intune managed Windows devices. If a user has multiple eligible devices, the device with the
    most recent Intune sync is selected. Devices that have not synced within LookbackDays are
    excluded. Existing group members are skipped.

    Intune does not expose a separate "primary device" flag. In this script, primary device means
    the most recently synced eligible Windows device whose Intune userPrincipalName matches the
    supplied user.

.PARAMETER GroupId
    Object ID of the target Entra group. Cannot be combined with GroupName.

.PARAMETER GroupName
    Display name of the target Entra group. The script fails if the name is not unique.

.PARAMETER UserListPath
    Text file containing one user principal name per line. Blank lines, duplicates, and lines
    beginning with # are ignored.

.PARAMETER LookbackDays
    Maximum age of the selected device's last Intune sync. Defaults to 30 days.

.PARAMETER CorporateOwnedOnly
    Only considers devices whose Intune managedDeviceOwnerType is company.

.PARAMETER OutputFile
    CSV report path. Defaults to C:\temp\PrimaryUserDeviceGroupResults.csv.

.EXAMPLE
    .\Add-PrimaryUserDevicesToEntraGroup.ps1 -GroupName "Target Devices" -UserListPath .\users.txt -WhatIf

    Shows which primary devices would be added without changing group membership.

.EXAMPLE
    .\Add-PrimaryUserDevicesToEntraGroup.ps1 -GroupId "00000000-0000-0000-0000-000000000000" -UserListPath .\users.txt -CorporateOwnedOnly

    Adds each user's most recently synced corporate-owned Windows device.

.NOTES
    Requires Microsoft.Graph.Authentication and delegated consent for
    DeviceManagementManagedDevices.Read.All, Device.Read.All, and GroupMember.ReadWrite.All.
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ById')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [ValidateNotNullOrEmpty()]
    [string]$GroupId,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [ValidateNotNullOrEmpty()]
    [string]$GroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$UserListPath,

    [ValidateRange(1, 3650)]
    [int]$LookbackDays = 30,

    [switch]$CorporateOwnedOnly,

    [ValidateNotNullOrEmpty()]
    [string]$OutputFile = 'C:\temp\PrimaryUserDeviceGroupResults.csv'
)

$ErrorActionPreference = 'Stop'
$RequiredScopes = @(
    'DeviceManagementManagedDevices.Read.All'
    'Device.Read.All'
    'GroupMember.ReadWrite.All'
)

function Invoke-PagedGraphRequest {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $Items = [System.Collections.Generic.List[object]]::new()

    do {
        $Response = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
        foreach ($Item in $Response.value) {
            $Items.Add($Item)
        }
        $Uri = $Response.'@odata.nextLink'
    } while ($Uri)

    return $Items.ToArray()
}

function Get-GroupsByName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $EscapedName = $Name.Replace("'", "''")
    $Uri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$EscapedName'&`$select=id,displayName,groupTypes"
    $Response = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
    return @($Response.value)
}

function Get-GroupMemberIds {
    param(
        [Parameter(Mandatory)]
        [string]$Id
    )

    $MemberIds = @{}
    $Members = Invoke-PagedGraphRequest -Uri "https://graph.microsoft.com/v1.0/groups/$Id/members?`$select=id&`$top=999"

    foreach ($Member in $Members) {
        $MemberIds[$Member.id] = $true
    }

    return $MemberIds
}

function Add-DeviceToGroup {
    param(
        [Parameter(Mandatory)]
        [string]$TargetGroupId,

        [Parameter(Mandatory)]
        [string]$DeviceObjectId
    )

    $Body = @{
        '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$DeviceObjectId"
    } | ConvertTo-Json

    Invoke-MgGraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/groups/$TargetGroupId/members/`$ref" `
        -Body $Body `
        -ContentType 'application/json' | Out-Null
}

if (-not (Test-Path -LiteralPath $UserListPath -PathType Leaf)) {
    throw "User list file not found: $UserListPath"
}

$UserPrincipalNames = @(
    Get-Content -LiteralPath $UserListPath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notlike '#*' } |
        Sort-Object -Unique
)

if ($UserPrincipalNames.Count -eq 0) {
    throw "No user principal names were found in '$UserListPath'."
}

$GraphContext = Get-MgContext
$MissingScopes = @(
    $RequiredScopes | Where-Object { -not $GraphContext -or $GraphContext.Scopes -notcontains $_ }
)

if ($MissingScopes.Count -gt 0) {
    if ($GraphContext) {
        Write-Output "Reconnecting to Microsoft Graph because required scopes are missing: $($MissingScopes -join ', ')"
        Disconnect-MgGraph | Out-Null
    }
    else {
        Write-Output 'Not connected to Microsoft Graph. Connecting...'
    }

    Connect-MgGraph -Scopes $RequiredScopes -NoWelcome | Out-Null
}
else {
    Write-Output 'Using the existing Microsoft Graph connection.'
}

if ($PSCmdlet.ParameterSetName -eq 'ByName') {
    $Groups = Get-GroupsByName -Name $GroupName

    if ($Groups.Count -eq 0) {
        throw "Group not found in Entra: $GroupName"
    }
    if ($Groups.Count -gt 1) {
        throw "$($Groups.Count) groups share the name '$GroupName'. Re-run with -GroupId using one of: $($Groups.id -join ', ')"
    }

    $TargetGroup = $Groups[0]
    $GroupId = $TargetGroup.id
}
else {
    try {
        $TargetGroup = Invoke-MgGraphRequest -Method GET -OutputType PSObject `
            -Uri "https://graph.microsoft.com/v1.0/groups/${GroupId}?`$select=id,displayName,groupTypes"
    }
    catch {
        throw "Group not found or not accessible: $GroupId - $($_.Exception.Message)"
    }
}

if ($TargetGroup.groupTypes -contains 'DynamicMembership') {
    throw "'$($TargetGroup.displayName)' is a dynamic group and cannot accept manually added members."
}

Write-Output "Target group: $($TargetGroup.displayName) ($GroupId)"
Write-Output "Reading Intune Windows devices..."

$ManagedDeviceUri = 'https://graph.microsoft.com/beta/deviceManagement/managedDevices?' +
    '$filter=operatingSystem eq ''Windows''&' +
    '$select=id,deviceName,azureADDeviceId,userPrincipalName,lastSyncDateTime,managedDeviceOwnerType'
$ManagedDevices = @(Invoke-PagedGraphRequest -Uri $ManagedDeviceUri)

Write-Output "Reading Entra Windows devices..."
$DirectoryDeviceUri = 'https://graph.microsoft.com/v1.0/devices?' +
    '$filter=operatingSystem eq ''Windows''&' +
    '$select=id,deviceId,displayName&$top=999'
$DirectoryDevices = @(Invoke-PagedGraphRequest -Uri $DirectoryDeviceUri)

$DirectoryDeviceByDeviceId = @{}
foreach ($DirectoryDevice in $DirectoryDevices) {
    if ($DirectoryDevice.deviceId) {
        $DirectoryDeviceByDeviceId[$DirectoryDevice.deviceId.ToString().ToLowerInvariant()] = $DirectoryDevice
    }
}

Write-Output 'Reading current group membership...'
$ExistingMemberIds = Get-GroupMemberIds -Id $GroupId
$SyncCutoff = (Get-Date).AddDays(-$LookbackDays)
$Results = [System.Collections.Generic.List[object]]::new()
$AddedCount = 0
$AlreadyMemberCount = 0
$NoDeviceCount = 0
$FailedCount = 0
$WhatIfCount = 0

foreach ($UserPrincipalName in $UserPrincipalNames) {
    $EligibleDevices = @(
        $ManagedDevices |
            Where-Object {
                $_.userPrincipalName -eq $UserPrincipalName -and
                $_.lastSyncDateTime -and
                [datetimeoffset]$_.lastSyncDateTime -ge $SyncCutoff -and
                $_.azureADDeviceId -and
                (-not $CorporateOwnedOnly -or $_.managedDeviceOwnerType -eq 'company')
            } |
            Sort-Object { [datetimeoffset]$_.lastSyncDateTime } -Descending
    )

    if ($EligibleDevices.Count -eq 0) {
        Write-Output "[MISS]  $UserPrincipalName - no eligible device found"
        $NoDeviceCount++
        $Results.Add([PSCustomObject]@{
            UserPrincipalName = $UserPrincipalName
            DeviceName        = $null
            DeviceOwnership   = $null
            LastSyncDateTime  = $null
            DeviceObjectId    = $null
            Status            = 'NoEligibleDevice'
            CandidateCount    = 0
        })
        continue
    }

    $PrimaryDevice = $EligibleDevices[0]
    $DeviceIdKey = $PrimaryDevice.azureADDeviceId.ToString().ToLowerInvariant()
    $DirectoryDevice = $DirectoryDeviceByDeviceId[$DeviceIdKey]

    if (-not $DirectoryDevice) {
        Write-Warning "[FAIL]  $UserPrincipalName - '$($PrimaryDevice.deviceName)' has no matching Entra device object"
        $FailedCount++
        $Status = 'DirectoryDeviceNotFound'
    }
    elseif ($ExistingMemberIds.ContainsKey($DirectoryDevice.id)) {
        Write-Output "[EXIST] $UserPrincipalName - '$($PrimaryDevice.deviceName)' is already a member"
        $AlreadyMemberCount++
        $Status = 'AlreadyMember'
    }
    elseif ($PSCmdlet.ShouldProcess("$($PrimaryDevice.deviceName) for $UserPrincipalName", "Add to '$($TargetGroup.displayName)'")) {
        try {
            Add-DeviceToGroup -TargetGroupId $GroupId -DeviceObjectId $DirectoryDevice.id
            $ExistingMemberIds[$DirectoryDevice.id] = $true
            Write-Output "[OK]    $UserPrincipalName - added '$($PrimaryDevice.deviceName)'"
            $AddedCount++
            $Status = 'Added'
        }
        catch {
            Write-Warning "[FAIL]  $UserPrincipalName - '$($PrimaryDevice.deviceName)': $($_.Exception.Message)"
            $FailedCount++
            $Status = 'Failed'
        }
    }
    else {
        $WhatIfCount++
        $Status = 'WhatIf'
    }

    $Results.Add([PSCustomObject]@{
        UserPrincipalName = $UserPrincipalName
        DeviceName        = $PrimaryDevice.deviceName
        DeviceOwnership   = $PrimaryDevice.managedDeviceOwnerType
        LastSyncDateTime  = $PrimaryDevice.lastSyncDateTime
        DeviceObjectId    = $DirectoryDevice.id
        Status            = $Status
        CandidateCount    = $EligibleDevices.Count
    })
}

$OutputDirectory = Split-Path -Path $OutputFile -Parent
if ($OutputDirectory -and -not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force -WhatIf:$false | Out-Null
}

$Results | Export-Csv -LiteralPath $OutputFile -NoTypeInformation -Force -WhatIf:$false

Write-Output "`n--- Summary ---"
Write-Output "Users processed:       $($UserPrincipalNames.Count)"
Write-Output "Devices added:         $AddedCount"
Write-Output "Already members:       $AlreadyMemberCount"
Write-Output "No eligible device:    $NoDeviceCount"
Write-Output "Failed:                $FailedCount"
if ($WhatIfCount -gt 0) {
    Write-Output "WhatIf selections:     $WhatIfCount"
}
Write-Output "Results exported to:   $OutputFile"

if ($FailedCount -gt 0) {
    exit 1
}