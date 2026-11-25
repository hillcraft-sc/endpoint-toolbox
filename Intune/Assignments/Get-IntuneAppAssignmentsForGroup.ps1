<#
.SYNOPSIS
    Lists the Intune apps assigned to a specific Entra group.

.DESCRIPTION
    Connects to Microsoft Graph, resolves an Entra group by display name or object ID, then pulls
    every app from deviceAppManagement/mobileApps with its assignments expanded and reports the
    ones targeting that group. Both include (groupAssignmentTarget) and exclude
    (exclusionGroupAssignmentTarget) assignments are reported, along with the intent and any
    assignment filter attached, since a filter changes who the assignment actually reaches.
    Results are saved as a timestamped CSV to -OutputPath with a summary printed to the console.

.PARAMETER EntraGroup
    The display name or object ID of the Entra group to report on.

.PARAMETER AppType
    Which app types to report on. "All" (default) covers every app type. "Win32" covers
    win32LobApp only. "WinGet" covers Microsoft Store (new) apps.

.PARAMETER Intent
    Only return assignments with this intent. Valid values: required, available,
    availableWithoutEnrollment, uninstall. All intents are returned when omitted.

.PARAMETER OutputPath
    The folder to save the final CSV report to. Defaults to the current user's temp folder.
    Created automatically if it doesn't already exist.

.PARAMETER OpenReport
    Open the finished CSV in its default application once the export completes.

.EXAMPLE
    .\Get-IntuneAppAssignmentsForGroup.ps1 -EntraGroup "Example Group"

    Lists every app assigned to the named group and saves the CSV to %TEMP%.

.EXAMPLE
    .\Get-IntuneAppAssignmentsForGroup.ps1 -EntraGroup "00000000-0000-0000-0000-000000000001" -AppType Win32 -Intent required

    Lists only the Win32 apps required on the group, resolved by object ID. Replace the example ID.

.EXAMPLE
    .\Get-IntuneAppAssignmentsForGroup.ps1 -EntraGroup "Example Group" -OutputPath "$env:USERPROFILE\Desktop" -OpenReport

    Saves the report to the desktop and opens it once the export completes.

.NOTES
    Requires an active Microsoft Graph connection with permissions to read Intune apps and Entra
    groups (e.g. DeviceManagementApps.Read.All and Group.Read.All). Uses the beta endpoint because
    $expand=assignments on the mobileApps collection is only reliable there.

    Author:         eric@hillcraft.email
    Created:        2026-09-17
    Last Modified:  2026-09-17
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$EntraGroup,

    [ValidateSet("All", "Win32", "WinGet")]
    [string]$AppType = "All",

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
    Connect-MgGraph -NoWelcome | Out-Null
    #-Scopes "DeviceManagementApps.Read.All","Group.Read.All" -NoWelcome
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

$appTypeFilter = switch ($AppType) {
    "Win32" { @("#microsoft.graph.win32LobApp") }
    "WinGet" { @("#microsoft.graph.winGetApp") }
    "All" { $null }
}

Write-Host "Retrieving apps and assignments from Intune..." -ForegroundColor Cyan

$apps = @()
$expandFailed = $false
$assignmentLookupFailures = 0

try {
    $apps = @(Get-GraphCollection -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$expand=assignments")
}
catch {
    # $expand=assignments on the collection can be rejected outright in large tenants
    Write-Warning "Expanding assignments inline failed ($($_.Exception.Message.Trim())). Falling back to per-app lookups; this is slower."
    $expandFailed = $true
}

if ($expandFailed) {
    $apps = @(Get-GraphCollection -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps")

    if ($appTypeFilter) {
        $apps = @($apps | Where-Object { $appTypeFilter -contains $_.'@odata.type' })
    }

    $appIndex = 0
    foreach ($app in $apps) {
        $appIndex++
        Write-Progress -Activity "Reading assignments" -Status $app.displayName -PercentComplete (($appIndex / $apps.Count) * 100)

        try {
            $app.assignments = @(Get-GraphCollection -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/assignments")
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

        if ($assignment.target.groupId -ne $group.id) { continue }
        if ($Intent -and $assignment.intent -ne $Intent) { continue }

        [PSCustomObject]@{
            DisplayName    = $app.displayName
            Publisher      = $app.publisher
            Version        = $app.displayVersion
            AppType        = ($app.'@odata.type' -replace '^#microsoft\.graph\.', '')
            AssignmentType = if ($assignment.target.'@odata.type' -like '*exclusionGroup*') { "Exclude" } else { "Include" }
            Intent         = $assignment.intent
            FilterMode     = $assignment.target.deviceAndAppManagementAssignmentFilterType
            FilterId       = $assignment.target.deviceAndAppManagementAssignmentFilterId
            GroupName      = $group.displayName
            GroupId        = $group.id
            CreatedDate    = $app.createdDateTime
            AppId          = $app.id
        }
    }
}

$results = @($results | Sort-Object AssignmentType, DisplayName, Intent)

if ($results.Count -eq 0) {
    Write-Warning "No $AppType apps are assigned to '$($group.displayName)'."
    return
}

# Resolve filter names so the output is readable without a second trip to the portal
$filterIds = @($results.FilterId | Where-Object { $_ } | Sort-Object -Unique)
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

# Prepare output locations
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

$safeGroupName = $group.displayName -replace '[\\/:*?"<>|]', '_'
$safeIntent = if ($Intent) { "-$Intent" } else { "" }
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$finalCsv = Join-Path $OutputPath "IntuneAppAssignments-$safeGroupName-$AppType$safeIntent-$timestamp.csv"

$results |
Select-Object DisplayName, Publisher, Version, AppType, AssignmentType, Intent, FilterName, FilterMode, FilterId, GroupName, GroupId, CreatedDate, AppId |
Export-Csv `
    -Path $finalCsv `
    -NoTypeInformation `
    -Encoding UTF8

$results |
Select-Object DisplayName, Version, AppType, AssignmentType, Intent, FilterName, FilterMode |
Format-Table -AutoSize

Write-Host "Assignments by intent:" -ForegroundColor Cyan

$results |
Group-Object -Property AssignmentType, Intent |
Sort-Object Count -Descending |
Select-Object @{ Name = "Assignment"; Expression = { $_.Name } }, Count |
Format-Table -AutoSize

Write-Host "Total assignments: $($results.Count)" -ForegroundColor Green
Write-Host "Distinct apps:     $(@($results.AppId | Sort-Object -Unique).Count)" -ForegroundColor Green

Write-Host "`nReport saved to:" -ForegroundColor Green
Write-Host $finalCsv

if ($OpenReport -and (Test-Path $finalCsv)) {
    Invoke-Item -Path $finalCsv
}