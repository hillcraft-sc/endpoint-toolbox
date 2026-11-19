# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$WorkflowId,
    [Parameter(Mandatory)][hashtable]$ScriptArguments,
    [string]$ActivityLogPath = '',
    [string]$RunId = '',
    [Func[bool]]$CancellationCheck,
    [scriptblock]$UiEventSink
)

. (Join-Path $PSScriptRoot 'ActivityLogging.ps1')
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
    $emFinished = $true
}
catch {
    $emFailure = $_
    throw
}
finally {
    $emCancelled = $CancellationCheck -and $CancellationCheck.Invoke()
    $emReadSets = @{
        'mobile-inventory' = @('Devices','report')
        'cloudpc-last-login' = @('Devices','Report')
        'group-devices' = @('Devices','results')
        'device-usage' = @('Devices','DeviceSummaries')
        'quality-updates' = @('Device report rows','results')
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
            if ($emWorkflow -eq 'device-usage') {
                $emSkipped = @($emVariable.Value | Where-Object Note -eq 'No azureADDeviceId').Count
                $emSummary.Succeeded -= $emSkipped
                $emSummary.Skipped += $emSkipped
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
        $emSets = switch ($emWorkflow) {
            'm365-cloud-update' { [ordered]@{ 'Cloud Update devices' = 'Report'; 'Rollout summary' = 'Summary'; 'Progress by wave' = 'WaveSummary'; Release = 'ReleaseInfo' } }
            'intune-script-device-status' { @{ 'Device status' = 'results' } }
            'mobile-inventory' { @{ Inventory = 'report' } }
            'cloudpc-last-login' { @{ 'Cloud PCs' = 'Report' } }
            'device-usage' { @{ Devices = 'DeviceSummaries'; 'Sign-in records' = 'UsageRecords' } }
            'primary-users' { @{ 'Primary users' = 'results' } }
            'intune-sync' { @{ 'Sync requests' = 'RequestedSyncs' } }
            'add-primary-devices-to-group' { @{ Membership = 'Results' } }
            'entra-cleanup' { @{ Cleanup = 'results' } }
            default { @{ Results = 'results' } }
        }
        foreach ($emName in $emSets.Keys) {
            $emVariable = Get-Variable -Name $emSets[$emName] -Scope Local -ErrorAction Ignore
            if ($emVariable -and $null -ne $emVariable.Value) {
                $emRows = @($emVariable.Value | ForEach-Object { $_ })
                if ($emRows.Count -or ($emWorkflow -eq 'm365-cloud-update' -and $emSets[$emName] -eq 'Report')) {
                    & $emSink ([pscustomobject]@{ Type = 'Rows'; Name = $emName; Data = $emRows }) | Out-Null
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
            $emTimestamp = Get-Variable -Name timestamp -Scope Local -ErrorAction Ignore
            $emApps = Get-Variable -Name selectedApps -Scope Local -ErrorAction Ignore
            $emOutput = Get-Variable -Name OutputPath -Scope Local -ErrorAction Ignore
            if ($emTimestamp -and $emApps -and $emOutput) {
                foreach ($emApp in $emApps.Value) {
                    $emSafeName = ($emApp.displayName -replace '[\\/:*?"<>|]', '_').Trim()
                    $emBase = '{0}_{1}_{2}' -f $emSafeName, $emApp.id, $emTimestamp.Value
                    foreach ($emSuffix in @('DeviceStatus', 'DeviceSummary', 'UserStatus')) {
                        $null = $emPaths.Add([IO.Path]::GetFullPath((Join-Path $emOutput.Value "$emBase`_$emSuffix.csv")))
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
                & $emSink ([pscustomobject]@{ Type = 'Rows'; Name = $emName; Data = @(Import-Csv -LiteralPath $emPath) }) | Out-Null
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
