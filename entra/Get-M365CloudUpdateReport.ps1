# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Retrieves Microsoft 365 Apps Monthly Enterprise Cloud Update release,
    rollout summary, and device-level update details.

.DESCRIPTION
    Authenticates interactively with MSAL.PS, discovers the current Monthly
    Enterprise release/build, retrieves rollout status, then retrieves all
    Cloud Update devices in pages. Optionally exports a portal-style CSV and
    a full inventory CSV.

.PARAMETER IncludeWaveGroups
    Adds a Group column to device rows and the portal-style CSV, using only
    only the Entra groups named in -WaveGroupNames.
    Requires an existing delegated Global Microsoft Graph connection in the
    Office sign-in tenant, with Group.Read.All and Device.Read.All.
    Exact, unique computer names correlate Office inventory with Entra devices;
    missing or duplicate names are Unknown. Nested device members are included.
    Multiple matching groups are separated by semicolons. Membership is current,
    not a historical explanation of the Office-reported wave.
    Missing or ambiguous configured groups warn and allow CSV export with partial
    correlation. Unmatched devices remain Unknown until every group is resolved.

.PARAMETER WaveGroupNames
    One or more exact Entra group display names to use for the Group column, for example
    your Microsoft 365 Apps rollout or update-ring device groups. Required with
    -IncludeWaveGroups; ignored otherwise. Names are matched exactly (no wildcards).

.NOTES
    This uses backend endpoints used by config.office.com and requires your account to have the Office Apps Administrator role enabled.
    These endpoints are not a documented public reporting API and may change without notice.

.EXAMPLE
    .\Get-M365CloudUpdateReport.ps1

.EXAMPLE
    .\Get-M365CloudUpdateReport.ps1 -ExportFolder C:\Temp\M365Reports

.EXAMPLE
    .\Get-M365CloudUpdateReport.ps1 -TenantId '<tenant-guid>' -NoExport
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId = 'organizations',

    [Parameter()]
    [ValidateRange(1, 200)]
    [int]$PageSize = 200,

    [Parameter()]
    [string]$ExportFolder = (Join-Path $PWD 'M365CloudUpdateReports'),

    [Parameter()]
    [switch]$NoExport,

    [Parameter()]
    [switch]$IncludeWaveGroups,

    [Parameter()]
    [string[]]$WaveGroupNames
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($IncludeWaveGroups) {
    $WaveGroupNames = @($WaveGroupNames | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } |
        Group-Object { $_.ToLowerInvariant() } | ForEach-Object { $_.Group[0] })
    if (-not $WaveGroupNames.Count) {
        throw '-IncludeWaveGroups requires -WaveGroupNames: one or more exact Entra group display names.'
    }
}

# Public client and resource verified for the Enterprise Insights service.
$ClientId = '1950a258-227b-4e31-a9cf-717495945fc2'
$Scope    = 'f9d02341-e7aa-456d-926d-4a0ca599fbee/.default'
$Channel  = 'MonthlyEnterpriseChannel'
$BaseUri  = 'https://query.inventory.insights.office.net/inventory/api'

function Write-Section {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Get-HttpFailureDetail {
    param([Parameter(Mandatory)]$ErrorRecord)

    $details = [System.Collections.Generic.List[string]]::new()
    $details.Add($ErrorRecord.Exception.Message)

    if ($ErrorRecord.Exception.Response) {
        try { $details.Add("HTTP status: $([int]$ErrorRecord.Exception.Response.StatusCode) $($ErrorRecord.Exception.Response.StatusCode)") } catch {}
        try {
            $body = $ErrorRecord.ErrorDetails.Message
            if (-not [string]::IsNullOrWhiteSpace($body)) { $details.Add("Response: $body") }
        } catch {}
    }

    return ($details -join [Environment]::NewLine)
}

function Invoke-InventoryApi {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter()][string]$ApiName
    )

    $requestHeaders = @{}
    foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] }
    if ($ApiName) { $requestHeaders['x-api-name'] = $ApiName }

    try {
        Invoke-RestMethod -Uri $Uri -Method Get -Headers $requestHeaders -TimeoutSec 90
    }
    catch {
        $detail = Get-HttpFailureDetail -ErrorRecord $_
        throw "API request failed.`nURI: $Uri`n$detail"
    }
}

function Get-CloudUpdateGraphCollection {
    param([Parameter(Mandatory)][string]$Uri)

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($Uri) {
        $address = [uri]$Uri
        if ($address.Scheme -ne 'https' -or $address.Host -ne 'graph.microsoft.com' -or
            $address.UserInfo -or -not $address.AbsolutePath.StartsWith('/v1.0/')) {
            throw 'Unexpected Graph pagination address during rollout group lookup.'
        }
        if (-not $seen.Add($Uri)) { throw 'Graph repeated a page during rollout group lookup.' }
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType Hashtable -Headers @{ConsistencyLevel='eventual'} -ErrorAction Stop
        if ($page -isnot [Collections.IDictionary] -or -not $page.Contains('value') -or
            $null -eq $page['value'] -or $page['value'] -is [string] -or
            $page['value'] -isnot [Collections.IEnumerable]) {
            throw 'Graph returned an invalid collection during rollout group lookup.'
        }
        $page['value']
        $Uri = [string]$page['@odata.nextLink']
    }
}

function Add-CloudUpdateWaveGroups {
    param([object[]]$Rows, [string]$OfficeTenantId, [string[]]$GroupNames)

    foreach ($row in $Rows) {
        $row | Add-Member -NotePropertyName Group -NotePropertyValue 'Unknown (group lookup incomplete)'
    }
    if (@(Get-Command Get-MgContext, Invoke-MgGraphRequest -ErrorAction Ignore).Count -ne 2) {
        throw 'Wave group lookup requires Microsoft.Graph.Authentication. Install it deliberately and connect to Graph before running with IncludeWaveGroups.'
    }
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context -or $context.AuthType -ne 'Delegated' -or $context.Environment -ne 'Global') {
        throw 'Wave group lookup requires an existing delegated Global Graph connection. Connect on Home, or use Connect-MgGraph in the terminal.'
    }
    if (-not $OfficeTenantId -or $context.TenantId -ne $OfficeTenantId) {
        throw 'Office and Graph tenant identities could not be matched. Use the same tenant for both sign-ins before requesting wave groups.'
    }
    $counts = [pscustomobject]@{Matched=0; NoGroup=0; Unknown=0; UnresolvedGroups=0}
    if (-not $Rows.Count) { return $counts }

    $memberships = @{}
    foreach ($groupName in $groupNames) {
        $filter = [uri]::EscapeDataString("displayName eq '$($groupName.Replace("'", "''"))'")
        $groups = @(Get-CloudUpdateGraphCollection "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName")
        if ($groups.Count -ne 1) {
            $counts.UnresolvedGroups++
            Write-Warning "Expected exactly one Entra rollout group named '$groupName'; found $($groups.Count). Continuing with the other configured groups and CSV export; group correlation is incomplete. Verify this configured group name."
            continue
        }
        if ($groups[0]['displayName'] -ne $groupName) { throw 'Graph returned a rollout group with an unexpected display name.' }
        $groupId = [guid]::Empty
        if (-not [guid]::TryParse([string]$groups[0]['id'], [ref]$groupId)) { throw 'Graph returned a rollout group without a valid object ID.' }
        foreach ($member in Get-CloudUpdateGraphCollection "https://graph.microsoft.com/v1.0/groups/$groupId/transitiveMembers/microsoft.graph.device?`$select=id&`$top=999&`$count=true") {
            $memberId = [guid]::Empty
            if (-not [guid]::TryParse([string]$member['id'], [ref]$memberId)) { throw 'Graph returned a rollout device member without a valid object ID.' }
            $key = $memberId.ToString()
            if (-not $memberships.ContainsKey($key)) { $memberships[$key] = [Collections.Generic.List[string]]::new() }
            if (-not $memberships[$key].Contains($groupName)) { $memberships[$key].Add($groupName) }
        }
    }

    # Office inventory IDs are not Entra object IDs. Only unique exact names can bridge them.
    $directoryNames = @{}
    foreach ($device in Get-CloudUpdateGraphCollection 'https://graph.microsoft.com/v1.0/devices?$select=id,displayName&$top=999') {
        $name = ([string]$device['displayName']).Trim()
        if (-not $name) { continue }
        $deviceId = [guid]::Empty
        if (-not [guid]::TryParse([string]$device['id'], [ref]$deviceId)) { throw 'Graph returned an Entra device without a valid object ID.' }
        if (-not $directoryNames.ContainsKey($name)) { $directoryNames[$name] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
        $null = $directoryNames[$name].Add($deviceId.ToString())
    }
    $reportNames = @{}
    foreach ($row in $Rows) {
        $name = ([string]$row.Name).Trim()
        if ($name) { $reportNames[$name] = [int]$reportNames[$name] + 1 }
    }
    foreach ($row in $Rows) {
        $name = ([string]$row.Name).Trim()
        if (-not $name -or -not $directoryNames.ContainsKey($name)) {
            $row.Group = 'Unknown (no matching Entra device)'
            $counts.Unknown++
        }
        elseif ($reportNames[$name] -ne 1 -or $directoryNames[$name].Count -ne 1) {
            $row.Group = 'Unknown (ambiguous computer name)'
            $counts.Unknown++
        }
        else {
            $deviceId = @($directoryNames[$name])[0]
            if ($memberships.ContainsKey($deviceId)) {
                $row.Group = $memberships[$deviceId] -join '; '
                $counts.Matched++
            }
            elseif ($counts.UnresolvedGroups) {
                $counts.Unknown++
            }
            else {
                $row.Group = 'No configured wave group'
                $counts.NoGroup++
            }
        }
    }
    if ($counts.Unknown) { Write-Warning "Wave group correlation is incomplete for $($counts.Unknown) device rows: computer names were missing, not found or ambiguous, or configured rollout groups could not be resolved. These rows are Unknown, not confirmed remaining-wave devices." }
    return $counts
}

# 1. Load MSAL.PS
Write-Section 'Prerequisites'
if (-not (Get-Module -ListAvailable -Name MSAL.PS)) {
    Write-Host 'MSAL.PS is not installed. Installing for the current user...'
    Install-Module MSAL.PS -Scope AllUsers -Force -AllowClobber
}
Import-Module MSAL.PS -ErrorAction Stop
Write-Host 'MSAL.PS loaded.' -ForegroundColor Green

# 2. Authenticate
Write-Section 'Authentication'
$Token = Get-MsalToken `
    -ClientId $ClientId `
    -TenantId $TenantId `
    -Scopes $Scope `
    -Interactive

if ($null -eq $Token -or [string]::IsNullOrWhiteSpace($Token.AccessToken)) {
    throw 'Authentication completed, but no access token was returned.'
}

$accountName = if ($Token.Account.Username) { $Token.Account.Username } else { $Token.Account.HomeAccountId.Identifier }
Write-Host "Authenticated as: $accountName" -ForegroundColor Green
Write-Host "Token expires:    $($Token.ExpiresOn)"

$Headers = @{
    Authorization = "Bearer $($Token.AccessToken)"
    Accept        = 'application/json'
}

# 3. Discover current Monthly Enterprise release
Write-Section 'Current Monthly Enterprise release'
$ReleaseUri = 'https://config.office.com/releases/v1.0/LatestRelease/MonthlyEnterpriseChannel?releaseType=feature'
try {
    $Release = Invoke-RestMethod -Uri $ReleaseUri -Method Get -Headers $Headers -TimeoutSec 30
}
catch {
    $detail = Get-HttpFailureDetail -ErrorRecord $_
    throw "Current release lookup failed.`n$detail"
}

$Build = $Release.buildVersion.buildVersionString
if ([string]::IsNullOrWhiteSpace($Build)) {
    throw 'The release endpoint did not return buildVersion.buildVersionString.'
}

$ReleaseInfo = [PSCustomObject]@{
    Channel          = $Channel
    ReleaseVersion   = $Release.releaseVersion
    BuildVersion     = $Build
    AvailabilityDate = $Release.availabilityDate
    EndOfSupportDate = $Release.endOfSupportDate
    KBLink           = $Release.kbLink
}
$ReleaseInfo | Format-List

# 4. Retrieve rollout summary
Write-Section 'Rollout summary'
$SummaryUri = "$BaseUri/DeviceActions/GetUpdateProgressSummaryByChannel()?cloudManagement=ManagedByMEC,OnboardingToMEC&mecVersion=$Build&enableChannelManagement=true"
$SummaryResponse = Invoke-InventoryApi -Uri $SummaryUri -Headers $Headers -ApiName 'getUpdateProgressSummaryByChannel'

$Summary = @(
    $SummaryResponse.summary |
        Where-Object { $_.targetChannel -eq $Channel } |
        ForEach-Object { $_.updateStatusSummary } |
        ForEach-Object {
            [PSCustomObject]@{
                Status  = $_.updateStatus
                Devices = [int]$_.numberOfDevices
            }
        }
)

$TotalDevices = [int]$SummaryResponse.totalNumberOfDevices
$Completed = [int](($Summary | Where-Object Status -eq 'Completed').Devices | Select-Object -First 1)
$InProgress = [int](($Summary | Where-Object Status -eq 'InProgress').Devices | Select-Object -First 1)
$Failed = [int](($Summary | Where-Object Status -eq 'Failed').Devices | Select-Object -First 1)
$CompletedPct = if ($TotalDevices) { [math]::Round(($Completed / $TotalDevices) * 100, 2) } else { 0 }
$StartedPct = if ($TotalDevices) { [math]::Round((($Completed + $InProgress) / $TotalDevices) * 100, 2) } else { 0 }

$Summary | Format-Table -AutoSize
Write-Host "Total devices:             $TotalDevices"
Write-Host "Completed:                 $CompletedPct%"
Write-Host "Completed or in progress:  $StartedPct%"

# 5. Retrieve every device with OData paging
Write-Section 'Device details'
$SelectFields = @(
    'deviceId','name','lastSeen','osBuildVersion','osFamily','osReleaseVersion',
    'totalRamInGigaBytes','processorArchitecture','manufacturer','model','modelFamily',
    'freeDiskSpaceInGigabytes','totalDiskSpaceInGigaBytes','officeArchitecture',
    'officeMacroEnabledFilesInMRU','officeReleaseVersion','officeServicingChannel',
    'officeAddinCategorization','officeBuildVersion','officeInventoryAddonVersion',
    'status','aadUserDisplayName','aadUserName','waveId','isExcluded','targetChannel',
    'targetVersion','currentVersion','deviceCheckinOn','updateStatus','isProfileEnabled',
    'cloudManagement','lastError'
) -join ','

$Filter = [uri]::EscapeDataString("(cloudManagement eq 'ManagedByMEC' or cloudManagement eq 'OnboardingToMEC')")
$Devices = [System.Collections.Generic.List[object]]::new()
$Skip = 0
$ExpectedCount = $null

do {
    $DeviceUri = "$BaseUri/DevicesWithCloudManagementInfo?api-version=1.1&`$select=$SelectFields&`$filter=$Filter&`$top=$PageSize&`$skip=$Skip&`$count=true&mecVersion=$Build&enableChannelManagement=true"
    $Page = Invoke-InventoryApi -Uri $DeviceUri -Headers $Headers

    if ($null -eq $ExpectedCount) {
        $ExpectedCount = [int]$Page.'@odata.count'
        Write-Host "API reports $ExpectedCount devices."
    }

    $PageRows = @($Page.value)
    foreach ($row in $PageRows) { $Devices.Add($row) }

    Write-Progress -Activity 'Retrieving Cloud Update devices' `
        -Status "$($Devices.Count) of $ExpectedCount" `
        -PercentComplete $(if ($ExpectedCount) { [math]::Min(100, ($Devices.Count / $ExpectedCount) * 100) } else { 0 })

    Write-Host "Retrieved $($Devices.Count) of $ExpectedCount"
    $Skip += $PageSize

    if ($PageRows.Count -eq 0 -and $Devices.Count -lt $ExpectedCount) {
        throw "Paging stopped unexpectedly at $($Devices.Count) of $ExpectedCount devices."
    }
} while ($Devices.Count -lt $ExpectedCount)

Write-Progress -Activity 'Retrieving Cloud Update devices' -Completed

# Portal-style report. $Devices retains every raw field.
$Report = @(
    $Devices | ForEach-Object {
        [PSCustomObject]@{
            Name                  = $_.name
            OfficeVersion         = $_.officeReleaseVersion
            OfficeBuild           = $_.officeBuildVersion
            TargetVersion         = $_.targetVersion
            CurrentVersion        = $_.currentVersion
            Wave                  = $_.waveId
            UpdateChannel         = $_.targetChannel
            UpdateStatus          = $_.updateStatus
            ErrorCode             = $_.lastError
            LastContactUtc        = $_.lastSeen
            DeviceCheckInUtc      = $_.deviceCheckinOn
            LastUser              = $_.aadUserDisplayName
            LastUserEmail         = $_.aadUserName
            CloudUpdateStatus     = $_.cloudManagement
            IsExcluded            = $_.isExcluded
            IsProfileEnabled      = $_.isProfileEnabled
            OSVersion             = $_.osReleaseVersion
            OSBuild               = $_.osBuildVersion
            Manufacturer          = $_.manufacturer
            Model                 = $_.model
            FreeDiskSpaceGB       = $_.freeDiskSpaceInGigabytes
            TotalDiskSpaceGB      = $_.totalDiskSpaceInGigaBytes
            RAMGB                 = $_.totalRamInGigaBytes
            DeviceId              = $_.deviceId
        }
    }
)

if ($Report.Count -ne $ExpectedCount) {
    Write-Warning "Retrieved $($Report.Count) records, but the API reported $ExpectedCount."
}

if ($IncludeWaveGroups) {
    Write-Section 'Rollout group membership (Microsoft Graph)'
    $GroupCorrelation = Add-CloudUpdateWaveGroups -Rows $Report -OfficeTenantId $Token.TenantId -GroupNames $WaveGroupNames
    Write-Host "Device rows matched to rollout groups: $($GroupCorrelation.Matched); no configured group: $($GroupCorrelation.NoGroup); unknown: $($GroupCorrelation.Unknown); unresolved rollout groups: $($GroupCorrelation.UnresolvedGroups)."
}

# 6. Useful views
Write-Section 'Progress by wave'
$WaveSummary = @(
    $Report |
        Group-Object Wave, UpdateStatus |
        ForEach-Object {
            [PSCustomObject]@{
                Wave   = $_.Group[0].Wave
                Status = $_.Group[0].UpdateStatus
                Devices = $_.Count
            }
        } |
        Sort-Object @{ Expression = { if ($null -eq $_.Wave) { 999 } else { [int]$_.Wave } } }, Status
)
$WaveSummary | Format-Table -AutoSize

if ($Failed -gt 0) {
    Write-Section 'Failed devices'
    $Report |
        Where-Object UpdateStatus -eq 'Failed' |
        Select-Object Name, OfficeBuild, TargetVersion, Wave, ErrorCode, LastContactUtc, LastUserEmail |
        Format-Table -AutoSize
}

# 7. Export
$ExportedFiles = [System.Collections.Generic.List[string]]::new()
if (-not $NoExport) {
    Write-Section 'Export'
    if (-not (Test-Path -LiteralPath $ExportFolder)) {
        New-Item -Path $ExportFolder -ItemType Directory -Force | Out-Null
    }

    $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $PortalCsv = Join-Path $ExportFolder "M365-CloudUpdate-Devices-$Stamp.csv"
    $RawCsv    = Join-Path $ExportFolder "M365-CloudUpdate-FullInventory-$Stamp.csv"
    $SummaryCsv = Join-Path $ExportFolder "M365-CloudUpdate-Summary-$Stamp.csv"

    $Report | Export-Csv -Path $PortalCsv -NoTypeInformation -Encoding utf8BOM
    $Devices | Export-Csv -Path $RawCsv -NoTypeInformation -Encoding utf8BOM
    $Summary | Export-Csv -Path $SummaryCsv -NoTypeInformation -Encoding utf8BOM

    $ExportedFiles.Add($PortalCsv)
    $ExportedFiles.Add($RawCsv)
    $ExportedFiles.Add($SummaryCsv)

    Write-Host "Portal-style report: $PortalCsv" -ForegroundColor Green
    Write-Host "Full inventory:      $RawCsv" -ForegroundColor Green
    Write-Host "Summary:             $SummaryCsv" -ForegroundColor Green
}

# Return a single reusable result object to the pipeline.
[PSCustomObject]@{
    Release       = $ReleaseInfo
    Summary       = $Summary
    WaveSummary   = $WaveSummary
    Devices       = $Report
    RawDevices    = $Devices
    ExportedFiles = $ExportedFiles
}
