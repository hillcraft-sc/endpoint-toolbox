<#
.SYNOPSIS
    Lists Intune apps that are assigned to the built-in "All Devices" target.

.DESCRIPTION
    Connects to Microsoft Graph, pulls every app from deviceAppManagement/mobileApps with its
    assignments expanded, and reports the ones targeting allDevicesAssignmentTarget (the built-in
    "All Devices" group in the admin center). Defaults to Win32 apps only. Each matching
    assignment is reported with its intent (required / available / uninstall) and any assignment
    filter attached to it, since a filter can drastically narrow what "All Devices" really means.

.PARAMETER AppType
    Which app types to report on. "Win32" (default) covers win32LobApp only. "WinGet" covers
    Microsoft Store (new) apps. "All" reports every app type, including iOS/Android/web links.

.PARAMETER IncludeAllUsers
    Also include apps assigned to the built-in "All Users" target, not just "All Devices".

.PARAMETER Intent
    Only return assignments with this intent. Valid values: required, available,
    availableWithoutEnrollment, uninstall. All intents are returned when omitted.

.PARAMETER OutputPath
    The folder to save the final CSV report to. Defaults to the current user's temp folder.
    Created automatically if it doesn't already exist.

.PARAMETER OpenReport
    Open the finished CSV in its default application once the export completes.

.EXAMPLE
    .\Get-AppsAssignedToAllDevices.ps1

    Lists every Win32 app assigned to All Devices and saves the CSV to %TEMP%.

.EXAMPLE
    .\Get-AppsAssignedToAllDevices.ps1 -Intent required -OpenReport

    Lists only the Win32 apps that are *required* on All Devices and opens the CSV.

.EXAMPLE
    .\Get-AppsAssignedToAllDevices.ps1 -AppType All -IncludeAllUsers -OutputPath "$env:USERPROFILE\Desktop"

    Reports every app type targeting All Devices or All Users and saves the CSV to the desktop.

.NOTES
    Requires an active Microsoft Graph connection with DeviceManagementApps.Read.All.
    Uses the beta endpoint because $expand=assignments on the mobileApps collection is only
    reliable there.

    Author:         eric@hillcraft.email
    Created:        2026-09-17
    Last Modified:  2026-09-17
#>
param(
    [ValidateSet("Win32", "WinGet", "All")]
    [string]$AppType = "Win32",

    [switch]$IncludeAllUsers,

    [ValidateSet("required", "available", "availableWithoutEnrollment", "uninstall")]
    [string]$Intent,

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
    Connect-MgGraph -Scopes "DeviceManagementApps.Read.All" -NoWelcome | Out-Null
}

$targetTypes = @("#microsoft.graph.allDevicesAssignmentTarget")
if ($IncludeAllUsers) {
    $targetTypes += "#microsoft.graph.allLicensedUsersAssignmentTarget"
}

$appTypeFilter = switch ($AppType) {
    "Win32" { @("#microsoft.graph.win32LobApp") }
    "WinGet" { @("#microsoft.graph.winGetApp") }
    "All" { $null }
}

Write-Host "Retrieving apps and assignments from Intune..." -ForegroundColor Cyan

$apps = @()
$uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$expand=assignments"
$expandFailed = $false
$assignmentLookupFailures = 0

try {
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri
        $apps += $response.value
        $uri = $response.'@odata.nextLink'
    }
    while ($uri)
}
catch {
    # $expand=assignments on the collection can be rejected outright in large tenants
    Write-Warning "Expanding assignments inline failed ($($_.Exception.Message.Trim())). Falling back to per-app lookups; this is slower."
    $expandFailed = $true
}

if ($expandFailed) {
    $apps = @()
    $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps"

    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri
        $apps += $response.value
        $uri = $response.'@odata.nextLink'
    }
    while ($uri)

    if ($appTypeFilter) {
        $apps = @($apps | Where-Object { $appTypeFilter -contains $_.'@odata.type' })
    }

    $appIndex = 0
    foreach ($app in $apps) {
        $appIndex++
        Write-Progress -Activity "Reading assignments" -Status $app.displayName -PercentComplete (($appIndex / $apps.Count) * 100)

        try {
            $assignments = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/assignments"
            $app.assignments = $assignments.value
        }
        catch {
            Write-Warning "Failed to read assignments for: $($app.displayName)"
            $assignmentLookupFailures++
            $app.assignments = @()
        }
    }

    Write-Progress -Activity "Reading assignments" -Completed
}
elseif ($appTypeFilter) {
    $apps = @($apps | Where-Object { $appTypeFilter -contains $_.'@odata.type' })
}

Write-Host "Apps retrieved: $($apps.Count)" -ForegroundColor DarkGray

$results = foreach ($app in $apps) {
    foreach ($assignment in @($app.assignments | Where-Object { $_ })) {

        if ($targetTypes -notcontains $assignment.target.'@odata.type') { continue }
        if ($Intent -and $assignment.intent -ne $Intent) { continue }

        [PSCustomObject]@{
            DisplayName = $app.displayName
            Publisher   = $app.publisher
            Version     = $app.displayVersion
            AppType     = ($app.'@odata.type' -replace '^#microsoft\.graph\.', '')
            Target      = if ($assignment.target.'@odata.type' -like '*allDevices*') { "All Devices" } else { "All Users" }
            Intent      = $assignment.intent
            FilterMode  = $assignment.target.deviceAndAppManagementAssignmentFilterType
            FilterId    = $assignment.target.deviceAndAppManagementAssignmentFilterId
            CreatedDate = $app.createdDateTime
            AppId       = $app.id
        }
    }
}

$results = @($results | Sort-Object Target, DisplayName, Intent)

if ($results.Count -eq 0) {
    $targetDescription = if ($IncludeAllUsers) { "All Devices or All Users" } else { "All Devices" }
    Write-Warning "No $AppType apps are assigned to $targetDescription."
    return
}

# Resolve filter names so the output is readable without a second trip to the portal
$filterIds = @($results.FilterId | Where-Object { $_ } | Sort-Object -Unique)

if ($filterIds.Count -gt 0) {
    $filterNames = @{}

    foreach ($filterId in $filterIds) {
        try {
            $filter = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/beta/deviceManagement/assignmentFilters/$filterId"
            $filterNames[$filterId] = $filter.displayName
        }
        catch {
            $filterNames[$filterId] = "(unresolved)"
        }
    }

    foreach ($result in $results) {
        $name = if ($result.FilterId) { $filterNames[$result.FilterId] } else { "" }
        $result | Add-Member -MemberType NoteProperty -Name FilterName -Value $name
    }
}

$results |
Select-Object DisplayName, Version, AppType, Target, Intent, FilterName, FilterMode |
Format-Table -AutoSize

Write-Host "Matching assignments: $($results.Count)" -ForegroundColor Green

$results |
Group-Object Intent |
Sort-Object Count -Descending |
Select-Object @{ Name = "Intent"; Expression = { $_.Name } }, Count |
Format-Table -AutoSize

# Prepare output locations
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

$safeScope = if ($IncludeAllUsers) { "AllDevicesAndAllUsers" } else { "AllDevices" }
$safeIntent = if ($Intent) { "-$Intent" } else { "" }
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$finalCsv = Join-Path $OutputPath "AppAssignments-$safeScope-$AppType$safeIntent-$timestamp.csv"

$results |
Select-Object DisplayName, Publisher, Version, AppType, Target, Intent, FilterName, FilterMode, FilterId, CreatedDate, AppId |
Export-Csv `
    -Path $finalCsv `
    -NoTypeInformation `
    -Encoding UTF8

Write-Host "`nReport saved to:" -ForegroundColor Green
Write-Host $finalCsv

if ($OpenReport -and (Test-Path $finalCsv)) {
    Invoke-Item -Path $finalCsv
}
