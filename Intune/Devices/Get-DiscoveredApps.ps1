# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Exports Intune discovered (inventoried) apps for a given OS platform, optionally scoped to a
    single app name and/or the devices and users in an Entra ID group.

.DESCRIPTION
    Connects to Microsoft Graph and runs the Intune "AppInvRawData" export report, which is the same
    data behind Apps > Monitor > Discovered apps. The report is downloaded, extracted, filtered, and
    saved as a CSV to -OutputPath, with a summary printed to the console.

    Platform filtering is done locally against the report's Platform / Platform_loc / OSDescription
    columns rather than through the Graph filter, because the raw Platform column is an enum whose
    numeric values differ by enrollment type.

.PARAMETER Platform
    The OS platform to report on: Windows, iOS, Android, or macOS.

.PARAMETER AppName
    The discovered app name to report on. Leave blank to return every discovered app for the
    platform. Wildcards (*) are supported and cause the match to be evaluated locally instead of by
    Graph, e.g. "Google Chrome*".

.PARAMETER EntraGroup
    Optional Entra ID group object ID or display name used to scope the report. Device members are
    matched against the report's DeviceId, and user members against its UserId, so both device and
    user groups work. If omitted, all devices are included.

.PARAMETER OutputPath
    The folder to save the final CSV report to. Defaults to the current user's temp folder.
    Created automatically if it doesn't already exist.

.PARAMETER OpenReport
    Open the finished CSV in its default application once the export completes.

.EXAMPLE
    .\Get-DiscoveredApps.ps1 -Platform Windows

    Reports every app discovered on Windows devices in the tenant.

.EXAMPLE
    .\Get-DiscoveredApps.ps1 -Platform macOS -AppName "Google Chrome"

    Reports only Google Chrome installs discovered on macOS devices.

.EXAMPLE
    .\Get-DiscoveredApps.ps1 -Platform iOS -AppName "Microsoft*" -EntraGroup "IT - Mobile Pilot"

    Reports every discovered app starting with "Microsoft" on iOS devices belonging to the members of
    the named Entra group.

.NOTES
    Requires an active Microsoft Graph connection with permissions to read Intune apps, managed
    devices, and device management reports (e.g. DeviceManagementApps.Read.All,
    DeviceManagementManagedDevices.Read.All, Group.Read.All, Directory.Read.All). Uses the beta
    Graph endpoint for deviceManagement/reports/exportJobs.

    Author:         eric@hillcraft.email
    Created:        2026-09-15
    Last Modified:  2026-09-15
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Windows", "iOS", "Android", "macOS")]
    [string]$Platform,

    [string]$AppName = "",
    [string]$EntraGroup = "",
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
    #-Scopes "DeviceManagementApps.Read.All","DeviceManagementManagedDevices.Read.All","Group.Read.All","Directory.Read.All" -NoWelcome
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

# Resolve the optional Entra group scope up front so we fail fast on a bad group
$scopedDeviceIds = $null
$scopedUserIds = $null

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

    $memberUri = "https://graph.microsoft.com/beta/groups/$($group.id)/transitiveMembers?`$select=id,displayName,deviceId,userPrincipalName&`$top=999"
    $members = @(Get-GraphCollection -Uri $memberUri -Headers @{ "ConsistencyLevel" = "eventual" })

    $entraDeviceIds = @($members | Where-Object { $_.deviceId } | ForEach-Object { $_.deviceId.ToLower() } | Sort-Object -Unique)
    $scopedUserIds = @($members | Where-Object { $_.userPrincipalName } | ForEach-Object { $_.id.ToLower() } | Sort-Object -Unique)

    Write-Host "Group members: $($entraDeviceIds.Count) device(s), $($scopedUserIds.Count) user(s)" -ForegroundColor Yellow

    if ($entraDeviceIds.Count -eq 0 -and $scopedUserIds.Count -eq 0) {
        throw "The group '$($group.displayName)' contains no device or user members to report on."
    }

    # The report keys on the Intune managed device ID, so translate the Entra device IDs first
    $scopedDeviceIds = @()

    if ($entraDeviceIds.Count -gt 0) {
        Write-Host "Mapping Entra device IDs to Intune device IDs..." -ForegroundColor Cyan

        $managedDevices = @(
            Get-GraphCollection -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$select=id,azureADDeviceId&`$top=1000"
        )

        $entraDeviceIdSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$entraDeviceIds)

        $scopedDeviceIds = @(
            $managedDevices |
            Where-Object { $_.azureADDeviceId -and $entraDeviceIdSet.Contains($_.azureADDeviceId.ToLower()) } |
            ForEach-Object { $_.id.ToLower() }
        )

        Write-Host "Matched $($scopedDeviceIds.Count) Intune device record(s)" -ForegroundColor Yellow
    }
}

# Graph's AppInvRawData filter only supports exact (eq) matches, so wildcards are handled locally
$useLocalNameMatch = $AppName -and $AppName.Contains("*")

$bodyObject = @{
    reportName       = "AppInvRawData"
    localizationType = "LocalizedValuesAsAdditionalColumn"
    format           = "csv"
    select           = @(
        "ApplicationName"
        "ApplicationPublisher"
        "ApplicationShortVersion"
        "ApplicationVersion"
        "ApplicationKey"
        "DeviceName"
        "DeviceId"
        "OSDescription"
        "OSVersion"
        "Platform"
        "UserName"
        "EmailAddress"
        "UserId"
    )
}

if ($AppName -and -not $useLocalNameMatch) {
    $escapedAppName = $AppName -replace "'", "''"
    $bodyObject.filter = "(ApplicationName eq '$escapedAppName')"
}

$body = $bodyObject | ConvertTo-Json -Depth 10

if ($AppName) {
    Write-Host "Starting Intune discovered apps export for '$AppName' on $Platform..." -ForegroundColor Cyan
}
else {
    Write-Host "Starting Intune discovered apps export for all apps on $Platform..." -ForegroundColor Cyan
}

try {
    $job = Invoke-MgGraphRequest `
        -Method POST `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs" `
        -Body $body `
        -ContentType "application/json"
}
catch {
    Write-Host "`nRequest body sent to Graph:" -ForegroundColor Yellow
    Write-Host $body
    throw
}

if (-not $job.Id) {
    throw "Intune did not return an export job ID."
}

$jobId = $job.Id

Write-Host "Export job ID: $jobId" -ForegroundColor DarkGray

# Wait for report generation. A full unfiltered inventory export can take a while in a large tenant.
$timeout = (Get-Date).AddMinutes(30)

do {
    Start-Sleep -Seconds 5

    $encodedJobId = [System.Uri]::EscapeDataString($jobId)

    $status = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs/$encodedJobId"

    Write-Host "Export status: $($status.Status)" -ForegroundColor Yellow

    if ($status.Status -eq "failed") {
        throw "The Intune report export failed."
    }

    if ((Get-Date) -gt $timeout) {
        throw "The Intune report export timed out after 30 minutes."
    }
}
until ($status.Status -eq "completed")

if (-not $status.Url) {
    throw "The export completed, but Intune did not return a download URL."
}

# Prepare output locations
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

$namePart = if ($AppName) { $AppName } else { "AllApps" }
$safeNamePart = $namePart -replace '[\\/:*?"<>|]', '_'
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$zipPath = Join-Path $env:TEMP "IntuneDiscoveredApps-$timestamp.zip"
$extractPath = Join-Path $env:TEMP "IntuneDiscoveredApps-$timestamp"
$finalCsv = Join-Path $OutputPath "DiscoveredApps-$Platform-$safeNamePart-$timestamp.csv"

# Download and extract
Write-Host "Downloading report..." -ForegroundColor Cyan

Invoke-WebRequest `
    -Uri $status.Url `
    -OutFile $zipPath `
    -UseBasicParsing

Expand-Archive `
    -Path $zipPath `
    -DestinationPath $extractPath `
    -Force

$downloadedCsv = Get-ChildItem `
    -Path $extractPath `
    -Filter "*.csv" `
    -File `
    -Recurse |
Select-Object -First 1

if (-not $downloadedCsv) {
    throw "The downloaded ZIP did not contain a CSV file."
}

$rows = @(Import-Csv -Path $downloadedCsv.FullName)

Write-Host "Records returned by Intune: $($rows.Count)" -ForegroundColor DarkGray

# Clean up temporary files now that the data is in memory
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue

# Platform is an enum whose numeric values vary, so classify from every platform-ish column we have
$platformPatterns = [ordered]@{
    Android = 'android'
    iOS     = 'ios|iphone|ipad|ipod'
    macOS   = 'mac|osx|os x'
    Windows = 'windows|winrt|wince|hololens|surfacehub'
}

foreach ($row in $rows) {
    $platformText = @($row.Platform_loc, $row.Platform, $row.OSDescription) -join ' '
    $friendly = "Unknown"

    foreach ($key in $platformPatterns.Keys) {
        if ($platformText -match $platformPatterns[$key]) {
            $friendly = $key
            break
        }
    }

    $row | Add-Member -MemberType NoteProperty -Name PlatformFriendly -Value $friendly -Force

    # Android populates ApplicationVersion while iOS/macOS populate ApplicationShortVersion
    $version = $row.ApplicationShortVersion
    if ([string]::IsNullOrWhiteSpace($version)) {
        $version = $row.ApplicationVersion
    }

    $row | Add-Member -MemberType NoteProperty -Name ReportedVersion -Value $version -Force
}

$results = @($rows | Where-Object PlatformFriendly -eq $Platform)

Write-Host "Records on $($Platform): $($results.Count)" -ForegroundColor DarkGray

if ($useLocalNameMatch) {
    $results = @($results | Where-Object { $_.ApplicationName -like $AppName })
    Write-Host "Records matching '$AppName': $($results.Count)" -ForegroundColor DarkGray
}

if ($EntraGroup) {
    $deviceIdSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$scopedDeviceIds)
    $userIdSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$scopedUserIds)

    $results = @(
        $results | Where-Object {
            ($_.DeviceId -and $deviceIdSet.Contains($_.DeviceId.ToLower())) -or
            ($_.UserId -and $userIdSet.Contains($_.UserId.ToLower()))
        }
    )

    Write-Host "Records in group scope: $($results.Count)" -ForegroundColor DarkGray
}

if ($results.Count -eq 0) {
    Write-Warning "No discovered app records matched the requested platform, app name, and group scope."
    return
}

$results |
Sort-Object ApplicationName, ReportedVersion, DeviceName |
Export-Csv `
    -Path $finalCsv `
    -NoTypeInformation `
    -Encoding UTF8

if ($AppName) {
    Write-Host "`nInstalled versions by device count:" -ForegroundColor Cyan

    $results |
    Group-Object -Property ApplicationName, ReportedVersion |
    Sort-Object @{ Expression = { $_.Group[0].ApplicationName } }, @{ Expression = { $_.Group[0].ReportedVersion } } |
    Select-Object -Property @{ Name = "ApplicationName"; Expression = { $_.Group[0].ApplicationName } },
    @{ Name = "Version"; Expression = { $_.Group[0].ReportedVersion } },
    @{ Name = "DeviceCount"; Expression = { @($_.Group.DeviceId | Sort-Object -Unique).Count } } |
    Format-Table -AutoSize
}
else {
    Write-Host "`nTop discovered apps by device count:" -ForegroundColor Cyan

    $results |
    Group-Object -Property ApplicationName |
    Sort-Object Count -Descending |
    Select-Object -First 25 -Property @{ Name = "ApplicationName"; Expression = { $_.Name } },
    @{ Name = "DeviceCount"; Expression = { @($_.Group.DeviceId | Sort-Object -Unique).Count } } |
    Format-Table -AutoSize
}

Write-Host "Distinct apps:    $(@($results.ApplicationName | Sort-Object -Unique).Count)" -ForegroundColor Green
Write-Host "Distinct devices: $(@($results.DeviceId | Sort-Object -Unique).Count)" -ForegroundColor Green
Write-Host "Total records:    $($results.Count)" -ForegroundColor Green

Write-Host "`nReport saved to:" -ForegroundColor Green
Write-Host $finalCsv

if ($OpenReport -and (Test-Path $finalCsv)) {
    Invoke-Item -Path $finalCsv
}
