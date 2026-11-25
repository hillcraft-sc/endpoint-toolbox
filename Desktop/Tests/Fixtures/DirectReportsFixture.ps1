[CmdletBinding()]
param(
    [string]$Scenario = 'Happy',
    [string]$Manager = 'Example Manager',
    [switch]$Preview,
    [switch]$Prompt,
    [switch]$Capture,
    [switch]$Direct,
    [scriptblock]$UiEventSink
)
$fixtureCalls = [Collections.Generic.List[object]]::new()
$fixtureEvents = [Collections.Generic.List[object]]::new()
$fixtureManager = @{
    id='00000000-0000-0000-0000-000000000001'
    displayName='Manager, Example'; userPrincipalName='manager@example.invalid'
    givenName='Example'; surname='Manager'
}
if ($Scenario -eq 'Whitespace') {
    $fixtureManager.givenName = " Example`t "
    $fixtureManager.surname = ' Manager '
}
if ($Scenario -eq 'MissingId') { $fixtureManager.id = '' }
if ($Scenario -eq 'MissingFirstName') { $fixtureManager.givenName = $null }
if ($Scenario -eq 'MissingLastName') { $fixtureManager.surname = " `t " }
if ($Scenario -eq 'LongName') { $fixtureManager.givenName = 'M' * 257 }
function Get-MgContext { @{AuthType='Delegated';Environment='Global'} }
function Connect-MgGraph { throw 'Offline fixture must not sign in.' }
function Invoke-MgGraphRequest {
    param($Method,$Uri,$Body,$ContentType,$OutputType)
    $fixtureCalls.Add([pscustomobject]@{Method=$Method;Uri=$Uri;Body=$Body;ContentType=$ContentType})
    if ($Method -eq 'POST') {
        if ($UiEventSink) { & $UiEventSink ([pscustomobject]@{Type='Stage';Name='Group POST';Data='Synthetic create only'}) | Out-Null }
        if ($Scenario -eq 'CreateFailure') { throw 'Synthetic create failure.' }
        if ($Scenario -eq 'MissingCreateId') { return @{} }
        return @{id='00000000-0000-0000-0000-000000000003'}
    }
    if ($Uri -like '*/users?*') {
        if ($Scenario -eq 'NotFound') { return @{value=@()} }
        if ($Scenario -eq 'LookupFailure') { throw 'Synthetic lookup failure.' }
        if ($Scenario -eq 'Malformed') { return @{} }
        if ($Scenario -eq 'PagedDuplicate') { return @{value=@($fixtureManager);'@odata.nextLink'='https://graph.microsoft.com/v1.0/next'} }
        if ($Scenario -eq 'ForeignPage') { return @{value=@($fixtureManager);'@odata.nextLink'='https://example.invalid/next'} }
        return @{value=@($fixtureManager)}
    }
    if ($Uri -eq 'https://graph.microsoft.com/v1.0/next') { return @{value=@($fixtureManager)} }
    if ($Uri -like '*/groups?*') {
        if ($Scenario -eq 'Existing') { return @{value=@(@{id='existing'})} }
        return @{value=@()}
    }
    if ($Uri -like '*/me?*') {
        if ($Scenario -eq 'MissingCreator') { return @{} }
        return @{id='00000000-0000-0000-0000-000000000002';userPrincipalName='creator@example.invalid'}
    }
    throw "Unhandled synthetic Graph request: $Method $Uri"
}
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$scriptPath = Join-Path (Split-Path $desktop -Parent) 'entra\New-EntraDirectReportsGroup.ps1'
$parameters = @{Manager=$Manager;WhatIf=[bool]$Preview}
if (-not $Prompt) { $parameters.Confirm = $false }
$sink = if ($Capture) { { param($event) $fixtureEvents.Add($event) } } else { $UiEventSink }
$fixtureError = $null
$fixtureOutput = @()
try {
    if ($Direct) { $fixtureOutput = @(& $scriptPath @parameters) }
    else {
        $fixtureOutput = @(& (Join-Path $desktop 'Invoke-WorkflowPresentation.ps1') -ScriptPath $scriptPath -WorkflowId 'create-direct-reports-group' -ScriptArguments $parameters -UiEventSink $sink)
    }
}
catch {
    if (-not $Capture) { throw }
    $fixtureError = $_
}
if ($Capture) {
    [pscustomobject]@{Calls=$fixtureCalls.ToArray();Events=$fixtureEvents.ToArray();Output=$fixtureOutput;Error=$fixtureError}
}
