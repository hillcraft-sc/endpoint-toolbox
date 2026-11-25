[CmdletBinding()]
param(
    [string]$WorkflowId,
    [scriptblock]$UiEventSink
)

function Get-MgContext { [pscustomobject]@{ Account = 'fixture@example.invalid' } }
function Invoke-MgGraphRequest {
    param($Method, $Uri)
    if ($Uri -match '/deviceHealthScripts\?') {
        return @{ value = @(
            [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000013'; displayName = 'Alpha remediation'; createdDateTime = '2026-01-01T00:00:00Z' }
            [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000014'; displayName = 'Beta remediation'; createdDateTime = '2026-01-02T00:00:00Z' }
        ) }
    }
    if ($Uri -like '*/deviceRunStates*') {
        & $UiEventSink ([pscustomobject]@{ Type = 'Stage'; Name = 'Selected run-state endpoint'; Data = $Uri }) | Out-Null
        return @{ value = @() }
    }
    throw "Unexpected Graph request in selection fixture: $Uri"
}

$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$catalog = Import-PowerShellDataFile (Join-Path $desktop 'WorkflowCatalog.psd1')
$workflow = $catalog.Workflows | Where-Object Id -eq $WorkflowId
$outputPath = Join-Path $env:TEMP "EndpointToolbox-script-selection-$([guid]::NewGuid())"
try {
    & (Join-Path $desktop 'Invoke-WorkflowPresentation.ps1') `
        -ScriptPath (Join-Path (Split-Path $desktop -Parent) $workflow.Path) `
        -WorkflowId $WorkflowId `
        -ScriptArguments @{ ScriptType = 'Remediation'; OutputPath = $outputPath } `
        -UiEventSink $UiEventSink
}
finally {
    if (Test-Path -LiteralPath $outputPath) {
        Get-ChildItem -LiteralPath $outputPath -File | Remove-Item -Force
        Remove-Item -LiteralPath $outputPath
    }
}
