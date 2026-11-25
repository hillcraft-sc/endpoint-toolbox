<#
.SYNOPSIS
    Investigates device records across Intune, Entra and Windows Autopilot.
.DESCRIPTION
    Searches exact Intune device names, serial numbers or associated user UPNs.
    Device-name searches also find Entra and Autopilot records with the same
    name; serial searches also find Autopilot records with the same serial.
    Uses recorded identifiers to correlate records, never serial number alone.
    Returns an overview; the detailed source records and reconciliation
    findings remain available as variables when dot-sourced.
.PARAMETER SearchBy
    Search by exact device name, serial number or Intune-associated user UPN.
.PARAMETER SearchValue
    The exact name, serial number or user principal name to investigate.
.EXAMPLE
    .\Get-EndpointDeviceInvestigation.ps1 -SearchBy 'Device name' -SearchValue 'PC-123'
.NOTES
    Requires Microsoft.Graph.Authentication and an authorized Global Graph
    connection with DeviceManagementManagedDevices.Read.All, Device.Read.All,
    User.Read.All and DeviceManagementServiceConfig.Read.All. Autopilot records
    are enumerated and filtered locally because server-side filter support varies.
    This is read-only. Reported state can be stale or limited by permissions.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Device name', 'Serial number', 'User UPN')]
    [string]$SearchBy,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SearchValue
)

$SearchValue = $SearchValue.Trim()
if (-not $SearchValue) { throw 'Enter a device name, serial number or user UPN.' }
$context = Get-MgContext -ErrorAction Stop
if (-not $context) {
    Connect-MgGraph -Scopes 'https://graph.microsoft.com/.default' -NoWelcome -ErrorAction Stop | Out-Null
    $context = Get-MgContext -ErrorAction Stop
}
if (-not $context -or $context.Environment -ne 'Global') { throw 'An active Global Microsoft Graph connection is required.' }

function Get-InvestigationCollection {
    param([string]$Uri)
    $expectedPath = ([uri]$Uri).AbsolutePath
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($Uri) {
        $address = [uri]$Uri
        if (-not $address.IsAbsoluteUri -or $address.Scheme -ne 'https' -or
            $address.Host -ne 'graph.microsoft.com' -or -not $address.IsDefaultPort -or
            $address.UserInfo -or $address.Fragment -or $address.AbsolutePath -cne $expectedPath -or
            -not $seen.Add($Uri)) {
            throw 'Graph returned an unexpected or repeated page; the investigation was not completed.'
        }
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType Hashtable -ErrorAction Stop
        if ($page -isnot [System.Collections.IDictionary] -or $page['value'] -isnot [array]) {
            throw 'Graph returned an invalid collection; the investigation was not completed.'
        }
        $page['value']
        $Uri = [string]$page['@odata.nextLink']
    }
}

function Test-InvestigationId {
    param($Value)
    $parsed = [guid]::Empty
    return [guid]::TryParse([string]$Value, [ref]$parsed) -and $parsed -ne [guid]::Empty
}

function Test-InvestigationAbsentId {
    param($Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $true }
    $parsed = [guid]::Empty
    return [guid]::TryParse([string]$Value, [ref]$parsed) -and $parsed -eq [guid]::Empty
}

function Add-InvestigationDirectoryRecord {
    param($Record, [hashtable]$Records)
    if ($Record -isnot [System.Collections.IDictionary] -or
        -not (Test-InvestigationId $Record['id']) -or -not (Test-InvestigationId $Record['deviceId'])) {
        throw 'Entra returned a device without a valid object ID and device ID.'
    }
    $Records[[string]$Record['id']] = $Record
}

$root = 'https://graph.microsoft.com/v1.0'
$managedSelect = 'id,deviceName,serialNumber,azureADDeviceId,userPrincipalName,operatingSystem,osVersion,complianceState,lastSyncDateTime,enrolledDateTime,model,manufacturer'
$directorySelect = 'id,deviceId,displayName,accountEnabled,trustType,operatingSystem,operatingSystemVersion,approximateLastSignInDateTime'
$property = switch ($SearchBy) {
    'Device name' { 'deviceName' }
    'Serial number' { 'serialNumber' }
    'User UPN' { 'userPrincipalName' }
}
$filter = [uri]::EscapeDataString("$property eq '$($SearchValue.Replace("'", "''"))'")
Write-Host 'Reading Intune device records and primary users...'
$managed = @(foreach ($record in @(Get-InvestigationCollection "$root/deviceManagement/managedDevices?`$filter=$filter&`$select=$managedSelect")) {
    if ($record -isnot [System.Collections.IDictionary]) { throw 'Intune returned an invalid device record.' }
    if ([string]$record[$property] -eq $SearchValue) { $record }
})
$managedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$directoryIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$serials = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$primaryByDevice = @{}
foreach ($device in $managed) {
    if (-not (Test-InvestigationId $device['id']) -or -not $managedIds.Add([string]$device['id'])) {
        throw 'Intune returned a missing, invalid or repeated managed device ID.'
    }
    if (Test-InvestigationId $device['azureADDeviceId']) { $null = $directoryIds.Add([string]$device['azureADDeviceId']) }
    if (-not [string]::IsNullOrWhiteSpace([string]$device['serialNumber'])) { $null = $serials.Add([string]$device['serialNumber']) }
    $primaryByDevice[[string]$device['id']] = @(Get-InvestigationCollection "$root/deviceManagement/managedDevices/$($device['id'])/users?`$select=id,displayName,userPrincipalName")
    foreach ($primary in $primaryByDevice[[string]$device['id']]) {
        if ($primary -isnot [System.Collections.IDictionary] -or -not (Test-InvestigationId $primary['id'])) {
            throw 'Intune returned a primary user without a valid object ID.'
        }
    }
}
if ($SearchBy -eq 'Serial number') { $null = $serials.Add($SearchValue) }

Write-Host 'Reading Entra device records...'
$directoryByObject = @{}
if ($SearchBy -eq 'Device name') {
    $nameFilter = [uri]::EscapeDataString("displayName eq '$($SearchValue.Replace("'", "''"))'")
    foreach ($record in @(Get-InvestigationCollection "$root/devices?`$filter=$nameFilter&`$select=$directorySelect")) {
        if ($record -isnot [System.Collections.IDictionary]) { throw 'Entra returned an invalid device record.' }
        if ([string]$record['displayName'] -eq $SearchValue) {
            Add-InvestigationDirectoryRecord $record $directoryByObject
            $null = $directoryIds.Add([string]$record['deviceId'])
        }
    }
}

Write-Host 'Reading Windows Autopilot inventory; large tenants may take time...'
# This endpoint can return HTTP 500 for $select; project report fields locally.
$autopilotAll = @(Get-InvestigationCollection "$root/deviceManagement/windowsAutopilotDeviceIdentities")
$autopilot = @(foreach ($record in $autopilotAll) {
    if ($record -isnot [System.Collections.IDictionary] -or -not (Test-InvestigationId $record['id'])) {
        throw 'Autopilot returned a record without a valid object ID.'
    }
    if (($record['managedDeviceId'] -and $managedIds.Contains([string]$record['managedDeviceId'])) -or
        ($record['azureActiveDirectoryDeviceId'] -and $directoryIds.Contains([string]$record['azureActiveDirectoryDeviceId'])) -or
        ($record['serialNumber'] -and $serials.Contains([string]$record['serialNumber'])) -or
        ($SearchBy -eq 'Device name' -and [string]$record['displayName'] -eq $SearchValue)) {
        $record
    }
})
foreach ($record in $autopilot) {
    if (Test-InvestigationId $record['azureActiveDirectoryDeviceId']) { $null = $directoryIds.Add([string]$record['azureActiveDirectoryDeviceId']) }
}
foreach ($id in @($directoryIds)) {
    $idFilter = [uri]::EscapeDataString("deviceId eq '$id'")
    foreach ($record in @(Get-InvestigationCollection "$root/devices?`$filter=$idFilter&`$select=$directorySelect")) {
        if ($record -isnot [System.Collections.IDictionary]) { throw 'Entra returned an invalid device record.' }
        if ([string]$record['deviceId'] -eq $id) { Add-InvestigationDirectoryRecord $record $directoryByObject }
    }
}
$directory = @($directoryByObject.Values)

$overview = [Collections.Generic.List[object]]::new()
$linkedDirectory = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$linkedAutopilot = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$autopilotEvidenceByIntune = @{}
foreach ($device in $managed) {
    $entraId = [string]$device['azureADDeviceId']
    $sharedEntraId = (Test-InvestigationId $entraId) -and @($managed | Where-Object { $_['azureADDeviceId'] -eq $entraId }).Count -gt 1
    $directoryMatches = @(if (Test-InvestigationId $entraId) { $directory | Where-Object { $_['deviceId'] -eq $entraId } })
    $strongAuto = @($autopilot | Where-Object {
        ($_['managedDeviceId'] -eq $device['id'] -and
            ((Test-InvestigationAbsentId $_['azureActiveDirectoryDeviceId']) -or
                ((Test-InvestigationId $_['azureActiveDirectoryDeviceId']) -and
                    ((Test-InvestigationAbsentId $entraId) -or $_['azureActiveDirectoryDeviceId'] -eq $entraId)))) -or
        (-not $sharedEntraId -and (Test-InvestigationId $entraId) -and $_['azureActiveDirectoryDeviceId'] -eq $entraId -and
            ((Test-InvestigationAbsentId $_['managedDeviceId']) -or $_['managedDeviceId'] -eq $device['id']))
    })
    $conflictingAuto = @($autopilot | Where-Object {
        (($_['managedDeviceId'] -eq $device['id']) -or ((Test-InvestigationId $entraId) -and $_['azureActiveDirectoryDeviceId'] -eq $entraId)) -and
        $_['id'] -notin $strongAuto.id
    })
    foreach ($match in $directoryMatches) { $null = $linkedDirectory.Add([string]$match['id']) }
    foreach ($match in $strongAuto) { $null = $linkedAutopilot.Add([string]$match['id']) }
    $serialCandidates = @($autopilot | Where-Object {
        $device['serialNumber'] -and $_['serialNumber'] -eq $device['serialNumber'] -and $_['id'] -notin $strongAuto.id
    })
    $conflictingAutoIds = @($conflictingAuto | ForEach-Object { $_['id'] })
    $autopilotEvidenceByIntune[[string]$device['id']] = @($strongAuto) + @($conflictingAuto) +
        @($serialCandidates | Where-Object { $_['id'] -notin $conflictingAutoIds })
    $primary = @($primaryByDevice[[string]$device['id']])
    $overview.Add([pscustomobject]@{
        RecordSource = 'Intune'
        DeviceName = [string]$device['deviceName']; SerialNumber = [string]$device['serialNumber']
        PrimaryUsers = (@($primary | ForEach-Object { [string]$_['userPrincipalName'] }) -join '; ')
        PrimaryUserIds = (@($primary | ForEach-Object { [string]$_['id'] }) -join '; ')
        PrimaryUserStatus = if (-not $primary.Count) { 'No primary user returned' } elseif (@($primary | Where-Object { -not $_['userPrincipalName'] }).Count) { 'Some UPNs unavailable' } else { 'Read' }
        AssociatedUser = [string]$device['userPrincipalName']
        Compliance = [string]$device['complianceState']; LastIntuneSync = [string]$device['lastSyncDateTime']
        OperatingSystem = [string]$device['operatingSystem']; OSVersion = [string]$device['osVersion']
        Manufacturer = [string]$device['manufacturer']; Model = [string]$device['model']; Enrolled = [string]$device['enrolledDateTime']
        EntraStatus = if (-not (Test-InvestigationId $entraId)) { 'Device ID unavailable' } elseif ($sharedEntraId) { 'Entra ID shared by Intune search results' } elseif ($directoryMatches.Count -eq 1) { 'One ID match' } elseif ($directoryMatches.Count -gt 1) { 'Multiple ID matches' } else { 'No ID match returned' }
        AutopilotStatus = if ($conflictingAuto.Count) { 'Shared or conflicting IDs; review Autopilot records' } elseif ($strongAuto.Count -gt 1) { 'Multiple ID matches' } elseif ($strongAuto.Count -eq 1) { 'One ID match' } elseif ($serialCandidates.Count) { 'Serial candidate only' } else { 'No ID match returned' }
        ManagedDeviceId = [string]$device['id']; EntraDeviceId = $entraId
        EntraObjectIds = (@($directoryMatches | ForEach-Object { [string]$_['id'] }) -join '; ')
        AutopilotIds = (@($strongAuto | ForEach-Object { [string]$_['id'] }) -join '; ')
    })
}
foreach ($record in $directory) {
    if ($linkedDirectory.Contains([string]$record['id'])) { continue }
    $overview.Add([pscustomobject]@{
        RecordSource='Entra only'; DeviceName=[string]$record['displayName']; SerialNumber=''; PrimaryUsers=''; PrimaryUserIds=''; PrimaryUserStatus='Not queried'; AssociatedUser=''
        Compliance=''; LastIntuneSync=''; OperatingSystem=[string]$record['operatingSystem']; OSVersion=[string]$record['operatingSystemVersion']
        Manufacturer=''; Model=''; Enrolled=''
        EntraStatus='No matching Intune record in search'; AutopilotStatus='See Autopilot records'
        ManagedDeviceId=''; EntraDeviceId=[string]$record['deviceId']; EntraObjectIds=[string]$record['id']; AutopilotIds=''
    })
}
foreach ($record in $autopilot) {
    if ($linkedAutopilot.Contains([string]$record['id'])) { continue }
    $overview.Add([pscustomobject]@{
        RecordSource='Autopilot candidate'; DeviceName=[string]$record['displayName']; SerialNumber=[string]$record['serialNumber']
        PrimaryUsers=''; PrimaryUserIds=''; PrimaryUserStatus='Not queried'; AssociatedUser=''; Compliance=''; LastIntuneSync=''; OperatingSystem=''; OSVersion=''
        Manufacturer=[string]$record['manufacturer']; Model=[string]$record['model']; Enrolled=''
        EntraStatus='See Entra records'; AutopilotStatus='Not uniquely linked; review IDs and serial'
        ManagedDeviceId=[string]$record['managedDeviceId']; EntraDeviceId=[string]$record['azureActiveDirectoryDeviceId']
        EntraObjectIds=''; AutopilotIds=[string]$record['id']
    })
}
$entraRows = @($directory | ForEach-Object {
    [pscustomobject]@{
        DeviceName=[string]$_['displayName']; EntraObjectId=[string]$_['id']; EntraDeviceId=[string]$_['deviceId']
        AccountEnabled=$_['accountEnabled']; JoinType=[string]$_['trustType']; OperatingSystem=[string]$_['operatingSystem']
        OSVersion=[string]$_['operatingSystemVersion']; ApproximateLastSignIn=[string]$_['approximateLastSignInDateTime']
    }
})
$autopilotRows = @($autopilot | ForEach-Object {
    [pscustomobject]@{
        DeviceName=[string]$_['displayName']; SerialNumber=[string]$_['serialNumber']; AutopilotId=[string]$_['id']
        ManagedDeviceId=[string]$_['managedDeviceId']; EntraDeviceId=[string]$_['azureActiveDirectoryDeviceId']
        GroupTag=[string]$_['groupTag']; EnrollmentState=[string]$_['enrollmentState']; LastContacted=[string]$_['lastContactedDateTime']
        Manufacturer=[string]$_['manufacturer']; Model=[string]$_['model']
    }
})
$results = $overview.ToArray()
$entraByObjectId = @{}
foreach ($record in $entraRows) { $entraByObjectId[$record.EntraObjectId] = $record }
$autopilotById = @{}
foreach ($record in $autopilotRows) { $autopilotById[$record.AutopilotId] = $record }
$repeatedNames = @{}
foreach ($group in ($results | Where-Object { $_.DeviceName } | Group-Object DeviceName)) {
    if ($group.Count -gt 1) { $repeatedNames[$group.Name] = $group.Count }
}
$reconciliationRows = @(foreach ($row in $results) {
    $findings = [ordered]@{}
    if ($row.DeviceName -and $repeatedNames.ContainsKey($row.DeviceName)) {
        $findings['Same name, separate records'] = "$($repeatedNames[$row.DeviceName]) overview rows share this name. A name alone does not establish a match."
    }
    if ($row.RecordSource -eq 'Intune') {
        $conflicts = @(if ($row.EntraStatus -in @('Entra ID shared by Intune search results', 'Multiple ID matches')) { "Entra: $($row.EntraStatus)" }
            if ($row.AutopilotStatus -in @('Shared or conflicting IDs; review Autopilot records', 'Multiple ID matches')) { "Autopilot: $($row.AutopilotStatus)" })
        if ($conflicts.Count) { $findings['Conflicting or shared IDs'] = $conflicts -join '; ' }
        if ($row.EntraStatus -eq 'Device ID unavailable') {
            $findings['Missing or invalid ID'] = 'Intune did not provide a usable Entra device ID.'
        }
        $missing = @(if ($row.EntraStatus -eq 'No ID match returned') { 'No Entra match for the recorded device ID' }
            if ($row.AutopilotStatus -in @('No ID match returned','Serial candidate only')) { "Autopilot: $($row.AutopilotStatus)" })
        if ($missing.Count) { $findings['No confirmed match'] = $missing -join '; ' }
    } else {
        $findings['No confirmed match'] = 'No confirmed Intune match for this record in the current search.'
    }
    if (-not $findings.Count) { continue }

    $entraEvidence = @(foreach ($id in ($row.EntraObjectIds -split '; ')) {
        if ($id) { $entraByObjectId[$id] }
    })
    $autoEvidence = @(if ($row.RecordSource -eq 'Intune') {
        foreach ($record in $autopilotEvidenceByIntune[$row.ManagedDeviceId]) { $autopilotById[[string]$record['id']] }
    } elseif ($row.AutopilotIds) { $autopilotById[$row.AutopilotIds] })
    foreach ($category in $findings.Keys) {
        [pscustomobject]@{
            DeviceName = $row.DeviceName
            Finding = $category
            Reason = $findings[$category]
            RecordSource = $row.RecordSource
            LastIntuneSync = $row.LastIntuneSync
            EntraApproximateLastSignIn = (@(foreach ($record in $entraEvidence) {
                if ($record.ApproximateLastSignIn) { "$($record.ApproximateLastSignIn) [$($record.EntraObjectId)]" }
            }) -join '; ')
            AutopilotLastContact = (@(foreach ($record in $autoEvidence) {
                if ($record.LastContacted) { "$($record.LastContacted) [$($record.AutopilotId)]" }
            }) -join '; ')
            SerialNumber = $row.SerialNumber
            RecordedManagedDeviceId = $row.ManagedDeviceId
            RecordedEntraDeviceId = $row.EntraDeviceId
            EntraObjectIds = $row.EntraObjectIds
            ConfirmedAutopilotIds = if ($row.RecordSource -eq 'Intune') { $row.AutopilotIds } else { '' }
            AutopilotEvidence = (@(foreach ($record in $autoEvidence) {
                "$($record.AutopilotId) [Intune: $($record.ManagedDeviceId); Entra: $($record.EntraDeviceId)]"
            }) -join '; ')
        }
    }
})
Write-Host "Found $($managed.Count) Intune, $($directory.Count) Entra and $($autopilot.Count) relevant Autopilot record(s). State may be stale; serial-only matches are candidates."
if ($SearchBy -eq 'User UPN') { Write-Host 'User searches use Intune associated-user UPN, not all devices owned or registered by that user.' }
$results
