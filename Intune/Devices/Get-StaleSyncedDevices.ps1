# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Exports AD-synced Entra ID devices with no Entra sign-in activity within a set number of days.

.DESCRIPTION
    Connects to Microsoft Graph and pages through every device object in Entra ID, keeping those
    currently or formerly synced from on-premises Active Directory (onPremisesSyncEnabled = true
    or false). Devices whose approximateLastSignInDateTime is at least -Days old are flagged as stale.
    Missing sign-in timestamps are included with ActivityStatus = Unknown, not confirmed as stale.
    Cloud-only devices (onPremisesSyncEnabled = null) are excluded.

    The result is saved as a CSV to -OutputPath with a summary printed to the console. The activity
    date filter is applied client-side, using UTC elapsed time. Report timestamps include their
    UTC offset. Entra activity is approximate and is not updated for every sign-in. It does not
    represent on-premises AD lastLogonTimestamp, which is not exposed on the Entra device record.
    The AD-to-Entra sync timestamp is not used to determine activity.
    This report cannot find AD computers that have never had an Entra device object.

.PARAMETER Days
    The number of days since the last approximate Entra sign-in after which a device is considered stale.
    Defaults to 90.

.PARAMETER OutputPath
    The folder to save the final CSV report to. Defaults to the current user's temp folder.
    Created automatically if it doesn't already exist.

.PARAMETER OpenReport
    Open the finished CSV in its default application once the export completes.

.EXAMPLE
    .\Get-StaleSyncedDevices.ps1

    Saves AD-synced devices with no Entra sign-in in 90 days, or unknown activity, to %TEMP%.

.EXAMPLE
    .\Get-StaleSyncedDevices.ps1 -Days 180 -OutputPath "$env:USERPROFILE\Desktop" -OpenReport

    Uses a 180-day threshold, saves the report to the desktop, and opens it when finished.

.NOTES
    Requires Microsoft.Graph.Authentication and permissions to read devices
    (Device.Read.All or Directory.Read.All). Connects with Device.Read.All if not already connected.
    An existing connection must already have sufficient permissions. No devices are modified.

    Author:         eric@hillcraft.email
    Created:        2026-10-19
    Last Modified:  2026-10-19
#>
param(
    [ValidateRange(1, 3650)]
    [int]$Days = 90,

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
    Connect-MgGraph -Scopes "Device.Read.All" -NoWelcome | Out-Null
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

$now = ([DateTimeOffset](Get-Date)).ToUniversalTime()
$cutoff = $now.AddDays(-$Days)

Write-Host "Retrieving Entra devices..." -ForegroundColor Cyan

$select = "id,deviceId,displayName,operatingSystem,operatingSystemVersion,accountEnabled,trustType,onPremisesSyncEnabled,approximateLastSignInDateTime,registrationDateTime"
$deviceUri = "https://graph.microsoft.com/v1.0/devices?`$select=$select&`$top=999"
$devices = @(Get-GraphCollection -Uri $deviceUri)

Write-Host "Total devices retrieved: $($devices.Count)" -ForegroundColor DarkGray

$syncedDevices = @($devices | Where-Object {
    $_.onPremisesSyncEnabled -eq $true -or $_.onPremisesSyncEnabled -eq $false
})

Write-Host "Currently or formerly AD-synced devices: $($syncedDevices.Count)" -ForegroundColor DarkGray

function ConvertTo-ReportDate {
    param($Value)

    if ($null -ne $Value -and "$Value" -ne '') {
        return [DateTimeOffset]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        ).ToUniversalTime()
    }
    return $null
}

$results = @(
    $syncedDevices | ForEach-Object {
        $lastSignIn = ConvertTo-ReportDate $_.approximateLastSignInDateTime

        if (-not $lastSignIn -or $lastSignIn -le $cutoff) {
            $registered = ConvertTo-ReportDate $_.registrationDateTime
            [PSCustomObject]@{
                DeviceName             = $_.displayName
                DeviceObjectId         = $_.id
                DeviceId               = $_.deviceId
                OperatingSystem        = $_.operatingSystem
                OperatingSystemVersion = $_.operatingSystemVersion
                AccountEnabled         = $_.accountEnabled
                TrustType              = $_.trustType
                OnPremisesSyncEnabled  = $_.onPremisesSyncEnabled
                ActivityStatus         = if ($lastSignIn) { "Stale" } else { "Unknown" }
                LastSignInDateTime     = if ($lastSignIn) { $lastSignIn.ToString('o') } else { $null }
                DaysSinceLastSignIn    = if ($lastSignIn) { [int][Math]::Floor(($now - $lastSignIn).TotalDays) } else { $null }
                RegistrationDateTime   = if ($registered) { $registered.ToString('o') } else { $null }
            }
        }
    }
)

if ($results.Count -eq 0) {
    Write-Host "`nNo AD-synced devices found with an Entra sign-in timestamp at least $Days days old or missing." -ForegroundColor Green
    return
}

# Prepare output locations
if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$finalCsv = Join-Path $OutputPath "StaleSyncedDevices-EntraActivity-$($Days)d-$timestamp.csv"

$results |
Sort-Object @{ Expression = { $_.DaysSinceLastSignIn }; Descending = $true }, DeviceName |
Export-Csv `
    -Path $finalCsv `
    -NoTypeInformation `
    -Encoding UTF8

Write-Host "`nReported devices by operating system:" -ForegroundColor Cyan

$results |
Group-Object -Property OperatingSystem |
Sort-Object Count -Descending |
Select-Object Name, Count |
Format-Table -AutoSize

$staleCount = @($results | Where-Object { $_.ActivityStatus -eq "Stale" }).Count
$unknownCount = @($results | Where-Object { $_.ActivityStatus -eq "Unknown" }).Count
Write-Host "Stale devices (last approximate Entra sign-in on or before $($cutoff.ToString('o'))): $staleCount" -ForegroundColor Green
Write-Host "Unknown last Entra sign-in timestamp: $unknownCount" -ForegroundColor Yellow
Write-Host "Total reported devices: $($results.Count)" -ForegroundColor Green

Write-Host "`nReport saved to:" -ForegroundColor Green
Write-Host $finalCsv

if ($OpenReport -and (Test-Path $finalCsv)) {
    Invoke-Item -Path $finalCsv
}
