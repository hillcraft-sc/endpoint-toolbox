# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Reports Entra sign-in usage for one or more Intune managed devices.

.DESCRIPTION
    For each target device the script looks up the Intune managed device, resolves its Entra
    azureADDeviceId, and pulls successful Entra sign-in logs recorded against that device within the
    lookback window. Target devices come from an Entra ID group (-EntraGroup), a text file
    (-DeviceListPath), or directly on the command line (-Devices).

    A per-device summary is printed to the console and every sign-in record is written to a
    timestamped CSV in -OutputPath. When exactly one device is targeted, the per-user and per-day
    breakdowns are printed as well.

    Read-only. No device attributes are modified.

.PARAMETER EntraGroup
    The Entra ID group object ID or display name to pull device names from. Transitive members are
    used, so devices in nested groups are included. Cannot be combined with -DeviceListPath or -Devices.

.PARAMETER DeviceListPath
    Path to a text file containing one device name per line. Blank lines and lines starting with
    '#' are ignored. Cannot be combined with -EntraGroup or -Devices.

.PARAMETER Devices
    One or more device names supplied directly. Accepts a single name, an array, or a
    comma-separated string. Cannot be combined with -EntraGroup or -DeviceListPath.

.PARAMETER LookbackDays
    How many days of sign-in history to pull. Defaults to 30.

.PARAMETER OutputPath
    The folder to save the final CSV report to. Defaults to the current user's temp folder.
    Created automatically if it doesn't already exist.

.PARAMETER OpenReport
    Open the finished CSV in its default application once the export completes.

.EXAMPLE
    .\Get-DeviceUserUsage.ps1 -Devices "DESKTOP-1234"

    Reports 30 days of sign-in usage for a single device, including the per-user and per-day detail.

.EXAMPLE
    .\Get-DeviceUserUsage.ps1 -EntraGroup "All.Lenovo.Laptops" -LookbackDays 60 -OpenReport

    Reports 60 days of usage for every device member of the group and opens the CSV when finished.

.EXAMPLE
    .\Get-DeviceUserUsage.ps1 -DeviceListPath "C:\temp\devices.txt"

    Reports usage for each device listed in devices.txt.

.NOTES
    Requires an active Microsoft Graph connection with the following delegated scopes:
    DeviceManagementManagedDevices.Read.All, AuditLog.Read.All, Directory.Read.All. Reading group
    membership additionally needs Group.Read.All.

    Author:         eric@hillcraft.email
    Created:        2026-09-11
    Last Modified:  2026-09-15
#>
[CmdletBinding(DefaultParameterSetName = 'ByDevice')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByGroup')]
    [ValidateNotNullOrEmpty()]
    [string]$EntraGroup,

    [Parameter(Mandatory, ParameterSetName = 'ByFile')]
    [ValidateNotNullOrEmpty()]
    [string]$DeviceListPath,

    [Parameter(Mandatory, ParameterSetName = 'ByDevice')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Devices,

    [int]$LookbackDays = 30,

    [string]$OutputPath = "$env:TEMP",

    # Open the finished CSV once the export completes.
    [switch]$OpenReport
)

$LookbackStartUtc = (Get-Date).ToUniversalTime().AddDays(-$LookbackDays)
$LookbackIso = $LookbackStartUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")

# =========================
# Connect to Graph
# =========================

if (Get-MgContext) {
    Write-Output "Connected to MgGraph..."
}
else {
    Write-Output "Not connected to MgGraph. Connecting..."
    Connect-MgGraph -NoWelcome | Out-Null
    #-Scopes "DeviceManagementManagedDevices.Read.All","AuditLog.Read.All","Directory.Read.All" -NoWelcome
}

$Context = Get-MgContext

Write-Output "Account : $($Context.Account)"
Write-Output "Tenant  : $($Context.TenantId)"
Write-Output "Lookback window starts: $LookbackIso"
Write-Output ""

# =========================
# Helper functions
# =========================

function Get-ObjectValue {
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string[]]$PropertyNames
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($Name in $PropertyNames) {

        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) {
                return $Object[$Name]
            }

            foreach ($Key in $Object.Keys) {
                if ($Key -ieq $Name) {
                    return $Object[$Key]
                }
            }
        }

        if ($Object.PSObject.Properties.Name -contains $Name) {
            return $Object.$Name
        }

        $Prop = $Object.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

        if ($Prop) {
            return $Prop.Value
        }

        if ($Object.PSObject.Properties.Name -contains "AdditionalProperties") {
            if ($Object.AdditionalProperties) {
                if ($Object.AdditionalProperties.ContainsKey($Name)) {
                    return $Object.AdditionalProperties[$Name]
                }

                foreach ($Key in $Object.AdditionalProperties.Keys) {
                    if ($Key -ieq $Name) {
                        return $Object.AdditionalProperties[$Key]
                    }
                }
            }
        }
    }

    return $null
}

function Get-GraphCollection {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [hashtable]$Headers = @{}
    )

    $Results = New-Object System.Collections.Generic.List[object]
    $NextUri = $Uri

    while ($NextUri) {
        if ($Headers.Count -gt 0) {
            $Response = Invoke-MgGraphRequest -Method GET -Uri $NextUri -Headers $Headers
        }
        else {
            $Response = Invoke-MgGraphRequest -Method GET -Uri $NextUri
        }

        if ($Response.value) {
            foreach ($Item in $Response.value) {
                $Results.Add($Item)
            }
        }

        $NextUri = $Response.'@odata.nextLink'
    }

    return $Results
}

# =========================
# Resolve target device names
# =========================

if ($EntraGroup) {
    Write-Output "Resolving Entra group: $EntraGroup"

    if ($EntraGroup -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        $Group = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$EntraGroup"
    }
    else {
        $GroupFilter = "displayName eq '$($EntraGroup -replace "'", "''")'"
        $GroupUri = "https://graph.microsoft.com/v1.0/groups?`$filter=$([System.Uri]::EscapeDataString($GroupFilter))&`$top=999"
        $FoundGroups = @(Get-GraphCollection -Uri $GroupUri)

        if ($FoundGroups.Count -eq 0) {
            # Retry on the leading portion of the name so spacing differences around suffixes still resolve
            $Prefix = (($EntraGroup -split '[(\[{]')[0]).Trim()
            $PrefixFilter = "startsWith(displayName,'$($Prefix -replace "'", "''")')"
            $PrefixUri = "https://graph.microsoft.com/v1.0/groups?`$filter=$([System.Uri]::EscapeDataString($PrefixFilter))&`$top=999"
            $Candidates = @(Get-GraphCollection -Uri $PrefixUri)

            $NormalizedName = $EntraGroup -replace '\s', ''
            $FoundGroups = @($Candidates | Where-Object { ($_.displayName -replace '\s', '') -eq $NormalizedName })

            if ($FoundGroups.Count -eq 0) {
                if ($Candidates.Count -gt 0) {
                    Write-Output "Groups starting with '$Prefix':"
                    $Candidates | ForEach-Object { Write-Output "  $($_.displayName)" }
                }
                throw "Entra group not found: $EntraGroup"
            }
        }

        if ($FoundGroups.Count -gt 1) {
            throw "Multiple Entra groups are named '$EntraGroup'. Re-run using the group object ID."
        }

        $Group = $FoundGroups[0]
    }

    Write-Output "Group: $($Group.displayName) [$($Group.id)]"

    $MemberUri = "https://graph.microsoft.com/beta/groups/$($Group.id)/transitiveMembers?`$select=id,displayName,deviceId&`$top=999"
    $Members = @(Get-GraphCollection -Uri $MemberUri -Headers @{ "ConsistencyLevel" = "eventual" })

    $TargetNames = @($Members | Where-Object { $_.deviceId } | ForEach-Object { $_.displayName })

    if ($TargetNames.Count -eq 0) {
        throw "The group '$($Group.displayName)' contains no device members."
    }

    $ScopeLabel = $Group.displayName
}
elseif ($DeviceListPath) {
    if (-not (Test-Path -Path $DeviceListPath)) {
        throw "Device list file not found: $DeviceListPath"
    }
    $TargetNames = Get-Content -Path $DeviceListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
    $ScopeLabel = [System.IO.Path]::GetFileNameWithoutExtension($DeviceListPath)
}
else {
    # Also accept a single comma-separated string, not just a real array
    $TargetNames = $Devices | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $ScopeLabel = if (@($TargetNames).Count -eq 1) { @($TargetNames)[0] } else { "$(@($TargetNames).Count)Devices" }
}

$TargetNames = @($TargetNames | Sort-Object -Unique)

Write-Output "Devices to report on: $($TargetNames.Count)"
Write-Output ""

# =========================
# Resolve the managed devices
# =========================

$ResolvedDevices = New-Object System.Collections.Generic.List[object]
$usageNotFound = 0

foreach ($TargetName in $TargetNames) {

    $Filter = "deviceName eq '$($TargetName -replace "'", "''")'"
    $EncodedFilter = [System.Uri]::EscapeDataString($Filter)
    $DeviceUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=$EncodedFilter"

    $FoundDevices = @(Get-GraphCollection -Uri $DeviceUri)

    if ($FoundDevices.Count -eq 0) {
        $usageNotFound++
        Write-Warning "No Intune managed device found with name '$TargetName'. Skipping."
        continue
    }

    if ($FoundDevices.Count -gt 1) {
        Write-Warning "Multiple managed devices ($($FoundDevices.Count)) named '$TargetName' were found. Reporting on all of them."
    }

    foreach ($FoundDevice in $FoundDevices) {
        $ResolvedDevices.Add($FoundDevice)
    }
}

if ($ResolvedDevices.Count -eq 0) {
    throw "None of the $($TargetNames.Count) target device name(s) resolved to an Intune managed device."
}

# =========================
# Collect usage per device
# =========================

$UsageRecords = New-Object System.Collections.Generic.List[object]
$DeviceSummaries = New-Object System.Collections.Generic.List[object]

# Per-user / per-day breakdowns are only readable when reporting on one device
$ShowDetail = $ResolvedDevices.Count -eq 1

foreach ($Device in $ResolvedDevices) {

    $DeviceName = Get-ObjectValue -Object $Device -PropertyNames @("deviceName", "DeviceName")

    $AzureAdDeviceId = Get-ObjectValue -Object $Device -PropertyNames @(
        "azureADDeviceId", "AzureADDeviceId", "azureActiveDirectoryDeviceId"
    )
    $PrimaryUserUpn = Get-ObjectValue -Object $Device -PropertyNames @(
        "userPrincipalName", "UserPrincipalName", "emailAddress"
    )
    $ManagedDeviceId = Get-ObjectValue -Object $Device -PropertyNames @("id", "Id")
    $OperatingSystem = Get-ObjectValue -Object $Device -PropertyNames @("operatingSystem", "OperatingSystem")
    $LastSync = Get-ObjectValue -Object $Device -PropertyNames @("lastSyncDateTime", "LastSyncDateTime")

    Write-Output "-------------------------------------------------------------"
    Write-Output "Device name        : $DeviceName"
    Write-Output "Managed device id  : $ManagedDeviceId"
    Write-Output "Entra deviceId     : $AzureAdDeviceId"
    Write-Output "Primary user (UPN) : $PrimaryUserUpn"
    Write-Output "Operating system   : $OperatingSystem"
    Write-Output "Last Intune sync   : $LastSync"
    Write-Output ""

    if (-not $AzureAdDeviceId) {
        Write-Warning "Device '$DeviceName' has no azureADDeviceId. Cannot correlate sign-ins. Skipping."
        $DeviceSummaries.Add([pscustomobject]@{
                DeviceName    = $DeviceName
                SignIns       = 0
                DistinctUsers = 0
                ActiveDays    = 0
                FirstSignIn   = $null
                LastSignIn    = $null
                Note          = "No azureADDeviceId"
            })
        continue
    }

    # =========================
    # Pull sign-ins that occurred ON this device
    # =========================

    $SignInFilter = "createdDateTime ge $LookbackIso and status/errorCode eq 0 and deviceDetail/deviceId eq '$AzureAdDeviceId'"
    $EncodedSignInFilter = [System.Uri]::EscapeDataString($SignInFilter)
    $SignInUri = "https://graph.microsoft.com/v1.0/auditLogs/signIns?`$filter=$EncodedSignInFilter&`$select=createdDateTime,userPrincipalName,userDisplayName,appDisplayName,clientAppUsed,deviceDetail,ipAddress,status&`$top=1000"

    $SignIns = Get-GraphCollection -Uri $SignInUri

    Write-Output "Successful sign-ins on this device (last $LookbackDays days): $($SignIns.Count)"

    foreach ($SignIn in $SignIns) {

        $DeviceDetail = Get-ObjectValue -Object $SignIn -PropertyNames @("deviceDetail")

        $UsageRecords.Add([pscustomobject]@{
                DeviceName        = $DeviceName
                AzureAdDeviceId   = $AzureAdDeviceId
                SignInUserUpn     = Get-ObjectValue -Object $SignIn -PropertyNames @("userPrincipalName")
                SignInUserName    = Get-ObjectValue -Object $SignIn -PropertyNames @("userDisplayName")
                CreatedDateTime   = Get-ObjectValue -Object $SignIn -PropertyNames @("createdDateTime")
                AppDisplayName    = Get-ObjectValue -Object $SignIn -PropertyNames @("appDisplayName")
                ClientAppUsed     = Get-ObjectValue -Object $SignIn -PropertyNames @("clientAppUsed")
                IpAddress         = Get-ObjectValue -Object $SignIn -PropertyNames @("ipAddress")
                DeviceOs          = Get-ObjectValue -Object $DeviceDetail -PropertyNames @("operatingSystem")
                DeviceBrowser     = Get-ObjectValue -Object $DeviceDetail -PropertyNames @("browser")
            })
    }

    if ($SignIns.Count -eq 0) {
        Write-Output "No sign-in usage found for this device in the lookback window."
        Write-Output ""
        $DeviceSummaries.Add([pscustomobject]@{
                DeviceName    = $DeviceName
                SignIns       = 0
                DistinctUsers = 0
                ActiveDays    = 0
                FirstSignIn   = $null
                LastSignIn    = $null
                Note          = "No sign-ins in window"
            })
        continue
    }

    # =========================
    # Summarize usage
    # =========================

    $Ordered = @(
        $UsageRecords | Where-Object { $_.AzureAdDeviceId -eq $AzureAdDeviceId } |
        Sort-Object { [datetime]$_.CreatedDateTime }
    )

    $FirstSignIn = ($Ordered | Select-Object -First 1).CreatedDateTime
    $LastSignIn = ($Ordered | Select-Object -Last 1).CreatedDateTime
    $ActiveDays = ($Ordered | ForEach-Object { ([datetime]$_.CreatedDateTime).ToUniversalTime().ToString("yyyy-MM-dd") } | Select-Object -Unique).Count

    $DeviceSummaries.Add([pscustomobject]@{
            DeviceName    = $DeviceName
            SignIns       = $Ordered.Count
            DistinctUsers = @($Ordered.SignInUserUpn | Sort-Object -Unique).Count
            ActiveDays    = $ActiveDays
            FirstSignIn   = $FirstSignIn
            LastSignIn    = $LastSignIn
            Note          = ""
        })

    Write-Output "First sign-in       : $FirstSignIn"
    Write-Output "Last sign-in        : $LastSignIn"
    Write-Output "Distinct active days: $ActiveDays"
    Write-Output ""

    if ($ShowDetail) {
        Write-Output "Usage by user:"
        $Ordered |
        Group-Object SignInUserUpn |
        Sort-Object Count -Descending |
        ForEach-Object {
            $Last = ($_.Group | Sort-Object { [datetime]$_.CreatedDateTime } | Select-Object -Last 1).CreatedDateTime
            Write-Output ("  {0,-40} SignIns: {1,-5} LastSignIn: {2}" -f $_.Name, $_.Count, $Last)
        }
        Write-Output ""

        Write-Output "Usage by day:"
        $Ordered |
        Group-Object { ([datetime]$_.CreatedDateTime).ToUniversalTime().ToString("yyyy-MM-dd") } |
        Sort-Object Name |
        ForEach-Object {
            Write-Output ("  {0}  SignIns: {1}" -f $_.Name, $_.Count)
        }
        Write-Output ""
    }
}

# =========================
# Summary and export
# =========================

if ($DeviceSummaries.Count -gt 0) {
    Write-Output "Per-device summary:"
    $DeviceSummaries |
    Sort-Object SignIns -Descending |
    Format-Table -AutoSize |
    Out-String |
    Write-Output
}

if ($UsageRecords.Count -gt 0) {
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $SafeScope = $ScopeLabel -replace '[\\/:*?"<>|]', '_'
    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutputCsvPath = Join-Path $OutputPath "DeviceUserUsage-$SafeScope-$($LookbackDays)d-$Timestamp.csv"

    $UsageRecords |
    Sort-Object DeviceName, { [datetime]$_.CreatedDateTime } |
    Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8

    Write-Output "Devices reported: $($DeviceSummaries.Count)"
    Write-Output "Total records: $($UsageRecords.Count)"
    Write-Output "Detailed sign-in records written to: $OutputCsvPath"

    if ($OpenReport -and (Test-Path $OutputCsvPath)) {
        Invoke-Item -Path $OutputCsvPath
    }
}
else {
    Write-Output "No usage records to export."
}
