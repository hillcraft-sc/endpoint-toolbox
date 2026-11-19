# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Pulls Intune deployment (install) status reports for one or more Win32 apps.

.DESCRIPTION
    Connects to Microsoft Graph and exports the per-device install status report for the specified
    Win32 app(s) (win32LobApp) from Intune. Apps can be targeted by display name or wildcard pattern
    (-AppName), or object ID (-AppId). Either parameter accepts multiple values. Name searches
    accept partial names as well as wildcard patterns. If a search
    matches more than one app object, the script lists them with name, version, created date, and ID so
    one or more can be selected interactively, all matches selected with A, or the pattern skipped.

    For each app, an Intune report export job (DeviceInstallStatusByApp) is submitted, polled until
    complete, downloaded, and saved as a CSV in -OutputPath. Every original device-report column
    is preserved, including error details. A separate device summary collapses per-user rows
    to one worst-known state per device. The per-user report (UserInstallStatusAggregateByApp)
    is also exported by default; use -IncludeUserStatus:$false for device reports only.
    Device detail rows are returned to the pipeline with app metadata and a readable status added.

.PARAMETER AppName
    One or more partial display names or PowerShell wildcard patterns of Win32 apps to report on.
    Matching is case-insensitive. A search without wildcard characters is treated as *search*.
    If a name or pattern matches multiple apps, you'll be prompted
    to enter one number, comma-separated numbers (e.g. 0,2,3), A for all matches, or blank to skip.

.PARAMETER AppId
    One or more Intune mobileApps object IDs to report on directly, bypassing the name lookup and
    any disambiguation prompt.

.PARAMETER OutputPath
    Folder where report CSVs are saved. Created if it doesn't exist. Defaults to TEMP.

.PARAMETER IncludeUserStatus
    Export the per-user install status report for each app. Enabled by default.
    Pass -IncludeUserStatus:$false to export device reports only.

.PARAMETER OpenReport
    Open each completed CSV report in its default application.

.PARAMETER TimeoutSeconds
    Maximum time to wait for each Intune export job to complete. Defaults to 300.

.EXAMPLE
    .\Get-Win32AppDeploymentStatus.ps1 -AppName "Google Chrome (MSI-x64) - (PMP Update)"

    Finds matching apps, lets you choose one or more, and exports deployment reports to TEMP.

.EXAMPLE
    .\Get-Win32AppDeploymentStatus.ps1 -AppName "*ACPWork10Tools*" -OutputPath C:\Temp\Reports -IncludeUserStatus

    Exports device and user install status reports for the selected matching apps to C:\Temp\Reports.

.EXAMPLE
    $status = .\Get-Win32AppDeploymentStatus.ps1 -AppId "00000000-0000-0000-0000-000000000000"
    $status | Where-Object InstallState -eq 'Failed' | Format-Table DeviceName, UserPrincipalName, ErrorCode

    Captures the device status rows and lists the failed devices.

.NOTES
    Requires an active Microsoft Graph connection with permissions to read Intune apps and reports
    (e.g. DeviceManagementApps.Read.All). Uses the beta Graph endpoints for
    deviceAppManagement/mobileApps and deviceManagement/reports/exportJobs.

    Author:         eric@hillcraft.email
    Created:        2026-10-29
    Last Modified:  2026-11-04
#>
[CmdletBinding()]
param(
    [string[]]$AppName = @(),
    [string[]]$AppId = @(),
    [string]$OutputPath = "$env:TEMP",
    [switch]$IncludeUserStatus = $true,
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 300,
    [switch]$OpenReport
)

$deploymentStarted = [datetimeoffset]::Now
$deploymentRuntime = [Diagnostics.Stopwatch]::StartNew()
Write-Host "Report started: $($deploymentStarted.ToString('yyyy-MM-dd HH:mm:ss.fff zzz'))" -ForegroundColor Cyan
try {
$ErrorActionPreference = "Stop"
if (Get-MgContext) {
    Write-Host "Connected to MgGraph..." -ForegroundColor Green
}
else {
    Write-Host "Not connected to MgGraph. Connecting..." -ForegroundColor Yellow
    Connect-MgGraph -NoWelcome | Out-Null
    #-Scopes "DeviceManagementApps.Read.All" -NoWelcome
}

if ($AppName.Count -eq 0 -and $AppId.Count -eq 0) {
    throw "Specify at least one -AppName or -AppId."
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

Write-Host "Loading Win32 apps from Intune..." -ForegroundColor Cyan

$uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')"
$apps = @()

do {
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri
    $apps += $response.value
    $uri = $response.'@odata.nextLink'
}
while ($uri)

$win32Apps = @(
    $apps | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.win32LobApp' }
)

function Resolve-Win32App {
    param(
        [string]$Name,
        [string]$Id
    )

    if ($Id) {
        $match = @($win32Apps | Where-Object id -eq $Id)
        if ($match.Count -eq 0) {
            Write-Warning "Win32 app not found with ID: $Id"
            return $null
        }
        return $match[0]
    }

    $pattern = if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Name)) { $Name } else { "*$Name*" }
    $matchingApps = @($win32Apps | Where-Object displayName -like $pattern | Sort-Object displayName, displayVersion, id)

    if ($matchingApps.Count -eq 0) {
        Write-Warning "Win32 app not found: $Name"
        return $null
    }
    elseif ($matchingApps.Count -eq 1) {
        return $matchingApps[0]
    }

    Write-Host "`nMultiple Win32 apps match '$Name'. Select one or more:" -ForegroundColor Yellow

    for ($i = 0; $i -lt $matchingApps.Count; $i++) {
        Write-Host ("[{0}]" -f $i) -ForegroundColor Cyan -NoNewline
        Write-Host (" Name: {0}  Version: {1}  Created: {2}  Id: {3}" -f $matchingApps[$i].displayName, $matchingApps[$i].displayVersion, $matchingApps[$i].createdDateTime, $matchingApps[$i].id)
    }

    $selection = Read-Host "`nEnter app numbers separated by commas, A for all matches, or blank to skip"
    if ([string]::IsNullOrWhiteSpace($selection)) {
        Write-Warning "Skipping '$Name'."
        return $null
    }

    if ($selection.Trim() -eq 'A') {
        return $matchingApps
    }

    $indices = @()
    foreach ($entry in ($selection -split ',')) {
        $entry = $entry.Trim()
        $index = 0
        if ($entry -notmatch '^\d+$' -or -not [int]::TryParse($entry, [ref]$index) -or $index -ge $matchingApps.Count) {
            Write-Warning "Invalid selection '$selection'. Enter valid app numbers separated by commas or A for all matches. Skipping '$Name'."
            return $null
        }
        if ($indices -notcontains $index) {
            $indices += $index
        }
    }

    return $matchingApps[$indices]
}

function Export-IntuneReport {
    param(
        [string]$ReportName,
        [string]$ApplicationId,
        [string]$Destination
    )

    $body = @{
        reportName       = $ReportName
        filter           = "(ApplicationId eq '$ApplicationId')"
        format           = "csv"
        localizationType = "LocalizedValuesAsAdditionalColumn"
    } | ConvertTo-Json

    $job = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs" -Body $body -ContentType "application/json"
    if (-not $job.id) { throw "Intune did not return an export job ID for $ReportName." }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($job.status -notin @('completed', 'failed')) {
        if ((Get-Date) -gt $deadline) {
            throw "Timed out after $TimeoutSeconds seconds waiting for $ReportName export job $($job.id)."
        }
        Start-Sleep -Seconds 3
        $job = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs('$($job.id)')"
    }

    if ($job.status -eq 'failed') {
        throw "$ReportName export job $($job.id) failed."
    }
    if (-not $job.url) { throw "$ReportName export completed without a download URL." }

    # The export is delivered as a zip containing a single CSV via a pre-signed URL (no auth header needed)
    $tempName = "IntuneWin32Report-$([guid]::NewGuid())"
    $zipPath = Join-Path ([IO.Path]::GetTempPath()) "$tempName.zip"
    $extractPath = Join-Path ([IO.Path]::GetTempPath()) $tempName
    try {
        Invoke-WebRequest -Uri $job.url -OutFile $zipPath -UseBasicParsing
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
        $csv = Get-ChildItem -LiteralPath $extractPath -Filter *.csv -File -Recurse | Select-Object -First 1
        if (-not $csv) {
            throw "$ReportName export job $($job.id) did not contain a CSV file."
        }
        Move-Item -LiteralPath $csv.FullName -Destination $Destination -Force
    }
    finally {
        foreach ($temporaryPath in @($zipPath, $extractPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                try { Remove-Item -LiteralPath $temporaryPath -Recurse -Force -ErrorAction Stop }
                catch { Write-Warning "Could not remove temporary report data at '$temporaryPath': $($_.Exception.Message)" }
            }
        }
    }

    return @(Import-Csv -LiteralPath $Destination)
}

function Get-DeploymentState {
    param([object]$Row)
    foreach ($column in @('AppInstallState_loc', 'InstallState_loc')) {
        if ($Row.PSObject.Properties[$column] -and -not [string]::IsNullOrWhiteSpace([string]$Row.$column)) {
            return [string]$Row.$column
        }
    }
    $map = @{ '-1'='Error'; '0'='Unknown'; '1'='Installed'; '2'='Failed'; '3'='Not applicable'; '4'='Not installed'; '5'='Pending install'; '6'='Uninstalled' }
    $raw = [string]$Row.InstallState
    if ($map.ContainsKey($raw)) { return $map[$raw] }
    if ($raw -and $raw -notmatch '^-?\d+$') { return $raw }
    return "Unknown ($raw)"
}

function Get-DeploymentDeviceSummary {
    param([object[]]$Rows, [string]$AppDisplayName, [string]$ApplicationId, [string]$AppDisplayVersion)
    $precedence = @('error', 'failed', 'notinstalled', 'installpending', 'pendinginstall', 'installed', 'uninstalled', 'notapplicable')
    # Missing IDs must not collapse unrelated records into a fictitious single device.
    $withIds = @($Rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.DeviceId) })
    $missingIds = @($Rows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.DeviceId) })
    if ($missingIds.Count) { Write-Warning "$($missingIds.Count) row(s) have no DeviceId; retained separately and excluded from identified-device counts." }
    $groups = @($withIds | Group-Object DeviceId)
    foreach ($group in $groups) {
        $worst = $group.Group | Sort-Object {
            $rawState = [string]$_.InstallState
            $state = if ($rawState -match '^-?\d+$') { Get-DeploymentState ([pscustomobject]@{InstallState=$rawState}) } else { $_.InstallStateFriendly }
            $rank = $precedence.IndexOf(($state -replace '\s', '').ToLowerInvariant())
            if ($rank -lt 0) { -1 } else { $rank }
        } | Select-Object -First 1
        [pscustomobject]@{
            AppDisplayName=$AppDisplayName; ApplicationId=$ApplicationId; AppDisplayVersion=$AppDisplayVersion
            DeviceId=$group.Name; DeviceName=$worst.DeviceName; InstallStateFriendly=$worst.InstallStateFriendly
            ReportRows=$group.Count; IdentityStatus='Identified'
        }
    }
    foreach ($row in $missingIds) {
        [pscustomobject]@{
            AppDisplayName=$AppDisplayName; ApplicationId=$ApplicationId; AppDisplayVersion=$AppDisplayVersion
            DeviceId=''; DeviceName=$row.DeviceName; InstallStateFriendly=$row.InstallStateFriendly
            ReportRows=1; IdentityStatus='Missing DeviceId'
        }
    }
}

$selectedApps = @()

foreach ($id in $AppId) {
    $resolved = Resolve-Win32App -Id $id
    if ($resolved) {
        $selectedApps += $resolved
    }
}

foreach ($name in $AppName) {
    $resolved = Resolve-Win32App -Name $name
    if ($resolved) {
        $selectedApps += $resolved
    }
}

$selectedApps = @($selectedApps | Sort-Object -Property id -Unique)

if ($selectedApps.Count -eq 0) {
    throw "No Win32 apps were resolved. Nothing to report on."
}

$timestamp = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N')
$deploymentResults = @(
    foreach ($app in $selectedApps) { [pscustomobject]@{ AppId = $app.id; Status = 'NotProcessed' } }
)

for ($appIndex = 0; $appIndex -lt $selectedApps.Count; $appIndex++) {
    $app = $selectedApps[$appIndex]
    $deploymentOutcome = $deploymentResults[$appIndex]
    Write-Host "`n---" -ForegroundColor DarkGray
    Write-Host "App:          $($app.displayName)" -ForegroundColor Green
    Write-Host "App version:  $($app.displayVersion)" -ForegroundColor Green
    Write-Host "App ID:       $($app.id)" -ForegroundColor Green

    $safeName = ($app.displayName -replace '[\\/:*?"<>|]', '_').Trim()
    $baseName = "{0}_{1}_{2}" -f $safeName, $app.id, $timestamp

    try {
        Write-Host "Exporting device install status report..." -ForegroundColor Cyan
        $deviceFile = Join-Path $OutputPath "$baseName`_DeviceStatus.csv"
        $deviceRows = @(Export-IntuneReport -ReportName "DeviceInstallStatusByApp" -ApplicationId $app.id -Destination $deviceFile)
        foreach ($row in $deviceRows) {
            $row | Add-Member -NotePropertyName InstallStateFriendly -NotePropertyValue (Get-DeploymentState $row) -Force
            $row | Add-Member -NotePropertyName AppDisplayName -NotePropertyValue $app.displayName -Force
            $row | Add-Member -NotePropertyName ApplicationId -NotePropertyValue $app.id -Force
            $row | Add-Member -NotePropertyName AppDisplayVersion -NotePropertyValue $app.displayVersion -Force
        }
        if ($deviceRows.Count) {
            $deviceRows | Sort-Object InstallStateFriendly, DeviceName | Export-Csv -LiteralPath $deviceFile -NoTypeInformation -Encoding utf8
        }
        Write-Host "Saved $($deviceRows.Count) device row(s) to $deviceFile" -ForegroundColor Green
        $deviceRows
        $summaryFile = Join-Path $OutputPath "$baseName`_DeviceSummary.csv"
        $deviceSummary = @(Get-DeploymentDeviceSummary -Rows $deviceRows -AppDisplayName $app.displayName -ApplicationId $app.id -AppDisplayVersion $app.displayVersion)
        if ($deviceSummary.Count) {
            $deviceSummary | Export-Csv -LiteralPath $summaryFile -NoTypeInformation -Encoding utf8
            Write-Host "Saved $($deviceSummary.Count) device summary row(s) to $summaryFile" -ForegroundColor Green
            Write-Host "`nDevice summary (one worst-known state per identified device):" -ForegroundColor Cyan
            $deviceSummary | Where-Object IdentityStatus -eq 'Identified' | Group-Object InstallStateFriendly |
                Select-Object Name, Count | Format-Table -AutoSize | Out-Host
        }
        else { Write-Warning "The device report for $($app.displayName) contains no records." }

        if ($deviceRows.Count -gt 0) {
            $stateColumn = 'InstallStateFriendly'
            if ($stateColumn) {
                Write-Host "`nRaw report row counts (a device can have multiple user rows):" -ForegroundColor Cyan
                $deviceRows | Group-Object -Property $stateColumn | Sort-Object Count -Descending |
                    Format-Table @{ Label = 'Status'; Expression = { $_.Name } }, Count -AutoSize | Out-Host
            }
        }

        if ($IncludeUserStatus) {
            Write-Host "Exporting user install status report..." -ForegroundColor Cyan
            $userFile = Join-Path $OutputPath "$baseName`_UserStatus.csv"
            $userRows = @(Export-IntuneReport -ReportName "UserInstallStatusAggregateByApp" -ApplicationId $app.id -Destination $userFile)
            Write-Host "Saved $($userRows.Count) user row(s) to $userFile" -ForegroundColor Green
        }
        if ($OpenReport) {
            foreach ($report in @($deviceFile, $summaryFile, $(if ($IncludeUserStatus) { $userFile }))) {
                if ($report -and (Test-Path -LiteralPath $report -PathType Leaf)) { Invoke-Item -LiteralPath $report -ErrorAction Stop }
            }
        }
        $deploymentOutcome.Status = 'Reported'
    }
    catch {
        $deploymentOutcome.Status = 'Failed'
        Write-Error "Failed to export report for $($app.displayName): $($_.Exception.Message)" -ErrorAction Continue
    }
}
}
finally {
    $deploymentRuntime.Stop()
    Write-Host "Report ended:   $([datetimeoffset]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff zzz'))" -ForegroundColor Cyan
    Write-Host "Report elapsed: $($deploymentRuntime.Elapsed.ToString('c')) (includes sign-in, app selection and report generation; does not imply success)" -ForegroundColor Cyan
}
