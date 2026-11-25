<#
.SYNOPSIS
    Reports Windows Update for Business fleet, device and KB status from Azure.
.DESCRIPTION
    Queries the five WUfB Log Analytics tables using an existing compatible Azure
    user session, or separate Azure sign-in when required.
    No CSV import, endpoint changes or automatic module installation.
    Graph is used only when optional device-name resolution is enabled.
    Returns device rows; supporting datasets remain available to the desktop adapter.
    Compliance uses OSSecurityUpdateStatus, not Autopatch policy compliance.
.PARAMETER WorkspaceId
    Log Analytics Workspace ID (GUID), not the Azure resource ID or workspace name.
.PARAMETER AzureTenantId
    Optional Azure tenant GUID. Leave blank to use the account's default tenant.
.PARAMETER TargetKB
    Optional exact KB number, for example KB5132043, for per-device investigation.
.PARAMETER DeviceNames
    Optional exact device names. Duplicate names retain separate device IDs.
    Unmatched requested names stop the report rather than silently reducing scope.
.PARAMETER LookbackDays
    Retained snapshot/update/alert lookback, 1-90 days; defaults to 28.
    The fleet is the latest UCClient snapshot, not every historical device.
.PARAMETER StaleDays
    Successful Windows Update scans and update-state evidence older than this
    threshold are stale; defaults to 7 days. Snapshot time alone is not freshness.
.PARAMETER UseDeviceAuthentication
    When sign-in is required, use Azure device-code authentication instead of
    the default browser/broker. A compatible existing user session is reused.
.PARAMETER ResolveDeviceNames
    Resolve missing or suppressed WUfB computer names from Microsoft Graph Entra
    device display names. Off by default. Requires an existing delegated Global
    Graph session in the Azure query tenant with Device.Read.All consent.
    Matches AzureADDeviceId to Entra deviceId, not object ID or device name.
.NOTES
    Requires Az.Accounts 5.0+ and existing Azure workspace/table query access,
    typically Log Analytics Reader. Home Graph consent is unchanged.
    Daily snapshots can contain old device data. Missing evidence is Unknown.
    KB/build mappings are observed workspace evidence, not a complete update catalog.
    No tokens or Azure contexts are written by this script to report files.
.EXAMPLE
    .\Get-WUfBReport.ps1 -WorkspaceId '<workspace-guid>' -TargetKB KB5132043
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [string]$AzureTenantId = '',
    [ValidatePattern('^(?i:KB)?[0-9]{6,8}$')][string]$TargetKB,
    [string[]]$DeviceNames = @(),
    [ValidateRange(1,90)][int]$LookbackDays = 28,
    [ValidateRange(1,28)][int]$StaleDays = 7,
    [switch]$UseDeviceAuthentication,
    [switch]$ResolveDeviceNames
)

function ConvertFrom-WUfBQueryResponse {
    param([Collections.IDictionary]$Response, [string]$Name, [int]$Limit = 100000)
    if (-not $Response -or $Response['error'] -or @($Response['tables']).Count -ne 1) {
        throw "Azure returned an incomplete or invalid result for $Name. No partial report will be displayed."
    }
    $table = $Response['tables'][0]
    if ($table -isnot [Collections.IDictionary] -or $table['columns'] -isnot [array] -or $table['rows'] -isnot [array]) {
        throw "Azure returned an invalid table for $Name."
    }
    if ($table['rows'].Count -gt $Limit) { throw "$Name exceeds the $Limit-row safety limit. Narrow the lookback; no partial report will be displayed." }
    $columns = @($table['columns'])
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($column in $columns) {
        if (-not $column['name'] -or -not $names.Add([string]$column['name'])) { throw "Azure returned invalid columns for $Name." }
    }
    foreach ($values in $table['rows']) {
        if ($values -isnot [array] -or $values.Count -ne $columns.Count) { throw "Azure returned an invalid row for $Name." }
        $record = [ordered]@{}
        for ($index = 0; $index -lt $columns.Count; $index++) {
            $value = $values[$index]
            if ($null -ne $value -and $columns[$index]['type'] -eq 'datetime' -and $value -ne '') {
                $value = [datetimeoffset]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
            }
            $record[[string]$columns[$index]['name']] = $value
        }
        [pscustomobject]$record
    }
}

function Invoke-WUfBQuery {
    param([string]$Query, [string]$Name, [guid]$Workspace, [object]$Profile, [int]$Limit = 100000)
    $access = Get-AzAccessToken -ResourceUrl 'https://api.loganalytics.io' -DefaultProfile $Profile -ErrorAction Stop
    if ($access.Token -isnot [Security.SecureString]) { throw 'Azure returned a non-secure token. Use Az.Accounts 5.0 or newer.' }
    try {
        $response = Invoke-WebRequest -Uri "https://api.loganalytics.azure.com/v1/workspaces/$Workspace/query" `
            -Method Post -Authentication Bearer -Token $access.Token -ContentType 'application/json' `
            -Body (@{ query = $Query } | ConvertTo-Json -Compress) -TimeoutSec 180 -ErrorAction Stop
        $payload = $response.Content | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
        ConvertFrom-WUfBQueryResponse $payload $Name $Limit
    }
    finally { $access = $null }
}

function Get-WUfBIdentity {
    param([object]$Row)
    $id = [guid]::Empty
    if ([guid]::TryParse([string]$Row.AzureADDeviceId, [ref]$id) -and $id -ne [guid]::Empty) { return $id.ToString() }
    if ($Row.GlobalDeviceId) { return "global:$($Row.GlobalDeviceId)" }
    throw 'WUfB returned a record without a usable device identifier. Device names cannot safely identify records.'
}

function Resolve-WUfBDeviceNames {
    param([object[]]$Clients)
    $targets = @{}
    foreach ($client in $Clients) {
        if ([string]::IsNullOrWhiteSpace($client.DeviceName) -or $client.DeviceName -match '^#+$') {
            $id = [guid]::Empty
            if ([guid]::TryParse([string]$client.AzureADDeviceId, [ref]$id) -and $id -ne [guid]::Empty) {
                $targets[$id.ToString()] = $true
            }
        }
    }
    $ids = @($targets.Keys | Sort-Object)
    $names = @{}; $ambiguous = @{}
    for ($offset = 0; $offset -lt $ids.Count; $offset += 15) {
        $batch = @($ids[$offset..([math]::Min($offset + 14, $ids.Count - 1))])
        $filter = ($batch | ForEach-Object { "deviceId eq '$_'" }) -join ' or '
        $uri = 'https://graph.microsoft.com/v1.0/devices?$select=deviceId,displayName&$filter=' + [uri]::EscapeDataString($filter)
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $count = 0
        while ($uri) {
            $address = [uri]$uri
            if ($address.Scheme -ne 'https' -or $address.Host -ne 'graph.microsoft.com' -or
                $address.Port -ne 443 -or $address.AbsolutePath -ne '/v1.0/devices' -or
                $address.UserInfo -or $address.Fragment -or -not $seen.Add($uri)) {
                throw 'Unexpected or repeated Graph device pagination address. Name resolution stopped.'
            }
            $page = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable -ErrorAction Stop
            if ($page -isnot [Collections.IDictionary] -or $page['error'] -or $page['value'] -isnot [array]) {
                throw 'Graph returned an invalid device collection. Name resolution stopped.'
            }
            foreach ($device in $page['value']) {
                $id = [guid]::Empty
                if ($device -isnot [Collections.IDictionary] -or
                    -not [guid]::TryParse([string]$device['deviceId'], [ref]$id) -or $id.ToString() -notin $batch) {
                    throw 'Graph returned an unexpected device identifier. Name resolution stopped.'
                }
                if (++$count -gt 100000) { throw 'Graph device name resolution exceeded the record safety limit.' }
                $key = $id.ToString()
                if ($names.ContainsKey($key)) { $ambiguous[$key] = $true }
                $names[$key] = [string]$device['displayName']
            }
            $uri = [string]$page['@odata.nextLink']
        }
    }
    $unresolved = 0
    foreach ($client in $Clients) {
        $reported = [string]$client.DeviceName
        $source = 'WUfB telemetry'; $resolution = 'Reported by WUfB'
        if ([string]::IsNullOrWhiteSpace($reported) -or $reported -match '^#+$') {
            $id = [guid]::Empty
            $source = 'Unresolved'; $resolution = 'No usable Entra device ID'
            if ([guid]::TryParse([string]$client.AzureADDeviceId, [ref]$id) -and $id -ne [guid]::Empty) {
                $key = $id.ToString()
                $resolution = if ($ambiguous[$key]) { 'Ambiguous Entra device ID' }
                    elseif (-not $names.ContainsKey($key)) { 'No matching Entra device' }
                    elseif ([string]::IsNullOrWhiteSpace($names[$key])) { 'Graph display name unavailable' }
                    else { 'Resolved by Entra device ID' }
                if ($resolution -eq 'Resolved by Entra device ID') {
                    $client.DeviceName = $names[$key]
                    $source = 'Microsoft Graph (Entra)'
                }
            }
            if ($source -eq 'Unresolved') { $unresolved++ }
        }
        [pscustomobject][ordered]@{
            DeviceName = $client.DeviceName; DeviceId = Get-WUfBIdentity $client
            ReportedDeviceName = $reported; NameSource = $source; Resolution = $resolution
        }
    }
    if ($unresolved) { Write-Warning "$unresolved WUfB computer names could not be resolved. Review Device name resolution; no names were guessed." }
}

function Get-WUfBFreshness {
    param([AllowNull()][object]$Time, [datetime]$Now, [int]$Days)
    if (-not $Time) { return 'Unknown' }
    if ([datetime]$Time -gt $Now.AddHours(1)) { return 'Unknown' }
    if ([datetime]$Time -lt $Now.AddDays(-$Days)) { return 'Stale' }
    return 'Fresh'
}

function ConvertTo-WUfBBuild {
    param([AllowNull()][string]$Build)
    if ($Build -match '^[0-9]+\.[0-9]+$') { return "10.0.$Build" }
    return $Build
}

function Get-WUfBUpdateState {
    param([object]$Update, [object[]]$Alerts)
    $state = [string]$Update.ClientSubstate
    if ($state -in @('Uninstalled','UninstallComplete','Uninstalling','UninstallStart')) { return 'Not installed' }
    if ($state -in @('Installed','UpdateInstalled')) { return 'Installed' }
    if ($state -in @('RebootRequired','RebootPending','RestartRequired','RestartPending')) { return 'Pending restart' }
    if ($state -in @('InstallFailed','InstallationFailed','DownloadFailed','DownloadError','InstallError')) { return 'Failed' }
    $active = @($Alerts | Where-Object { $_.AlertStatus -eq 'Active' -and $_.AlertClassification -eq 'Error' })
    if (@($active | Where-Object { $_.AlertType -eq 'ClientUpdateAlert' -and $_.AlertSubtype -match '^(Install|Download)' -and $_.AlertSubtype -notmatch 'RestartRequired|Cancelled' }).Count) {
        return 'Failed'
    }
    if ($state -in @('DownloadStart','DownloadComplete','DownloadInProgress','Installing','InstallStart','InstallComplete','InstallInProgress')) { return 'In progress' }
    if ($state -in @('Offering','OfferReceived','OfferReady','Canceled','Cancelled','OnHold')) { return 'Not installed' }
    if ($active.Count) { return 'Needs attention' }
    return 'Unknown'
}

function New-WUfBReport {
    param(
        [object[]]$Clients, [object[]]$Updates, [object[]]$Services, [object[]]$UpdateAlerts,
        [object[]]$DeviceAlerts, [object[]]$Trends, [object[]]$Health,
        [string]$KB, [string[]]$Names, [int]$FreshDays, [datetime]$Now = [datetime]::UtcNow
    )
    $clientsById = @{}
    foreach ($client in $Clients) {
        $key = Get-WUfBIdentity $client
        if ($clientsById.ContainsKey($key)) { throw 'The latest WUfB snapshot contains duplicate device identifiers.' }
        $clientsById[$key] = $client
    }
    if ($Names.Count) {
        $requested = @($Names | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if (-not $requested.Count) { throw 'DeviceNames must contain at least one nonempty exact name.' }
        foreach ($name in $requested) {
            if (-not @($Clients | Where-Object DeviceName -eq $name).Count) { throw "Requested device '$name' is absent from the latest WUfB snapshot." }
        }
        foreach ($key in @($clientsById.Keys)) {
            if ($clientsById[$key].DeviceName -notin $requested) { $clientsById.Remove($key) }
        }
    }
    $alertsByDevice = @{}; $alertsByUpdate = @{}; $servicesByUpdate = @{}
    $allAlerts = [Collections.Generic.List[object]]::new()
    foreach ($source in @(
        @{ Rows = $UpdateAlerts; Table = 'UCUpdateAlert' },
        @{ Rows = $DeviceAlerts; Table = 'UCDeviceAlert' }
    )) {
        foreach ($alert in $source.Rows) {
            $key = Get-WUfBIdentity $alert
            if (-not $clientsById.ContainsKey($key)) { continue }
            if (-not $alertsByDevice.ContainsKey($key)) { $alertsByDevice[$key] = [Collections.Generic.List[object]]::new() }
            $alertsByDevice[$key].Add($alert)
            if ($source.Table -eq 'UCUpdateAlert' -and $alert.TargetBuild) {
                $updateKey = "$key|$(ConvertTo-WUfBBuild $alert.TargetBuild)|$($alert.DeploymentId)"
                if (-not $alertsByUpdate.ContainsKey($updateKey)) { $alertsByUpdate[$updateKey] = [Collections.Generic.List[object]]::new() }
                $alertsByUpdate[$updateKey].Add($alert)
            }
            $allAlerts.Add([pscustomobject][ordered]@{
                DeviceName = $clientsById[$key].DeviceName; DeviceId = $key; SourceTable = $source.Table
                AlertId = $alert.AlertId; AlertStatus = $alert.AlertStatus; Severity = $alert.AlertClassification
                AlertType = $alert.AlertType; AlertSubtype = $alert.AlertSubtype
                TargetBuild = $alert.TargetBuild; DeploymentId = $alert.DeploymentId
                ErrorCode = $alert.ErrorCode; ErrorSymName = $alert.ErrorSymName
                Description = $alert.Description; Recommendation = $alert.Recommendation
                StartTimeUtc = $alert.StartTime; ResolvedTimeUtc = $alert.ResolvedTime
                SnapshotTimeUtc = $alert.TimeGenerated
            })
        }
    }
    $serviceRows = [Collections.Generic.List[object]]::new()
    foreach ($service in $Services) {
        $key = Get-WUfBIdentity $service
        if (-not $clientsById.ContainsKey($key)) { continue }
        $updateKey = "$key|$(ConvertTo-WUfBBuild $service.TargetBuild)|$($service.UpdateCategory)|$($service.DeploymentId)"
        if ($servicesByUpdate.ContainsKey($updateKey)) { throw 'WUfB returned ambiguous service update records.' }
        $servicesByUpdate[$updateKey] = $service
        $serviceRows.Add([pscustomobject][ordered]@{
            DeviceName = $clientsById[$key].DeviceName; DeviceId = $key; TargetBuild = $service.TargetBuild
            UpdateCategory = $service.UpdateCategory; UpdateDisplayName = $service.UpdateDisplayName
            DeploymentId = $service.DeploymentId; ServiceState = $service.ServiceState
            ServiceSubstate = $service.ServiceSubstate; StateTimeUtc = $service.ServiceSubstateTime
            OfferReadyTimeUtc = $service.OfferReadyTime; SnapshotTimeUtc = $service.TimeGenerated
        })
    }
    $updatesByDevice = @{}
    $updateRows = [Collections.Generic.List[object]]::new()
    foreach ($update in $Updates) {
        $key = Get-WUfBIdentity $update
        if (-not $clientsById.ContainsKey($key)) { continue }
        $updateKey = "$key|$(ConvertTo-WUfBBuild $update.TargetBuild)|$($update.DeploymentId)"
        $relatedAlerts = @($alertsByUpdate[$updateKey] | Where-Object { $null -ne $_ })
        if ($update.DeploymentId) {
            $relatedAlerts += @($alertsByUpdate["$key|$(ConvertTo-WUfBBuild $update.TargetBuild)|"] | Where-Object { $null -ne $_ })
        }
        $service = $servicesByUpdate["$key|$(ConvertTo-WUfBBuild $update.TargetBuild)|$($update.UpdateCategory)|$($update.DeploymentId)"]
        $row = [pscustomobject][ordered]@{
            DeviceName = $clientsById[$key].DeviceName; DeviceId = $key
            TargetKB = $update.TargetKBNumber; TargetBuild = $update.TargetBuild; TargetVersion = $update.TargetVersion
            UpdateCategory = $update.UpdateCategory; Classification = $update.UpdateClassification
            UpdateDisplayName = $update.UpdateDisplayName; UpdateReleaseTimeUtc = $update.UpdateReleaseTime
            State = Get-WUfBUpdateState $update $relatedAlerts; RawClientSubstate = $update.ClientSubstate
            StateTimeUtc = $update.ClientSubstateTime; EvidenceFreshness = Get-WUfBFreshness $update.ClientSubstateTime $Now $FreshDays
            StateAgeDays = $null; ProgressReview = 'No stalled-state finding'
            InstalledTimeUtc = $update.UpdateInstalledTime; RestartRequiredTimeUtc = $update.RestartRequiredTime
            RestartWaitingDays = $null; DeploymentId = $update.DeploymentId
            ServiceState = if ($service) { $service.ServiceState } else { '' }
            ServiceSubstate = if ($service) { $service.ServiceSubstate } else { '' }
            ActiveErrorCodes = (@($relatedAlerts | Where-Object { $_.AlertStatus -eq 'Active' -and $_.AlertClassification -eq 'Error' } |
                ForEach-Object ErrorCode | Where-Object { $_ } | Sort-Object -Unique) -join '; ')
            SnapshotTimeUtc = $update.TimeGenerated
        }
        if ($row.StateTimeUtc -and [datetime]$row.StateTimeUtc -le $Now) {
            $row.StateAgeDays = [math]::Round(($Now - [datetime]$row.StateTimeUtc).TotalDays, 1)
            if ($row.State -eq 'In progress' -and $row.StateAgeDays -ge $FreshDays) {
                $row.ProgressReview = 'Stalled candidate (old state evidence)'
            }
        }
        if ($row.State -eq 'Pending restart' -and $row.RestartRequiredTimeUtc -and [datetime]$row.RestartRequiredTimeUtc -le $Now) {
            $row.RestartWaitingDays = [math]::Round(($Now - [datetime]$row.RestartRequiredTimeUtc).TotalDays, 1)
        }
        $updateRows.Add($row)
        if (-not $updatesByDevice.ContainsKey($key)) { $updatesByDevice[$key] = [Collections.Generic.List[object]]::new() }
        $updatesByDevice[$key].Add($row)
    }
    $devices = [Collections.Generic.List[object]]::new()
    $kbRows = [Collections.Generic.List[object]]::new()
    $kbTargets = @($Updates | Where-Object { $_.TargetKBNumber -eq $KB -and $_.UpdateCategory -eq 'WindowsQualityUpdate' })
    foreach ($key in @($clientsById.Keys | Sort-Object)) {
        $client = $clientsById[$key]
        $freshness = Get-WUfBFreshness $client.LastWUScanTime $Now $FreshDays
        if ((Get-WUfBFreshness $client.TimeGenerated $Now $FreshDays) -ne 'Fresh' -and $freshness -eq 'Fresh') { $freshness = 'Stale' }
        $compliance = if ($freshness -ne 'Fresh') { $freshness } else {
            switch ($client.OSSecurityUpdateStatus) {
                'Latest' { 'Compliant' }
                { $_ -in @('NotLatest','MultipleSecurityUpdatesMissing') } { 'Not compliant' }
                default { 'Unknown' }
            }
        }
        $deviceUpdates = @($updatesByDevice[$key] | Where-Object { $null -ne $_ })
        $latestInstalled = @($deviceUpdates | Where-Object {
            $_.UpdateCategory -eq 'WindowsQualityUpdate' -and $_.State -eq 'Installed' -and
            (ConvertTo-WUfBBuild $_.TargetBuild) -eq (ConvertTo-WUfBBuild $client.OSBuild)
        } | Sort-Object InstalledTimeUtc -Descending | Select-Object -First 1)
        $activeAlerts = @($alertsByDevice[$key] | Where-Object AlertStatus -eq 'Active')
        $pending = @($deviceUpdates | Where-Object State -eq 'Pending restart')
        $devices.Add([pscustomobject][ordered]@{
            DeviceName = $client.DeviceName; DeviceId = $key; IdentitySource = if ($key.StartsWith('global:')) { 'GlobalDeviceId' } else { 'Entra device ID' }
            SecurityCompliance = $compliance; ReportedSecurityStatus = $client.OSSecurityUpdateStatus
            ReportedQualityStatus = $client.OSQualityUpdateStatus; Freshness = $freshness
            OSVersion = $client.OSVersion; OSEdition = $client.OSEdition; Architecture = $client.OSArchitecture
            OSBuild = $client.OSBuild; ServicingChannel = $client.OSServicingChannel
            LatestInstalledQualityKB = if ($latestInstalled.Count) { $latestInstalled[0].TargetKB } else { '' }
            QualityInstalledTimeUtc = if ($latestInstalled.Count) { $latestInstalled[0].InstalledTimeUtc } else { $null }
            InstalledQualityReleaseTimeUtc = $client.OSQualityUpdateReleaseTime
            PendingRestart = if ($pending.Count) { 'Reported' } else { 'No evidence' }
            PendingRestartKBs = ($pending.TargetKB | Sort-Object -Unique) -join '; '
            FailedUpdateRecords = @($deviceUpdates | Where-Object State -eq 'Failed').Count
            ActiveAlerts = $activeAlerts.Count
            ActiveErrorCodes = (@($activeAlerts | ForEach-Object ErrorCode | Where-Object { $_ } | Sort-Object -Unique) -join '; ')
            OSServiceStatus = $client.OSFeatureUpdateStatus; OSEndOfServiceUtc = $client.OSFeatureUpdateEOSTime
            QualityPauseState = $client.WUQualityPauseState; QualityDeferralDays = $client.WUQualityDeferralDays
            QualityDeadlineDays = $client.WUQualityDeadlineDays; QualityGracePeriodDays = $client.WUQualityGracePeriodDays
            LastWUScanTimeUtc = $client.LastWUScanTime; LastCensusScanTimeUtc = $client.LastCensusScanTime
            SnapshotTimeUtc = $client.TimeGenerated
        })
        if ($KB) {
            $matches = @($deviceUpdates | Where-Object TargetKB -eq $KB | Sort-Object StateTimeUtc -Descending)
            $kbState = 'Unknown'; $evidence = 'No update evidence for this KB in the retained query window.'
            $match = if ($matches.Count) { $matches[0] } else { $null }
            $corroboratedInstall = $match -and $match.State -eq 'Installed' -and
                (ConvertTo-WUfBBuild $match.TargetBuild) -eq (ConvertTo-WUfBBuild $client.OSBuild)
            if ($match -and ($match.EvidenceFreshness -eq 'Fresh' -or $corroboratedInstall) -and $freshness -eq 'Fresh') {
                $kbState = $match.State
                $evidence = 'Latest reported client state for this device and KB.'
                if (@($matches | Where-Object { $_.State -ne $match.State -and $_.EvidenceFreshness -eq 'Fresh' }).Count) {
                    $kbState = 'Unknown'; $evidence = 'Conflicting deployment states; inspect the individual update records.'
                }
            }
            elseif ($match) { $evidence = 'KB evidence or device telemetry is stale/unknown; inspect the reported state below.' }
            if ($kbState -ne 'Installed' -and $freshness -eq 'Fresh') {
                $currentBuild = $null
                if ([version]::TryParse([string]$client.OSBuild, [ref]$currentBuild) -and $currentBuild.Revision -ge 0) {
                    foreach ($target in $kbTargets) {
                        $targetBuild = $null
                        if ([version]::TryParse((ConvertTo-WUfBBuild $target.TargetBuild), [ref]$targetBuild) -and $targetBuild.Revision -ge 0 -and
                            $target.TargetVersion -eq $client.OSVersion -and $currentBuild.Major -eq $targetBuild.Major -and
                            $currentBuild.Minor -eq $targetBuild.Minor -and $currentBuild.Build -eq $targetBuild.Build -and
                            $currentBuild.Revision -gt $targetBuild.Revision) {
                            $kbState = 'Newer build (inferred coverage)'
                            $evidence = 'Current OS revision exceeds the observed KB target in the same OS branch. Not proof this exact KB was installed.'
                            break
                        }
                    }
                }
            }
            $kbRows.Add([pscustomobject][ordered]@{
                DeviceName = $client.DeviceName; DeviceId = $key; TargetKB = $KB; KBStatus = $kbState
                Evidence = $evidence; OSVersion = $client.OSVersion; OSBuild = $client.OSBuild; Freshness = $freshness
                ReportedKBState = if ($match) { $match.State } else { '' }
                RawClientSubstate = if ($match) { $match.RawClientSubstate } else { '' }
                TargetBuild = if ($match) { $match.TargetBuild } else { '' }
                InstalledTimeUtc = if ($match) { $match.InstalledTimeUtc } else { $null }
                StateTimeUtc = if ($match) { $match.StateTimeUtc } else { $null }
                ActiveErrorCodes = if ($match) { $match.ActiveErrorCodes } else { '' }
                LastWUScanTimeUtc = $client.LastWUScanTime; SnapshotTimeUtc = $client.TimeGenerated
            })
        }
    }
    $compliant = @($devices | Where-Object SecurityCompliance -eq 'Compliant').Count
    $notCompliant = @($devices | Where-Object SecurityCompliance -eq 'Not compliant').Count
    $denominator = $compliant + $notCompliant
    $overview = [pscustomobject][ordered]@{
        ComplianceBasis = 'WUfB latest security update status for each OS version; not Autopatch policy compliance'
        SecurityCompliancePercent = if ($denominator) { [math]::Round(100.0 * $compliant / $denominator, 2) } else { $null }
        CompliantDevices = $compliant; NotCompliantDevices = $notCompliant; EvaluatedDevices = $denominator
        TotalDevices = $devices.Count; StaleDevices = @($devices | Where-Object SecurityCompliance -eq 'Stale').Count
        UnknownDevices = @($devices | Where-Object SecurityCompliance -eq 'Unknown').Count
        StaleThresholdDays = $FreshDays; DevicesWithFailedUpdates = @($devices | Where-Object { $_.FailedUpdateRecords -gt 0 }).Count
        DevicesWithPendingRestart = @($devices | Where-Object PendingRestart -eq 'Reported').Count
        DevicesWithActiveAlerts = @($devices | Where-Object { $_.ActiveAlerts -gt 0 }).Count
        Scope = if ($Names.Count) { 'Requested exact names in latest workspace snapshot' } else { 'Latest workspace device snapshot only' }
        TargetKB = $KB; RetrievedTimeUtc = $Now
    }
    [pscustomobject]@{
        Devices = $devices.ToArray(); Overview = @($overview); Updates = $updateRows.ToArray(); Services = $serviceRows.ToArray()
        Alerts = $allAlerts.ToArray(); KB = $kbRows.ToArray(); Health = $Health
        Missing = @($devices | Where-Object SecurityCompliance -eq 'Not compliant')
        Failures = @($updateRows | Where-Object State -eq 'Failed')
        Restarts = @($updateRows | Where-Object State -eq 'Pending restart')
        Stalled = @($updateRows | Where-Object ProgressReview -eq 'Stalled candidate (old state evidence)')
        Trends = if ($Names.Count) { @() } else { $Trends }
        Errors = @($allAlerts | Where-Object { $_.AlertStatus -eq 'Active' -and $_.Severity -eq 'Error' } | Group-Object ErrorCode |
            ForEach-Object {
                [pscustomobject]@{
                    ErrorCode = $_.Name; AffectedDevices = @($_.Group.DeviceId | Sort-Object -Unique).Count
                    ActiveAlertRecords = $_.Count; SymbolicNames = ($_.Group.ErrorSymName | Where-Object { $_ } | Sort-Object -Unique) -join '; '
                    Description = ($_.Group.Description | Where-Object { $_ } | Sort-Object -Unique) -join '; '
                    Recommendation = ($_.Group.Recommendation | Where-Object { $_ } | Sort-Object -Unique) -join '; '
                }
            })
        UpdateCatalog = @($Updates | Where-Object TargetKBNumber | Group-Object TargetKBNumber,TargetBuild,TargetVersion,UpdateClassification |
            ForEach-Object { $_.Group[0] } | Select-Object TargetKBNumber,TargetBuild,TargetVersion,UpdateClassification,UpdateDisplayName,UpdateReleaseTime)
    }
}

if ($WorkspaceId -eq [guid]::Empty) { throw 'WorkspaceId cannot be an empty GUID.' }
if ($AzureTenantId) {
    $tenantGuid = [guid]::Empty
    if (-not [guid]::TryParse($AzureTenantId, [ref]$tenantGuid) -or $tenantGuid -eq [guid]::Empty) { throw 'AzureTenantId must be a nonempty tenant GUID.' }
}
if ($TargetKB) { $TargetKB = 'KB' + ($TargetKB -replace '^(?i:KB)', '') }
$module = Get-Module -ListAvailable Az.Accounts | Where-Object Version -ge ([version]'5.0') | Select-Object -First 1
if (-not $module) { throw 'WUfB reporting requires Az.Accounts 5.0+. Install it deliberately in PowerShell 7: Install-Module Az.Accounts -Scope CurrentUser. The app does not install modules.' }
Import-Module Az.Accounts -MinimumVersion 5.0 -ErrorAction Stop
$null = Disable-AzContextAutosave -Scope Process -ErrorAction Stop
$loginArguments = @{ Scope = 'Process'; SkipContextPopulation = $true; ErrorAction = 'Stop' }
if ($AzureTenantId) { $loginArguments.Tenant = $AzureTenantId }
if ($UseDeviceAuthentication) { $loginArguments.UseDeviceAuthentication = $true }
$azureProfile = $null; $azureLogin = $null; $expectedAccount = ''
$existing = Get-AzContext -ErrorAction Stop
$existingTenant = [guid]::Empty
if ($existing -and $existing.Account.Type -eq 'User' -and $existing.Account.Id -and
    $existing.Environment.Name -eq 'AzureCloud' -and
    [guid]::TryParse([string]$existing.Tenant.Id, [ref]$existingTenant) -and $existingTenant -ne [guid]::Empty -and
    (-not $AzureTenantId -or $existingTenant -eq [guid]$AzureTenantId)) {
    $access = $null
    try {
        $access = Get-AzAccessToken -ResourceUrl 'https://api.loganalytics.io' -DefaultProfile $existing -ErrorAction Stop
        if ($access.Token -isnot [Security.SecureString] -or $access.Token.Length -eq 0) {
            throw 'Azure returned an invalid or non-secure token. Use Az.Accounts 5.0 or newer.'
        }
        $azureProfile = $existing
        Write-Host 'Reusing the existing Azure user session for read-only WUfB workspace queries. Home Graph is unchanged.'
    }
    catch {
        $authenticationFailure = $false
        for ($exception = $_.Exception; $exception; $exception = $exception.InnerException) {
            if ($exception.GetType().FullName -in @(
                'Microsoft.Azure.Commands.Common.Exceptions.AzPSAuthenticationFailedException',
                'Microsoft.Azure.Commands.Common.Authentication.AadAuthenticationCantRenewException',
                'Microsoft.Azure.Commands.Common.Authentication.AadAuthenticationFailedWithoutPopupException',
                'Azure.Identity.AuthenticationRequiredException',
                'Microsoft.Identity.Client.MsalUiRequiredException'
            )) { $authenticationFailure = $true; break }
        }
        if (-not $authenticationFailure) { throw }
        Write-Warning 'The existing Azure session requires authentication renewal. Sign in again with the same account and tenant.'
        $expectedAccount = [string]$existing.Account.Id
        $loginArguments.AccountId = $expectedAccount
        $loginArguments.Tenant = $existingTenant.ToString()
    }
    finally { $access = $null }
}
if (-not $azureProfile) {
    Write-Host 'Sign in to Azure for read-only WUfB workspace queries. Home Graph is unchanged.'
    $loginConfig = @(Get-AzConfig -LoginExperienceV2 -Scope Process -AppliesTo Az -ErrorAction Stop)
    if ($loginConfig.Count -gt 1) { throw 'Azure returned ambiguous process login configuration. Sign-in was not started.' }
    try {
        # Log Analytics queries are workspace-bound; the console subscription selector is unnecessary.
        $null = Update-AzConfig -LoginExperienceV2 Off -Scope Process -AppliesTo Az -ErrorAction Stop
        $azureLogin = Connect-AzAccount @loginArguments
    }
    finally {
        if ($loginConfig.Count) {
            $null = Update-AzConfig -LoginExperienceV2 $loginConfig[0].Value -Scope Process -AppliesTo Az -ErrorAction Stop
        }
        else {
            $null = Clear-AzConfig -LoginExperienceV2 -Scope Process -AppliesTo Az -ErrorAction Stop
        }
    }
    $azureProfile = $azureLogin.Context
}
$tenant = [guid]::Empty
if (-not $azureProfile -or $azureProfile.Account.Type -ne 'User' -or -not $azureProfile.Account.Id -or
    $azureProfile.Environment.Name -ne 'AzureCloud' -or
    -not [guid]::TryParse([string]$azureProfile.Tenant.Id, [ref]$tenant) -or $tenant -eq [guid]::Empty) {
    throw 'A valid Azure public-cloud user context is required for WUfB reporting.'
}
if ($AzureTenantId -and $tenant -ne [guid]$AzureTenantId) { throw 'Azure signed in to a different tenant than requested.' }
if ($expectedAccount -and ($azureProfile.Account.Id -ne $expectedAccount -or $tenant -ne $existingTenant)) {
    throw 'Azure signed in to a different account or tenant during session renewal. No workspace query was started.'
}
if ($ResolveDeviceNames) {
    $graphContext = Get-MgContext -ErrorAction Stop
    if (-not $graphContext -or $graphContext.AuthType -ne 'Delegated' -or $graphContext.Environment -ne 'Global') {
        throw 'Graph name resolution requires an existing delegated Global Graph session. Connect on Home or use Connect-MgGraph before running.'
    }
    if ([string]$graphContext.TenantId -ne $tenant.ToString()) {
        throw 'Graph and Azure tenants differ. Connect Graph to the Azure workspace tenant before resolving names.'
    }
    if ('Device.Read.All' -notin $graphContext.Scopes) {
        throw 'Graph name resolution requires existing Device.Read.All delegated consent. No additional consent is requested automatically.'
    }
}
Write-Host "Azure tenant: $tenant. Checking WUfB table schemas and querying retained snapshots."
$definitions = [ordered]@{
    UCClient = @{
        Required = @('AzureADDeviceId','AzureADTenantId','TimeGenerated','OSSecurityUpdateStatus','LastWUScanTime','OSBuild')
        Fields = @('AzureADDeviceId','GlobalDeviceId','DeviceName','TimeGenerated','LastWUScanTime','LastCensusScanTime','OSSecurityUpdateStatus','OSQualityUpdateStatus','OSBuild','OSVersion','OSEdition','OSArchitecture','OSServicingChannel','OSQualityUpdateReleaseTime','OSFeatureUpdateStatus','OSFeatureUpdateEOSTime','WUQualityPauseState','WUQualityDeferralDays','WUQualityDeadlineDays','WUQualityGracePeriodDays')
        Key = 'AzureADDeviceId, GlobalDeviceId'
    }
    UCClientUpdateStatus = @{
        Required = @('AzureADDeviceId','AzureADTenantId','TimeGenerated','TargetKBNumber','TargetBuild','ClientSubstate','ClientSubstateTime','UpdateCategory')
        Fields = @('AzureADDeviceId','GlobalDeviceId','TimeGenerated','TargetKBNumber','TargetBuild','TargetVersion','ClientSubstate','ClientSubstateTime','UpdateCategory','UpdateClassification','UpdateDisplayName','UpdateReleaseTime','UpdateInstalledTime','RestartRequiredTime','DeploymentId')
        Key = 'AzureADDeviceId, GlobalDeviceId, TargetBuild, UpdateCategory, DeploymentId'
    }
    UCServiceUpdateStatus = @{
        Required = @('AzureADDeviceId','AzureADTenantId','TimeGenerated','TargetBuild','ServiceSubstate')
        Fields = @('AzureADDeviceId','GlobalDeviceId','TimeGenerated','TargetBuild','UpdateCategory','UpdateDisplayName','DeploymentId','ServiceState','ServiceSubstate','ServiceSubstateTime','OfferReadyTime')
        Key = 'AzureADDeviceId, GlobalDeviceId, TargetBuild, UpdateCategory, DeploymentId'
    }
    UCUpdateAlert = @{
        Required = @('AzureADDeviceId','AzureADTenantId','TimeGenerated','AlertId','AlertStatus','AlertClassification','TargetBuild')
        Fields = @('AzureADDeviceId','GlobalDeviceId','TimeGenerated','AlertId','AlertStatus','AlertClassification','AlertType','AlertSubtype','TargetBuild','DeploymentId','ErrorCode','ErrorSymName','Description','Recommendation','StartTime','ResolvedTime')
        Key = 'AzureADDeviceId, GlobalDeviceId, AlertId'
    }
    UCDeviceAlert = @{
        Required = @('AzureADDeviceId','AzureADTenantId','TimeGenerated','AlertId','AlertStatus','AlertClassification')
        Fields = @('AzureADDeviceId','GlobalDeviceId','TimeGenerated','AlertId','AlertStatus','AlertClassification','AlertType','AlertSubtype','TargetBuild','DeploymentId','ErrorCode','ErrorSymName','Description','Recommendation','StartTime','ResolvedTime')
        Key = 'AzureADDeviceId, GlobalDeviceId, AlertId'
    }
}
$raw = @{}; $healthRows = [Collections.Generic.List[object]]::new()
try {
    foreach ($tableName in $definitions.Keys) {
        $definition = $definitions[$tableName]
        $schema = @(Invoke-WUfBQuery "$tableName | getschema" "$tableName schema" $WorkspaceId $azureProfile)
        $available = @{}
        foreach ($column in $schema) { $available[[string]$column.ColumnName] = [string]$column.ColumnName }
        foreach ($required in $definition.Required) {
            if (-not $available.ContainsKey($required)) { throw "$tableName is missing required column $required. No partial report will be displayed." }
        }
        $missing = @($definition.Fields | Where-Object { -not $available.ContainsKey($_) })
        if ($missing.Count) { Write-Warning "$tableName has unavailable optional fields: $($missing -join ', '). These values will remain blank." }
        $projection = ($definition.Fields | ForEach-Object {
            if ($available.ContainsKey($_)) { "$_ = $($available[$_])" } else { "$_ = ''" }
        }) -join ', '
        $base = "$tableName | where TimeGenerated >= ago($($LookbackDays)d) | where AzureADTenantId =~ '$tenant'"
        $query = if ($tableName -eq 'UCClient') {
            "let snapshot = toscalar($base | summarize max(TimeGenerated)); $base | where TimeGenerated == snapshot | project $projection"
        } else {
            "$base | project $projection | summarize arg_max(TimeGenerated, *) by $($definition.Key)"
        }
        $raw[$tableName] = @(Invoke-WUfBQuery "$query | take 100001" $tableName $WorkspaceId $azureProfile)
        if ($tableName -eq 'UCClient') { $clientHistoryQuery = "$base | project $projection" }
        $healthRows.Add([pscustomobject]@{
            Table = $tableName; RecordsReturned = $raw[$tableName].Count
            LatestSnapshotUtc = if ($raw[$tableName].Count) { ($raw[$tableName] | Sort-Object TimeGenerated -Descending | Select-Object -First 1).TimeGenerated } else { $null }
            MissingOptionalFields = $missing -join '; '; LookbackDays = $LookbackDays
        })
    }
    if (-not $raw.UCClient.Count) { throw 'No UCClient device records were returned for the signed-in tenant and lookback. Check workspace access, enrollment and ingestion; no compliance percentage can be calculated.' }
    if ($ResolveDeviceNames) {
        Write-Host 'Resolving missing WUfB names from Graph using Entra device IDs. Device diagnostic-data policies are unchanged.'
        $wufbNameResolution = @(Resolve-WUfBDeviceNames $raw.UCClient)
    }
    $trendQuery = "$clientHistoryQuery | summarize arg_max(TimeGenerated, *) by AzureADDeviceId, GlobalDeviceId, SnapshotDay = startofday(TimeGenerated) | extend Fresh = isnotnull(LastWUScanTime) and LastWUScanTime >= TimeGenerated - $($StaleDays)d and LastWUScanTime <= TimeGenerated + 1h | summarize TotalDevices = count(), CompliantDevices = countif(Fresh and OSSecurityUpdateStatus == 'Latest'), NotCompliantDevices = countif(Fresh and OSSecurityUpdateStatus in ('NotLatest','MultipleSecurityUpdatesMissing')) by SnapshotDay | extend EvaluatedDevices = CompliantDevices + NotCompliantDevices | extend UnknownOrStaleDevices = TotalDevices - EvaluatedDevices, SecurityCompliancePercent = iff(EvaluatedDevices > 0, round(100.0 * CompliantDevices / EvaluatedDevices, 2), real(null)) | order by SnapshotDay asc"
    $trendRows = if ($DeviceNames.Count) { @() } else { @(Invoke-WUfBQuery $trendQuery 'Compliance trend' $WorkspaceId $azureProfile) }
    $wufb = New-WUfBReport -Clients $raw.UCClient -Updates $raw.UCClientUpdateStatus -Services $raw.UCServiceUpdateStatus `
        -UpdateAlerts $raw.UCUpdateAlert -DeviceAlerts $raw.UCDeviceAlert -Trends $trendRows -Health $healthRows.ToArray() `
        -KB $TargetKB -Names $DeviceNames -FreshDays $StaleDays
    $results = $wufb.Devices
    if ($ResolveDeviceNames) {
        $reportedIds = @{}
        foreach ($device in $results) { $reportedIds[$device.DeviceId] = $true }
        $wufbNameResolution = @($wufbNameResolution | Where-Object { $reportedIds.ContainsKey($_.DeviceId) })
    }
    $wufbOverview = $wufb.Overview; $wufbUpdates = $wufb.Updates; $wufbServices = $wufb.Services
    $wufbAlerts = $wufb.Alerts; $wufbKB = $wufb.KB; $wufbHealth = $wufb.Health; $wufbTrends = $wufb.Trends
    $wufbMissing = $wufb.Missing; $wufbFailures = $wufb.Failures; $wufbRestarts = $wufb.Restarts; $wufbCatalog = $wufb.UpdateCatalog
    $wufbErrors = $wufb.Errors
    $wufbStalled = $wufb.Stalled
    if ($TargetKB -and -not @($raw.UCClientUpdateStatus | Where-Object TargetKBNumber -eq $TargetKB).Count) {
        Write-Warning "$TargetKB was not observed in the retained update records. No-record devices are Unknown, not missing."
    }
    Write-Host 'WUfB is delayed telemetry. Snapshot ingestion is not device scan time. Only workspace devices are covered; missing values and no KB evidence do not mean healthy or not installed.'
    Write-Host "$($results.Count) device records. Security compliance: $($wufbOverview[0].CompliantDevices)/$($wufbOverview[0].EvaluatedDevices) evaluated; $($wufbOverview[0].StaleDevices) stale and $($wufbOverview[0].UnknownDevices) unknown excluded."
    $results
}
finally { $azureProfile = $null; $azureLogin = $null }
