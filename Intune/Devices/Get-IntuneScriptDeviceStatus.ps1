# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Exports per-device status for one Intune remediation or platform script.

.DESCRIPTION
    Lists Intune remediations and platform scripts, filters by type and optional partial or
    wildcard name, then selects one script when multiple matches remain. Retrieves the
    script's device run states and exports the results as a CSV.

.PARAMETER ScriptType
    Script types to search: All, Remediation or Platform script.

.PARAMETER ScriptName
    Optional partial name or PowerShell wildcard pattern used to find scripts.

.PARAMETER ScriptId
    Optional Intune script ID. Use with a specific ScriptType to run a report directly for a
    previously selected script without repeating discovery.

.PARAMETER ListScripts
    Return the available scripts for ScriptType without retrieving device status.

.PARAMETER OutputPath
    Folder where the CSV report is saved. Created if it does not exist. Defaults to TEMP.

.EXAMPLE
    .\Get-IntuneScriptDeviceStatus.ps1 -ScriptType Remediation -ScriptName "BitLocker"

    Finds remediation scripts with BitLocker in the name and exports the selected script's
    device status to TEMP.

.EXAMPLE
    $scripts = .\Get-IntuneScriptDeviceStatus.ps1 -ScriptType All -ListScripts
    .\Get-IntuneScriptDeviceStatus.ps1 -ScriptType Remediation -ScriptId $scripts[0].Id

    Lists available scripts, then reports device status for a previously selected remediation.

.NOTES
    Requires an active Microsoft Graph connection with DeviceManagementScripts.Read.All.
    Uses Microsoft Graph beta deviceManagement/deviceHealthScripts and
    deviceManagement/deviceManagementScripts deviceRunStates endpoints.
    Microsoft Graph beta APIs are subject to change.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Remediation', 'Platform script')]
    [string]$ScriptType = 'All',

    [string]$ScriptName = '',

    [string]$ScriptId = '',

    [switch]$ListScripts,

    [string]$OutputPath = "$env:TEMP"
)

$ErrorActionPreference = 'Stop'
if (Get-MgContext) {
    Write-Host 'Connected to MgGraph...' -ForegroundColor Green
}
else {
    Write-Host 'Not connected to MgGraph. Connecting...' -ForegroundColor Yellow
    Connect-MgGraph -NoWelcome | Out-Null
}

function Get-IntuneGraphCollection {
    param([Parameter(Mandatory)][string]$Uri)

    $items = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($Uri) {
        $address = [uri]$Uri
        if ($address.Scheme -ne 'https' -or $address.Host -ne 'graph.microsoft.com' -or
            -not $address.AbsolutePath.StartsWith('/beta/', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Intune returned an unexpected Graph pagination address.'
        }
        if (-not $seen.Add($Uri)) {
            throw 'Intune returned a repeated Graph page. The report was stopped.'
        }

        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri
        $hasValue = if ($page -is [System.Collections.IDictionary]) {
            $page.Contains('value')
        }
        else {
            $page -and $page.PSObject.Properties.Name -contains 'value'
        }
        if (-not $hasValue -or $null -eq $page.value) {
            throw 'Intune returned an invalid script or device status collection.'
        }
        foreach ($item in $page.value) { $items.Add($item) }
        $Uri = [string]$page.'@odata.nextLink'
    }

    return $items.ToArray()
}

function Get-IntuneScriptList {
    param([Parameter(Mandatory)][string]$Type)

    $items = [Collections.Generic.List[object]]::new()
    if ($Type -in @('All', 'Remediation')) {
        foreach ($item in (Get-IntuneGraphCollection 'https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts?$select=id,displayName,createdDateTime')) {
            $itemId = [guid]::Empty
            if (-not [guid]::TryParse([string]$item.id, [ref]$itemId) -or [string]::IsNullOrWhiteSpace([string]$item.displayName)) {
                throw 'Intune returned a remediation without a valid ID or display name.'
            }
            $items.Add([pscustomobject]@{
                Id = $itemId.ToString()
                DisplayName = [string]$item.displayName
                ScriptType = 'Remediation'
                CreatedDateTime = [string]$item.createdDateTime
                RunStatesPath = 'deviceHealthScripts'
            })
        }
    }
    if ($Type -in @('All', 'Platform script')) {
        foreach ($item in (Get-IntuneGraphCollection 'https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts?$select=id,displayName,createdDateTime')) {
            $itemId = [guid]::Empty
            if (-not [guid]::TryParse([string]$item.id, [ref]$itemId) -or [string]::IsNullOrWhiteSpace([string]$item.displayName)) {
                throw 'Intune returned a platform script without a valid ID or display name.'
            }
            $items.Add([pscustomobject]@{
                Id = $itemId.ToString()
                DisplayName = [string]$item.displayName
                ScriptType = 'Platform script'
                CreatedDateTime = [string]$item.createdDateTime
                RunStatesPath = 'deviceManagementScripts'
            })
        }
    }
    return @($items | Sort-Object ScriptType, DisplayName, Id)
}

if ($ListScripts -and $ScriptId) { throw 'ListScripts cannot be combined with ScriptId.' }
if ($ScriptId -and $ScriptType -eq 'All') { throw 'Specify Remediation or Platform script when using ScriptId.' }
$scripts = if ($ListScripts -or -not $ScriptId) { @(Get-IntuneScriptList $ScriptType) } else { @() }
if ($ListScripts) { return $scripts }

if ($ScriptId) {
    $parsedId = [guid]::Empty
    if (-not [guid]::TryParse($ScriptId, [ref]$parsedId)) { throw 'ScriptId must be a valid Intune script GUID.' }
    $scriptCollection = if ($ScriptType -eq 'Remediation') { 'deviceHealthScripts' } else { 'deviceManagementScripts' }
    $scriptInfoUri = "https://graph.microsoft.com/beta/deviceManagement/$scriptCollection/$($parsedId.ToString())?`$select=id,displayName,createdDateTime"
    $scriptInfo = Invoke-MgGraphRequest -Method GET -Uri $scriptInfoUri
    if ([string]$scriptInfo.id -ne $parsedId.ToString() -or [string]::IsNullOrWhiteSpace([string]$scriptInfo.displayName)) {
        throw "Intune script not found with ID '$ScriptId' for type '$ScriptType'."
    }
    if ($ScriptName -and $ScriptName -ine $scriptInfo.displayName) { throw 'The selected script name no longer matches the Intune script with this ID. Reload the script list and try again.' }
    $selectedScript = [pscustomobject]@{
        Id = [string]$scriptInfo.id
        DisplayName = [string]$scriptInfo.displayName
        ScriptType = $ScriptType
        CreatedDateTime = [string]$scriptInfo.createdDateTime
        RunStatesPath = $scriptCollection
    }
}
else {
    $matchingScripts = @($scripts | Where-Object {
        $_.Id -and $_.DisplayName -and
        (-not $ScriptName -or $_.DisplayName -like $(if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($ScriptName)) { $ScriptName } else { "*$ScriptName*" }))
    } | Sort-Object ScriptType, DisplayName, Id)

    if ($matchingScripts.Count -eq 0) {
        if ($ScriptName) { throw "No Intune scripts matched '$ScriptName' for type '$ScriptType'." }
        throw "No Intune scripts were found for type '$ScriptType'."
    }

    if ($matchingScripts.Count -gt 1) {
        Write-Host "`nSelect one Intune script:" -ForegroundColor Yellow
        for ($index = 0; $index -lt $matchingScripts.Count; $index++) {
            $candidate = $matchingScripts[$index]
            Write-Host ("[{0}] {1} | {2} | {3}" -f $index, $candidate.ScriptType, $candidate.DisplayName, $candidate.Id) -ForegroundColor Cyan
        }
        $selection = Read-Host 'Enter one script number'
        $selectedIndex = -1
        if ([string]::IsNullOrWhiteSpace($selection) -or
            $selection.Trim() -notmatch '^\d+$' -or
            -not [int]::TryParse($selection.Trim(), [ref]$selectedIndex) -or
            $selectedIndex -ge $matchingScripts.Count) {
            throw 'No valid script was selected. No report was run.'
        }
        $selectedScript = $matchingScripts[$selectedIndex]
    }
    else {
        $selectedScript = $matchingScripts[0]
    }
}

Write-Host "Selected $($selectedScript.ScriptType): $($selectedScript.DisplayName)" -ForegroundColor Cyan
$scriptId = [uri]::EscapeDataString($selectedScript.Id)
$runStatesUri = "https://graph.microsoft.com/beta/deviceManagement/$($selectedScript.RunStatesPath)/$scriptId/deviceRunStates?`$expand=managedDevice(`$select=id,deviceName,userPrincipalName,operatingSystem)"
$states = @(Get-IntuneGraphCollection $runStatesUri)

$results = @(
    foreach ($state in $states) {
        $device = $state.managedDevice
        $common = [ordered]@{
            ScriptType = $selectedScript.ScriptType
            ScriptName = $selectedScript.DisplayName
            ScriptId = $selectedScript.Id
            DeviceName = [string]$device.deviceName
            DeviceId = [string]$device.id
            UserPrincipalName = [string]$device.userPrincipalName
            OperatingSystem = [string]$device.operatingSystem
            LastStateUpdateDateTime = [string]$state.lastStateUpdateDateTime
        }
        if ($selectedScript.ScriptType -eq 'Remediation') {
            $common.DetectionState = [string]$state.detectionState
            $common.RemediationState = [string]$state.remediationState
            $common.ExpectedStateUpdateDateTime = [string]$state.expectedStateUpdateDateTime
            $common.LastDeviceSyncDateTime = [string]$state.lastSyncDateTime
            $common.PreRemediationDetectionScriptOutput = [string]$state.preRemediationDetectionScriptOutput
            $common.PreRemediationDetectionScriptError = [string]$state.preRemediationDetectionScriptError
            $common.RemediationScriptError = [string]$state.remediationScriptError
            $common.PostRemediationDetectionScriptOutput = [string]$state.postRemediationDetectionScriptOutput
            $common.PostRemediationDetectionScriptError = [string]$state.postRemediationDetectionScriptError
        }
        else {
            $common.RunState = [string]$state.runState
            $common.ResultMessage = [string]$state.resultMessage
            $common.ErrorCode = $state.errorCode
            $common.ErrorDescription = [string]$state.errorDescription
        }
        [pscustomobject]$common
    }
)

if (-not (Test-Path -LiteralPath $OutputPath -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $OutputPath -Force
}
$safeName = $selectedScript.DisplayName -replace '[\\/:*?"<>|]', '_'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$finalCsv = Join-Path $OutputPath "$safeName-$($selectedScript.ScriptType -replace ' ', '-')-DeviceStatus-$timestamp.csv"
if ($results.Count) {
    $results | Sort-Object DeviceName, UserPrincipalName | Export-Csv -LiteralPath $finalCsv -NoTypeInformation -Encoding UTF8
}
else {
    Write-Warning 'Intune returned no device run states for the selected script.'
    $columns = if ($selectedScript.ScriptType -eq 'Remediation') {
        @('ScriptType','ScriptName','ScriptId','DeviceName','DeviceId','UserPrincipalName','OperatingSystem','LastStateUpdateDateTime','DetectionState','RemediationState','ExpectedStateUpdateDateTime','LastDeviceSyncDateTime','PreRemediationDetectionScriptOutput','PreRemediationDetectionScriptError','RemediationScriptError','PostRemediationDetectionScriptOutput','PostRemediationDetectionScriptError')
    }
    else {
        @('ScriptType','ScriptName','ScriptId','DeviceName','DeviceId','UserPrincipalName','OperatingSystem','LastStateUpdateDateTime','RunState','ResultMessage','ErrorCode','ErrorDescription')
    }
    Set-Content -LiteralPath $finalCsv -Value ($columns -join ',') -Encoding utf8
}

Write-Host "Device status rows: $($results.Count)" -ForegroundColor Green
Write-Host "Report saved to: $finalCsv" -ForegroundColor Green
