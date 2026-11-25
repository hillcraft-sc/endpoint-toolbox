[CmdletBinding()]
param([string]$SnapshotDirectory, [switch]$SettingsOnly)
$ErrorActionPreference = 'Stop'
if ($SnapshotDirectory -and -not (Test-Path -LiteralPath $SnapshotDirectory -PathType Container)) { throw 'Snapshot directory must exist.' }
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
if ($SettingsOnly) {
    & (Get-Module EndpointToolboxUI) {
        param($desktop)
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs')
        $window = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((Join-Path $desktop 'MainWindow.xaml')))
        $controls = @{}
        foreach ($node in ([xml](Get-Content -LiteralPath (Join-Path $desktop 'MainWindow.xaml') -Raw)).SelectNodes('//*[@Name]')) {
            $name = $node.GetAttribute('Name'); $controls[$name] = $window.FindName($name)
        }
        $table = [Data.DataTable]::new('Fixture report')
        $null = $table.Columns.Add('Value'); $null = $table.Rows.Add('Preserved report row')
        $controls.ResultsGrid.ItemsSource = $table.DefaultView
        $null = $controls.DatasetSelector.Items.Add('Fixture report')
        $controls.DatasetSelector.SelectedItem = 'Fixture report'
        $script:Ui = @{
            Window=$window; Controls=$controls; Settings=$null; Workflow=$null; Active=$null
            Datasets=@{'Fixture report'=$table}; LogRoot=''; HistoryPath=''; RemoteSettingsPath=''; TestMode=$true
            Graph=[EndpointToolbox.DesktopEngine]::new(); Remote=[EndpointToolbox.DesktopEngine]::new()
        }
        $controls.SettingsButton.Add_Click({ Show-EndpointSettings })
    } $desktop
}
else { Start-EndpointToolboxUI -SmokeTest | Format-List }
& (Get-Module EndpointToolboxUI) {
    param($SnapshotDirectory, $SettingsOnly)
    $ui = $script:Ui
    $fakeEngine = [pscustomobject]@{ Cancelled=$false }
    $fakeEngine | Add-Member -MemberType ScriptMethod -Name Cancel -Value { $this.Cancelled=$true }
    $ui.Active = [pscustomobject]@{ WorkflowId='delete-win32-apps'; Engine=$fakeEngine }
    $ui.Window.Show()
    try {
        $ui.Active=$null
        if (-not $SettingsOnly) {
        $ui.Controls.WorkflowList.SelectedItem=$ui.Catalog | Where-Object Id -eq 'device-usage'
        $ui.FieldControls.Devices.Text='Synthetic-PC'
        $originalForm=$ui.Controls.Form.Children[0]
        $ui.Controls.HomeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if ($ui.Controls.HomePanel.Visibility -ne 'Visible') { throw 'The sidebar Home button did not open Home.' }
        $ui.Controls.ReturnToTaskButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if ($ui.Controls.TaskPanel.Visibility -ne 'Visible' -or $ui.FieldControls.Devices.Text -ne 'Synthetic-PC' -or $ui.Controls.Form.Children[0] -ne $originalForm) { throw 'Returning from Home rebuilt or lost task inputs.' }
        $ui.Controls.HomeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $keyEvent=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($ui.Window),0,[Windows.Input.Key]::Return)
        $keyEvent.RoutedEvent=[Windows.Input.Keyboard]::KeyDownEvent
        $ui.Controls.WorkflowList.RaiseEvent($keyEvent)
        if ($ui.Controls.TaskPanel.Visibility -ne 'Visible') { throw 'Enter on the selected sidebar task did not leave Home.' }
        'Native Home navigation and preserved task inputs passed.'
        $ui.Controls.WorkflowList.SelectedItem=$ui.Catalog | Where-Object Id -eq 'intune-script-device-status'
        $scriptPicker=$ui.ScriptPicker
        if (-not $scriptPicker -or $ui.Controls.RunButton.IsEnabled) { throw 'The script status report became runnable before a script was selected.' }
        Set-EndpointScriptChoices ([pscustomobject]@{
            ScriptType='All'
            Choices=@(
                [pscustomobject]@{Id='00000000-0000-0000-0000-000000000001';ScriptType='Remediation';DisplayName='Alpha remediation';Display='Remediation | Alpha remediation'}
                [pscustomobject]@{Id='00000000-0000-0000-0000-000000000002';ScriptType='Platform script';DisplayName='Beta platform script';Display='Platform script | Beta platform script'}
            )
        })
        $scriptPicker.Search.Text='Beta'
        if ($scriptPicker.List.Items.Count -ne 1 -or $scriptPicker.List.Items[0].DisplayName -ne 'Beta platform script') { throw 'The form-level script search did not filter the loaded scripts.' }
        $scriptPicker.List.SelectedIndex=0
        if (-not $ui.Controls.RunButton.IsEnabled -or $scriptPicker.Selected.Id -ne '00000000-0000-0000-0000-000000000002') { throw 'Selecting a loaded script did not enable the report for the selected item.' }
        $scriptPicker.TypeControl.SelectedItem='Remediation'
        if ($scriptPicker.Selected -or $scriptPicker.List.Items.Count -ne 0 -or $ui.Controls.RunButton.IsEnabled) { throw 'Changing script type retained a stale selection.' }
        'Native pre-run script loading, filtering, selection and type reset passed.'
        $ui.Controls.WorkflowList.SelectedItem=$ui.Catalog | Where-Object Id -eq 'quality-updates'
        $policyPicker=$ui.ScriptPicker
        if ($ui.Controls.RunButton.IsEnabled -or $policyPicker.Load.Content -ne 'Load policies' -or
            $ui.FieldControls.ContainsKey('PolicyName')) { throw 'Expedited quality updates did not require a policy from the picker.' }
        Set-EndpointScriptChoices ([pscustomobject]@{
            ScriptType='Policies'
            Choices=@(
                [pscustomobject]@{Id='00000000-0000-0000-0000-000000000021';ScriptType='';DisplayName='Fixture January';Display='Fixture January'}
                [pscustomobject]@{Id='00000000-0000-0000-0000-000000000022';ScriptType='';DisplayName='Fixture February';Display='Fixture February'}
            )
        })
        $policyPicker.Search.Text='feb'
        if ($policyPicker.List.Items.Count -ne 1 -or $ui.Controls.RunButton.IsEnabled) { throw 'Filtering policy choices should not select a policy automatically.' }
        $policyPicker.List.SelectedIndex=0
        if (-not $ui.Controls.RunButton.IsEnabled -or $policyPicker.Selected.Id -ne '00000000-0000-0000-0000-000000000022') { throw 'Selecting the filtered policy did not enable the report.' }
        $policyPicker.Search.Text='January'
        if ($ui.Controls.RunButton.IsEnabled) { throw 'The report remained runnable after the selected policy was filtered out.' }
        'Native pre-run expedited policy picker passed.'
        $ui.Controls.WorkflowList.SelectedItem=$ui.Catalog | Where-Object Id -eq 'm365-cloud-update'
        if ($ui.FieldControls.ContainsKey('WaveGroupNames')) { throw 'The Cloud Update workflow exposes a group list outside Settings.' }
        $ui.FieldControls.IncludeWaveGroups.IsChecked=$true
        $values=@{}
        foreach ($field in $ui.Workflow.Fields) {
            $control=$ui.FieldControls[$field.Name]
            $values[$field.Name]=if ($field.Type -eq [switch]) { [bool]$control.IsChecked } else { $control.Text }
        }
        $arguments=Get-EndpointArguments $ui.Workflow $values
        if (-not $arguments.IncludeWaveGroups -or $arguments.ContainsKey('WaveGroupNames')) { throw 'The optional switch did not bind independently of the saved settings.' }
        $ui.FieldControls.IncludeWaveGroups.IsChecked=$false
        if ($ui.FieldControls.IncludeWaveGroups.IsChecked) { throw 'Rollout group membership could not be disabled.' }
        'Native Cloud Update group list form passed.'
        $ui.Controls.WorkflowList.SelectedItem=$ui.Catalog | Where-Object Id -eq 'device-usage'
        $ui.Controls.RemoteTab.Visibility='Visible'
        $ui.Controls.OutputTab.IsSelected=$true
        $ui.Controls.RemoteTab.IsSelected=$true
        $beforeOutput=$ui.Controls.RemoteOutput.Text
        $beforeActivity=$ui.Controls.Activity.Text
        $commands = @(Get-EndpointRemoteCommands)
        if ($ui.Controls.RemoteCommandPicker.Items.Count -ne $commands.Count) { throw 'The saved-command dropdown is incomplete.' }
        foreach ($command in $ui.Controls.RemoteCommandPicker.Items) {
            $ui.Controls.RemoteCommandPicker.SelectedItem=$command
            if ($ui.Controls.RemoteCommand.Text -cne $command.Command) { throw "Command text changed for $($command.Name)." }
            if ($ui.Controls.RemoteCommandDescription.Text -cne $command.Description) { throw "Description missing for $($command.Name)." }
            if ($ui.Active -or $ui.Remote.Busy -or $ui.Controls.SendCommandButton.IsEnabled) { throw 'Selecting a saved command started execution or bypassed connection requirements.' }
        }
        $ui.Controls.RemoteCommand.Text='Write-Output "Manually edited command"'
        if ($ui.Controls.RemoteCommand.IsReadOnly -or $ui.Controls.RemoteCommand.Text -ne 'Write-Output "Manually edited command"') { throw 'The remote command editor no longer permits custom commands.' }
        if ($ui.Controls.RemoteOutput.Text -cne $beforeOutput -or $ui.Controls.Activity.Text -cne $beforeActivity) { throw 'Saved command selection generated output or activity records.' }
        'Native saved remote command selection and editable text passed.'
        $ui.Graph = [EndpointToolbox.DesktopEngine]::new()
        $ui.Remote = [EndpointToolbox.DesktopEngine]::new()
        $ui.Graph.FormatPipelineOutput = $true
        $ui.Remote.FormatPipelineOutput = $true
        $ui.Graph.Host.PrepareReportTables = $true
        $ui.Remote.Host.PrepareReportTables = $true
        $previousSummary=$ui.Controls.RunSummary.Text
        $previousTiming=$ui.Controls.RunTiming.Text
        $previousDatasets=$ui.Datasets
        $graphFixture=Join-Path $PSScriptRoot 'GraphSessionFixture.ps1'
        foreach ($operation in @(
            @{Path=$graphFixture;Arguments=@{Mode='Bootstrap'};WithSink=$false}
            @{Path=(Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) 'Invoke-GraphSession.ps1');Arguments=@{Action='Connect'};WithSink=$true}
        )) {
            $ui.Active=[pscustomobject]@{Engine=$ui.Graph;WorkflowId='graph-session-connect';Start=[datetime]::UtcNow;RunId=[guid]::NewGuid().ToString();Failures=$false;Warnings=$false;PendingApproval=$false;IsRemote=$false;Completed=$false;State=''}
            $ui.Graph.RunFile($operation.Path,$operation.Arguments,$operation.WithSink)
            $deadline=[datetime]::UtcNow.AddSeconds(15)
            while ($ui.Active -and [datetime]::UtcNow -lt $deadline) { Receive-EndpointEvents; Start-Sleep -Milliseconds 10 }
            if ($ui.Active -or $ui.Faulted -or $ui.Graph.HasErrors) { throw 'The offline Home connection did not complete through the native UI event loop.' }
        }
        if ($ui.GraphSession.State -ne 'Checked' -or $ui.Controls.GraphSessionDetails.Text -notmatch 'fixture@example.invalid' -or $ui.Controls.GraphSessionDetails.Text -notmatch 'Intune Administrator') { throw 'Home did not display the live connection snapshot and active role.' }
        if ($ui.Controls.RunSummary.Text -cne $previousSummary -or $ui.Controls.RunTiming.Text -cne $previousTiming -or $ui.Datasets -ne $previousDatasets) { throw 'A Home connection check overwrote the prior task results or summary.' }
        if (-not $ui.Controls.GraphCheckButton.IsEnabled) { throw 'Home actions were not reenabled after connection completed.' }
        'Native Home connection events and preserved report state passed.'
        }
        $savedHistoryPath = $ui.HistoryPath
        $savedRemoteSettingsPath = $ui.RemoteSettingsPath
        $savedThemePath = if ($ui.ContainsKey('ThemePath')) { $ui.ThemePath } else { '' }
        $savedCloudUpdateSettingsPath = if ($ui.ContainsKey('CloudUpdateSettingsPath')) { $ui.CloudUpdateSettingsPath } else { '' }
        $historyRoot = Join-Path $env:TEMP "EndpointToolbox-settings-$([guid]::NewGuid())"
        $null = New-Item -Path $historyRoot -ItemType Directory
        $ui.HistoryPath = Join-Path $historyRoot 'history.jsonl'
        $ui.ThemePath = Join-Path $historyRoot 'settings.json'
        $ui.RemoteSettingsPath = $ui.ThemePath
        $ui.CloudUpdateSettingsPath = $ui.ThemePath
        $savedLogRoot = $ui.LogRoot
        $ui.LogRoot = ''
        $reportState = @{
            Datasets=$ui.Datasets; Selected=$ui.Controls.DatasetSelector.SelectedItem
            Grid=$ui.Controls.ResultsGrid.ItemsSource; Filter=$ui.Controls.ResultFilter.Text
            Summary=$ui.Controls.RunSummary.Text; Timing=$ui.Controls.RunTiming.Text
            Home=$ui.Controls.HomePanel.Visibility; Task=$ui.Controls.TaskPanel.Visibility
            Output=$ui.Controls.OutputTab.IsSelected; Results=$ui.Controls.ResultsTab.IsSelected
            Remote=$ui.Controls.RemoteTab.IsSelected
        }
        function Assert-SettingsPreservesReport {
            if (-not [object]::ReferenceEquals($ui.Datasets, $reportState.Datasets) -or $ui.Datasets.ContainsKey('Run history') -or
                $ui.Controls.DatasetSelector.SelectedItem -ne $reportState.Selected -or
                -not [object]::ReferenceEquals($ui.Controls.ResultsGrid.ItemsSource, $reportState.Grid) -or
                $ui.Controls.ResultFilter.Text -cne $reportState.Filter -or
                $ui.Controls.RunSummary.Text -cne $reportState.Summary -or $ui.Controls.RunTiming.Text -cne $reportState.Timing -or
                $ui.Controls.HomePanel.Visibility -ne $reportState.Home -or $ui.Controls.TaskPanel.Visibility -ne $reportState.Task -or
                $ui.Controls.OutputTab.IsSelected -ne $reportState.Output -or $ui.Controls.ResultsTab.IsSelected -ne $reportState.Results -or
                $ui.Controls.RemoteTab.IsSelected -ne $reportState.Remote) { throw 'Settings overwrote report data, summary or workspace navigation.' }
        }
        try {
            $script:FixtureConfirm = $false
            function script:Confirm-EndpointAction { param($Owner, $Message, $Title) return $script:FixtureConfirm }
            foreach ($name in @('HistoryButton','ClearHistoryButton','OpenActivityLogsButton')) {
                if ($ui.Window.FindName($name)) { throw "The old sidebar control remains: $name." }
            }
            if ([Windows.Automation.AutomationProperties]::GetName($ui.Controls.SettingsButton) -ne 'Settings' -or -not $ui.Controls.SettingsButton.ToolTip) { throw 'The gear button lacks an accessible name or tooltip.' }
            $ui.Controls.SettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            $settings = $ui.Settings
            $settings.Window.UpdateLayout()
            if ($settings.Window.Owner -ne $ui.Window -or -not $settings.Window.IsVisible -or -not $settings.Controls.HistoryTab.IsSelected) { throw 'The gear did not open the owned settings History tab.' }
            if (-not $settings.Controls.RemoteTab -or -not $settings.Controls.DnsSuffixBox -or
                [Windows.Automation.AutomationProperties]::GetName($settings.Controls.DnsSuffixBox) -ne 'DNS suffix') { throw 'The remote DNS suffix setting is missing or inaccessible.' }
            if (-not $settings.Controls.GraphTab -or -not $settings.Controls.TenantIdBox -or
                [Windows.Automation.AutomationProperties]::GetName($settings.Controls.TenantIdBox) -ne 'Default tenant ID or domain' -or
                -not [Windows.Automation.AutomationProperties]::GetLabeledBy($settings.Controls.TenantIdBox)) { throw 'The Graph tenant setting is missing or inaccessible.' }
            if (-not $settings.Controls.CloudUpdateTab -or $settings.Controls.CloudGroupsBox.Text -ne '' -or
                [Windows.Automation.AutomationProperties]::GetName($settings.Controls.CloudGroupsBox) -ne 'Rollout group names' -or
                -not [Windows.Automation.AutomationProperties]::GetLabeledBy($settings.Controls.CloudGroupsBox)) { throw 'The empty Cloud Update group setting is missing or inaccessible.' }
            if ($settings.Controls.HistoryGrid.Items.Count -ne 0 -or $settings.Controls.HistoryStatus.Text -notmatch 'No saved') { throw 'Missing history did not display the empty state.' }
            if (-not $settings.Controls.HistoryGrid.IsReadOnly -or -not $settings.Controls.HistoryGrid.EnableRowVirtualization -or
                [Windows.Controls.VirtualizingPanel]::GetVirtualizationMode($settings.Controls.HistoryGrid) -ne 'Recycling' -or
                $settings.Controls.HistoryGrid.Style -ne $ui.Window.FindResource([Windows.Controls.DataGrid])) { throw 'History does not use the shared virtualized read-only grid style.' }
            if ($settings.Controls.HistoryGrid.SelectionUnit -ne 'Cell' -or $settings.Controls.HistoryGrid.SelectionMode -ne 'Extended' -or
                $settings.Controls.HistoryGrid.ClipboardCopyMode -ne 'ExcludeHeader') { throw 'History does not support copying selected cells without headers.' }
            if ($settings.Controls.HistoryGrid.Columns.Count -ne 6 -or [Windows.Automation.AutomationProperties]::GetName($settings.Controls.HistoryGrid) -ne 'Run history') { throw 'History grid columns or accessible name are incorrect.' }
            foreach ($size in @(@{Width=1000;Height=700},@{Width=1400;Height=940})) {
                $settings.Window.Width=[Math]::Min($size.Width,[Windows.SystemParameters]::WorkArea.Width)
                $settings.Window.Height=[Math]::Min($size.Height,[Windows.SystemParameters]::WorkArea.Height)
                $settings.Window.UpdateLayout()
                if ($settings.Controls.HistoryGrid.ActualHeight -lt 200) { throw 'The dedicated history grid has insufficient space.' }
                $close=$settings.Controls.CloseSettingsButton
                $position=$close.TransformToAncestor($settings.Window.Content).Transform([Windows.Point]::new(0,0))
                if ($position.Y + $close.ActualHeight -gt $settings.Window.Content.ActualHeight + 1) { throw 'Settings close action is clipped.' }
                $settings.Controls.CloudUpdateTab.IsSelected=$true
                $settings.Window.UpdateLayout()
                $save=$settings.Controls.SaveCloudGroupsButton
                $savePosition=$save.TransformToAncestor($settings.Window.Content).Transform([Windows.Point]::new(0,0))
                if (-not $save.IsVisible -or $settings.Controls.CloudGroupsBox.ActualHeight -lt 56 -or
                    $savePosition.Y + $save.ActualHeight -gt $settings.Window.Content.ActualHeight + 1) { throw 'Cloud Update settings controls are clipped or unusable.' }
                $settings.Controls.HistoryTab.IsSelected=$true
            }
            $record = [pscustomobject]@{RunId='fixture-history';WorkflowId='offline-fixture';StartUtc='2026-01-01T00:00:00Z';EndUtc='2026-01-01T00:01:00Z';State='Succeeded';Rows=7}
            $record | ConvertTo-Json -Compress | Set-Content -LiteralPath $ui.HistoryPath
            $settings.Controls.RemoteTab.IsSelected=$true
            $settings.Controls.DnsSuffixBox.Text='bad\suffix'
            $settings.Window.UpdateLayout()
            $settings.Controls.SaveRemoteSettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if ($settings.Controls.RemoteSettingsStatus.Text -notmatch 'DNS suffix' -or
                -not $settings.Controls.DnsSuffixBox.IsKeyboardFocusWithin -or (Test-Path -LiteralPath $ui.RemoteSettingsPath)) {
                throw 'An invalid DNS suffix was not rejected beside the focused setting.'
            }
            $settings.Controls.DnsSuffixBox.Text=' .corp.example.com. '
            $settings.Controls.SaveRemoteSettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if ($settings.Controls.DnsSuffixBox.Text -ne 'corp.example.com' -or
                (Get-EndpointRemoteSettings $ui.RemoteSettingsPath).DnsSuffix -ne 'corp.example.com') { throw 'The remote DNS suffix was not normalized and saved.' }
            $settings.Controls.GraphTab.IsSelected=$true
            $settings.Controls.TenantIdBox.Text='not a tenant'
            $beforeInvalidTenant = Get-Content -LiteralPath $ui.ThemePath -Raw
            $settings.Controls.SaveTenantSettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if ($settings.Controls.TenantSettingsStatus.Text -notmatch 'tenant GUID' -or (Get-Content -LiteralPath $ui.ThemePath -Raw) -cne $beforeInvalidTenant) {
                throw 'An invalid tenant setting was accepted or persisted.'
            }
            $settings.Controls.TenantIdBox.Text='AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'
            $settings.Controls.SaveTenantSettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if ($settings.Controls.TenantIdBox.Text -ne 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -or
                (Get-EndpointTenantPreference $ui.ThemePath) -ne $settings.Controls.TenantIdBox.Text -or
                (Get-EndpointThemePreference $ui.ThemePath) -ne 'Light' -or
                (Get-EndpointGraphTenant '' $ui.ThemePath) -ne 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -or
                (Get-EndpointGraphTenant 'other.example.com' $ui.ThemePath) -ne 'other.example.com') {
                throw 'The tenant setting was not saved, preserved with appearance preferences, or applied as the Home default.'
            }
            $settings.Controls.CloudUpdateTab.IsSelected=$true
            $settings.Controls.CloudGroupsBox.Text="Fixture.Group.One`r`nFixture.Group.Two"
            $settings.Controls.SaveCloudGroupsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if ((@(Get-EndpointCloudUpdateGroups $ui.CloudUpdateSettingsPath) -join '|') -ne 'Fixture.Group.One|Fixture.Group.Two' -or
                $settings.Controls.CloudGroupsStatus.Text -notmatch 'Saved 2') { throw 'Cloud Update groups were not saved.' }
            if ((Get-EndpointRemoteSettings $ui.ThemePath).DnsSuffix -ne 'corp.example.com' -or
                (Get-EndpointTenantPreference $ui.ThemePath) -ne 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee') {
                throw 'A settings editor overwrote another section in the unified file.'
            }
            $settings.Controls.HistoryButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if ($settings.Controls.HistoryGrid.Items.Count -ne 1 -or $settings.Controls.HistoryGrid.Items[0].RunId -ne 'fixture-history' -or $settings.Controls.HistoryGrid.Items[0].Rows -ne '7') { throw 'Refresh history did not bind the exact saved metadata.' }
            Assert-SettingsPreservesReport
            $ui.Active=[pscustomobject]@{WorkflowId='offline-fixture'}
            $ui.Controls.SettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if ($ui.Settings -ne $settings) { throw 'Repeated settings clicks created another window.' }
            $blocked=$false
            try { $settings.Controls.ClearHistoryButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
            catch { if ($_ -notmatch 'Wait for the running operation') { throw }; $blocked=$true }
            if (-not $blocked -or -not (Test-Path -LiteralPath $ui.HistoryPath)) { throw 'Clearing history was not blocked during a run.' }
            $ui.Active=$null
            $settings.Controls.ClearHistoryButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if (-not (Test-Path -LiteralPath $ui.HistoryPath) -or $settings.Controls.HistoryGrid.Items.Count -ne 1) { throw 'Declining to clear history changed the history.' }
            $script:FixtureConfirm=$true
            $settings.Controls.ClearHistoryButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if ((Test-Path -LiteralPath $ui.HistoryPath) -or $settings.Controls.HistoryGrid.Items.Count -ne 0) { throw 'Clear history did not remove only the saved metadata and clear its grid.' }
            Assert-SettingsPreservesReport
            Set-Content -LiteralPath $ui.HistoryPath -Value '{invalid json'
            $rejected=$false
            try { $settings.Controls.HistoryButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
            catch { $rejected=$true }
            if (-not $rejected) { throw 'Corrupt history was silently treated as empty.' }
            Remove-Item -LiteralPath $ui.HistoryPath
            $settings.Controls.LogsTab.IsSelected=$true
            $ui.LogRoot=$historyRoot
            $script:OpenedSettingsLogPath=$null
            function Invoke-Item { param([string]$LiteralPath) $script:OpenedSettingsLogPath=$LiteralPath }
            try {
                $settings.Controls.OpenActivityLogsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                if ($script:OpenedSettingsLogPath -ne $historyRoot) { throw 'Open activity logs did not open the configured log folder.' }
            }
            finally { Remove-Item Function:\Invoke-Item }
            $ui.LogRoot=''
            $settings.Controls.DnsSuffixBox.Text='unsaved.example.com'
            $settings.Controls.TenantIdBox.Text='bbbbbbbb-cccc-dddd-eeee-ffffffffffff'
            $settings.Controls.CloudGroupsBox.Text='Fixture.Unsaved'
            $ui.Controls.SettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if ($settings.Controls.DnsSuffixBox.Text -ne 'unsaved.example.com' -or
                $settings.Controls.TenantIdBox.Text -ne 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff' -or
                $settings.Controls.CloudGroupsBox.Text -ne 'Fixture.Unsaved') { throw 'Refocusing settings discarded an unsaved setting.' }
            $script:FixtureConfirm=$false
            $settings.Controls.CloseSettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if (-not $ui.Settings -or $settings.Controls.DnsSuffixBox.Text -ne 'unsaved.example.com' -or
                $settings.Controls.TenantIdBox.Text -ne 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff') { throw 'Declining to discard settings closed the window or lost an edit.' }
            $closing=[ComponentModel.CancelEventArgs]::new()
            Close-EndpointSettingsBeforeMainWindow $closing
            if (-not $closing.Cancel -or -not $ui.Settings -or $settings.Controls.DnsSuffixBox.Text -ne 'unsaved.example.com' -or
                $settings.Controls.TenantIdBox.Text -ne 'bbbbbbbb-cccc-dddd-eeee-ffffffffffff') { throw 'Closing the main window bypassed the unsaved-settings confirmation.' }
            $script:FixtureConfirm=$true
            $settings.Controls.CloseSettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if ($ui.Settings) { throw 'Closing settings retained a closed window.' }
            $ui.Controls.SettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if (-not $ui.Settings.Window.IsVisible -or $ui.Settings -eq $settings) { throw 'Settings could not be reopened after closing.' }
            if ($ui.Settings.Controls.DnsSuffixBox.Text -ne 'corp.example.com' -or
                $ui.Settings.Controls.TenantIdBox.Text -ne 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -or
                $ui.Settings.Controls.CloudGroupsBox.Text -ne "Fixture.Group.One`r`nFixture.Group.Two") { throw 'The saved settings were not restored when settings reopened.' }
            Assert-SettingsPreservesReport
            $ui.Settings.Controls.CloudGroupsBox.Text='Fixture.Unsaved'
            $script:FixtureConfirm=$false
            $ui.Settings.Controls.CloseSettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if (-not $ui.Settings -or $ui.Settings.Controls.CloudGroupsBox.Text -ne 'Fixture.Unsaved') { throw 'An unsaved Cloud Update edit did not prevent closing.' }
            $ui.Settings.Controls.CloudGroupsBox.Text="Fixture.Group.One`r`nFixture.Group.Two"
            $keyEvent=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($ui.Settings.Window),0,[Windows.Input.Key]::Escape)
            $keyEvent.RoutedEvent=[Windows.Input.Keyboard]::KeyDownEvent
            $ui.Settings.Window.RaiseEvent($keyEvent)
            if ($ui.Settings -or -not $keyEvent.Handled) { throw 'Esc did not close settings.' }
            'Native dedicated settings history, logs and preserved report state passed.'
        }
        finally {
            $ui.Active=$null
            if ($ui.Settings) { $ui.Settings.Window.Close() }
            if (Test-Path -LiteralPath $ui.HistoryPath) { Remove-Item -LiteralPath $ui.HistoryPath }
            Remove-Item -LiteralPath $historyRoot -Recurse -Force
            $ui.HistoryPath=$savedHistoryPath; $ui.RemoteSettingsPath=$savedRemoteSettingsPath; $ui.ThemePath=$savedThemePath; $ui.CloudUpdateSettingsPath=$savedCloudUpdateSettingsPath; $ui.LogRoot=$savedLogRoot
        }
        if ($SettingsOnly) { return }
        $auditRoot = Join-Path $env:TEMP "EndpointToolbox-ui-audit-$([guid]::NewGuid())"
        $ui.LogRoot = $auditRoot
        try {
            $ui.Active = [pscustomobject]@{ Engine=$ui.Graph; WorkflowId='delete-win32-apps'; Start=[datetime]::UtcNow; RunId='fixture-removal'; Failures=$false; Warnings=$false; PendingApproval=$false; IsRemote=$false; Completed=$false; State='' }
            $ui.Datasets=@{}; $ui.Controls.DatasetSelector.Items.Clear()
            $ui.ActivitySummary=$null; $ui.DiagnosticCount=0
            Write-EndpointUiRecord -Event 'RunRequested' -Required
            $ui.Graph.RunFile((Join-Path $PSScriptRoot 'Win32RemovalFixture.ps1'), @{OutputPath=$auditRoot}, $true)
            for ($i=0; $i -lt 30; $i++) { $ui.Graph.Host.Emit('Warning','Synthetic warning','Bearer synthetic.token') }
            $auditWatch = [Diagnostics.Stopwatch]::StartNew()
            while ($ui.Active -and $auditWatch.Elapsed.TotalSeconds -lt 15) { Receive-EndpointEvents; Start-Sleep -Milliseconds 10 }
            if ($ui.Active -or $ui.Faulted) { throw 'Native activity audit fixture did not finish.' }
            if ($ui.Controls.RunSummary.Text -notmatch 'Apps targeted: 3 \| Succeeded: 3 \| Failed: 0') { throw 'The run header did not show exact app outcome counts.' }
            if ($ui.Controls.Activity.Text -notmatch 'Summary: Apps targeted: 3') { throw 'The script output did not retain the final app summary.' }
            $logPath = Join-Path $auditRoot "task-delete-win32-apps-$([datetime]::UtcNow.ToString('yyyy-MM-dd')).jsonl"
            $records = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
            if (@($records | Where-Object Event -eq 'TaskWarning').Count -ne 20) { throw 'Automatic diagnostics did not enforce the 20-record limit.' }
            $finished = @($records | Where-Object Event -eq 'RunFinished')
            if ($finished.Count -ne 1 -or $finished[0].Summary.Succeeded -ne 3) { throw 'The UI did not persist its final run counts.' }
            if ((Get-Content -LiteralPath $logPath -Raw) -match 'synthetic.token') { throw 'A synthetic bearer token reached the automatic log.' }
            $ui.Active = [pscustomobject]@{Failures=$false;Warnings=$false;PendingApproval=$false}
            $ui.ActivitySummary = Get-EndpointOutcomeSummary 'Report rows' @([pscustomobject]@{Status='Failed'}) -ReadOnly
            Add-EndpointRows 'Reported installation failures' ([EndpointToolbox.PreparedReport]::new('Reported installation failures', @([pscustomobject]@{Status='Failed'}), $ui.Graph.Host))
            if ($ui.Active.Failures) { throw 'Device health data incorrectly overrode the structured operation summary.' }
            $ui.Active=$null; $ui.ActivitySummary=$null
            'Native activity logging, bounded diagnostics and app summary passed.'
        }
        finally {
            $ui.LogRoot=''
            if (Test-Path -LiteralPath $auditRoot) {
                Get-ChildItem -LiteralPath $auditRoot -File | Remove-Item -Force
                Remove-Item -LiteralPath $auditRoot
            }
        }
        $ui.Active = [pscustomobject]@{ Engine=$ui.Graph; WorkflowId='offline-responsiveness'; Start=[datetime]::UtcNow; RunId=[guid]::NewGuid().ToString(); Failures=$false; Warnings=$false; PendingApproval=$false; IsRemote=$false; Completed=$false; State='' }
        $ui.Controls.OutputTab.IsSelected=$true
        $ui.Controls.ActivityTab.IsSelected=$true
        $ui.Controls.CancelButton.IsEnabled=$true
        $frame=[Windows.Threading.DispatcherFrame]::new()
        $heartbeat=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Input)
        $heartbeat.Interval=[timespan]::FromMilliseconds(20)
        $heartbeat.Tag=@{Ui=$ui; Frame=$frame; Total=[Diagnostics.Stopwatch]::StartNew(); Gap=[Diagnostics.Stopwatch]::StartNew(); MaxGap=0; Ticks=0; CancelledWhileBusy=$false; Error=$null}
        $heartbeat.Add_Tick({
            param($sender)
            $state=$sender.Tag
            $state.MaxGap=[Math]::Max($state.MaxGap,$state.Gap.ElapsedMilliseconds)
            $state.Gap.Restart()
            $state.Ticks++
            if (-not $state.CancelledWhileBusy -and $state.Ui.Controls.Activity.Text.Contains('Formatting completed')) {
                $state.CancelledWhileBusy=$state.Ui.Graph.Busy
                $state.Ui.Controls.CancelButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            }
            if ($state.Total.Elapsed.TotalSeconds -gt 45) {
                $state.Error="Long-running responsiveness fixture timed out. Busy: $($state.Ui.Graph.Busy); queued: $($state.Ui.Graph.Host.Events.Count); log length: $($state.Ui.Controls.Activity.Text.Length)"
                $state.Ui.Graph.Cancel()
                $state.Frame.Continue=$false
            }
            if (-not $state.Ui.Active) { $state.Frame.Continue=$false }
        })
        try {
            $ui.Graph.RunFile((Join-Path $PSScriptRoot 'HostFixture.ps1'), @{Mode='ResponsiveWorkload'}, $false)
            $ui.Timer.Start()
            $heartbeat.Start()
            [Windows.Threading.Dispatcher]::PushFrame($frame)
            if ($heartbeat.Tag.Error) { throw $heartbeat.Tag.Error }
            if ($ui.Faulted) { throw 'Long-running UI processing faulted.' }
            if (-not $heartbeat.Tag.CancelledWhileBusy -or $ui.Graph.LastState -ne 'Cancelled') { throw 'Cancel was not responsive during the long-running worker.' }
            if ($heartbeat.Tag.Ticks -lt 10 -or $heartbeat.Tag.MaxGap -gt 500) { throw "Dispatcher stalled during long-running output: $($heartbeat.Tag.MaxGap) ms." }
            if (-not $ui.Controls.Activity.Text.Contains('Long-running fixture output 1999')) { throw 'Batched activity output was lost.' }
            "Long-running dispatcher and Cancel passed: maximum heartbeat gap $($heartbeat.Tag.MaxGap) ms."
            $ui.Active = [pscustomobject]@{ Engine=$ui.Graph; WorkflowId='offline-cancel-backlog'; Start=[datetime]::UtcNow; RunId=[guid]::NewGuid().ToString(); Failures=$false; Warnings=$false; PendingApproval=$false; IsRemote=$false; Completed=$false; State='' }
            $ui.Graph.RunFile((Join-Path $PSScriptRoot 'HostFixture.ps1'), @{Mode='Wait'}, $false)
            Add-EndpointRows 'Cancelled backlog' (1..100000)
            for ($i=0; $i -lt 20000; $i++) { $ui.Graph.Host.Emit('Output','Backlog',"Queued output $i") }
            $ui.Controls.CancelButton.IsEnabled=$true
            $cancelWatch=[Diagnostics.Stopwatch]::StartNew()
            $ui.Controls.CancelButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if ($ui.PendingBatches.Count) { throw 'Cancel retained pending report row batches.' }
            while ($ui.Active -and $cancelWatch.Elapsed.TotalSeconds -lt 5) { Receive-EndpointEvents; Start-Sleep -Milliseconds 10 }
            if ($ui.Active -or -not $ui.Controls.RunButton.IsEnabled) { throw 'Cancellation backlog prevented another run.' }
            if ($ui.Controls.Activity.Text.Contains('Queued output 19999')) { throw 'Cancelled output continued rendering.' }
            if ($ui.Controls.Status.Text -notmatch 'results may be incomplete') { throw 'Cancelled partial results were not identified.' }
            $ui.Active = [pscustomobject]@{ Engine=$ui.Graph; WorkflowId='offline-after-cancel'; Start=[datetime]::UtcNow; RunId=[guid]::NewGuid().ToString(); Failures=$false; Warnings=$false; PendingApproval=$false; IsRemote=$false; Completed=$false; State='' }
            $ui.Datasets=@{}
            $ui.Controls.DatasetSelector.Items.Clear()
            $ui.Graph.RunFile((Join-Path $PSScriptRoot 'HostFixture.ps1'), @{Mode='Rows';Count=1000}, $true)
            $nextWatch=[Diagnostics.Stopwatch]::StartNew()
            while (-not $ui.Graph.FinishedUtc -and $nextWatch.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 10 }
            if (-not $ui.Graph.FinishedUtc) { throw 'Worker timing was not published before UI processing.' }
            $workerElapsed=$ui.Graph.Elapsed
            Start-Sleep -Milliseconds 250
            Update-EndpointRunTiming
            if (-not $ui.Controls.RunTiming.Text.Contains('Preparing display...')) { throw 'Worker completion and pending display processing were not distinguished.' }
            while ($ui.Active -and $nextWatch.Elapsed.TotalSeconds -lt 5) { Receive-EndpointEvents; Start-Sleep -Milliseconds 10 }
            if ($ui.Active -or $ui.Graph.LastState -ne 'Completed') { throw 'Next run failed after cancelling a report backlog.' }
            if ($ui.Graph.Elapsed -ne $workerElapsed) { throw 'UI processing incorrectly increased worker runtime.' }
            foreach ($label in @('Started:','Worker ended:','Worker runtime:','Display processing ended:','After-worker display time:','Total:')) {
                if (-not $ui.Controls.RunTiming.Text.Contains($label)) { throw "Completed timing is missing $label" }
            }
            if (-not $ui.Controls.Activity.Text.Contains('[Run timing]') -and -not $ui.Controls.Activity.Text.Contains('Run timing:')) { throw 'Run timing was not included in the savable activity log.' }
            "Cancellation backlog and next run passed."
            $ui.Datasets=@{}
            $ui.Controls.DatasetSelector.Items.Clear()
            $ui.Controls.ResultsGrid.ItemsSource=$null
            $ui.Controls.Activity.Clear()
            $ui.Active = [pscustomobject]@{ Engine=$ui.Graph; WorkflowId='offline-large-report'; Start=[datetime]::UtcNow; RunId=[guid]::NewGuid().ToString(); Failures=$false; Warnings=$false; PendingApproval=$false; IsRemote=$false; Completed=$false; State='' }
            $largeWatch=[Diagnostics.Stopwatch]::StartNew()
            $ui.Graph.SuppressScriptObjectOutput=$true
            $ui.Graph.RunFile((Join-Path $desktop 'Invoke-WorkflowPresentation.ps1'), @{
                ScriptPath=(Join-Path $PSScriptRoot 'HostFixture.ps1'); WorkflowId='offline-report'; ScriptArguments=@{Mode='ReportOutput';Count=100000}
            }, $true)
            $lastWorkerEnd=$null
            while ($ui.Active -and $largeWatch.Elapsed.TotalSeconds -lt 30) {
                Receive-EndpointEvents
                if ($ui.Graph.FinishedUtc) { $lastWorkerEnd=$ui.Graph.FinishedUtc }
                Start-Sleep -Milliseconds 10
            }
            if ($ui.Active -or $ui.Graph.HasErrors) { throw 'Large report did not finish within 30 seconds.' }
            if ($ui.Datasets['Results'].Rows.Count -ne 100000 -or $ui.Datasets['Results'].Columns.Count -ne 20) { throw 'Large report lost rows or columns.' }
            if ($ui.Datasets['Results'].Rows[99999].DeviceName -ne 'Report-device-99999') { throw 'Final large report row was lost.' }
            if ($ui.Controls.Activity.Text.Contains('Report-device-')) { throw 'Report rows were duplicated in Script output.' }
            if (-not $ui.Controls.Activity.Text.Contains('Report fixture warning') -or -not $ui.Controls.Activity.Text.Contains('Generating report fixture')) { throw 'Report diagnostics were suppressed.' }
            $displayTail=([datetime]::UtcNow - $lastWorkerEnd).TotalSeconds
            if ($displayTail -gt 2) { throw "Large report display processing exceeded 2 seconds after worker completion: $displayTail." }
            $largeWatch.Stop()
            $ui.Window.UpdateLayout()
            if ($ui.Controls.ResultsGrid.Columns.Count -ne 20 -or $ui.Controls.ResultsGrid.Items.Count -ne 100000) { throw 'Prepared report did not expose the complete grid schema and rows.' }
            $filterWatch=[Diagnostics.Stopwatch]::StartNew()
            $ui.Controls.ResultFilter.Text='Report-device-99999'
            if ($filterWatch.ElapsedMilliseconds -gt 250) { throw "Typing a report filter blocked the UI for $($filterWatch.ElapsedMilliseconds) ms." }
            $filterDeadline=[datetime]::UtcNow.AddSeconds(30)
            while ($ui.ResultFilterState.Timer.IsEnabled -and [datetime]::UtcNow -lt $filterDeadline) {
                Receive-EndpointResultFilter
                Start-Sleep -Milliseconds 10
            }
            if ($ui.ResultFilterState.Timer.IsEnabled) { throw 'Large report filtering did not finish.' }
            if ($ui.Controls.ResultsGrid.Items.Count -ne 1 -or $ui.Controls.ResultsGrid.Items[0].DeviceName -ne 'Report-device-99999') { throw 'Prepared report filtering did not preserve the matching row.' }
            $ui.Controls.ResultFilter.Clear()
            $ui.Controls.ResultsGrid.Items.SortDescriptions.Add([ComponentModel.SortDescription]::new('DeviceName',[ComponentModel.ListSortDirection]::Descending))
            if ($ui.Controls.ResultsGrid.Items[0].DeviceName -ne 'Report-device-99999') { throw 'Prepared report column sorting failed.' }
            $ui.Controls.ResultsGrid.Items.SortDescriptions.Clear()
            "Large report passed: 100000 rows, 20 columns, total $([Math]::Round($largeWatch.Elapsed.TotalSeconds,2)) seconds, after-worker display $([Math]::Round($displayTail,2)) seconds."
        }
        finally {
            $heartbeat.Stop(); $ui.Timer.Stop()
            $ui.Active=$null
            $ui.Graph.Dispose(); $ui.Remote.Dispose()
            if (Test-Path -LiteralPath $ui.HistoryPath) { Remove-Item -LiteralPath $ui.HistoryPath }
        }
        $ui.Active = [pscustomobject]@{ WorkflowId='delete-win32-apps'; Engine=$fakeEngine }
        foreach ($size in @(@{Width=1000;Height=700}, @{Width=1400;Height=940})) {
            $ui.Window.Width = [Math]::Min($size.Width, [Windows.SystemParameters]::WorkArea.Width)
            $ui.Window.Height = [Math]::Min($size.Height, [Windows.SystemParameters]::WorkArea.Height)
            foreach ($id in @('delete-win32-apps','primary-users','intune-assignment-win32-deployment-exports','intune-script-device-status')) {
                $ui.Controls.WorkflowList.SelectedItem = $ui.Catalog | Where-Object Id -eq $id
                $ui.Window.UpdateLayout()
                $position = $ui.Controls.RunButton.TransformToAncestor($ui.Window).Transform([Windows.Point]::new(0,0))
                if ($position.X -lt 0 -or $position.Y -lt 0 -or $position.X + $ui.Controls.RunButton.ActualWidth -gt $ui.Window.ActualWidth -or $position.Y + $ui.Controls.RunButton.ActualHeight -gt $ui.Window.ActualHeight) { throw "Primary action clipped for $id." }
                if ($ui.Controls.FormScroll.ActualHeight -lt 100) { throw "Configuration is unusable at $($size.Width)x$($size.Height)." }
            }
        }
        foreach ($mode in @('Single','Multiple','Skip','Cancel','Script')) {
            $ui.Active.WorkflowId = if ($mode -eq 'Single') { 'intune-assignment-win32-deployment-exports' } elseif ($mode -eq 'Script') { 'intune-script-device-status' } else { 'delete-win32-apps' }
            $request = [EndpointToolbox.InputRequest]::new('Text', 'Synthetic script input', 'Select the original matching apps', $null)
            if ($mode -eq 'Script') {
                $ui.Choice = [pscustomobject]@{Name='Script';Data=@(
                    [pscustomobject]@{ScriptType='Remediation';DisplayName='Alpha remediation';CreatedDateTime='2026-01-01';Id='00000000-0000-0000-0000-000000000001'}
                    [pscustomobject]@{ScriptType='Platform script';DisplayName='Beta platform script';CreatedDateTime='2026-02-01';Id='00000000-0000-0000-0000-000000000002'}
                )}
            }
            else {
                $ui.Choice = [pscustomobject]@{Name=$(if($mode -eq 'Single'){'Single'}else{'Multiple'});Data=@(
                    [pscustomobject]@{displayName='Synthetic App';displayVersion='1.0';createdDateTime='2026-01-01';id='00000000-0000-0000-0000-000000000001'}
                    [pscustomobject]@{displayName='Synthetic App';displayVersion='2.0';createdDateTime='2026-02-01';id='00000000-0000-0000-0000-000000000002'}
                )}
            }
            $timer = [Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [timespan]::FromMilliseconds(150)
            $timer.Tag = @{Ui=$ui; Mode=$mode; Error=$null; SnapshotDirectory=$SnapshotDirectory}
            $timer.Add_Tick({
                param($sender)
                $state=$sender.Tag
                if (-not $state.Ui.Window.OwnedWindows.Count) { return }
                $sender.Stop()
                $dialog=$state.Ui.Window.OwnedWindows[0]
                try {
                    $panel=$dialog.Content.Content
                    $grid=$panel.Children | Where-Object { $_ -is [Windows.Controls.DataGrid] } | Select-Object -First 1
                    if (-not $grid) { throw 'Selection grid is missing.' }
                    $buttons=@($panel.Children | Where-Object { $_ -is [Windows.Controls.WrapPanel] } | ForEach-Object { $_.Children })
                    if ($state.Mode -eq 'Script') {
                        $searchBox=$panel.Children | Where-Object { $_ -is [Windows.Controls.TextBox] } | Select-Object -First 1
                        if (-not $searchBox) { throw 'Script selection search field is missing.' }
                        $searchBox.Text='Beta'
                        if ($grid.Items.Count -ne 1 -or $grid.Items[0].Name -ne 'Beta platform script') { throw 'Script search did not filter the candidate list.' }
                        $grid.SelectedItem=$grid.Items[0]; $label='Use this script'
                    }
                    elseif ($state.Mode -eq 'Single') { $grid.SelectedIndex=1; $label='Use this app' }
                    elseif ($state.Mode -eq 'Multiple') {
                        $button=$buttons | Where-Object Content -eq 'Use selected apps' | Select-Object -First 1
                        $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                        if (-not $button.Tag.Validation.Text) { throw 'Empty app selection was accepted.' }
                        foreach ($row in $grid.ItemsSource) { $row.Selected=$true }
                        $grid.Items.Refresh(); $label='Use selected apps'
                    }
                    elseif ($state.Mode -eq 'Skip') { $label='Skip pattern' }
                    else { $label='Cancel run' }
                    if ($state.Mode -eq 'Multiple' -and $state.SnapshotDirectory) {
                        $dialog.UpdateLayout()
                        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$dialog.ActualWidth,[int]$dialog.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
                        $bitmap.Render($dialog)
                        $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
                        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                        $stream=[IO.File]::Create((Join-Path $state.SnapshotDirectory 'redesign-app-selection.png'))
                        try {$encoder.Save($stream)}finally{$stream.Dispose()}
                    } $SnapshotDirectory
                    $button=$buttons | Where-Object Content -eq $label | Select-Object -First 1
                    if (-not $button) { throw "Missing $label button." }
                    $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                }
                catch { $state.Error=$_; $dialog.Close() }
            })
            $timer.Start()
            try {
                Show-EndpointInput $request
                if ($timer.Tag.Error) { throw $timer.Tag.Error }
                if ($mode -eq 'Script' -and $request.Answer -ne '1') { throw 'Script selection did not preserve the candidate index after filtering.' }
                if ($mode -eq 'Single' -and $request.Answer -ne '1') { throw 'Single selection response changed.' }
                if ($mode -eq 'Multiple' -and $request.Answer -ne '0,1') { throw 'Multi-selection response changed.' }
                if ($mode -eq 'Skip' -and $request.Answer -ne '') { throw 'Skip response changed.' }
                if ($mode -eq 'Cancel' -and (-not $request.Cancelled -or -not $fakeEngine.Cancelled)) { throw 'Cancel failed to stop the run.' }
                "Native $mode selection dialog passed."
            }
            finally { $timer.Stop(); $request.Dispose() }
        }
    }
    finally {
        $ui.Active=$null; $ui.Window.Close()
        $ui.Graph.Dispose(); $ui.Remote.Dispose()
        if ($ui.HistoryPath -and (Test-Path -LiteralPath $ui.HistoryPath)) { Remove-Item -LiteralPath $ui.HistoryPath -ErrorAction Stop }
    }
} $SnapshotDirectory $SettingsOnly
