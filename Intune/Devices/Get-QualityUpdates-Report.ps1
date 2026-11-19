# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Exports device-level status for an Intune Windows Quality Update (expedited update) policy.

.DESCRIPTION
    Connects to Microsoft Graph, finds a Windows Quality Update profile (expedited update policy)
    by display name, and runs the Intune "QualityUpdateDeviceStatusByPolicy" export report for it.
    The report is downloaded, extracted, sorted, saved as a CSV to -OutputPath, and a summary of
    device counts by aggregate status is printed to the console.

.PARAMETER PolicyName
    The display name of the Windows Quality Update profile to report on. Must match exactly
    one policy; the script throws if zero or more than one policy is found with this name.

.PARAMETER PolicyId
    Selects a Windows Quality Update profile by ID instead of name.

.PARAMETER ListPolicies
    Returns available policy IDs and display names without starting a report.

.PARAMETER OutputPath
    The folder to save the final CSV report to. Defaults to the current user's temp folder.
    Created automatically if it doesn't already exist.

.PARAMETER OpenReport
    Open the finished CSV in its default application once the export completes.

.EXAMPLE
    .\Get-QualityUpdates-Report.ps1 -PolicyName "September 2026 zero-day Firmwide"

    Reports on the named expedited update policy and saves the CSV to %TEMP%.

.EXAMPLE
    .\Get-QualityUpdates-Report.ps1 -PolicyName "September 2026 zero-day Firmwide" -OutputPath "$env:USERPROFILE\Desktop"

    Reports on the named policy and saves the CSV to the desktop instead.

.EXAMPLE
    .\Get-QualityUpdates-Report.ps1 -PolicyName "September 2026 zero-day Firmwide" -OpenReport

    Reports on the named policy and opens the CSV when the export finishes.

.NOTES
    Requires an active Microsoft Graph connection with permissions to read Intune device
    management reports (e.g. DeviceManagementConfiguration.Read.All). Uses the beta Graph
    endpoint for windowsQualityUpdateProfiles and deviceManagement/reports/exportJobs.

    Author:         eric@hillcraft.email
    Created:        2026-09-11
    Last Modified:  2026-09-15
#>

[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'ByName')]
    [ValidateNotNullOrEmpty()]
    [string]$PolicyName,

    [Parameter(Position = 1, ParameterSetName = 'ByName')]
    [Parameter(ParameterSetName = 'ById')]
    [string]$OutputPath = "$env:TEMP",

    # Open the finished CSV once the export completes.
    [Parameter(ParameterSetName = 'ByName')]
    [Parameter(ParameterSetName = 'ById')]
    [switch]$OpenReport,

    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [guid]$PolicyId,

    [Parameter(Mandatory, ParameterSetName = 'List')]
    [switch]$ListPolicies
)

if ($PSCmdlet.ParameterSetName -eq 'List' -and -not $ListPolicies) { throw 'Specify -ListPolicies to list policies.' }
$ErrorActionPreference = "Stop"
if (Get-MgContext) {
   write-host "Connected to MgGraph..."
    #Disconnect-MgGraph | Out-Null
} else {
    write-host "Not connected to MgGraph. Connecting..."
    Connect-MgGraph -NoWelcome | Out-Null
    #-Scopes "DeviceManagementApps.Read.All" -NoWelcome
}

# Find the expedited update policy
if ($PSCmdlet.ParameterSetName -eq 'ByName') {
    Write-Host "Finding expedited update policy: $PolicyName" -ForegroundColor Cyan
}

$uri = "https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdateProfiles"
$policies = @()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

do {
    $address = [uri]$uri
    if (-not $address.IsAbsoluteUri -or $address.Scheme -ne 'https' -or
        $address.Host -ne 'graph.microsoft.com' -or -not $address.IsDefaultPort -or
        $address.AbsolutePath -ne '/beta/deviceManagement/windowsQualityUpdateProfiles' -or -not $seen.Add($uri)) {
        throw 'Intune returned an invalid or repeated policy page.'
    }
    $response = Invoke-MgGraphRequest -Method GET -Uri $uri
    if ($null -eq $response.value) { throw 'Intune did not return a policy collection.' }
    $policies += $response.value
    $uri = $response.'@odata.nextLink'
}
while ($uri)

if ($ListPolicies) {
    return @($policies | Sort-Object DisplayName, Id | ForEach-Object {
        $id = [guid]::Empty
        if (-not [guid]::TryParse([string]$_.Id, [ref]$id) -or [string]::IsNullOrWhiteSpace([string]$_.DisplayName)) {
            throw 'Intune returned a policy without a valid ID or display name.'
        }
        [pscustomobject]@{ Id = $id.ToString(); DisplayName = [string]$_.DisplayName }
    })
}

if ($PSCmdlet.ParameterSetName -eq 'ById') {
    $policy = @($policies | Where-Object Id -eq $PolicyId.ToString())
    if ($policy.Count -ne 1) { throw 'The selected policy could not be resolved. Reload policies and try again.' }
    $PolicyName = [string]$policy[0].DisplayName
}
else {
    $policy = @($policies | Where-Object DisplayName -eq $PolicyName)

    if ($policy.Count -eq 0) { throw "Policy not found: $PolicyName" }
    if ($policy.Count -gt 1) { throw "Multiple policies were found named: $PolicyName" }
}

$selectedPolicyId = $policy[0].Id

Write-Host "Policy found: $($policy[0].DisplayName)" -ForegroundColor Green
Write-Host "Policy ID:    $selectedPolicyId" -ForegroundColor Green

# Do not manually select the _loc columns.
# Intune adds them through localizationType.
$bodyObject = @{
    reportName       = "QualityUpdateDeviceStatusByPolicy"
    filter           = "(PolicyId eq '$selectedPolicyId')"
    localizationType = "LocalizedValuesAsAdditionalColumn"
    format           = "csv"
    select           = @(
        "AADDeviceId"
        "AggregateState"
        "CurrentDeviceUpdateStatus"
        "CurrentDeviceUpdateSubstatus"
        "DeviceId"
        "DeviceName"
        "EventDateTimeUTC"
        "LastWUScanTimeUTC"
        "LatestAlertMessage"
        "OwnerType"
        "PolicyId"
        "UPN"
    )
}

$body = $bodyObject | ConvertTo-Json -Depth 10

Write-Host "Starting Intune report export..." -ForegroundColor Cyan

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

# Wait for report generation
$timeout = (Get-Date).AddMinutes(10)

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
        throw "The Intune report export timed out after 10 minutes."
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

$safePolicyName = $PolicyName -replace '[\\/:*?"<>|]', '_'
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$zipPath = Join-Path $env:TEMP "IntuneExpeditedUpdate-$timestamp.zip"
$extractPath = Join-Path $env:TEMP "IntuneExpeditedUpdate-$timestamp"
$finalCsv = Join-Path $OutputPath "$safePolicyName-Status-$timestamp.csv"

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

# Import the actual device data
$results = @(
    Import-Csv -Path $downloadedCsv.FullName
)

if ($results.Count -eq 0) {
    Write-Warning "The export completed but returned zero device records."
}
else {
    # Create a clean, sorted CSV
    $results |
    Sort-Object AggregateState_loc, DeviceName |
    Export-Csv `
        -Path $finalCsv `
        -NoTypeInformation `
        -Encoding UTF8

    Write-Host "`nStatus summary:" -ForegroundColor Cyan

    $statusColumn = if (
        $results[0].PSObject.Properties.Name -contains "AggregateState_loc"
    ) {
        "AggregateState_loc"
    }
    else {
        "AggregateState"
    }

   $results |
    Group-Object -Property $statusColumn |
    Sort-Object Count -Descending |
    Select-Object Name, Count |
    Format-Table -AutoSize

    Write-Host "Total device records: $($results.Count)" -ForegroundColor Green

   # Write-Host "`nDevice status results:" -ForegroundColor Cyan

    <#$results |
    Select-Object `
        DeviceName,
    UPN,
    AggregateState_loc,
    CurrentDeviceUpdateStatus_loc,
    CurrentDeviceUpdateSubstatus_loc,
    EventDateTimeUTC,
    LastWUScanTimeUTC,
    LatestAlertMessage_loc |
    Format-Table -AutoSize#>
}

# Clean up temporary files
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`nReport saved to:" -ForegroundColor Green
Write-Host $finalCsv

if ($OpenReport -and (Test-Path $finalCsv)) {
    Invoke-Item -Path $finalCsv
}