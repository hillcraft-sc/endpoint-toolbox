# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Deletes one or more Win32 apps from Intune, with wildcard name matching and interactive selection.

.DESCRIPTION
    Connects to Microsoft Graph and deletes the specified Win32 app(s) (win32LobApp) from Intune.
    Apps can be targeted by display name or wildcard pattern (-AppName), or object ID (-AppId).
    Either parameter accepts multiple values for bulk deletion. If a name or pattern matches
    more than one app object, the script lists them with name, version, created date, and ID so
    one or more can be selected interactively, all matches selected with A, or the pattern skipped.
    Before deleting, all requested apps are resolved up front, deduplicated by ID, and displayed.
    Each app's current assignments are checked and warned about,
    and deletion requires confirmation (via ShouldProcess) plus a justification string, which
    Intune requires via the x-msft-approval-justification header. If the tenant has Multi Admin
    Approval enabled for app deletions, the request is submitted for a second admin's approval
    instead of deleting immediately, and the script reports the approval code.
    Assignment lookup or deletion failures are reported per app without stopping the remaining
    selected apps. Apps whose assignments cannot be checked are not deleted. Dependency or
    supersedence relationships are not automatically removed to bypass Intune's deletion guards.
    Saves a unique per-run CSV with app details, status and reason, including pending approval,
    preview, declined and unprocessed targets. Prints a final summary of the run.

.PARAMETER AppName
    One or more display names or PowerShell wildcard patterns of Win32 apps to delete.
    Matching is case-insensitive. Use * for any number of characters, ? for one character,
    or [abc] for a character set. If a name or pattern matches multiple apps, you'll be
    prompted to enter one number, comma-separated numbers (e.g. 0,2,3), A for all matches,
    or blank to skip the pattern. Matching all apps does not automatically select all for deletion.
    Escape wildcard characters with [System.Management.Automation.WildcardPattern]::Escape()
    when searching for a literal display name containing them.

.PARAMETER AppId
    One or more Intune mobileApps object IDs to delete directly, bypassing the name lookup and
    any disambiguation prompt.

.PARAMETER Justification
    The business justification text required by Intune for the deletion. If not supplied, you'll
    be prompted for it once and it's reused for every app being deleted in this run.

.PARAMETER OutputPath
    Folder for the per-run outcome CSV. Defaults to TEMP. Reports are also written in preview.

.EXAMPLE
    .\Remove-Win32App.ps1 -AppName "Google Chrome (MSI-x64) - (PMP Update)" -Justification "Cleaning up unused application"

    Deletes the named Win32 app, prompting to select versions if more than one is found.

.EXAMPLE
    .\Remove-Win32App.ps1 -AppName "*ACPWork10Tools*" -Justification "Cleaning up a retired application"

    Finds apps whose names contain ACPWork10Tools. If multiple apps match, enter 0,2 to select
    those two apps, A to select all matches, or blank to skip. Deletion still requires confirmation.

.EXAMPLE
    .\Remove-Win32App.ps1 -AppName "App One", "App Two" -AppId "00000000-0000-0000-0000-000000000000"

    Resolves and deletes all three specified apps in one run, prompting for justification once.

.NOTES
    Requires an active Microsoft Graph connection with permissions to read and delete Intune apps
    (e.g. DeviceManagementApps.ReadWrite.All). Uses the beta Graph endpoint for
    deviceAppManagement/mobileApps. Supports -WhatIf/-Confirm via SupportsShouldProcess.

    Author:         eric@hillcraft.email
    Created:        2026-09-11
    Last Modified:  2026-11-05
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string[]]$AppName = @(),
    [string[]]$AppId = @(),
    [string]$Justification = "",
    [ValidateNotNullOrEmpty()][string]$OutputPath = $env:TEMP
)

$ErrorActionPreference = "Stop"
if (Get-MgContext) {
    Write-Host "Connected to MgGraph..." -ForegroundColor Green
}
else {
    Write-Host "Not connected to MgGraph. Connecting..." -ForegroundColor Yellow
    Connect-MgGraph -NoWelcome | Out-Null
    #-Scopes "DeviceManagementApps.ReadWrite.All" -NoWelcome
}

if ($AppName.Count -eq 0 -and $AppId.Count -eq 0) {
    throw "Specify at least one -AppName or -AppId."
}

Write-Host "Loading Win32 apps from Intune..." -ForegroundColor Cyan

$uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps"
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

    $matchingApps = @(
        $win32Apps | Where-Object displayName -like $Name
    )

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

# Resolve every requested app up front so bad names/IDs are reported before anything is deleted
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
    throw "No Win32 apps were resolved. Nothing to delete."
}

Write-Host "`nApps to delete:" -ForegroundColor Cyan
$selectedApps | ForEach-Object {
    Write-Host (" - {0} (v{1}) [{2}]" -f $_.displayName, $_.displayVersion, $_.id)
}

if (-not $Justification) {
    $Justification = Read-Host "`nEnter a justification for these deletions (required by Intune)"
}

$encodedJustification = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Justification))

function Get-RemovalFailureReason {
    param([Management.Automation.ErrorRecord]$Record)
    $reason = $Record.Exception.Message
    if ($Record.ErrorDetails.Message) {
        try {
            $detail = $Record.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
            if ($detail.error.message) {
                $reason = [string]$detail.error.message
                if ($reason.TrimStart().StartsWith('{')) {
                    $nested = $reason | ConvertFrom-Json -ErrorAction Stop
                    if ($nested.Message) { $reason = [string]$nested.Message }
                }
            }
        }
        catch { Write-Verbose 'The Graph error was not a recognized JSON error envelope; using the original error message.' }
    }
    $dependency = [regex]::Match($reason, '(?i)Cannot delete this app as it is the parent of another app:\s*[0-9a-f-]+')
    if ($dependency.Success) { return $dependency.Value.TrimEnd('.') + '. Resolve the app relationship before retrying.' }
    $reason = ($reason -replace '\s+', ' ').Trim()
    if ($reason.Length -gt 1000) { return $reason.Substring(0,1000) + '...' }
    return $reason
}

$null = New-Item -Path $OutputPath -ItemType Directory -Force -WhatIf:$false -Confirm:$false
$OutputCsvPath = Join-Path $OutputPath ('Win32AppRemoval_{0}_{1}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N'))
$results = @(
    foreach ($app in $selectedApps) {
        [pscustomobject]@{
            AppName = $app.displayName
            AppVersion = $app.displayVersion
            AppId = $app.id
            Status = 'NotProcessed'
            Reason = 'The run ended before this app was processed.'
        }
    }
)
# Verify report persistence before submitting any deletion requests.
$results | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Encoding utf8 -WhatIf:$false -Confirm:$false

try {
for ($appIndex = 0; $appIndex -lt $selectedApps.Count; $appIndex++) {
    $app = $selectedApps[$appIndex]
    $outcome = $results[$appIndex]
    Write-Host "`n---" -ForegroundColor DarkGray
    Write-Host "App found:    $($app.displayName)" -ForegroundColor Green
    Write-Host "App version:  $($app.displayVersion)" -ForegroundColor Green
    Write-Host "App ID:       $($app.id)" -ForegroundColor Green

    # Warn if the app still has assignments, since deleting it removes those assignments too
    try {
        $assignments = @(
            (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)/assignments").value
        )
    }
    catch {
        if ($_.Exception -is [Management.Automation.PipelineStoppedException]) { throw }
        $outcome.Status = 'Failed'
        $outcome.Reason = "Assignment lookup failed; deletion was not attempted: $(Get-RemovalFailureReason $_)"
        Write-Error "Failed to read assignments for '$($app.displayName)' ($($app.id)); skipping deletion: $_" -ErrorAction Continue
        continue
    }

    if ($assignments.Count -gt 0) {
        Write-Warning "This app has $($assignments.Count) assignment(s). Deleting it will remove those assignments as well."
    }

    if (-not $PSCmdlet.ShouldProcess("$($app.displayName) ($($app.id))", "Delete Win32 app from Intune")) {
        $outcome.Status = if ($WhatIfPreference) { 'WhatIf' } else { 'Declined' }
        $outcome.Reason = if ($WhatIfPreference) { 'Preview only; no deletion request submitted.' } else { 'Deletion confirmation was declined.' }
        continue
    }

    try {
        $outcome.Status = 'NotConfirmed'
        $outcome.Reason = 'A deletion request started, but completion was not confirmed. Check Intune before retrying.'
        Invoke-MgGraphRequest `
            -Method DELETE `
            -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($app.id)" `
            -Headers @{ "x-msft-approval-justification" = $encodedJustification }

        Write-Host "Deleted: $($app.displayName) ($($app.id))" -ForegroundColor Green
        $outcome.Status = 'Deleted'
        $outcome.Reason = 'Intune accepted the deletion request.'
    }
    catch {
        if ($_.Exception -is [Management.Automation.PipelineStoppedException]) { throw }
        # Tenants with Multi-Admin Approval return 412 with an approval code instead of deleting immediately
        $errorText = "$($_.Exception.Message)`n$($_.ErrorDetails.Message)"
        $approvalMatch = [regex]::Match($errorText, 'x-msft-approval-code[":\s]+([0-9a-fA-F-]{36})')

        if ($approvalMatch.Success) {
            $outcome.Status = 'PendingApproval'
            $outcome.Reason = "Multi-Admin Approval required; approval code: $($approvalMatch.Groups[1].Value). The app has not been deleted."
            Write-Host "Deletion requires Multi-Admin Approval." -ForegroundColor Yellow
            Write-Host "A request has been submitted (approval code: $($approvalMatch.Groups[1].Value))." -ForegroundColor Yellow
            Write-Host "Ask another admin to approve it under Intune admin center > Tenant administration > Multi Admin Approval." -ForegroundColor Yellow
        }
        else {
            $outcome.Status = 'Failed'
            $outcome.Reason = Get-RemovalFailureReason $_
            Write-Error "Failed to delete '$($app.displayName)': $_" -ErrorAction Continue
        }
    }
}
}
finally {
    $results | Export-Csv -LiteralPath $OutputCsvPath -NoTypeInformation -Encoding utf8 -WhatIf:$false -Confirm:$false
    $deletedCount = @($results | Where-Object Status -eq 'Deleted').Count
    $failedCount = @($results | Where-Object Status -eq 'Failed').Count
    $pendingCount = @($results | Where-Object Status -eq 'PendingApproval').Count
    $skippedCount = @($results | Where-Object Status -in @('WhatIf','Declined')).Count
    $unprocessedCount = @($results | Where-Object Status -in @('NotProcessed','NotConfirmed')).Count
    Write-Host "`nSummary: Apps targeted: $($results.Count) | Succeeded: $deletedCount | Failed: $failedCount | Pending approval: $pendingCount | Skipped/preview: $skippedCount | Not processed/unknown: $unprocessedCount" -ForegroundColor Cyan
    Write-Host "Run report: $OutputCsvPath" -ForegroundColor Cyan
}
