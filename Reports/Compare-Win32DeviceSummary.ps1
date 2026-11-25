<#
.SYNOPSIS
    Compares two Endpoint Toolbox Win32 DeviceSummary CSVs for the same app.
.PARAMETER BeforeCsv
    The older DeviceSummary CSV. Use exports from the same tenant and reporting scope.
.PARAMETER AfterCsv
    The newer DeviceSummary CSV.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BeforeCsv,
    [Parameter(Mandatory)][string]$AfterCsv
)

$ErrorActionPreference = 'Stop'

function Read-DeploymentSnapshot {
    param([string]$Path, [string]$Label)
    $rows = @(Import-Csv -LiteralPath $Path)
    if (-not $rows.Count) { throw "$Label report has no data rows." }
    foreach ($column in @('ApplicationId','AppDisplayVersion','DeviceId','DeviceName','InstallStateFriendly','IdentityStatus','ReportRows')) {
        if (-not $rows[0].PSObject.Properties[$column]) { throw "$Label report is not a Win32 DeviceSummary CSV (missing $column)." }
    }
    $appId = [guid]::Empty
    if (-not [guid]::TryParse($rows[0].ApplicationId, [ref]$appId) -or $appId -eq [guid]::Empty) {
        throw "$Label report does not contain a valid application ID."
    }
    $index = @{}
    $excluded = 0
    foreach ($row in $rows) {
        if ($row.ApplicationId -ne $rows[0].ApplicationId) { throw "$Label report contains multiple application IDs." }
        $id = $row.DeviceId.Trim()
        if (-not $id -or $row.IdentityStatus -ne 'Identified') { $excluded++; continue }
        if ($index.ContainsKey($id)) { throw "$Label report contains duplicate device IDs. Use the per-device summary, not raw deployment rows." }
        $index[$id] = $row
    }
    [pscustomobject]@{ Index = $index; AppId = $appId; Excluded = $excluded; Version = $rows[0].AppDisplayVersion }
}

$before = Read-DeploymentSnapshot $BeforeCsv 'Before'
$after = Read-DeploymentSnapshot $AfterCsv 'After'
if ($before.AppId -ne $after.AppId) { throw 'Choose two DeviceSummary CSVs for the same application ID.' }
if (-not ($before.Index.Count + $after.Index.Count)) { throw 'Neither report contains identified devices to compare.' }

$comparisonBasis = "Same application ID. Use exports from the same tenant and scope; the CSVs do not verify either. App version: $($before.Version) to $($after.Version). Excluded rows without a usable identity: $($before.Excluded) before, $($after.Excluded) after."
Write-Output $comparisonBasis
$notInstalled = @('Failed','Error','Not installed','Pending install','Uninstalled')
$results = @(foreach ($id in @($before.Index.Keys) + @($after.Index.Keys | Where-Object { -not $before.Index.ContainsKey($_) })) {
    $old = $before.Index[$id]
    $new = $after.Index[$id]
    $oldState = if ($old) { ([string]$old.InstallStateFriendly).Trim() } else { 'Not in export' }
    $newState = if ($new) { ([string]$new.InstallStateFriendly).Trim() } else { 'Not in export' }
    $change = if (-not $old) { 'Newly reported' }
        elseif (-not $new) { 'No longer reported' }
        elseif ($oldState -eq $newState) { 'Unchanged' }
        elseif ($newState -eq 'Installed' -and $oldState -in $notInstalled) { 'Improved' }
        elseif ($oldState -eq 'Installed' -and $newState -in $notInstalled) { 'Regressed' }
        else { 'Other status change' }
    [pscustomobject]@{
        DeviceName = if ($new) { $new.DeviceName } else { $old.DeviceName }
        Change = $change
        Transition = "$oldState -> $newState"
        BeforeStatus = $oldState
        AfterStatus = $newState
        DeviceId = $id
    }
})
Write-Output "Compared $($results.Count) unique devices. Missing from an export does not establish why a device stopped reporting."
$results
