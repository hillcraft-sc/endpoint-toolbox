# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Gets the Intune primary user for devices, with optional assignment or removal.

.DESCRIPTION
    Reads the managed device's users relationship, not its enrollment user or Entra owner.
    Read-only runs return one object per device, including devices with no primary user. Supplying
    -NewPrimaryUser assigns that user to every selected device. -RemovePrimaryUser clears
    the primary-user association without deleting the user account or device. Changes support
    -WhatIf and -Confirm. Every assignment or removal also requires a separate Yes/No
    confirmation for that device, even with -Confirm:$false. There is no Yes to All option
    for this required prompt. Device names must resolve to exactly one Intune record.
    Read-only results display as a compact table of device name, primary-user UPN, and status.
    Full read-only result properties remain available in the pipeline and CSV export.
    Assignment/removal runs print only a short per-device status; full results can be exported
    using -CsvPath.

.PARAMETER Devices
    One or more exact device names. Arrays and comma-separated names are accepted.

.PARAMETER ManagedDeviceId
    One or more Intune managed device IDs, not Entra device object IDs or device IDs.

.PARAMETER DeviceListPath
    Text file containing one device name per line. Blank lines and # comments are ignored.

.PARAMETER GroupName
    Entra group display name. All transitive device members are matched to their Intune managed
    device records using the Entra device ID against the complete paginated Intune inventory.
    Unmatched or ambiguous members are reported as Failed with their Entra device name and ID;
    they are never matched by name for primary-user changes.

.PARAMETER NewPrimaryUser
    UPN or Entra user object ID to assign. Cannot be combined with -RemovePrimaryUser.
    Omit both change options for a read-only report.

.PARAMETER RemovePrimaryUser
    Removes the primary user from every selected device, leaving no user affinity (shared device).
    Devices with no primary user are skipped. Cannot be combined with -NewPrimaryUser.

.PARAMETER CsvPath
    Optional full path for a CSV copy of the results. Parent folders are created if needed.

.EXAMPLE
    .\Get-IntuneDevicePrimaryUser.ps1 -Devices "PC-001","PC-002"

.EXAMPLE
    .\Get-IntuneDevicePrimaryUser.ps1 -DeviceListPath "C:\temp\devices.txt" -CsvPath "C:\temp\primary-users.csv"

.EXAMPLE
    .\Get-IntuneDevicePrimaryUser.ps1 -Devices "PC-001" -NewPrimaryUser "user@contoso.com" -WhatIf

.EXAMPLE
    .\Get-IntuneDevicePrimaryUser.ps1 -ManagedDeviceId "00000000-0000-0000-0000-000000000001" -NewPrimaryUser "user@contoso.com" -Confirm

.EXAMPLE
    .\Get-IntuneDevicePrimaryUser.ps1 -Devices "PC-001","PC-002" -RemovePrimaryUser -WhatIf

.EXAMPLE
    .\Get-IntuneDevicePrimaryUser.ps1 -DeviceListPath "C:\temp\devices.txt" -RemovePrimaryUser -Confirm

.EXAMPLE
    .\Get-IntuneDevicePrimaryUser.ps1 -GroupName "Contoso-Pilot-Devices"

.NOTES
    Requires Microsoft.Graph.Authentication. Read permissions:
    DeviceManagementManagedDevices.Read.All, User.Read.All, and permission to read Entra groups
    and their members (e.g. Group.Read.All and Directory.Read.All). Changes require
    DeviceManagementManagedDevices.ReadWrite.All and Intune RBAC Managed devices/Set
    primary user permission. Uses the beta Graph API for the primary-user relationship.

    Primary-user changes are supported only for Windows devices that are Entra joined
    or hybrid joined. The target user must be licensed for Intune. Graph/Intune enforce
    enrollment eligibility and permissions; this script does not assign licenses.
    Changes can take up to 10 minutes to appear. Successful assignment/removal requests are
    reported as ChangeRequested/RemovalRequested, not as verified changes. PrimaryUser fields
    contain the values read before the request. Enrollment user and local groups are unchanged.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByDevice', ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByDevice')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Devices,

    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [ValidateNotNullOrEmpty()]
    [guid[]]$ManagedDeviceId,

    [Parameter(Mandatory, ParameterSetName = 'ByFile')]
    [ValidateNotNullOrEmpty()]
    [string]$DeviceListPath,

    [Parameter(Mandatory, ParameterSetName = 'ByGroup')]
    [ValidateNotNullOrEmpty()]
    [string]$GroupName,

    [ValidateNotNullOrEmpty()]
    [string]$NewPrimaryUser,

    [switch]$RemovePrimaryUser,

    [ValidateNotNullOrEmpty()]
    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'

if ($RemovePrimaryUser -and $NewPrimaryUser) {
    throw 'Specify either -NewPrimaryUser or -RemovePrimaryUser, not both.'
}

function Get-GraphCollection {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        [hashtable]$Headers = @{}
    )

    do {
        if ($Headers.Count -gt 0) {
            $response = Invoke-MgGraphRequest -Method GET -Uri $Uri -Headers $Headers
        }
        else {
            $response = Invoke-MgGraphRequest -Method GET -Uri $Uri
        }
        foreach ($item in $response.value) {
            $item
        }
        $Uri = $response.'@odata.nextLink'
    }
    while ($Uri)
}

if ($PSCmdlet.ParameterSetName -eq 'ByFile') {
    $targets = @(Get-Content -LiteralPath $DeviceListPath | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') } | Sort-Object -Unique)
}
elseif ($PSCmdlet.ParameterSetName -eq 'ById') {
    $targets = @($ManagedDeviceId | ForEach-Object { $_.ToString() } | Sort-Object -Unique)
}
elseif ($PSCmdlet.ParameterSetName -eq 'ByGroup') {
    $targets = @()
}
else {
    $targets = @($Devices | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } |
        Where-Object { $_ } | Sort-Object -Unique)
}

if ($PSCmdlet.ParameterSetName -ne 'ByGroup' -and $targets.Count -eq 0) {
    throw 'No devices were supplied.'
}

if (Get-MgContext) {
    Write-Host "Connected to MgGraph..."
}
else {
    Write-Host "Not connected to MgGraph. Connecting..."
    Connect-MgGraph -NoWelcome | Out-Null
}

$graphRoot = 'https://graph.microsoft.com/beta'
$deviceSelect = 'id,deviceName,operatingSystem,serialNumber,azureADDeviceId'

if ($PSCmdlet.ParameterSetName -eq 'ByGroup') {
    $escapedGroupName = $GroupName.Trim() -replace "'", "''"
    $groupFilter = [System.Uri]::EscapeDataString("displayName eq '$escapedGroupName'")
    $groups = @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$groupFilter&`$select=id,displayName")
    if ($groups.Count -eq 0) {
        throw "Entra group not found: $GroupName"
    }
    if ($groups.Count -gt 1) {
        throw "Multiple Entra groups are named '$GroupName'. Use a unique display name."
    }

    $group = $groups[0]
    $groupMembers = @(Get-GraphCollection -Uri "$graphRoot/groups/$($group.id)/transitiveMembers?`$select=id,displayName,deviceId&`$top=999" -Headers @{ ConsistencyLevel = 'eventual' })
    $membersByEntraId = @{}
    foreach ($member in $groupMembers) {
        if ($member.deviceId) {
            $membersByEntraId[$member.deviceId] = $member
        }
    }
    $targets = @($groupMembers | Where-Object { $_.deviceId } | ForEach-Object { $_.deviceId } | Sort-Object -Unique)
    if ($targets.Count -eq 0) {
        throw "The Entra group '$($group.displayName)' has no transitive device members."
    }
    Write-Host "Found $($targets.Count) device member(s) in Entra group '$($group.displayName)'."

    Write-Host 'Retrieving Intune managed devices to match Entra device IDs...'
    $devicesByEntraId = @{}
    foreach ($managedDevice in (Get-GraphCollection -Uri "$graphRoot/deviceManagement/managedDevices?`$select=$deviceSelect&`$top=1000")) {
        if ($managedDevice.azureADDeviceId -and $membersByEntraId.ContainsKey($managedDevice.azureADDeviceId)) {
            if (-not $devicesByEntraId.ContainsKey($managedDevice.azureADDeviceId)) {
                $devicesByEntraId[$managedDevice.azureADDeviceId] = @()
            }
            $devicesByEntraId[$managedDevice.azureADDeviceId] += $managedDevice
        }
    }
}

$newUser = $null
if ($NewPrimaryUser) {
    $encodedUser = [System.Uri]::EscapeDataString($NewPrimaryUser.Trim())
    $newUser = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$encodedUser`?`$select=id,displayName,userPrincipalName"
    if (-not $newUser.id) {
        throw "Could not resolve the new primary user: $NewPrimaryUser"
    }
}

$results = @(foreach ($target in $targets) {
    $result = [pscustomobject]@{
        DeviceName                = $target
        ManagedDeviceId           = ''
        EntraDeviceId             = ''
        OperatingSystem           = ''
        SerialNumber              = ''
        PrimaryUserId             = ''
        PrimaryUserDisplayName    = ''
        PrimaryUserPrincipalName  = ''
        RequestedPrimaryUserId    = if ($newUser) { $newUser.id } else { '' }
        RequestedPrimaryUserUPN   = if ($newUser) { $newUser.userPrincipalName } else { '' }
        Status                    = 'Read'
        Error                     = ''
    }

    if ($PSCmdlet.ParameterSetName -eq 'ByGroup') {
        $member = $membersByEntraId[$target]
        if ($member.displayName) {
            $result.DeviceName = $member.displayName
        }
        $result.EntraDeviceId = $target
    }

    try {
        if ($PSCmdlet.ParameterSetName -eq 'ById') {
            $device = Invoke-MgGraphRequest -Method GET -Uri "$graphRoot/deviceManagement/managedDevices/$target`?`$select=$deviceSelect"
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByGroup') {
            $foundDevices = @()
            if ($devicesByEntraId.ContainsKey($target)) {
                $foundDevices = @($devicesByEntraId[$target])
            }
            if ($foundDevices.Count -eq 0) {
                throw "No Intune record in the retrieved inventory matches '$($result.DeviceName)' (Entra device ID: $target)."
            }
            if ($foundDevices.Count -gt 1) {
                throw "Multiple Intune records match Entra device ID '$target'. Use -ManagedDeviceId to select one record. IDs: $($foundDevices.id -join ', ')"
            }
            $device = $foundDevices[0]
        }
        else {
            $filter = "deviceName eq '$($target -replace "'", "''")'"
            $encodedFilter = [System.Uri]::EscapeDataString($filter)
            $foundDevices = @(Get-GraphCollection -Uri "$graphRoot/deviceManagement/managedDevices?`$filter=$encodedFilter&`$select=$deviceSelect")
            if ($foundDevices.Count -eq 0) {
                throw "Device not found in Intune: $target"
            }
            if ($foundDevices.Count -gt 1) {
                throw "Multiple Intune records match '$target'. Use -ManagedDeviceId to select one record. IDs: $($foundDevices.id -join ', ')"
            }
            $device = $foundDevices[0]
        }

        if (-not $device.id) {
            throw "Intune did not return a managed device ID for '$target'."
        }
        $result.DeviceName = $device.deviceName
        $result.ManagedDeviceId = $device.id
        $result.EntraDeviceId = $device.azureADDeviceId
        $result.OperatingSystem = $device.operatingSystem
        $result.SerialNumber = $device.serialNumber

        $usersUri = "$graphRoot/deviceManagement/managedDevices/$($device.id)/users"
        $primaryUsers = @(Get-GraphCollection -Uri "$usersUri`?`$select=id,displayName,userPrincipalName")
        $result.PrimaryUserId = $primaryUsers.id -join '; '
        $result.PrimaryUserDisplayName = $primaryUsers.displayName -join '; '
        $result.PrimaryUserPrincipalName = $primaryUsers.userPrincipalName -join '; '
        if ($primaryUsers.Count -eq 0) {
            $result.Status = 'NoPrimaryUser'
        }

        if ($newUser -or $RemovePrimaryUser) {
            if ($device.operatingSystem -ne 'Windows') {
                throw 'Changing the primary user is supported only for Entra joined or hybrid joined Windows devices.'
            }
        }

        if ($RemovePrimaryUser) {
            if ($primaryUsers.Count -eq 0) {
                $result.Status = 'NoPrimaryUser'
            }
            elseif ($PSCmdlet.ShouldProcess("$($device.deviceName) [$($device.id)]", "Remove Intune primary user ($($result.PrimaryUserPrincipalName))") -and
                $PSCmdlet.ShouldContinue("Device: $($device.deviceName) [$($device.id)]`nCurrent primary user: $($result.PrimaryUserPrincipalName)`nRemove the primary-user association?", 'Confirm primary-user removal')) {
                Invoke-MgGraphRequest -Method DELETE -Uri "$usersUri/`$ref" | Out-Null
                $result.Status = 'RemovalRequested'
            }
            else {
                $result.Status = 'Skipped'
            }
        }
        elseif ($newUser) {
            if ($primaryUsers.Count -eq 1 -and $primaryUsers[0].id -eq $newUser.id) {
                $result.Status = 'AlreadyAssigned'
            }
            elseif ($PSCmdlet.ShouldProcess("$($device.deviceName) [$($device.id)]", "Set Intune primary user to $($newUser.userPrincipalName)") -and
                $PSCmdlet.ShouldContinue("Device: $($device.deviceName) [$($device.id)]`nCurrent primary user: $($result.PrimaryUserPrincipalName)`nNew primary user: $($newUser.userPrincipalName)`nAssign this primary user?", 'Confirm primary-user assignment')) {
                $body = @{ '@odata.id' = "https://graph.microsoft.com/beta/users/$($newUser.id)" } | ConvertTo-Json
                Invoke-MgGraphRequest -Method POST -Uri "$usersUri/`$ref" -Body $body -ContentType 'application/json' | Out-Null
                $result.Status = 'ChangeRequested'
            }
            else {
                $result.Status = 'Skipped'
            }
        }
    }
    catch {
        $result.Status = 'Failed'
        $result.Error = $_.Exception.Message
        Write-Warning "$($result.DeviceName) : $($result.Error)"
    }

    $result
})

if ($CsvPath) {
    $parentPath = Split-Path -Path $CsvPath -Parent
    if ($parentPath -and -not (Test-Path -LiteralPath $parentPath)) {
        New-Item -Path $parentPath -ItemType Directory -Force | Out-Null
    }
    $results | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Report saved to: $CsvPath"
}

if (-not $NewPrimaryUser -and -not $RemovePrimaryUser) {
    $displayProperties = [System.Management.Automation.PSPropertySet]::new(
        'DefaultDisplayPropertySet',
        [string[]]@('DeviceName', 'PrimaryUserPrincipalName', 'Status')
    )
    foreach ($result in $results) {
        $result | Add-Member -MemberType MemberSet -Name PSStandardMembers -Value @($displayProperties) -Force
    }
    $results
}
else {
    foreach ($result in $results) {
        Write-Host "$($result.DeviceName): $($result.Status)"
    }
}