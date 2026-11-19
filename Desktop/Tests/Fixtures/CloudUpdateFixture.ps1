# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

[CmdletBinding()]
param(
    [string]$Scenario = 'Happy',
    [string]$OutputRoot,
    [switch]$NoExport,
    [switch]$IncludeWaveGroups,
    [switch]$Direct,
    [switch]$Capture,
    [scriptblock]$UiEventSink
)
$fixtureEvents = [Collections.Generic.List[object]]::new()
$fixtureCalls = [Collections.Generic.List[string]]::new()
$fixtureGraphCalls = [Collections.Generic.List[string]]::new()
$fixtureGroupNames = [Collections.Generic.List[string]]::new()
$fixtureWarnings = @()
function Get-Module {
    param($Name, [switch]$ListAvailable)
    if ($Name -ne 'MSAL.PS' -or -not $ListAvailable) { throw 'Unexpected module lookup.' }
    if ($Scenario -ne 'MissingModule') { [pscustomobject]@{Name='MSAL.PS'} }
}
function Import-Module {
    param($Name)
    if ($Name -ne 'MSAL.PS') { throw 'Unexpected module import.' }
}
function Install-Module { throw 'The desktop must never install modules.' }
function Get-MsalToken {
    param($ClientId, $TenantId, $Scopes, [switch]$Interactive)
    if (-not $Interactive) { throw 'Interactive authentication was not preserved.' }
    if ($Scenario -eq 'AuthCancelled') { throw 'Synthetic sign-in cancelled.' }
    @{AccessToken='offline-placeholder';Account=@{Username='fixture@example.invalid'};ExpiresOn=[datetime]::UtcNow.AddHours(1);TenantId='00000000-0000-0000-0000-000000000001'}
}
function Get-MgContext {
    if (-not $IncludeWaveGroups) { throw 'Graph must not be used by the default Office report.' }
    if ($Scenario -eq 'GraphDisconnected') { return $null }
    @{
        AuthType='Delegated';Environment='Global'
        TenantId=$(if ($Scenario -eq 'GraphDifferentTenant') { '00000000-0000-0000-0000-000000000099' } else { '00000000-0000-0000-0000-000000000001' })
    }
}
function Connect-MgGraph { throw 'Wave correlation must not sign in or request consent automatically.' }
function Invoke-MgGraphRequest {
    param($Method, $Uri, $OutputType, $Headers)
    if (-not $IncludeWaveGroups -or $Method -ne 'GET') { throw 'Unexpected Graph use.' }
    $fixtureGraphCalls.Add($Uri)
    $device1 = '00000000-0000-0000-0000-000000000011'
    $device2 = '00000000-0000-0000-0000-000000000012'
    $device3 = '00000000-0000-0000-0000-000000000013'
    if ($Uri.StartsWith('https://graph.microsoft.com/v1.0/groups?', [StringComparison]::Ordinal)) {
        $decoded = [uri]::UnescapeDataString($Uri)
        if ($decoded -notmatch "displayName eq '([^']+)'") { throw 'Expected an exact rollout group lookup.' }
        $name = $Matches[1]
        $fixtureGroupNames.Add($name)
        $group = @{id=('00000000-0000-0000-0000-{0:d12}' -f (100 + $fixtureGroupNames.Count));displayName=$name}
        if ($Scenario -eq 'GraphAllGroupsMissing' -or ($Scenario -in @('GraphMissingGroup','GraphMissingGroupAllMatched') -and $fixtureGroupNames.Count -eq 3)) { return @{value=@()} }
        if ($Scenario -eq 'GraphDuplicateGroup' -and $fixtureGroupNames.Count -eq 3) { return @{value=@($group,$group)} }
        if ($Scenario -eq 'GraphMalformedPage') { return @{} }
        if ($Scenario -eq 'GraphForeignPage') { return @{value=@($group);'@odata.nextLink'='https://example.invalid/not-graph'} }
        if ($Scenario -eq 'GraphRepeatedPage') { return @{value=@($group);'@odata.nextLink'=$Uri} }
        return @{value=@($group)}
    }
    if ($Uri -like '*/transitiveMembers/microsoft.graph.device?*') {
        if ($Headers.ConsistencyLevel -ne 'eventual') { throw 'Missing advanced-query consistency header.' }
        if ($Scenario -eq 'GraphFailure') { throw 'Synthetic rollout membership lookup failure.' }
        if ($Scenario -eq 'GraphMissingMemberId') { return @{value=@(@{})} }
        if ($Uri -like '*/00000000-0000-0000-0000-000000000101/*') {
            return @{value=@(@{id=$device1});'@odata.nextLink'='https://graph.microsoft.com/v1.0/fixture-members-next'}
        }
        if ($Uri -like '*/00000000-0000-0000-0000-000000000102/*') {
            if ($Scenario -eq 'GraphMissingGroupAllMatched') { return @{value=@(@{id=$device2},@{id=$device3})} }
            return @{value=@(@{id=$device2})}
        }
        if ($Scenario -eq 'MultipleGroups' -and $Uri -like '*/00000000-0000-0000-0000-000000000105/*') { return @{value=@(@{id=$device1})} }
        return @{value=@()}
    }
    if ($Uri -eq 'https://graph.microsoft.com/v1.0/fixture-members-next') { return @{value=@(@{id=$device1})} }
    if ($Uri -like 'https://graph.microsoft.com/v1.0/devices?*') {
        return @{
            value=@(@{id=$device1;displayName='fixture-pc1'},@{id=$device2;displayName='FIXTURE-PC2'})
            '@odata.nextLink'='https://graph.microsoft.com/v1.0/fixture-devices-next'
        }
    }
    if ($Uri -eq 'https://graph.microsoft.com/v1.0/fixture-devices-next') {
        if ($Scenario -eq 'MissingEntraDevice') { return @{value=@()} }
        $devices = @(@{id=$device3;displayName='Fixture-PC3'})
        if ($Scenario -eq 'DuplicateEntraName') { $devices += @{id='00000000-0000-0000-0000-000000000014';displayName='Fixture-PC1'} }
        return @{value=$devices}
    }
    throw "Unexpected Graph URI in offline Cloud Update fixture: $Uri"
}
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $TimeoutSec)
    $fixtureCalls.Add($Uri)
    if ($Method -ne 'Get') { throw 'Cloud Update reporting must be read only.' }
    if ($Uri -like 'https://config.office.com/releases/*') {
        return @{
            buildVersion=@{buildVersionString='16.0.10000.10000'};releaseVersion='2601'
            availabilityDate='2026-01-01';endOfSupportDate='2026-04-01';kbLink='https://example.invalid/release'
        }
    }
    if ($Uri -like '*GetUpdateProgressSummaryByChannel*') {
        if ($Scenario -eq 'ApiFailure') { throw 'Synthetic Office API failure.' }
        return @{
            totalNumberOfDevices=$(if ($Scenario -eq 'Empty') { 0 } else { 3 })
            summary=@(@{
                targetChannel='MonthlyEnterpriseChannel'
                updateStatusSummary=@(
                    @{updateStatus='Completed';numberOfDevices=$(if ($Scenario -eq 'Empty') { 0 } else { 1 })}
                    @{updateStatus='InProgress';numberOfDevices=$(if ($Scenario -eq 'Empty') { 0 } else { 1 })}
                    @{updateStatus='Failed';numberOfDevices=$(if ($Scenario -eq 'Empty') { 0 } else { 1 })}
                )
            })
        }
    }
    if ($Uri -notlike '*DevicesWithCloudManagementInfo*') { throw "Unexpected offline URI: $Uri" }
    $rows = @(
        foreach ($index in 1..3) {
            @{
                deviceId="fixture-$index";name=$(if ($Scenario -eq 'DuplicateOfficeName' -and $index -eq 2) { 'Fixture-PC1' } else { "Fixture-PC$index" });lastSeen='2026-01-15'
                officeReleaseVersion='2512';officeBuildVersion='16.0.9999.10000'
                targetVersion='16.0.10000.10000';currentVersion='16.0.9999.10000'
                waveId=$index;targetChannel='MonthlyEnterpriseChannel';updateStatus=@('Completed','InProgress','Failed')[$index-1]
                lastError=$(if ($index -eq 3) { '50006' } else { '' });deviceCheckinOn='2026-01-15'
                aadUserDisplayName='Fixture User';aadUserName='fixture@example.invalid'
                cloudManagement='ManagedByMEC';isExcluded=$false;isProfileEnabled=$true
                osReleaseVersion='25H2';osBuildVersion='10.0.00000';manufacturer='Fixture';model='Fixture model'
                freeDiskSpaceInGigabytes=100;totalDiskSpaceInGigaBytes=200;totalRamInGigaBytes=16
            }
        }
    )
    $pageRows = if ($Scenario -eq 'Empty' -or ($Scenario -eq 'PagingFailure' -and $Uri -like '*$skip=2*')) { @() }
        elseif ($Uri -like '*$skip=0*') { @($rows[0], $rows[1]) }
        else { @($rows[2]) }
    @{'@odata.count'=$(if ($Scenario -eq 'Empty') { 0 } else { 3 });value=@($pageRows)}
}
function Export-Csv {
    param($Path, [switch]$NoTypeInformation, $Encoding, [Parameter(ValueFromPipeline)]$InputObject)
    begin { $fixtureExportRows = [Collections.Generic.List[object]]::new() }
    process { $fixtureExportRows.Add($InputObject) }
    end {
        if ($Scenario -eq 'ExportFailure' -and $Path -like '*FullInventory*') { throw 'Synthetic inventory export failure.' }
        $fixtureExportRows | Microsoft.PowerShell.Utility\Export-Csv -Path $Path -NoTypeInformation -Encoding $Encoding
    }
}
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$scriptPath = Join-Path (Split-Path $desktop -Parent) 'entra\Get-M365CloudUpdateReport.ps1'
$parameters = @{PageSize=2;NoExport=[bool]$NoExport}
if ($IncludeWaveGroups) { $parameters.IncludeWaveGroups = $true; $parameters.WaveGroupNames = @(1..7 | ForEach-Object { "Fixture.Rollout.Group$_" }) }
if ($OutputRoot) { $parameters.ExportFolder = $OutputRoot }
$sink = if ($Capture) { { param($event) $fixtureEvents.Add($event) } } else { $UiEventSink }
$fixtureError = $null
$fixtureOutput = @()
try {
    if ($Direct) { $fixtureOutput = @(& $scriptPath @parameters -WarningVariable fixtureWarnings) }
    else {
        $fixtureOutput = @(& (Join-Path $desktop 'Invoke-WorkflowPresentation.ps1') -ScriptPath $scriptPath -WorkflowId 'm365-cloud-update' -ScriptArguments $parameters -UiEventSink $sink -WarningVariable fixtureWarnings)
    }
}
catch {
    if (-not $Capture) { throw }
    $fixtureError = $_
}
if ($Capture) {
    [pscustomobject]@{Events=$fixtureEvents.ToArray();Calls=$fixtureCalls.ToArray();GraphCalls=$fixtureGraphCalls.ToArray();GroupNames=$fixtureGroupNames.ToArray();Warnings=$fixtureWarnings;Output=$fixtureOutput;Error=$fixtureError}
}
