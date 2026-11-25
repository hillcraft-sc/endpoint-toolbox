<#
.SYNOPSIS
    Investigates a Win32 app installation on one Intune device.
.DESCRIPTION
    Resolves one exact device and Win32 app, reuses the existing deployment
    report, and retains all reported user-context rows for that managed device
    ID. Returns an overview with current assignments and suggested checks
    available as separate variables when dot-sourced. Does not determine
    effective targeting or run an installation, sync or remediation.
.PARAMETER DeviceSearchBy
    Resolve the device by exact name or Intune managed device ID.
.PARAMETER DeviceSearchValue
    The exact device name or Intune managed device ID, not an Entra device ID.
.PARAMETER AppSearchBy
    Resolve the Win32 app by exact display name or Intune app object ID.
.PARAMETER AppSearchValue
    The exact app display name or Intune mobileApps object ID.
.EXAMPLE
    .\Get-IntuneAppInvestigation.ps1 -DeviceSearchBy 'Device name' -DeviceSearchValue 'PC-123' -AppSearchBy 'App name' -AppSearchValue 'Example App'
.NOTES
    Requires Microsoft.Graph.Authentication and an authorized Global Graph
    connection with DeviceManagementManagedDevices.Read.All,
    DeviceManagementApps.Read.All, Group.Read.All and
    DeviceManagementConfiguration.Read.All. Uses the existing beta Win32 report
    export workflow; beta APIs can change. Temporarily downloads the selected
    app's fleet-wide device report, removes its scratch folder, and exposes only
    rows matching the selected managed device ID. No matching rows is not proof
    of installation success or lack of targeting. Assignments are current
    configuration, not historical or effective targeting.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Device name', 'Intune device ID')]
    [string]$DeviceSearchBy,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DeviceSearchValue,

    [Parameter(Mandatory)]
    [ValidateSet('App name', 'App ID')]
    [string]$AppSearchBy,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AppSearchValue,

    [hashtable]$DeploymentSnapshot,
    [string]$SnapshotTenantId
)

$ErrorActionPreference = 'Stop'
$DeviceSearchValue = $DeviceSearchValue.Trim()
$AppSearchValue = $AppSearchValue.Trim()
if (-not $DeviceSearchValue -or -not $AppSearchValue) { throw 'Enter both a device and a Win32 app to investigate.' }

function Test-AppInvestigationId {
    param($Value)
    $parsed = [guid]::Empty
    return [guid]::TryParse([string]$Value, [ref]$parsed) -and $parsed -ne [guid]::Empty
}

if (($DeviceSearchBy -eq 'Intune device ID' -and -not (Test-AppInvestigationId $DeviceSearchValue)) -or
    ($AppSearchBy -eq 'App ID' -and -not (Test-AppInvestigationId $AppSearchValue))) {
    throw 'Device and app object IDs must be nonempty GUIDs.'
}
$context = Get-MgContext -ErrorAction Stop
if (-not $context) {
    Connect-MgGraph -Scopes 'https://graph.microsoft.com/.default' -NoWelcome -ErrorAction Stop | Out-Null
    $context = Get-MgContext -ErrorAction Stop
}
if (-not $context -or $context.Environment -ne 'Global') { throw 'An active Global Microsoft Graph connection is required.' }
if ($PSBoundParameters.ContainsKey('DeploymentSnapshot') -and
    (-not $SnapshotTenantId -or $context.TenantId -ne $SnapshotTenantId)) {
    throw 'The rollout snapshot belongs to a different or unverified tenant. Return to the rollout or run diagnostics separately.'
}

function Get-AppInvestigationCollection {
    param([string]$Uri)
    $expectedPath = ([uri]$Uri).AbsolutePath
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($Uri) {
        $address = [uri]$Uri
        if (-not $address.IsAbsoluteUri -or $address.Scheme -ne 'https' -or
            $address.Host -ne 'graph.microsoft.com' -or -not $address.IsDefaultPort -or
            $address.UserInfo -or $address.Fragment -or $address.AbsolutePath -cne $expectedPath -or
            -not $seen.Add($Uri)) {
            throw 'Graph returned an unexpected or repeated page; app investigation stopped.'
        }
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType Hashtable -ErrorAction Stop
        if ($page -isnot [System.Collections.IDictionary] -or $page['value'] -isnot [array]) {
            throw 'Graph returned an invalid collection; app investigation stopped.'
        }
        foreach ($record in $page['value']) {
            if ($record -isnot [System.Collections.IDictionary]) { throw 'Graph returned an invalid collection record.' }
            $record
        }
        $Uri = [string]$page['@odata.nextLink']
    }
}

$root = 'https://graph.microsoft.com/v1.0'
$appRoot = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps'
$deviceSelect = 'id,deviceName,serialNumber,userPrincipalName,lastSyncDateTime,operatingSystem,osVersion,azureADDeviceId'
Write-Host 'Resolving the device and Win32 app...'
if ($DeviceSearchBy -eq 'Intune device ID') {
    $device = Invoke-MgGraphRequest -Method GET -Uri "$root/deviceManagement/managedDevices/$DeviceSearchValue`?`$select=$deviceSelect" -OutputType Hashtable -ErrorAction Stop
}
else {
    $filter = [uri]::EscapeDataString("deviceName eq '$($DeviceSearchValue.Replace("'", "''"))'")
    $devices = @(Get-AppInvestigationCollection "$root/deviceManagement/managedDevices?`$filter=$filter&`$select=$deviceSelect")
    if ($devices.Count -ne 1 -or $devices[0]['deviceName'] -ne $DeviceSearchValue) {
        throw 'Device name did not resolve to exactly one Intune record. Check the name or use its Intune device ID.'
    }
    $device = $devices[0]
}
if ($device -isnot [System.Collections.IDictionary] -or -not (Test-AppInvestigationId $device['id']) -or
    ($DeviceSearchBy -eq 'Intune device ID' -and $device['id'] -ne $DeviceSearchValue)) {
    throw 'Intune did not return a valid matching managed device.'
}
if ($AppSearchBy -eq 'App ID') {
    $app = Invoke-MgGraphRequest -Method GET -Uri "$appRoot/$AppSearchValue" -OutputType Hashtable -ErrorAction Stop
}
else {
    $filter = [uri]::EscapeDataString("displayName eq '$($AppSearchValue.Replace("'", "''"))'")
    $apps = @(Get-AppInvestigationCollection "$appRoot`?`$filter=$filter" |
        Where-Object { $_['@odata.type'] -eq '#microsoft.graph.win32LobApp' -and $_['displayName'] -eq $AppSearchValue })
    if ($apps.Count -ne 1) { throw 'App name did not resolve to exactly one Win32 app. Check the name or use its app ID.' }
    $app = $apps[0]
}
if ($app -isnot [System.Collections.IDictionary] -or -not (Test-AppInvestigationId $app['id']) -or
    $app['@odata.type'] -ne '#microsoft.graph.win32LobApp' -or
    ($AppSearchBy -eq 'App ID' -and $app['id'] -ne $AppSearchValue)) {
    throw 'Intune did not return a valid matching Win32 app.'
}

Write-Host 'Reading current app assignments. Effective targeting is not evaluated.'
$assignments = @(Get-AppInvestigationCollection "$appRoot/$($app['id'])/assignments")
$groupNames = @{}
$filters = @{}
$assignmentRows = @(foreach ($assignment in $assignments) {
    $target = $assignment['target']
    if ($target -isnot [System.Collections.IDictionary] -or -not $target['@odata.type'] -or -not $assignment['intent']) {
        throw 'Intune returned an unreadable app assignment.'
    }
    $groupId = [string]$target['groupId']
    $filterId = [string]$target['deviceAndAppManagementAssignmentFilterId']
    if ($groupId -and -not $groupNames.ContainsKey($groupId)) {
        if (-not (Test-AppInvestigationId $groupId)) { throw 'An assignment contains an invalid group ID.' }
        $group = Invoke-MgGraphRequest -Method GET -Uri "$root/groups/$groupId`?`$select=id,displayName" -OutputType Hashtable -ErrorAction Stop
        if ($group -isnot [System.Collections.IDictionary] -or $group['id'] -ne $groupId) { throw 'Graph returned an invalid assignment group.' }
        $groupNames[$groupId] = [string]$group['displayName']
    }
    if ($filterId -and -not $filters.ContainsKey($filterId)) {
        if (-not (Test-AppInvestigationId $filterId)) { throw 'An assignment contains an invalid filter ID.' }
        $assignmentFilter = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/assignmentFilters/$filterId" -OutputType Hashtable -ErrorAction Stop
        if ($assignmentFilter -isnot [System.Collections.IDictionary] -or $assignmentFilter['id'] -ne $filterId) { throw 'Graph returned an invalid assignment filter.' }
        $filters[$filterId] = $assignmentFilter
    }
    [pscustomobject]@{
        Intent = [string]$assignment['intent']
        TargetType = ([string]$target['@odata.type'] -replace '^#microsoft\.graph\.', '')
        GroupName = if ($groupId) { $groupNames[$groupId] } else { '' }
        GroupId = $groupId
        FilterMode = [string]$target['deviceAndAppManagementAssignmentFilterType']
        FilterName = if ($filterId) { [string]$filters[$filterId]['displayName'] } else { '' }
        FilterRule = if ($filterId) { [string]$filters[$filterId]['rule'] } else { '' }
        FilterId = $filterId
        Targeting = 'Not evaluated; current assignment configuration only'
    }
})

function Get-AppInvestigationSnapshotRows {
    param([string]$Id)
    if (-not $DeploymentSnapshot -or -not $DeploymentSnapshot.ContainsKey($Id)) { return }
    $table = $DeploymentSnapshot[$Id]
    if ($table -isnot [Data.DataTable] -or -not $table.Columns.Contains('DeviceId') -or -not $table.Columns.Contains('ApplicationId')) {
        throw 'The rollout snapshot does not have verified app and managed-device ID columns.'
    }
    foreach ($row in $table.Rows) {
        if ($row['DeviceId'] -eq $device['id'] -and $row['ApplicationId'] -eq $Id) {
            $fields = [ordered]@{}
            foreach ($column in $table.Columns) { $fields[$column.ColumnName] = [string]$row[$column] }
            [pscustomobject]$fields
        }
    }
}

$snapshotUsed = $PSBoundParameters.ContainsKey('DeploymentSnapshot')
if ($snapshotUsed) {
    if (-not $DeploymentSnapshot.ContainsKey([string]$app['id'])) { throw 'This app is not in the retained rollout. Return to the rollout or run diagnostics separately.' }
    Write-Host 'Reusing the retained rollout snapshot. No deployment export requested.'
    $deploymentRows = @(Get-AppInvestigationSnapshotRows $app['id'])
} else {
    Write-Host 'Reading the Win32 deployment report; large app deployments may take time...'
    $scratch = Join-Path ([IO.Path]::GetTempPath()) "EndpointToolbox-AppInvestigation-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -Path $scratch -ItemType Directory -ErrorAction Stop
    try {
        $deploymentErrors = @()
        $allDeploymentRows = @(& (Join-Path $PSScriptRoot 'Get-Win32AppDeploymentStatus.ps1') -AppId $app['id'] -OutputPath $scratch -IncludeUserStatus:$false -ErrorVariable deploymentErrors)
        if ($deploymentErrors.Count) { throw 'The deployment report failed; app investigation is incomplete. Review the preceding report error.' }
        foreach ($row in $allDeploymentRows) {
            if (-not $row.PSObject.Properties['DeviceId']) { throw 'The deployment report did not include DeviceId; device matching cannot be verified.' }
        }
        $deploymentRows = @($allDeploymentRows | Where-Object { $_.DeviceId -eq $device['id'] -and $_.ApplicationId -eq $app['id'] })
    }
    finally {
        try { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Stop }
        catch { Write-Warning "Could not remove temporary app investigation reports at '$scratch': $($_.Exception.Message)" }
    }
}

$installContext = if ($app['installExperience'] -is [System.Collections.IDictionary]) { [string]$app['installExperience']['runAsAccount'] } else { '' }
$helpUrl = 'https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/troubleshoot-app-install'
$checkRows = @(
    [pscustomobject]@{
        Check='Reported installation state'
        Evidence=if ($deploymentRows.Count) { "$($deploymentRows.Count) report row(s) matched the Intune device ID. Review every user context and raw error." } else { 'No report rows matched the Intune device ID. This is not installation success or proof of no assignment.' }
        NextStep='Review InstallStateFriendly, ErrorCode and available report timestamps. Compare with current device logs before deciding on a fix.'
        Reference=$helpUrl
    }
    [pscustomobject]@{
        Check='Assignment evidence'; Evidence="$($assignmentRows.Count) current assignment(s). See Diagnostic findings for available membership evidence. Filters and intent precedence are not evaluated."
        NextStep='Review include/exclude target types, required/available/uninstall intents and filter rules in App assignments. Confirm effective targeting in Intune.'
        Reference='https://learn.microsoft.com/en-us/intune/fundamentals/filters/troubleshoot'
    }
    [pscustomobject]@{
        Check='Reporting freshness'; Evidence="Last successful Intune sync reported by the device record: $($device['lastSyncDateTime']). Blank means unavailable."
        NextStep='Compare the device sync and app-report times. Device check-in and app reporting are separate; a sync does not prove installation.'
        Reference=$helpUrl
    }
    [pscustomobject]@{
        Check='Win32 requirements, detection and local logs'
        Evidence="Configured install context: $installContext; minimum Windows release: $($app['minimumSupportedWindowsRelease']). Blank means unavailable; no endpoint checks were run."
        NextStep='Review app requirements, detection rules, dependencies, supersedence and installer return-code mappings in Intune. Compare with Intune Management Extension logs on the device; a reporting error code is not necessarily the installer exit code.'
        Reference=$helpUrl
    }
)
$findings = @( & {
    function New-Finding($Check, $Outcome, $Evidence, $NextStep) {
        [pscustomobject]@{ Check=$Check; Outcome=$Outcome; Evidence=$Evidence; NextStep=$NextStep }
    }
    function ConvertTo-ReportTime($Value) {
        $parsed = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed) -and $parsed.Year -gt 1900) { $parsed }
    }
    $builds = @{
        Windows10_21H2=19044; Windows10_22H2=19045; Windows11_21H2=22000
        Windows11_22H2=22621; Windows11_23H2=22631; Windows11_24H2=26100; Windows11_25H2=26200
    }
    $minimum = [string]$app['minimumSupportedWindowsRelease']
    $version = [version]'0.0'
    if ($builds.ContainsKey($minimum) -and [version]::TryParse([string]$device['osVersion'], [ref]$version) -and
        $version.Major -eq 10 -and $version.Minor -eq 0 -and $version.Build -ge 10240) {
        $outcome = if ($version.Build -lt $builds[$minimum]) { 'Current requirement mismatch' } else { 'Meets build threshold' }
        New-Finding 'Windows build' $outcome "Reported build $($version.Build); current minimum $minimum (build $($builds[$minimum]))." 'Check the configured minimum against the intended rollout devices.'
    } else {
        New-Finding 'Windows build' 'Not evaluated' "Current minimum: $minimum; reported OS: $($device['osVersion']). No comparable build pair." 'Check the app requirement and current device build in Intune.'
    }
    $allowed = [string]$app['allowedArchitectures']
    if (-not $allowed -or $allowed -eq 'none') { $allowed = [string]$app['applicableArchitectures'] }
    $architectures = @($allowed -split ',\s*' | Where-Object { $_ })
    if ($architectures.Count -and -not @($architectures | Where-Object { $_ -notin @('x86','x64','arm','arm64') }).Count) {
        try {
            $hardware = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($device['id'])?`$select=id,processorArchitecture" -OutputType Hashtable -ErrorAction Stop
            $architecture = if ($hardware -is [System.Collections.IDictionary] -and $hardware['id'] -eq $device['id']) { [string]$hardware['processorArchitecture'] }
            if ($architecture -notin @('x86','x64','arm','arm64')) {
                New-Finding 'Architecture' 'Not evaluated' "Configured architectures: $allowed; no verified device architecture." 'Check the device inventory and app requirements.'
            } else {
                $outcome = if ($architecture -in $architectures) { 'Listed in app configuration' } else { 'Architecture not listed' }
                New-Finding 'Architecture' $outcome "Reported processor architecture: $architecture; configured: $allowed." 'Confirm package compatibility and Windows emulation support; this is not a device-side applicability result.'
            }
        } catch {
            New-Finding 'Architecture' 'Lookup unavailable' 'Intune did not return architecture evidence.' 'Check the device inventory and app requirements.'
        }
    }
    $changed = ConvertTo-ReportTime $app['lastModifiedDateTime']
    $states = @($deploymentRows | ForEach-Object {
        $raw = [string]$_.PSObject.Properties['InstallState']?.Value
        if ($raw -in @('2','-1','Failed','Error')) { 'Failure' }
        elseif ($raw -in @('1','Installed')) { 'Installed' }
    } | Sort-Object -Unique)
    if ($states.Count -gt 1) {
        New-Finding 'Deployment rows' 'Mixed reported outcomes' 'This managed device has both installed and failed/error rows.' 'Compare the user contexts and report times before treating this as a device-wide failure.'
    }
    $failureTimes = @($deploymentRows | Where-Object { $_.PSObject.Properties['InstallState']?.Value -in @('2','-1','Failed','Error') } |
        ForEach-Object { ConvertTo-ReportTime $_.PSObject.Properties['LastModifiedDateTime']?.Value })
    if ($changed -and @($failureTimes | Where-Object { $_ -lt $changed }).Count) {
        New-Finding 'Evidence timing' 'Failure predates app edit' "One or more failure rows predate the app's recorded last modification ($($changed.ToString('u')))." 'Verify whether the failure still reproduces under the current configuration. The timestamp does not identify what was edited.'
    }
    $groupTargets = @($assignmentRows | Where-Object GroupId)
    if ($groupTargets.Count) {
        $principals = [ordered]@{}
        if (Test-AppInvestigationId $device['azureADDeviceId']) {
            try {
                $entra = Invoke-MgGraphRequest -Method GET -Uri "$root/devices(deviceId='$($device['azureADDeviceId'])')?`$select=id,deviceId" -OutputType Hashtable -ErrorAction Stop
                if ($entra -isnot [System.Collections.IDictionary] -or $entra['deviceId'] -ne $device['azureADDeviceId'] -or -not (Test-AppInvestigationId $entra['id'])) {
                    throw 'No verified Entra device match.'
                }
                $principals['Device'] = "$root/devices/$($entra['id'])/transitiveMemberOf"
            } catch { New-Finding 'Device group membership' 'Lookup unavailable' 'The linked Entra device could not be verified.' 'Verify Device.Read.All access and the Entra device link.' }
        } else {
            New-Finding 'Device group membership' 'Not evaluated' 'No valid Entra device ID was reported.' 'Verify the Intune-to-Entra device link.'
        }
            $reportUsers = @($deploymentRows | ForEach-Object { [string]$_.PSObject.Properties['UserPrincipalName']?.Value } |
                Where-Object { $_ -match '^[^@\s/\\]+@[^@\s/\\]+$' } | Sort-Object -Unique)
            if (-not $reportUsers.Count) {
                New-Finding 'User group membership' 'Not evaluated' 'No usable user UPN was returned in the device deployment rows.' 'Do not substitute the primary user for an unknown report context.'
            }
            foreach ($upn in $reportUsers) {
            $principals["Report user $upn"] = "$root/users/$([uri]::EscapeDataString($upn))/transitiveMemberOf"
        }
        foreach ($principal in $principals.Keys) {
            try {
                $memberships = @(Get-AppInvestigationCollection $principals[$principal])
                if (@($memberships | Where-Object { -not (Test-AppInvestigationId $_['id']) }).Count) { throw 'Membership response is incomplete.' }
            } catch {
                New-Finding 'Assignment group membership' 'Lookup unavailable' "$principal membership could not be verified." 'Check directory read permissions and verify membership in Entra.'
                continue
            }
            foreach ($target in $groupTargets) {
                $member = $target.GroupId -in @($memberships | ForEach-Object { $_['id'] })
                $outcome = if (-not $member) { 'No membership returned' }
                    elseif ($target.TargetType -eq 'exclusionGroupAssignmentTarget') { 'Excluded group membership found' }
                    else { 'Included group membership found' }
                $filterEvidence = if ($target.FilterId) { ' Assignment filter outcome is unknown.' } else { '' }
                New-Finding 'Assignment group membership' $outcome "$principal | $($target.GroupName) | $($target.Intent).$filterEvidence" 'Confirm effective targeting in Intune; a membership match does not evaluate filters, context, or intent precedence.'
            }
        }
    }
    try {
        $dependencies = @(Get-AppInvestigationCollection "$appRoot/$($app['id'])/relationships" | Where-Object {
            $_['@odata.type'] -eq '#microsoft.graph.mobileAppDependency' -and $_['targetType'] -eq 'child'
        })
        foreach ($dependency in $dependencies) {
            if (-not (Test-AppInvestigationId $dependency['targetId'])) { throw 'An app dependency did not include a valid target ID.' }
            $dependencyRows = @(Get-AppInvestigationSnapshotRows $dependency['targetId'])
            $failed = @($dependencyRows | Where-Object { $_.PSObject.Properties['InstallState']?.Value -in @('2','-1','Failed','Error') }).Count
            $outcome = if ($failed) { 'Dependency also reports failure' } elseif ($dependencyRows.Count) { 'No failure in available dependency rows' } else { 'Dependency status unavailable' }
            New-Finding 'App dependency' $outcome "$($dependency['targetDisplayName']) ($($dependency['targetId'])) | mode: $($dependency['dependencyType']) | matching snapshot rows: $($dependencyRows.Count)." 'Check that dependency first if it reports failure. Include the dependency in the rollout report to compare the same device without another export.'
        }
    } catch {
        New-Finding 'App dependency' 'Lookup unavailable' 'Dependency relationships or snapshot evidence could not be read.' 'Verify the app relationship in Intune.'
    }
})
$leads = @($findings | Where-Object Outcome -in @('Current requirement mismatch','Architecture not listed','Excluded group membership found','Dependency also reports failure'))
$headline = if ($leads.Count) { 'Potential blockers found; see the evidence below' } else { 'No blocker identified from available Intune data' }
$findings = @([pscustomobject]@{
    Check='Summary'; Outcome=$headline
    Evidence='Current configuration and reported device state are not proof of the original cause. Missing evidence does not rule out a blocker.'
    NextStep='Start with requirement mismatches, assignment evidence, or a dependency reporting failure.'
}) + $leads + @($findings | Where-Object Outcome -notin @('Current requirement mismatch','Architecture not listed','Excluded group membership found','Dependency also reports failure'))
Import-Module (Join-Path $PSScriptRoot 'Win32ErrorCodes.psm1') -Scope Local -ErrorAction Stop
$reportedFailures = @(foreach ($row in $deploymentRows) {
    if (-not (Test-Win32FailureRow ($row.PSObject.Properties['InstallState']?.Value) ($row.PSObject.Properties['InstallStateFriendly']?.Value))) { continue }
    $raw = [string]$row.PSObject.Properties['ErrorCode']?.Value
    $hex = [string]$row.PSObject.Properties['HexErrorCode']?.Value
    [pscustomobject]@{ Code=(Get-Win32ReportedCode $raw $hex); Raw=$raw; RawHex=$hex }
})
$codeGroups = @($reportedFailures | Group-Object Code)
$rolloutCounts = @{}
if ($snapshotUsed -and $codeGroups.Count) {
    $rolloutDevices = [Collections.Generic.HashSet[guid]]::new()
    foreach ($group in $codeGroups) {
        $rolloutCounts[$group.Name] = [Collections.Generic.HashSet[guid]]::new()
    }
    $sourceTable = $DeploymentSnapshot[[string]$app['id']]
    foreach ($row in $sourceTable.Rows) {
        if ($row['ApplicationId'] -ne $app['id']) { continue }
        $id = [guid]::Empty
        if (-not [guid]::TryParse([string]$row['DeviceId'], [ref]$id) -or $id -eq [guid]::Empty) { continue }
        $null = $rolloutDevices.Add($id)
        if (-not (Test-Win32FailureRow $row.InstallState $row.InstallStateFriendly)) { continue }
        $code = Get-Win32ReportedCode $row.ErrorCode $row.HexErrorCode
        if ($rolloutCounts.ContainsKey($code)) { $null = $rolloutCounts[$code].Add($id) }
    }
}
$errorCodeDetails = @(foreach ($group in $codeGroups) {
    $explanation = Get-Win32ErrorExplanation $group.Name $app
    [pscustomobject]@{
        Code=$group.Name
        Meaning=$explanation.Meaning
        NextCheck=$explanation.NextCheck
        RolloutImpact=if ($snapshotUsed) {
            "$($rolloutCounts[$group.Name].Count) of $($rolloutDevices.Count) identified devices"
        } else { 'No retained rollout used' }
        DetectionSettings=$explanation.DetectionSettings
        ReturnCodeConfiguration=$explanation.ReturnCodeConfiguration
        DeviceFailureRows=$group.Count
        HexCode=$explanation.HexCode
        SignedDecimal=$explanation.SignedDecimal
        UnsignedDecimal=$explanation.UnsignedDecimal
        ReportedErrorCode=(@($group.Group.Raw | Where-Object { $_ } | Sort-Object -Unique) -join '; ')
        ReportedHexErrorCode=(@($group.Group.RawHex | Where-Object { $_ } | Sort-Object -Unique) -join '; ')
        Reference=$explanation.Reference
    }
})
$results = @([pscustomobject]@{
    DeviceName=[string]$device['deviceName']; AppName=[string]$app['displayName']
    ReportStatus=if ($deploymentRows.Count) { 'Reported rows available; review all user contexts' } else { 'No matching device report rows; outcome unknown' }
    ReportedStates=(@($deploymentRows.InstallStateFriendly | Sort-Object -Unique) -join '; ')
    ErrorCodes=(@($deploymentRows.ErrorCode | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique) -join '; ')
    ReportRows=$deploymentRows.Count; AssignmentCount=$assignmentRows.Count
    LastIntuneSync=[string]$device['lastSyncDateTime']; AssociatedUser=[string]$device['userPrincipalName']
    SerialNumber=[string]$device['serialNumber']; OperatingSystem=[string]$device['operatingSystem']; OSVersion=[string]$device['osVersion']
    AppVersion=[string]$app['displayVersion']; ManagedDeviceId=[string]$device['id']; AppId=[string]$app['id']
    InstallContext=$installContext; PublishingState=[string]$app['publishingState']
    MinimumWindowsRelease=[string]$app['minimumSupportedWindowsRelease']; AllowedArchitectures=[string]$app['allowedArchitectures']
    LegacyApplicableArchitectures=[string]$app['applicableArchitectures']; AppLastModified=[string]$app['lastModifiedDateTime']
    Targeting='Not evaluated'; CollectedUtc=[datetimeoffset]::UtcNow.ToString('o')
})
Write-Host "Investigation complete: $($deploymentRows.Count) matching deployment row(s). No installation, retry or sync was requested."
$results
