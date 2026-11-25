function New-EndpointStatusChart {
    param([string]$Title, [string]$Basis, [object[]]$Rows, [string]$Column, [System.Collections.IDictionary]$States, [string]$CountColumn)
    $counts = @{}
    $total = 0L
    foreach ($row in $Rows) {
        $key = ([string]$row.PSObject.Properties[$Column]?.Value).Trim()
        if (-not $States.Contains($key)) { $key = 'unknown' }
        $count = if ($CountColumn) { [long]$row.$CountColumn } else { 1L }
        $counts[$key] += $count
        $total += $count
    }
    [pscustomobject]@{
        Title = $Title
        Basis = $Basis
        Total = $total
        Bars = @(foreach ($key in $States.Keys) {
            [pscustomobject]@{ Label = $States[$key][0]; Color = $States[$key][1]; Count = [long]$counts[$key] }
        })
    }
}

function Get-EndpointDeploymentChart {
    param([string]$Kind, [object[]]$Rows)
    if (-not $Rows.Count) { return }
    if ($Kind -eq 'DeviceSummary') {
        $identified = @($Rows | Where-Object IdentityStatus -eq 'Identified')
        $basis = 'One worst-known state per identified device.'
        if ($identified.Count -lt $Rows.Count) { $basis += " $($Rows.Count - $identified.Count) rows without a device ID excluded." }
        New-EndpointStatusChart 'Device status' $basis $identified InstallStateFriendly ([ordered]@{
            Installed = 'Installed','Success'; Failed = 'Failed','Failure'; Error = 'Error','Failure'
            'Pending install' = 'Pending install','Pending'; 'Not installed' = 'Not installed','Warning'
            'Not applicable' = 'Not applicable','Neutral'; Uninstalled = 'Uninstalled','Neutral'
            Unknown = 'Other or unknown (including unrecognized localized states)','Neutral'
        })
    }
    elseif ($Kind -eq 'UserStatus') {
        $columns = [ordered]@{
            InstalledDeviceCount = 'Installed','Success'; FailedDeviceCount = 'Failed','Failure'
            NotInstalledDeviceCount = 'Not installed','Warning'
        }
        $bars = @(foreach ($column in $columns.Keys) {
            $sum = 0L
            $complete = $true
            foreach ($row in $Rows) {
                $value = 0L
                if (-not [long]::TryParse([string]$row.PSObject.Properties[$column]?.Value, [ref]$value) -or $value -lt 0 -or $value -gt [int]::MaxValue) {
                    $complete = $false
                    break
                }
                $sum += $value
            }
            if ($complete) { [pscustomobject]@{ Label = $columns[$column][0]; Color = $columns[$column][1]; Count = $sum } }
        })
        if ($bars.Count) {
            [pscustomobject]@{
                Title = 'Device outcomes in the user report'
                Basis = 'Device counts summed across user report rows, not unique users or devices. Only complete count columns are shown.'
                Total = ($bars | Measure-Object Count -Sum).Sum
                Bars = $bars
            }
        }
    }
}

function Get-EndpointFailureTriageCharts {
    param([object[]]$Rows, [string]$Dataset, [switch]$IncludeDeviceContext)
    $basis = 'One entry per managed device ID and error code. Unidentified rows are kept separately. A device can appear under more than one code.'
    $dimensions = [ordered]@{ ErrorCode = 'Win32 failures by error code' }
    if ($IncludeDeviceContext) {
        $dimensions.ErrorByOS = 'Error code by reported OS version'
        $dimensions.ErrorBySyncAge = 'Error code by last Intune sync age'
    }
    foreach ($column in $dimensions.Keys) {
        $eligible = @($Rows | Where-Object { $_.$column })
        $groups = @($eligible | Group-Object -Property $column | Sort-Object @{Expression='Count';Descending=$true}, Name)
        $detail = if ($column -eq 'ErrorCode') { $basis }
            else { "Only $($eligible.Count) of $($Rows.Count) failure entries have verified device context for this chart. Counts are not failure rates across the rollout." }
        if ($groups.Count -gt 8) { $detail += ' Showing the eight largest clusters; see Failure triage for all entries.' }
        if ($column -eq 'ErrorCode') { $detail += ' Cumulative percentage uses all failure entries with an error code, including clusters not shown.' }
        if (-not $eligible.Count) { $detail += ' No entries to chart.' }
        $cumulative = 0
        [pscustomobject]@{
            Title = $dimensions[$column]; Basis = $detail; Total = $eligible.Count
            Bars = @(foreach ($group in ($groups | Select-Object -First 8)) {
                $cumulative += $group.Count
                $bar = [pscustomobject]@{ Label = $group.Name; Count = $group.Count; Color = 'Warning'; Dataset = $Dataset; Column = $column }
                if ($column -eq 'ErrorCode') {
                    $bar | Add-Member -NotePropertyName Cumulative -NotePropertyValue ($cumulative / $eligible.Count)
                }
                $bar
            })
        }
    }
}

function New-EndpointRankedChart {
    param([string]$Title, [string]$Basis, [object[]]$Rows, [string]$Column, [string]$Dataset)
    $counts = @{}
    $missing = 0
    foreach ($row in $Rows) {
        $value = [string]$row.PSObject.Properties[$Column]?.Value
        if (-not [string]::IsNullOrWhiteSpace($value)) { $counts[$value]++ } else { $missing++ }
    }
    $groups = @($counts.GetEnumerator() | Sort-Object @{ Expression = 'Value'; Descending = $true }, Name)
    $bars = @(foreach ($group in ($groups | Select-Object -First 8)) {
        $bar = [pscustomobject]@{ Label = $group.Key; Count = $group.Value; Color = 'Pending' }
        if ($Dataset) { $bar | Add-Member -NotePropertyMembers @{ Dataset = $Dataset; Column = $Column } }
        $bar
    })
    if ($groups.Count -gt 8) {
        $other = ($groups | Select-Object -Skip 8 | Measure-Object Value -Sum).Sum
        $bars += [pscustomobject]@{ Label = 'Other reported values'; Count = $other; Color = 'Neutral' }
    }
    if ($missing) { $bars += [pscustomobject]@{ Label = 'Not reported'; Count = $missing; Color = 'Neutral' } }
    [pscustomobject]@{ Title = $Title; Basis = "$Basis Up to eight values are shown separately; remaining values and missing data are grouped." ; Total = $Rows.Count; Bars = $bars }
}

function Get-EndpointSignInCharts {
    param([object[]]$Rows, [int]$LookbackDays, [bool]$HasMore, [int]$Received, [bool]$FailuresOnly)
    $basis = "$($Rows.Count) shown event(s) from $Received received; rolling $LookbackDays-day UTC window. "
    $basis += if ($HasMore) { 'Incomplete: more pages are available. ' } else { 'No more pages returned. ' }
    $basis += 'Results depend on audit retention and access; grid filters do not change these charts.'
    if ($FailuresOnly) { $basis += ' Failures-only excludes successful and unclassifiable events.' }
    $daily = @{}
    $invalid = 0
    foreach ($row in $Rows) {
        $date = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse([string]$row.CreatedDateTimeUtc, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$date)) { $invalid++; continue }
        $day = $date.UtcDateTime.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        if (-not $daily.ContainsKey($day)) { $daily[$day] = @{ Success = 0; Failure = 0; Unknown = 0 } }
        $outcome = if ($row.Outcome -in @('Success','Failure')) { [string]$row.Outcome } else { 'Unknown' }
        $daily[$day][$outcome]++
    }
    $days = @($daily.Keys | Sort-Object)
    $omittedDays = [Math]::Max(0, $days.Count - 32)
    if ($omittedDays) { $days = @($days | Select-Object -Last 32) }
    foreach ($outcome in @('Success','Failure','Unknown')) {
        $color = switch ($outcome) { 'Success' { 'Success' } 'Failure' { 'Failure' } default { 'Neutral' } }
        [pscustomobject]@{
            Title = "Sign-ins by UTC day - $outcome"
            Basis = "$basis $invalid event(s) have an invalid or missing timestamp and are excluded from daily charts. Only days with returned events are shown; $omittedDays older day(s) omitted from the visual."
            Total = $Rows.Count - $invalid
            Bars = @(foreach ($day in $days) {
                [pscustomobject]@{ Label = $day; Count = $daily[$day][$outcome]; Color = $color }
            })
        }
    }
    $failures = @($Rows | Where-Object Outcome -eq 'Failure')
    New-EndpointRankedChart 'Sign-in failure codes' "$basis Counts failed events only." $failures 'ErrorCode' 'Sign-in events'
    New-EndpointRankedChart 'Sign-ins by application' $basis $Rows 'Application' 'Sign-in events'
    New-EndpointRankedChart 'Sign-ins by client app' $basis $Rows 'ClientApp' 'Sign-in events'
}

function Get-EndpointMobileVersionChart {
    param([object[]]$Rows)
    $values = @(foreach ($row in $Rows) {
        $platform = ([string]$row.OperatingSystem).Trim()
        $version = ([string]$row.OSVersion).Trim()
        if (-not $platform) { $platform = 'Platform not reported' }
        if (-not $version) { $version = 'Version not reported' }
        [pscustomobject]@{ PlatformVersion = "$platform | $version" }
    })
    New-EndpointRankedChart 'Mobile OS versions' 'Counts returned mobile device records, not unique devices.' $values 'PlatformVersion' ''
}

function Get-EndpointCloudPcHistoryCharts {
    param([object[]]$Rows, [string]$Basis)
    $metrics = [ordered]@{
        RoundTripTimeInMsP50 = @('Connection round-trip time (service P50)', 'ms')
        AvailableBandwidthInMbpsP50 = @('Available bandwidth (service P50)', 'Mbps')
        RemoteSignInTimeInSec = @('Remote sign-in time', 'seconds')
        UsageInHour = @('Reported usage', 'hours')
    }
    foreach ($column in $metrics.Keys) {
        $points = [Collections.Generic.List[object]]::new()
        $missing = 0
        foreach ($row in $Rows) {
            $number = 0.0
            $timestamp = [datetimeoffset]::MinValue
            $raw = $row.PSObject.Properties[$column]?.Value
            $dateValue = $row.SignInDateTime
            $validDate = if ($dateValue -is [datetime] -or $dateValue -is [datetimeoffset]) { $true } else {
                [datetimeoffset]::TryParse([string]$dateValue, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$timestamp)
            }
            if ($null -eq $raw -or -not [double]::TryParse([string]$raw, [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
                [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0 -or
                -not $validDate) { $missing++; continue }
            $label = if ($dateValue -is [datetime] -or $dateValue -is [datetimeoffset]) { $dateValue.ToString('o') } else { [string]$dateValue }
            $points.Add([pscustomobject]@{ Label=$label; Value=$number; Color='Pending' })
        }
        $shown = if ($points.Count -le 40) { @($points) } else {
            @(for ($i = 0; $i -lt 40; $i++) {
                $points[[int][Math]::Floor($i * ($points.Count - 1) / 39)]
            })
        }
        $maximum = if ($points.Count) { ($points | Measure-Object Value -Maximum).Maximum } else { 0 }
        [pscustomobject]@{
            Title=$metrics[$column][0]; Basis="$Basis $missing row(s) lack a valid metric or timestamp. Showing $($shown.Count) of $($points.Count) available points, evenly sampled in service order when necessary; see report data for all rows."
            Metric=$true; Unit=$metrics[$column][1]; Scale=$maximum; Total=$points.Count; Bars=$shown
        }
    }
}

function Get-EndpointRemediationCharts {
    param([object[]]$Rows)
    $basis = 'Based on returned device run-state records, not all targeted devices.'
    New-EndpointStatusChart 'Detection status' $basis $Rows DetectionState ([ordered]@{
        success = 'Without issues','Success'; fail = 'With issues','Warning'; scriptError = 'Script error','Failure'
        pending = 'Pending','Pending'; notApplicable = 'Not applicable','Neutral'; unknown = 'Other or unknown','Neutral'
    })
    New-EndpointStatusChart 'Remediation status' $basis $Rows RemediationState ([ordered]@{
        success = 'Succeeded','Success'; remediationFailed = 'Remediation failed','Failure'; scriptError = 'Script error','Failure'
        skipped = 'Skipped','Neutral'; unknown = 'Other or unknown','Neutral'
    })
}

function New-EndpointUpdateStateChart {
    param([string]$Title, [object[]]$Rows, [string]$Column)
    $counts = @{}
    $missing = 0
    foreach ($row in $Rows) {
        $label = ([string]$row.PSObject.Properties["${Column}_loc"]?.Value).Trim()
        if (-not $label) { $label = ([string]$row.PSObject.Properties[$Column]?.Value).Trim() }
        if ($label) { $counts[$label]++ } else { $missing++ }
    }
    $palette = @('Pending', 'Success', 'Warning', 'Accent1', 'Failure', 'Accent2', 'Accent3', 'Accent4')
    $top = @($counts.GetEnumerator() | Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, Name | Select-Object -First $palette.Count)
    $colorByLabel = @{}
    $index = 0
    foreach ($entry in ($top | Sort-Object Name)) {
        $colorByLabel[$entry.Key] = $palette[$index++]
    }
    $remaining = $Rows.Count - $missing
    $bars = @(foreach ($entry in $top) {
        $remaining -= $entry.Value
        [pscustomobject]@{ Label = $entry.Key; Color = $colorByLabel[$entry.Key]; Count = $entry.Value }
    })
    if ($remaining) { $bars += [pscustomobject]@{ Label = 'Other reported values'; Color = 'Neutral'; Count = $remaining } }
    if ($missing) { $bars += [pscustomobject]@{ Label = 'No value in report'; Color = 'Neutral'; Count = $missing } }
    [pscustomobject]@{
        Title = $Title
        Basis = 'Counts device records exported by Intune. Colors distinguish the reported values shown, not severity; missing values are counted separately.'
        Total = $Rows.Count
        Bars = $bars
    }
}

function Get-EndpointStaleDeviceChart {
    param([object[]]$Rows)
    $counts = [ordered]@{ '0-89 days' = 0; '90-179 days' = 0; '180-364 days' = 0; '365+ days' = 0; Unknown = 0 }
    foreach ($row in $Rows) {
        $days = 0
        $bucket = if ($row.ActivityStatus -ne 'Stale' -or -not [int]::TryParse([string]$row.DaysSinceLastSignIn, [ref]$days) -or $days -lt 0) { 'Unknown' }
            elseif ($days -lt 90) { '0-89 days' }
            elseif ($days -lt 180) { '90-179 days' }
            elseif ($days -lt 365) { '180-364 days' }
            else { '365+ days' }
        $counts[$bucket]++
    }
    [pscustomobject]@{
        Title = 'Days since last Entra sign-in'
        Basis = 'Only devices returned by the report are counted. The configured stale threshold still applies; Unknown is not confirmed stale.'
        Total = $Rows.Count
        Bars = @(foreach ($entry in $counts.GetEnumerator()) {
            [pscustomobject]@{ Label = $entry.Key; Color = $(if ($entry.Key -eq 'Unknown') { 'Neutral' } else { 'Warning' }); Count = $entry.Value }
        })
    }
}

function Get-EndpointDiscoveredVersionChart {
    param([object[]]$Rows)
    $devicesByVersion = @{}
    foreach ($row in $Rows) {
        $version = ([string]$row.ReportedVersion).Trim()
        if (-not $devicesByVersion.ContainsKey($version)) {
            $devicesByVersion[$version] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        }
        $null = $devicesByVersion[$version].Add(([string]$row.DeviceId).Trim())
    }
    $summary = @(foreach ($version in $devicesByVersion.Keys) {
        [pscustomobject]@{ Version = $version; DeviceCount = $devicesByVersion[$version].Count }
    })
    $versionRows = @($summary | Where-Object Version |
        Sort-Object -Property @{ Expression = 'DeviceCount'; Descending = $true }, Version)
    $bars = @(foreach ($row in ($versionRows | Select-Object -First 8)) {
        [pscustomobject]@{ Label = $row.Version; Color = 'Pending'; Count = $row.DeviceCount }
    })
    if ($versionRows.Count -gt 8) {
        $other = ($versionRows | Select-Object -Skip 8 | Measure-Object DeviceCount -Sum).Sum
        $bars += [pscustomobject]@{ Label = 'Other reported versions'; Color = 'Neutral'; Count = $other }
    }
    $missing = ($summary | Where-Object { -not $_.Version } | Measure-Object DeviceCount -Sum).Sum
    if ($missing) {
        $bars += [pscustomobject]@{ Label = 'No version reported'; Color = 'Neutral'; Count = $missing }
    }
    [pscustomobject]@{
        Title = 'Installed versions by device count'
        Basis = 'Counts distinct device IDs per version and shows up to eight reported versions. Percentages use the sum of the version counts; a device can appear under more than one version.'
        Total = ($summary | Measure-Object DeviceCount -Sum).Sum
        Bars = $bars
    }
}

function Get-EndpointActivityRecencyChart {
    param([string]$Workflow, [object[]]$Rows, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $isCloud = $Workflow -eq 'cloudpc-last-login'
    $states = [ordered]@{
        '0-6 days' = 'Success'; '7-29 days' = 'Pending'; '30-89 days' = 'Warning'; '90+ days' = 'Warning'
    }
    if ($isCloud) {
        $title = 'Days since last reported Cloud PC logon'
        $basis = 'Latest Intune-reported Windows user logon, not a Windows 365 connection or Intune sync. No logon reported does not mean never used.'
        $states['No logon reported'] = 'Neutral'
        $states['Lookup failed'] = 'Failure'
    }
    else {
        $title = 'Days since latest successful Entra sign-in'
        $basis = 'Counts scoped devices using successful sign-ins returned within the configured lookback and available audit retention. No sign-in in window does not mean inactive.'
        $states['No sign-in in window'] = 'Neutral'
        $states['No Entra device ID'] = 'Neutral'
    }
    $states['Unknown timestamp'] = 'Neutral'
    $counts = @{}
    foreach ($row in $Rows) {
        $stamp = [datetimeoffset]::MinValue
        $state = if ($isCloud -and $row.LoginStatus -eq 'Lookup failed') { 'Lookup failed' }
            elseif ($isCloud -and $row.LoginStatus -eq 'Not reported') { 'No logon reported' }
            elseif (-not $isCloud -and $row.Note -eq 'No azureADDeviceId') { 'No Entra device ID' }
            elseif (-not $isCloud -and $row.Note -eq 'No sign-ins in window') { 'No sign-in in window' }
            else {
                $value = if ($isCloud) { $row.LastLoginEastern } else { $row.LastSignIn }
                $culture = [Globalization.CultureInfo]::InvariantCulture
                $style = [Globalization.DateTimeStyles]::AssumeUniversal
                $valid = if ($isCloud) {
                    [datetimeoffset]::TryParseExact([string]$value, 'yyyy-MM-dd HH:mm:ss zzz', $culture, $style, [ref]$stamp)
                }
                elseif ($value -is [datetimeoffset]) { $stamp = $value; $true }
                elseif ($value -is [datetime]) {
                    if ($value.Kind -eq [DateTimeKind]::Unspecified) { $value = [datetime]::SpecifyKind($value, [DateTimeKind]::Utc) }
                    $stamp = [datetimeoffset]$value
                    $true
                }
                else {
                    [string]$value -match '^\d{4}-\d{2}-\d{2}T' -and [datetimeoffset]::TryParse([string]$value, $culture, $style, [ref]$stamp)
                }
                if (-not $valid -or $stamp -gt $Now) { 'Unknown timestamp' }
                elseif (($Now - $stamp).TotalDays -lt 7) { '0-6 days' }
                elseif (($Now - $stamp).TotalDays -lt 30) { '7-29 days' }
                elseif (($Now - $stamp).TotalDays -lt 90) { '30-89 days' }
                else { '90+ days' }
            }
        $counts[$state]++
    }
    [pscustomobject]@{
        Title = $title
        Basis = $basis
        Total = $Rows.Count
        Bars = @(foreach ($state in $states.Keys) {
            [pscustomobject]@{ Label = $state; Color = $states[$state]; Count = [long]$counts[$state] }
        })
    }
}

function New-EndpointReviewChart {
    param([string]$Title, [string]$Basis, [object[]]$Rows, [string]$Column, [string]$Dataset, [System.Collections.IDictionary]$Colors)
    $counts = @{}
    foreach ($row in $Rows) { $counts[$row.$Column]++ }
    [pscustomobject]@{
        Title = $Title; Basis = $Basis; Total = $Rows.Count
        Bars = @(foreach ($key in $Colors.Keys) {
            [pscustomobject]@{ Label = $key; Color = $Colors[$key]; Count = [int]$counts[$key]; Dataset = $Dataset; Column = $Column }
        })
    }
}

function Get-EndpointInventoryCharts {
    param([string]$Workflow, [object[]]$Rows, [int]$LookbackDays, [string]$SearchBy)
    if (-not $Rows.Count -and $Workflow -ne 'device-investigation') { return }
    switch ($Workflow) {
        'mobile-inventory' {
            $basis = 'Counts mobile device records returned by this report.'
            New-EndpointStatusChart 'Compliance' $basis $Rows ComplianceState ([ordered]@{
                compliant = 'Compliant','Success'; noncompliant = 'Noncompliant','Failure'; inGracePeriod = 'In grace period','Warning'
                error = 'Error','Failure'; conflict = 'Conflict','Warning'; unknown = 'Other or unknown','Neutral'
            })
            New-EndpointStatusChart 'Ownership' $basis $Rows Ownership ([ordered]@{
                company = 'Company','Pending'; personal = 'Personal','Success'; unknown = 'Other or unknown','Neutral'
            })
            New-EndpointStatusChart 'Operating system' $basis $Rows OperatingSystem ([ordered]@{
                iOS = 'iOS','Pending'; iPadOS = 'iPadOS','Warning'; Android = 'Android','Success'
                AndroidEnterprise = 'Android Enterprise','Success'; AndroidForWork = 'Android for Work','Success'
                AndroidOpenSourceProject = 'Android Open Source Project','Success'; unknown = 'Other or unknown','Neutral'
            })
            Get-EndpointMobileVersionChart $Rows
        }
        'cloudpc-inventory' {
            $basis = 'Counts Cloud PC records returned by Graph, including unprovisioned records.'
            New-EndpointStatusChart 'Provisioning status' $basis $Rows RawStatus ([ordered]@{
                provisioned = 'Provisioned','Success'; provisionedWithWarnings = 'Provisioned with warnings','Warning'
                provisioning = 'Provisioning','Pending'; pendingProvision = 'Pending','Pending'
                notProvisioned = 'Not provisioned','Neutral'; inGracePeriod = 'In grace period','Warning'
                deprovisioning = 'Deprovisioning','Warning'; failed = 'Failed','Failure'; unknown = 'Other or unknown','Neutral'
            })
            New-EndpointStatusChart 'Product type' $basis $Rows DeviceType ([ordered]@{
                enterprise = 'Enterprise','Pending'; frontline = 'Frontline','Success'; business = 'Business','Warning'
                devBox = 'Dev Box','Pending'; powerAutomate = 'Power Automate','Success'; unknown = 'Other or unknown','Neutral'
            })
        }
        'get-entra-group-members' {
            New-EndpointStatusChart 'Member types' 'All returned member types. Indirect members are included only when Expand nested groups is enabled.' $Rows MemberType ([ordered]@{
                user = 'Users','Pending'; device = 'Devices','Success'; group = 'Groups','Warning'
                servicePrincipal = 'Service principals','Pending'; orgContact = 'Organizational contacts','Success'; unknown = 'Other or unknown','Neutral'
            })
        }
        'm365-cloud-update' {
            New-EndpointStatusChart 'Rollout status' 'Uses the service-reported device counts for the selected update channel, not the number of grid rows.' $Rows Status ([ordered]@{
                Completed = 'Completed','Success'; InProgress = 'In progress','Pending'; Failed = 'Failed','Failure'
                NotStarted = 'Not started','Warning'; unknown = 'Other or unknown','Neutral'
            }) -CountColumn Devices
        }
        'quality-updates' {
            New-EndpointUpdateStateChart 'Overall update status' $Rows AggregateState
            New-EndpointUpdateStateChart 'Device update substatus' $Rows CurrentDeviceUpdateSubstatus
        }
        'wufb-report' {
            New-EndpointReviewChart 'Security compliance' 'Latest security status for each OS version. Stale and unknown devices are excluded from the percentage, but included here. Workspace devices only.' $Rows 'SecurityCompliance' 'Devices' ([ordered]@{
                Compliant = 'Success'; 'Not compliant' = 'Failure'; Stale = 'Warning'; Unknown = 'Neutral'
            })
            New-EndpointRankedChart 'OS versions' 'Counts device records in the latest WUfB snapshot.' $Rows 'OSVersion' 'Devices'
            New-EndpointRankedChart 'Installed OS builds' 'Counts device records, not update events.' $Rows 'OSBuild' 'Devices'
            New-EndpointReviewChart 'Restart evidence' 'No evidence is not proof that a restart is unnecessary. See Pending restarts for affected updates and waiting times.' $Rows 'PendingRestart' 'Devices' ([ordered]@{
                Reported = 'Warning'; 'No evidence' = 'Neutral'
            })
        }
        'stale-synced-devices' { Get-EndpointStaleDeviceChart $Rows }
        'cloudpc-last-login' { Get-EndpointActivityRecencyChart $Workflow $Rows }
        'device-investigation' {
            New-EndpointReviewChart 'Device record reconciliation' "Exact $SearchBy search. Counts findings, not unique devices. No confirmed match does not mean orphaned; this is not a deletion recommendation." $Rows 'Finding' 'Reconciliation queue' ([ordered]@{
                'Conflicting or shared IDs' = 'Warning'; 'Same name, separate records' = 'Accent1'
                'Missing or invalid ID' = 'Pending'; 'No confirmed match' = 'Neutral'
            })
        }
        'device-usage' {
            $window = if ($LookbackDays -gt 0) { "the last $LookbackDays days" } else { 'the selected window' }
            New-EndpointReviewChart 'Primary-user review' "Based on distinct successful Entra sign-in days (UTC) over $window, limited by available audit history. Not Windows logons." $Rows 'ReviewCategory' 'Devices' ([ordered]@{
                Match = 'Success'; Mismatch = 'Warning'; Unassigned = 'Pending'; Inconclusive = 'Neutral'
            })
            Get-EndpointActivityRecencyChart $Workflow $Rows
        }
    }
}

function Get-EndpointPlatformScriptChart {
    param([object[]]$Rows)
    New-EndpointStatusChart 'Platform script run status' 'Counts returned run-state records, not all targeted devices.' $Rows RunState ([ordered]@{
        success = 'Succeeded','Success'; fail = 'Failed','Failure'; scriptError = 'Script error','Failure'
        pending = 'Pending','Pending'; notApplicable = 'Not applicable','Neutral'; unknown = 'Other or unknown','Neutral'
    })
}
