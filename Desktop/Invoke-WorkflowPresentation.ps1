[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$WorkflowId,
    [Parameter(Mandatory)][hashtable]$ScriptArguments,
    [string]$ActivityLogPath = '',
    [string]$RunId = '',
    [Func[bool]]$CancellationCheck,
    [scriptblock]$UiEventSink,
    [ValidateSet('New','More','All')][string]$SignInAction = 'New',
    [string]$SignInContinuationId = ''
)

. (Join-Path $PSScriptRoot 'ActivityLogging.ps1')
. (Join-Path $PSScriptRoot 'ReportVisuals.ps1')
$emSink = $UiEventSink
$emWorkflow = $WorkflowId
$emArguments = $ScriptArguments
$emScript = $ScriptPath
$emLogPath = $ActivityLogPath
$emRunId = if ($RunId) { $RunId } else { [guid]::NewGuid().ToString() }
if ($emWorkflow -eq 'm365-cloud-update' -and -not $emArguments['ExportFolder']) {
    $emArguments['ExportFolder'] = $env:TEMP
}
$emFailure = $null
$emSummary = $null
$emFinished = $false
$emDevice = if ($emWorkflow -eq 'remote-endpoint') { [string]$emArguments['Device'] } else { '' }
$emBefore = @{}
$emFolders = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($emKey in @('OutputPath', 'OutputFile', 'CsvPath', 'ExportFolder')) {
    if (-not $emArguments[$emKey]) { continue }
    $emValue = [IO.Path]::GetFullPath([string]$emArguments[$emKey])
    $emFolder = if ([IO.Path]::GetExtension($emValue) -eq '.csv') { Split-Path $emValue -Parent } else { $emValue }
    $null = $emFolders.Add($emFolder)
}
$null = $emFolders.Add($env:TEMP)
foreach ($emFolder in $emFolders) {
    if (-not (Test-Path -LiteralPath $emFolder -PathType Container)) { continue }
    foreach ($emFile in Get-ChildItem -LiteralPath $emFolder -Filter '*.csv' -File) {
        $emBefore[$emFile.FullName] = "$($emFile.LastWriteTimeUtc.Ticks):$($emFile.Length)"
    }
}

# Adapt the original Read-Host response, not the script's matching or selection rules.
if ($emWorkflow -in @('delete-win32-apps', 'intune-assignment-win32-deployment-exports', 'intune-script-device-status')) {
    function Read-Host {
        [CmdletBinding()]
        param([string]$Prompt)
        if ($emWorkflow -eq 'intune-script-device-status') {
            $emMatches = Get-Variable -Name matchingScripts -Scope 1 -ErrorAction Ignore
            if ($emMatches -and $Prompt -match 'script number' -and $emSink) {
                & $emSink ([pscustomobject]@{
                    Type = 'Choice'; Name = 'Script'
                    Data = @($emMatches.Value | ForEach-Object { $_ })
                }) | Out-Null
            }
            return Microsoft.PowerShell.Utility\Read-Host -Prompt $Prompt
        }
        $emMatches = Get-Variable -Name matchingApps -Scope 1 -ErrorAction Ignore
        if ($emMatches -and $Prompt -match 'number' -and $emSink) {
            & $emSink ([pscustomobject]@{
                Type = 'Choice'; Name = 'Multiple'
                Data = @($emMatches.Value | ForEach-Object { $_ })
            }) | Out-Null
        }
        Microsoft.PowerShell.Utility\Read-Host -Prompt $Prompt
    }
}

if ($emLogPath) {
    Write-EndpointActivityRecord -LogRoot $emLogPath -Event 'RunStarted' -WorkflowId $emWorkflow -RunId $emRunId -Device $emDevice -State $(if ($emArguments['WhatIf']) { 'Preview' } else { 'Running' })
}
try {
    if ($emWorkflow -eq 'user-sign-in-history') {
        if ($SignInAction -eq 'New') {
            Remove-Variable -Name EndpointSignInHistoryState -Scope Global -ErrorAction Ignore
        }
        else {
            $emPrevious = Get-Variable -Name EndpointSignInHistoryState -Scope Global -ValueOnly -ErrorAction Ignore
            if ($SignInContinuationId -and $emPrevious -and $emPrevious['Id'] -ne $SignInContinuationId) {
                $emPrevious = $emPrevious['Previous']
            }
            if ($SignInContinuationId -and (-not $emPrevious -or $emPrevious['Id'] -ne $SignInContinuationId)) {
                throw 'The displayed sign-in continuation is no longer available. Run a new report.'
            }
            if (-not $emPrevious -or -not $emPrevious.Continuation.NextLink) { throw 'No sign-in continuation is available. Run a new report.' }
            # Retain only the displayed page and its next candidate, including across cancelled retries.
            $emPrevious.Remove('Previous')
            $global:EndpointSignInHistoryState = $emPrevious
            $emArguments = $emArguments.Clone()
            $emArguments.Continuation = $emPrevious.Continuation
            $emArguments.ReportMode = if ($SignInAction -eq 'All') { 'Detailed events' } else { 'Paged events' }
        }
    }
    if ($emWorkflow -eq 'm365-cloud-update' -and -not (Get-Module -ListAvailable -Name MSAL.PS)) {
        throw 'MSAL.PS is missing. Install it deliberately in PowerShell 7: Install-Module MSAL.PS -Scope CurrentUser. The desktop app does not install modules.'
    }
    if ($emWorkflow -eq 'intune-script-device-status' -and $emArguments['ListScripts']) {
        $emScriptList = @(. $emScript @emArguments)
        $emChoices = @($emScriptList | ForEach-Object {
            [pscustomobject]@{
                Id = [string]$_.Id
                ScriptType = [string]$_.ScriptType
                DisplayName = [string]$_.DisplayName
                CreatedDateTime = [string]$_.CreatedDateTime
                Display = "$($_.ScriptType) | $($_.DisplayName)"
            }
        })
        if ($emSink) {
            & $emSink ([pscustomobject]@{
                Type = 'ScriptChoices'
                Name = 'Intune scripts'
                Data = [pscustomobject]@{ ScriptType = [string]$emArguments['ScriptType']; Choices = $emChoices }
            }) | Out-Null
        }
    }
    elseif ($emWorkflow -eq 'quality-updates' -and $emArguments['ListPolicies']) {
        $emPolicies = @(& $emScript @emArguments)
        $emDuplicateNames = @{}
        foreach ($emGroup in ($emPolicies | Group-Object DisplayName)) {
            if ($emGroup.Count -gt 1) { $emDuplicateNames[$emGroup.Name] = $true }
        }
        $emChoices = @($emPolicies | ForEach-Object {
            [pscustomobject]@{
                Id = $_.Id
                DisplayName = $_.DisplayName
                ScriptType = ''
                Display = if ($emDuplicateNames.ContainsKey($_.DisplayName)) { "$($_.DisplayName) ($($_.Id))" } else { $_.DisplayName }
            }
        })
        if ($emSink) {
            & $emSink ([pscustomobject]@{
                Type = 'Choice'; Name = 'Quality update policies'; Data = $emChoices
            }) | Out-Null
        }
    }
    else { . $emScript @emArguments }
    if ($emWorkflow -eq 'user-sign-in-history') {
        if ($SignInAction -ne 'New') { $results = @($emPrevious.Rows) + @($results) }
    }
    $emFinished = $true
}
catch {
    $emFailure = $_
    throw
}
finally {
    $emCancelled = $CancellationCheck -and $CancellationCheck.Invoke()
    $emReadSets = @{
        'device-investigation' = @('Investigation records','results')
        'app-install-investigation' = @('Device/app investigations','results')
        'mobile-inventory' = @('Devices','report')
        'cloudpc-inventory' = @('Cloud PCs','results')
        'cloudpc-last-login' = @('Devices','Report')
        'get-entra-group-members' = @('Members','results')
        'user-sign-in-history' = @('Sign-in events','results')
        'device-usage' = @('Devices','DeviceSummaries')
        'quality-updates' = @('Device report rows','results')
        'wufb-report' = @('Workspace device records','results')
        'intune-script-device-status' = @('Device run states','results')
        'stale-synced-devices' = @('Devices','results')
        'discovered-apps' = @('Device/app report rows','results')
        'm365-cloud-update' = @('Devices reported','Report')
    }
    $emOutcomeSets = @{
        'create-direct-reports-group' = @('Groups','results')
        'delete-win32-apps' = @('Apps','results')
        'primary-users' = @('Devices','results')
        'entra-cleanup' = @('Device records','results')
        'add-primary-devices-to-group' = @('Users','Results')
        'add-members-to-group' = @('Group members','results')
        'remove-members-from-group' = @('Group members','results')
        'intune-sync' = @('Devices','syncResults')
        'intune-assignment-win32-deployment-exports' = @('Apps','deploymentResults')
    }
    if ($emReadSets.ContainsKey($emWorkflow) -or $emOutcomeSets.ContainsKey($emWorkflow)) {
        $emDefinition = if ($emReadSets.ContainsKey($emWorkflow)) { $emReadSets[$emWorkflow] } else { $emOutcomeSets[$emWorkflow] }
        $emVariable = Get-Variable -Name $emDefinition[1] -Scope Local -ErrorAction Ignore
        if ($emVariable) {
            $emStatuses = switch ($emWorkflow) {
                'cloudpc-last-login' { @('LoginStatus') }
                'entra-cleanup' { @('EntraAction','AutopilotAction') }
                default { if (-not $emReadSets.ContainsKey($emWorkflow)) { 'Status' } }
            }
            $emSummary = Get-EndpointOutcomeSummary -Entity $emDefinition[0] -Rows @($emVariable.Value | ForEach-Object { $_ }) -StatusProperties $emStatuses -ReadOnly:$emReadSets.ContainsKey($emWorkflow)
            if ($emWorkflow -eq 'm365-cloud-update' -and $emFinished) {
                $emSummary.CountsComplete = $Report.Count -eq $ExpectedCount
                if ($emArguments['IncludeWaveGroups']) {
                    $emSummary.CountsComplete = $emSummary.CountsComplete -and $GroupCorrelation.Unknown -eq 0 -and $GroupCorrelation.UnresolvedGroups -eq 0
                }
            }
            if ($emWorkflow -eq 'user-sign-in-history' -and $emFinished) {
                $emSummary.CountsComplete = -not [bool]$signInPage.NextLink
            }
            if ($emWorkflow -eq 'device-usage') {
                $emSkipped = @($emVariable.Value | Where-Object Note -eq 'No azureADDeviceId').Count
                $emSummary.Succeeded -= $emSkipped
                $emSummary.Skipped += $emSkipped
                $emUsageFailed = @($emVariable.Value | Where-Object {
                    $_.Note -ne 'No azureADDeviceId' -and ($_.Note -eq 'Sign-in lookup failed' -or $_.IntunePrimaryUserStatus -eq 'Lookup failed')
                }).Count
                $emSummary.Succeeded -= $emUsageFailed
                $emSummary.Failed += $emUsageFailed
                $emMissing = Get-Variable -Name usageNotFound -Scope Local -ErrorAction Ignore
                if ($emMissing) {
                    $emSummary.Targeted += $emMissing.Value
                    $emSummary.NotFound += $emMissing.Value
                }
            }
        }
    }
    elseif ($emWorkflow -eq 'entra-user-lookup') {
        $emLookup = Get-Variable -Name results -Scope Local -ErrorAction Ignore
        if ($emLookup) {
            # One outcome per input name; only a single exact match is confirmed.
            $emNameRows = @($emLookup.Value | Where-Object { $null -ne $_ } | Group-Object Input | ForEach-Object {
                $emNameStatus = switch (@($_.Group)[0].Status) {
                    'Found' { 'Read' }
                    { $_ -in @('Multiple','PossibleMatch') } { 'Unresolved' }
                    default { $_ }
                }
                [pscustomobject]@{ Status = $emNameStatus }
            })
            $emSummary = Get-EndpointOutcomeSummary -Entity 'Names' -Rows $emNameRows
        }
    }
    elseif ($emWorkflow -in @('all-device-assignments','group-app-assignments')) {
        $emApps = Get-Variable -Name apps -Scope Local -ErrorAction Ignore
        $emLookupFailures = Get-Variable -Name assignmentLookupFailures -Scope Local -ErrorAction Ignore
        if ($emApps -and $emLookupFailures) {
            $emSummary = [pscustomobject]@{
                Entity = 'Apps checked'; Targeted = @($emApps.Value).Count
                Succeeded = if ($emFinished) { @($emApps.Value).Count - $emLookupFailures.Value } else { 0 }
                Failed = $emLookupFailures.Value; PendingApproval = 0; Skipped = 0; NotFound = 0
                Unprocessed = if ($emFinished) { 0 } else { @($emApps.Value).Count - $emLookupFailures.Value }
                Affected = 0; CountsComplete = $emFinished
            }
        }
    }
    if ($emSummary) {
        $emSummary.CountsComplete = $emSummary.CountsComplete -and $emFinished -and -not $emCancelled
        if ($emWorkflow -ne 'delete-win32-apps') { Write-Host "`nSummary: $(Format-EndpointOutcomeSummary $emSummary)" -ForegroundColor Cyan }
        if ($emSink) { & $emSink ([pscustomobject]@{ Type = 'OperationSummary'; Name = 'Run outcomes'; Data = $emSummary }) | Out-Null }
    }
    $emState = if ($emCancelled -or (-not $emFinished -and $emFailure -and $emFailure.Exception -is [Management.Automation.PipelineStoppedException])) { 'Cancelled' }
        elseif (-not $emFinished -or ($emSummary -and $emSummary.Failed -gt 0)) { 'Failed/partial' }
        elseif ($emSummary -and $emSummary.PendingApproval -gt 0) { 'PendingApproval' }
        elseif ($emSummary -and ($emSummary.NotFound -gt 0 -or -not $emSummary.CountsComplete)) { 'Incomplete/unresolved' }
        elseif ($emWorkflow -eq 'remote-endpoint') {
            $emSession = Get-Variable -Name session -Scope Local -ErrorAction Ignore
            if ($emSession -and $emSession.Value -and $emSession.Value.State -eq 'Opened') { 'Connected' } else { 'ConnectionFailed' }
        }
        else { 'Finished' }
    if ($emLogPath) {
        try {
            Write-EndpointActivityRecord -LogRoot $emLogPath -Event 'RunEnded' -WorkflowId $emWorkflow -RunId $emRunId -State $emState -Device $emDevice -Summary $emSummary
        }
        catch { Write-Error "Activity logging failed; the run may be missing its final audit record: $($_.Exception.Message)" -ErrorAction Continue }
    }
    if ($emSink) {
        if ($emWorkflow -eq 'intune-script-device-status' -and $emFinished -and -not $emCancelled -and -not $emArguments['ListScripts']) {
            $emSelection = Get-Variable -Name selectedScript -Scope Local -ErrorAction Ignore
            if ($emSelection -and $results.Count) {
                $emCharts = @(switch ($emSelection.Value.ScriptType) {
                    'Remediation' { Get-EndpointRemediationCharts $results }
                    'Platform script' { Get-EndpointPlatformScriptChart $results }
                })
                if ($emCharts.Count) {
                    & $emSink ([pscustomobject]@{ Type = 'ReportVisual'; Name = $emSelection.Value.DisplayName; Data = $emCharts }) | Out-Null
                }
            }
        }
        if ($emWorkflow -eq 'discovered-apps' -and $emFinished -and -not $emCancelled -and $emArguments['AppName']) {
            foreach ($emApp in ($results | Where-Object { $_.ApplicationName -and $_.DeviceId } | Group-Object ApplicationName | Sort-Object Name)) {
                $emChart = Get-EndpointDiscoveredVersionChart $emApp.Group
                & $emSink ([pscustomobject]@{ Type = 'ReportVisual'; Name = $emApp.Name; Data = @($emChart) }) | Out-Null
            }
        }
        $emVisualDataset = switch ($emWorkflow) {
            'mobile-inventory' { 'Inventory' }
            'cloudpc-inventory' { 'All Cloud PCs' }
            'cloudpc-last-login' { 'Cloud PCs' }
            'device-investigation' { 'Reconciliation queue' }
            'device-usage' { 'Devices' }
            'get-entra-group-members' { 'Members' }
            'user-sign-in-history' { 'Sign-in events' }
            'm365-cloud-update' { 'Rollout summary' }
            'wufb-report' { 'Devices' }
            { $_ -in @('quality-updates', 'stale-synced-devices') } { 'Results' }
        }
        if ($emWorkflow -eq 'compare-win32-runs' -and $emFinished -and -not $emCancelled -and $results.Count) {
            $emChart = New-EndpointReviewChart 'Win32 deployment changes' $comparisonBasis $results 'Change' 'Device changes' ([ordered]@{
                Improved = 'Success'; Regressed = 'Failure'; 'Newly reported' = 'Pending'; 'No longer reported' = 'Warning'
                'Other status change' = 'Accent1'; Unchanged = 'Neutral'
            })
            $emCharts = @($emChart)
            $emTransitions = @($results | Where-Object Change -in @('Improved','Regressed','Other status change'))
            if ($emTransitions.Count) {
                $emColors = [ordered]@{}
                foreach ($emGroup in ($emTransitions | Group-Object Transition | Sort-Object Count -Descending | Select-Object -First 8)) {
                    $emColors[$emGroup.Name] = switch ($emGroup.Group[0].Change) {
                        'Improved' { 'Success' }
                        'Regressed' { 'Failure' }
                        default { 'Accent1' }
                    }
                }
                $emCharts += New-EndpointReviewChart 'Most common status transitions' 'Up to eight transitions among devices present in both exports whose status changed. All transitions are available in Device changes.' $emTransitions 'Transition' 'Device changes' $emColors
            }
        }
        $emSets = switch ($emWorkflow) {
            'compare-win32-runs' { @{ 'Device changes' = 'results' } }
            'device-investigation' { [ordered]@{ 'Device overview' = 'results'; 'Entra records' = 'entraRows'; 'Autopilot records' = 'autopilotRows'; 'Reconciliation queue' = 'reconciliationRows' } }
            'app-install-investigation' { [ordered]@{ 'Diagnostic findings' = 'findings'; 'Error code details' = 'errorCodeDetails'; 'App investigation' = 'results'; 'Device deployment rows' = 'deploymentRows'; 'App assignments' = 'assignmentRows'; 'Suggested checks' = 'checkRows' } }
            'm365-cloud-update' { [ordered]@{ 'Cloud Update devices' = 'Report'; 'Rollout summary' = 'Summary'; 'Progress by wave' = 'WaveSummary'; Release = 'ReleaseInfo' } }
            'wufb-report' { [ordered]@{ Devices = 'results'; 'Fleet overview' = 'wufbOverview'; 'Missing security updates' = 'wufbMissing'; 'Failed updates' = 'wufbFailures'; 'Pending restarts' = 'wufbRestarts'; 'Stalled candidates' = 'wufbStalled'; 'Update records' = 'wufbUpdates'; 'Service states' = 'wufbServices'; Alerts = 'wufbAlerts'; 'Error summary' = 'wufbErrors'; 'KB investigation' = 'wufbKB'; 'Observed updates' = 'wufbCatalog'; 'Compliance trend' = 'wufbTrends'; 'Data health' = 'wufbHealth'; 'Device name resolution' = 'wufbNameResolution' } }
            'intune-script-device-status' { @{ 'Device status' = 'results' } }
            'mobile-inventory' { @{ Inventory = 'report' } }
            'cloudpc-inventory' { @{ 'All Cloud PCs' = 'results' } }
            'cloudpc-last-login' { @{ 'Cloud PCs' = 'Report' } }
            'device-usage' { @{ Devices = 'DeviceSummaries'; 'Sign-in records' = 'UsageRecords' } }
            'primary-users' { @{ 'Primary users' = 'results' } }
            'intune-sync' { @{ 'Sync requests' = 'RequestedSyncs' } }
            'add-primary-devices-to-group' { @{ Membership = 'Results' } }
            'get-entra-group-members' { @{ Members = 'results' } }
            'user-sign-in-history' { @{ 'Sign-in events' = 'results' } }
            'entra-cleanup' { @{ Cleanup = 'results' } }
            default { @{ Results = 'results' } }
        }
        foreach ($emName in $emSets.Keys) {
            $emVariable = Get-Variable -Name $emSets[$emName] -Scope Local -ErrorAction Ignore
            if ($emVariable -and $null -ne $emVariable.Value -and ($emWorkflow -notin @('device-investigation','app-install-investigation','cloudpc-inventory','user-sign-in-history') -or $emFinished) -and
                ($emWorkflow -ne 'wufb-report' -or ($emFinished -and -not $emCancelled)) -and
                ($emWorkflow -ne 'user-sign-in-history' -or -not $emCancelled)) {
                $emRows = @($emVariable.Value | ForEach-Object { $_ })
                if ($emWorkflow -eq 'device-usage' -and $emName -eq 'Devices') {
                    $emRows = @($emRows | Sort-Object ActiveDayGap -Descending)
                }
                if ($emRows.Count -or ($emWorkflow -eq 'm365-cloud-update' -and $emSets[$emName] -eq 'Report') -or
                    ($emWorkflow -eq 'wufb-report' -and $emFinished -and -not $emCancelled -and $emName -ne 'KB investigation') -or
                    ($emWorkflow -eq 'app-install-investigation' -and $emFinished -and $emName -ne 'Error code details') -or
                    ($emWorkflow -eq 'get-entra-group-members' -and $emFinished) -or
                    ($emWorkflow -eq 'user-sign-in-history' -and $emFinished) -or
                    ($emWorkflow -eq 'cloudpc-inventory' -and $emFinished) -or
                    ($emWorkflow -eq 'device-investigation' -and $emFinished -and -not $emCancelled -and $emName -in @('Device overview','Reconciliation queue'))) {
                    if ($emWorkflow -eq 'user-sign-in-history') {
                        $emSignInCharts = @(Get-EndpointSignInCharts $emRows $LookbackDays ([bool]$signInPage.NextLink) $signInPage.Received ([bool]$FailuresOnly))
                    }
                    & $emSink ([pscustomobject]@{ Type = 'Rows'; Name = $emName; Data = $emRows }) | Out-Null
                    if ($emWorkflow -eq 'user-sign-in-history') {
                        $global:EndpointSignInHistoryState = @{
                            Id=$emRunId; Continuation=$signInPage; Rows=$results
                            Previous=$(if ($SignInAction -ne 'New') { $emPrevious } else { $null })
                        }
                        & $emSink ([pscustomobject]@{
                            Type='Stage'; Name='Sign-in paging'
                            Data=[pscustomobject]@{ HasMore=[bool]$signInPage.NextLink; Received=$signInPage.Received; ContinuationId=$emRunId }
                        }) | Out-Null
                    }
                    if ($emWorkflow -eq 'compare-win32-runs' -and $emFinished -and -not $emCancelled) {
                        & $emSink ([pscustomobject]@{ Type = 'ReportVisual'; Name = 'Win32 run comparison'; Data = $emCharts }) | Out-Null
                    }
                    elseif ($emFinished -and -not $emCancelled -and $emName -eq $emVisualDataset -and ($emRows.Count -or $emWorkflow -in @('device-investigation','user-sign-in-history'))) {
                        $emChartOptions = @{}
                        if ($emWorkflow -eq 'device-usage') { $emChartOptions.LookbackDays = $LookbackDays }
                        if ($emWorkflow -eq 'device-investigation') { $emChartOptions.SearchBy = $SearchBy }
                        $emCharts = if ($emWorkflow -eq 'user-sign-in-history') {
                            $emSignInCharts
                        } else { @(Get-EndpointInventoryCharts $emWorkflow $emRows @emChartOptions) }
                        & $emSink ([pscustomobject]@{ Type = 'ReportVisual'; Name = $emName; Data = $emCharts }) | Out-Null
                    }
                    if ($emWorkflow -eq 'wufb-report' -and $emName -eq 'KB investigation' -and $emRows.Count) {
                        $emChart = New-EndpointRankedChart 'KB investigation outcomes' 'Counts workspace device records; inferred coverage is not exact KB installation.' $emRows 'KBStatus' 'KB investigation'
                        & $emSink ([pscustomobject]@{ Type = 'ReportVisual'; Name = 'KB investigation'; Data = @($emChart) }) | Out-Null
                    }
                }
            }
        }
        $emPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $emPathVariables = @('finalCsv', 'targetFile', 'CsvPath', 'OutputCsvPath', 'OutputFile')
        if ($emWorkflow -eq 'm365-cloud-update') { $emPathVariables += @('PortalCsv', 'RawCsv', 'SummaryCsv') }
        foreach ($emName in $emPathVariables) {
            $emVariable = Get-Variable -Name $emName -Scope Local -ErrorAction Ignore
            if ($emVariable -and $emVariable.Value -is [string] -and $emVariable.Value) {
                $null = $emPaths.Add([IO.Path]::GetFullPath($emVariable.Value))
            }
        }
        if ($emWorkflow -eq 'intune-assignment-win32-deployment-exports') {
            $emVisualSources = @{}
            $emVisualGroups = [ordered]@{}
            $emTimestamp = Get-Variable -Name timestamp -Scope Local -ErrorAction Ignore
            $emApps = Get-Variable -Name selectedApps -Scope Local -ErrorAction Ignore
            $emOutput = Get-Variable -Name OutputPath -Scope Local -ErrorAction Ignore
            if ($emTimestamp -and $emApps -and $emOutput) {
                foreach ($emApp in $emApps.Value) {
                    $emSafeName = ($emApp.displayName -replace '[\\/:*?"<>|]', '_').Trim()
                    $emBase = '{0}_{1}_{2}' -f $emSafeName, $emApp.id, $emTimestamp.Value
                    foreach ($emSuffix in @('DeviceStatus', 'DeviceSummary', 'UserStatus')) {
                        $emPath = [IO.Path]::GetFullPath((Join-Path $emOutput.Value "$emBase`_$emSuffix.csv"))
                        $null = $emPaths.Add($emPath)
                        if ($emSuffix -ne 'DeviceStatus') { $emVisualSources[$emPath] = @{ App = $emApp; Kind = $emSuffix } }
                    }
                }
            }
        }
        foreach ($emPath in $emPaths) {
            if (-not (Test-Path -LiteralPath $emPath -PathType Leaf)) { continue }
            $emFile = Get-Item -LiteralPath $emPath
            if ($emBefore[$emPath] -eq "$($emFile.LastWriteTimeUtc.Ticks):$($emFile.Length)") { continue }
            $emName = [IO.Path]::GetFileNameWithoutExtension($emPath)
            & $emSink ([pscustomobject]@{ Type = 'Artifact'; Name = $emName; Data = $emPath }) | Out-Null
            if ($emWorkflow -eq 'intune-assignment-win32-deployment-exports') {
                $emReportRows = @(Import-Csv -LiteralPath $emPath)
                & $emSink ([pscustomobject]@{ Type = 'Rows'; Name = $emName; Data = $emReportRows }) | Out-Null
                $emSource = $emVisualSources[$emPath]
                if ($emSource) {
                    $emChart = Get-EndpointDeploymentChart $emSource.Kind $emReportRows
                    if ($emChart) {
                        $emLabel = "$($emSource.App.displayName) ($($emSource.App.id))"
                        if (-not $emVisualGroups.Contains($emLabel)) { $emVisualGroups[$emLabel] = [Collections.Generic.List[object]]::new() }
                        $emVisualGroups[$emLabel].Add($emChart)
                    }
                }
            }
        }
        if ($emWorkflow -eq 'intune-assignment-win32-deployment-exports') {
            $emTriage = Get-Variable -Name failureTriageByApp -Scope Local -ErrorAction Ignore
            if ($emFinished -and -not $emCancelled -and $emTriage -and $emApps) {
                foreach ($emApp in $emApps.Value) {
                    if (-not $emTriage.Value.ContainsKey([string]$emApp.id)) { continue }
                    $emLabel = "$($emApp.displayName) ($($emApp.id))"
                    $emDataset = "Failure triage - $emLabel"
                    $emRows = $emTriage.Value[[string]$emApp.id]
                    if ($emRows.Count) {
                        & $emSink ([pscustomobject]@{ Type = 'Rows'; Name = $emDataset; Data = $emRows }) | Out-Null
                    }
                    if (-not $emVisualGroups.Contains($emLabel)) { $emVisualGroups[$emLabel] = [Collections.Generic.List[object]]::new() }
                    foreach ($emChart in (Get-EndpointFailureTriageCharts $emRows $emDataset -IncludeDeviceContext:$IncludeDeviceContext)) {
                        $emVisualGroups[$emLabel].Add($emChart)
                    }
                }
            }
            foreach ($emLabel in $emVisualGroups.Keys) {
                & $emSink ([pscustomobject]@{ Type = 'ReportVisual'; Name = $emLabel; Data = $emVisualGroups[$emLabel].ToArray() }) | Out-Null
            }
        }
        if ($emWorkflow -eq 'remote-endpoint') {
            $emSession = Get-Variable -Name session -Scope Local -ErrorAction Ignore
            if ($emSession -and $emSession.Value) {
                & $emSink ([pscustomobject]@{ Type = 'Session'; Name = 'Created'; Data = $emSession.Value }) | Out-Null
            }
        }
    }
}
