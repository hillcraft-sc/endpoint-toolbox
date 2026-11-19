# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

[CmdletBinding()]
param(
    [string]$WorkflowId,
    [scriptblock]$UiEventSink
)
$fixtureApps = @(
    @{id='00000000-0000-0000-0000-000000000001';displayName='Fixture App';displayVersion='1.0';createdDateTime='2026-01-01';'@odata.type'='#microsoft.graph.win32LobApp'}
    @{id='00000000-0000-0000-0000-000000000002';displayName='Fixture App';displayVersion='2.0';createdDateTime='2026-02-01';'@odata.type'='#microsoft.graph.win32LobApp'}
)
function Get-MgContext { @{Account='fixture@example.invalid'} }
function Invoke-MgGraphRequest {
    param($Method, $Uri, $Body, $Headers, $ContentType)
    if ($Method -eq 'GET') {
        if ($Uri -like '*/assignments') { return @{value=@()} }
        return @{value=$fixtureApps}
    }
    if ($Method -eq 'POST' -and $Uri -like '*exportJobs') {
        & $UiEventSink ([pscustomobject]@{ Type='Stage'; Name='Requested report'; Data=$Body }) | Out-Null
        throw 'Synthetic export stop: no download or tenant operation was performed.'
    }
    throw "Unexpected Graph request in fixture: $Method $Uri"
}
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$catalog = Import-PowerShellDataFile (Join-Path $desktop 'WorkflowCatalog.psd1')
$workflow = $catalog.Workflows | Where-Object Id -eq $WorkflowId
$parameters = @{AppName=$(if ($WorkflowId -eq 'delete-win32-apps') { 'Fixture*' } else { 'Fixture' })}
if ($WorkflowId -eq 'delete-win32-apps') {
    $parameters.WhatIf=$true; $parameters.Justification='Synthetic selection fixture'
    $parameters.OutputPath=Join-Path $env:TEMP "EndpointToolbox-selection-$([guid]::NewGuid())"
}
else { $parameters.OutputPath=$env:TEMP }
try {
    & (Join-Path $desktop 'Invoke-WorkflowPresentation.ps1') -ScriptPath (Join-Path (Split-Path $desktop -Parent) $workflow.Path) -WorkflowId $WorkflowId -ScriptArguments $parameters -UiEventSink $UiEventSink
}
finally {
    if ($WorkflowId -eq 'delete-win32-apps' -and (Test-Path -LiteralPath $parameters.OutputPath)) {
        Get-ChildItem -LiteralPath $parameters.OutputPath -File | Remove-Item -Force
        Remove-Item -LiteralPath $parameters.OutputPath
    }
}
