[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][object[]]$Charts,
    [ValidateSet('Light','Dark','CatppuccinMocha','GruvboxDark')][string]$Theme = 'Light',
    [Func[bool]]$CancellationCheck,
    [scriptblock]$UiEventSink
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $PSScriptRoot 'EndpointToolboxUI.psm1') -Force
& (Get-Module EndpointToolboxUI) {
    param($Path, $Title, $Charts, $Theme, $CancellationCheck)
    Export-EndpointReportVisualPng -Path $Path -Title $Title -Charts $Charts -Theme $Theme -CancellationCheck $CancellationCheck
} $Path $Title $Charts $Theme $CancellationCheck
if ($UiEventSink) {
    & $UiEventSink ([pscustomobject]@{ Type='Artifact'; Name='Visual summary PNG'; Data=$Path }) | Out-Null
}
Write-Host 'Visual summary PNG saved. Find the image under Saved reports.'
