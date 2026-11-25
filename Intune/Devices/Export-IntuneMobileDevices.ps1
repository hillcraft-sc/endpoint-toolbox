<#
.SYNOPSIS
    Exports all iOS and Android managed devices from Microsoft Intune to a CSV file using Microsoft Graph API.

.DESCRIPTION
    Connects to Microsoft Graph interactively and queries Intune managed devices (iOS and Android).
    Supports automatic paging through all records, handles both iOS (including iPadOS) and Android
    (including Android Enterprise / Android for Work), extracts key mobile device management attributes,
    and exports them to a timestamped CSV file.

.PARAMETER Platform
    Specifies the mobile platform to export. Options are 'All' (default, includes iOS and Android),
    'iOS' (includes iOS and iPadOS), or 'Android' (includes Android Enterprise / Android for Work).

.PARAMETER OutputPath
    The directory or file path where the CSV report will be saved.
    Defaults to the user's temp directory with a timestamped file name.

.PARAMETER ForceInteractive
    Forces a fresh interactive sign-in prompt even if an active Graph session already exists.

.PARAMETER OpenReport
    Automatically opens the exported CSV file in the default application once complete.

.EXAMPLE
    .\Export-IntuneMobileDevices.ps1

    Interactively connects to Graph, retrieves all iOS and Android devices, and saves the CSV to %TEMP%.

.EXAMPLE
    .\Export-IntuneMobileDevices.ps1 -Platform iOS -OutputPath "C:\Reports" -OpenReport

    Exports all iOS/iPadOS devices to C:\Reports and opens the resulting CSV.

.EXAMPLE
    .\Export-IntuneMobileDevices.ps1 -Platform Android -ForceInteractive

    Forces a new interactive sign-in prompt and exports all Android devices.

.NOTES
    Requires the Microsoft.Graph.Authentication module and delegated permissions:
    DeviceManagementManagedDevices.Read.All (or DeviceManagementManagedDevices.ReadWrite.All).

    Endpoint used: Microsoft Graph beta deviceManagement/managedDevices.
#>

[CmdletBinding()]
param(
    [ValidateSet('All', 'iOS', 'Android')]
    [string]$Platform = 'All',

    [string]$OutputPath = "$env:TEMP",

    [switch]$ForceInteractive,

    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'

# ==============================================================================
# Graph Connection (Interactive)
# ==============================================================================

$requiredScopes = @('DeviceManagementManagedDevices.Read.All')

if ($ForceInteractive) {
    Write-Host "Forcing interactive sign-in to Microsoft Graph..." -ForegroundColor Cyan
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    catch { }
    Connect-MgGraph -Scopes $requiredScopes -NoWelcome
}
else {
    $currentContext = Get-MgContext
    $hasRequiredScope = $false

    if ($currentContext -and $currentContext.Scopes) {
        $hasRequiredScope = [bool]($currentContext.Scopes | Where-Object {
            $_ -in @('DeviceManagementManagedDevices.Read.All', 'DeviceManagementManagedDevices.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All')
        })
    }

    if ($currentContext -and $hasRequiredScope) {
        Write-Host "Already connected to Microsoft Graph as: $($currentContext.Account) (Tenant: $($currentContext.TenantId))" -ForegroundColor Green
    }
    else {
        Write-Host "Initiating interactive sign-in to Microsoft Graph..." -ForegroundColor Cyan
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    }
}

$context = Get-MgContext
if (-not $context) {
    throw "Failed to establish a connection to Microsoft Graph."
}

Write-Host "Signed in as: $($context.Account)" -ForegroundColor Gray
Write-Host "Tenant ID  : $($context.TenantId)" -ForegroundColor Gray

# ==============================================================================
# Build Filter & Graph Query
# ==============================================================================

$iosFilter = "(operatingSystem eq 'iOS' or operatingSystem eq 'iPadOS')"
$androidFilter = "(operatingSystem eq 'Android' or operatingSystem eq 'AndroidEnterprise' or operatingSystem eq 'AndroidForWork' or operatingSystem eq 'AndroidOpenSourceProject')"

switch ($Platform) {
    'iOS' {
        $filter = $iosFilter
        Write-Host "Querying Intune for iOS and iPadOS devices..." -ForegroundColor Cyan
    }
    'Android' {
        $filter = $androidFilter
        Write-Host "Querying Intune for Android devices..." -ForegroundColor Cyan
    }
    'All' {
        $filter = "$iosFilter or $androidFilter"
        Write-Host "Querying Intune for all iOS, iPadOS, and Android devices..." -ForegroundColor Cyan
    }
}

# Encode query filter
$encodedFilter = [System.Uri]::EscapeDataString($filter)
$baseUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=$encodedFilter&`$top=999"

# ==============================================================================
# Retrieve Managed Devices (with Paging)
# ==============================================================================

$devices = [System.Collections.Generic.List[object]]::new()
$nextUri = $baseUri
$pageCount = 0

Write-Host "Fetching devices from Graph API..." -ForegroundColor Cyan

do {
    $pageCount++
    Write-Host "  Retrieving page $pageCount..." -ForegroundColor Gray
    $response = Invoke-MgGraphRequest -Method GET -Uri $nextUri

    if ($response.value) {
        foreach ($item in $response.value) {
            $devices.Add($item)
        }
    }

    $nextUri = $response.'@odata.nextLink'
} while ($nextUri)

Write-Host "Retrieved $($devices.Count) device(s) total." -ForegroundColor Green

if ($devices.Count -eq 0) {
    Write-Warning "No devices matched the selected filter ($Platform)."
    return
}

# ==============================================================================
# Process and Format Device Records
# ==============================================================================

Write-Host "Processing device attributes for export..." -ForegroundColor Cyan

$report = foreach ($d in $devices) {
    [PSCustomObject]@{
        DeviceName            = $d.deviceName
        UserPrincipalName     = $d.userPrincipalName
        UserDisplayName       = $d.userDisplayName
        OperatingSystem       = $d.operatingSystem
        OSVersion             = $d.osVersion
        Model                 = $d.model
        Manufacturer          = $d.manufacturer
        SerialNumber          = $d.serialNumber
        IMEI                  = $d.imei
        MEID                  = $d.meid
        PhoneNumber           = $d.phoneNumber
        WiFiMacAddress        = $d.wiFiMacAddress
        ComplianceState       = $d.complianceState
        Ownership             = $d.managedDeviceOwnerType
        ManagementAgent       = $d.managementAgent
        IsSupervised          = $d.isSupervised
        JailBroken            = $d.jailBroken
        EnrolledDateTime      = $d.enrolledDateTime
        LastSyncDateTime      = $d.lastSyncDateTime
        IntuneDeviceId        = $d.id
        EntraDeviceId         = $d.azureADDeviceId
        EntraRegistered       = $d.azureADRegistered
        TotalStorageGB        = if ($d.totalStorageSpaceInBytes) { [math]::Round($d.totalStorageSpaceInBytes / 1GB, 2) } else { $null }
        FreeStorageGB         = if ($d.freeStorageSpaceInBytes) { [math]::Round($d.freeStorageSpaceInBytes / 1GB, 2) } else { $null }
        SubscriberCarrier     = $d.subscriberCarrier
    }
}

# ==============================================================================
# Export to CSV
# ==============================================================================

# Determine file and folder path
if ($OutputPath -match '\.csv$') {
    $targetFile = $OutputPath
    $targetFolder = Split-Path -Path $targetFile -Parent
}
else {
    $targetFolder = $OutputPath
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $targetFile = Join-Path -Path $targetFolder -ChildPath "IntuneMobileDevices-$Platform-$timestamp.csv"
}

if (-not (Test-Path -Path $targetFolder)) {
    New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
}

$report | Export-Csv -Path $targetFile -NoTypeInformation -Encoding UTF8

Write-Host "`nExport successfully completed!" -ForegroundColor Green
Write-Host "Report saved to: $targetFile" -ForegroundColor Yellow

# ==============================================================================
# Summary Breakdown
# ==============================================================================

Write-Host "`n--- Summary Breakdown ---" -ForegroundColor Cyan
Write-Host "Total Devices: $($report.Count)"

Write-Host "`nBy Operating System:" -ForegroundColor Gray
$report | Group-Object OperatingSystem | Select-Object Count, Name | Format-Table -AutoSize | Out-String | Write-Host

Write-Host "By Compliance State:" -ForegroundColor Gray
$report | Group-Object ComplianceState | Select-Object Count, Name | Format-Table -AutoSize | Out-String | Write-Host

Write-Host "By Ownership (Company / Personal):" -ForegroundColor Gray
$report | Group-Object Ownership | Select-Object Count, Name | Format-Table -AutoSize | Out-String | Write-Host

if ($OpenReport) {
    Write-Host "Opening report..." -ForegroundColor Cyan
    Invoke-Item -Path $targetFile
}
