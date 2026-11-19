# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Reports all Intune-managed Cloud PCs and their last reported user logon.

.DESCRIPTION
    Reads Windows managed devices from Microsoft Graph beta and identifies Cloud PCs by
    deviceType (cloudPC) or model (Cloud PC*). Retrieves usersLoggedOn for each Cloud PC
    and reports the latest lastLogOnDateTime across all reported users.

    These are Intune-reported Windows logons, not Windows 365 connection events or Entra
    sign-ins. Data can lag behind actual use. Missing timestamps do not mean never used.
    Last Intune sync is reported separately. Report timestamps use Eastern time with
    automatic daylight-saving adjustments (EST/EDT) and include the UTC offset.
    Exports one row per Cloud PC to CSV and returns the report objects. Read-only.

.PARAMETER OutputPath
    CSV output folder. Defaults to the current user's temp folder.

.PARAMETER OpenReport
    Opens the exported CSV in its default application.

.EXAMPLE
    .\Get-CloudPCsLastLogin.ps1 -OutputPath C:\Temp -OpenReport

.NOTES
    Requires Microsoft.Graph.Authentication and Graph access with
    DeviceManagementManagedDevices.Read.All (delegated or application permission).
    Reuses an existing Graph connection or connects with Connect-MgGraph -NoWelcome.
    Your account also needs appropriate Intune read access. If your tenant requires
    assignment to the Graph application, an administrator must grant that access.
    Uses beta because usersLoggedOn is not available in v1.0.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = $env:TEMP,

    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
$EasternTimeZone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')

if (Get-MgContext) {
    Write-Host "Connected to MgGraph..."
}
else {
    Write-Host "Not connected to MgGraph. Connecting..."
    Connect-MgGraph -NoWelcome | Out-Null
}

$Context = Get-MgContext

Write-Host "Reading Intune Windows devices in tenant $($Context.TenantId)..."
$Select = 'id,deviceName,deviceType,model,userPrincipalName,userDisplayName,azureADDeviceId,lastSyncDateTime'
$Filter = [Uri]::EscapeDataString("operatingSystem eq 'Windows'")
$NextUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=$Filter&`$select=$Select&`$top=999"
$CloudPCs = [System.Collections.Generic.List[object]]::new()

while ($NextUri) {
    $Response = Invoke-MgGraphRequest -Method GET -Uri $NextUri -OutputType Hashtable
    foreach ($Device in $Response.value) {
        if ($Device.deviceType -eq 'cloudPC' -or $Device.model -like 'Cloud PC*') {
            $CloudPCs.Add($Device)
        }
    }
    $NextUri = $Response.'@odata.nextLink'
}

if ($CloudPCs.Count -eq 0) {
    Write-Warning 'No Intune-managed Cloud PCs were found within your access scope.'
    return
}

$Report = @(foreach ($Device in $CloudPCs) {
    $LastLogin = $null
    $LastLoginUserId = $null
    $LoginStatus = 'Not reported'
    try {
        $DetailUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($Device.id)?`$select=id,usersLoggedOn"
        $Detail = Invoke-MgGraphRequest -Method GET -Uri $DetailUri -OutputType Hashtable
        foreach ($LoggedOnUser in $Detail.usersLoggedOn) {
            if (-not $LoggedOnUser.lastLogOnDateTime) {
                continue
            }
            $LoginDate = [DateTimeOffset]::Parse($LoggedOnUser.lastLogOnDateTime).ToUniversalTime()
            if ($LoginDate -gt [DateTimeOffset]'1601-01-01T00:00:00Z' -and
                ($null -eq $LastLogin -or $LoginDate -gt $LastLogin)) {
                $LastLogin = $LoginDate
                $LastLoginUserId = $LoggedOnUser.userId
            }
        }
        if ($null -ne $LastLogin) {
            $LoginStatus = 'Reported'
        }
    }
    catch {
        $LastLogin = $null
        $LastLoginUserId = $null
        $LoginStatus = 'Lookup failed'
        Write-Warning "Could not read logon data for '$($Device.deviceName)': $($_.Exception.Message)"
    }

    [pscustomobject]@{
        DeviceName        = $Device.deviceName
        PrimaryUserUPN    = $Device.userPrincipalName
        PrimaryUserName   = $Device.userDisplayName
        Model             = $Device.model
        LastLoginEastern  = if ($null -ne $LastLogin) {
            [TimeZoneInfo]::ConvertTime($LastLogin, $EasternTimeZone).ToString('yyyy-MM-dd HH:mm:ss zzz')
        } else { $null }
        LastLoginUserId    = $LastLoginUserId
        LoginStatus       = $LoginStatus
        LastIntuneSyncEastern = if ($Device.lastSyncDateTime) {
            $SyncDate = [DateTimeOffset]::Parse($Device.lastSyncDateTime)
            [TimeZoneInfo]::ConvertTime($SyncDate, $EasternTimeZone).ToString('yyyy-MM-dd HH:mm:ss zzz')
        } else { $null }
        IntuneDeviceId    = $Device.id
        EntraDeviceId     = $Device.azureADDeviceId
    }
})

$Report = @($Report | Sort-Object DeviceName)
New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
$CsvPath = Join-Path $OutputPath "CloudPCs-LastLogin-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$Report | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
Write-Host "Exported $($Report.Count) Cloud PCs to $CsvPath"
Write-Host 'Dates use Eastern time (EST/EDT). LastLoginEastern is the latest Intune-reported user logon, not the last sync or Windows 365 connection.'
if ($OpenReport) {
    Invoke-Item -LiteralPath $CsvPath
}
$Report