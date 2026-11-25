$ErrorActionPreference = 'Stop'
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$xml = [xml](Get-Content -LiteralPath (Join-Path $desktop 'MainWindow.xaml') -Raw)
$window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
$controls = @{}
foreach ($node in $xml.SelectNodes('//*[@Name]')) {
    $name = $node.GetAttribute('Name')
    $controls[$name] = $window.FindName($name)
}
$workflow = Get-EndpointCatalog | Where-Object Id -eq 'm365-cloud-update'
$null = $controls.WorkflowList.Items.Add($workflow)
$controls.WorkflowList.SelectedItem = $workflow

& (Get-Module EndpointToolboxUI) {
    param($Window, $Controls, $Workflow)
    $script:Ui = @{
        Window = $Window; Controls = $Controls; Workflow = $null; GraphContext = $null
        Remote = [pscustomobject]@{ Connected = $false }; Active = $null; Faulted = $false
        FieldControls = @{}; FieldRows = @{}; Selectors = @(); Inactive = @()
        ScriptPicker = $null; LogRoot = ''
    }
    $root = Join-Path $env:TEMP "EndpointToolbox-cloud-settings-$([guid]::NewGuid())"
    $path = Join-Path $root 'settings.json'
    try {
        Set-EndpointTheme $Window Light
        New-EndpointForm
        if ($script:Ui.FieldControls.ContainsKey('WaveGroupNames')) { throw 'Group names should be managed in Settings, not the workflow form.' }
        if (@(Get-EndpointCloudUpdateGroups $path).Count -ne 0) { throw 'New users must start without configured groups.' }
        $script:Ui.FieldControls.IncludeWaveGroups.IsChecked = $true
        $arguments = Get-EndpointArguments $Workflow @{ IncludeWaveGroups = $true }
        $rejected = $false
        try { Set-EndpointCloudUpdateGroupsArgument $arguments $path } catch { $rejected = $_.Exception.Message -like '*Settings > Cloud Update*' }
        if (-not $rejected) { throw 'Missing saved groups did not block the optional lookup with guidance.' }
        $saved = @(Save-EndpointCloudUpdateGroups $path " Fixture.Custom.CloudPC `r`nFixture.Custom.Pilot`r`nfixture.custom.pilot")
        if (($saved -join '|') -ne 'Fixture.Custom.CloudPC|Fixture.Custom.Pilot') { throw 'Saved group names were not normalized and deduplicated.' }
        Set-EndpointCloudUpdateGroupsArgument $arguments $path
        if (($arguments.WaveGroupNames -join '|') -ne 'Fixture.Custom.CloudPC|Fixture.Custom.Pilot') { throw 'Saved group names were not bound to the script arguments.' }
        $null = @(Save-EndpointCloudUpdateGroups $path 'Fixture.Only')
        $single = @{IncludeWaveGroups=$true}
        Set-EndpointCloudUpdateGroupsArgument $single $path
        if ($single.WaveGroupNames.Count -ne 1 -or $single.WaveGroupNames[0] -ne 'Fixture.Only') { throw 'A single saved group was not bound as an array.' }
        Set-Content -LiteralPath $path -Value '{invalid json'
        $rejected = $false
        try { Set-EndpointCloudUpdateGroupsArgument @{ IncludeWaveGroups=$true } $path } catch { $rejected = $_.Exception.Message -like '*could not be loaded*' }
        if (-not $rejected) { throw 'Corrupt settings were silently accepted.' }
        $script:Ui.FieldControls.IncludeWaveGroups.IsChecked = $false
        Set-EndpointCloudUpdateGroupsArgument @{} $path
        $rejected = $false
        try { $null = @(Save-EndpointCloudUpdateGroups $path '') } catch { $rejected = $true }
        if (-not $rejected -or (Get-Content -LiteralPath $path -Raw).Trim() -ne '{invalid json') {
            throw 'Saving groups silently overwrote corrupt shared settings.'
        }
        Remove-Item -LiteralPath $path -ErrorAction Stop
        $null = @(Save-EndpointCloudUpdateGroups $path '')
        if (@(Get-EndpointCloudUpdateGroups $path).Count) { throw 'Cleared groups were not saved as an empty list.' }
        'Cloud Update saved group settings and optional switch behavior passed.'
    }
    finally {
        $Window.Close()
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
} $window $controls $workflow
