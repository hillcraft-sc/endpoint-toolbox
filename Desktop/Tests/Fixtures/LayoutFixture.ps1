[CmdletBinding()]
param([string]$SnapshotDirectory, [ValidateSet('Light','Dark','CatppuccinMocha','GruvboxDark')][string]$Theme = 'Light')
$ErrorActionPreference = 'Stop'
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs')
& (Get-Module EndpointToolboxUI) {
    param($desktop,$SnapshotDirectory,$Theme)
    $previous = Get-Variable -Name Ui -Scope Script -ValueOnly -ErrorAction Ignore
    $xml = [xml](Get-Content -LiteralPath (Join-Path $desktop 'MainWindow.xaml') -Raw)
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
    if ($window.Title -cne 'Endpoint Toolbox') { throw 'The application window title does not use the current app name.' }
    Set-EndpointWindowIcon $window
    Set-EndpointTheme $window $Theme
    if (-not $window.Icon -or $window.Icon.PixelWidth -ne 1024 -or $window.Icon.PixelHeight -ne 1024) { throw 'The application window icon is not the supplied transparent 1024x1024 image.' }
    $controls = @{}
    foreach ($node in $xml.SelectNodes('//*[@Name]')) {
        $name=$node.GetAttribute('Name')
        $controls[$name]=$window.FindName($name)
    }
    $graph=[EndpointToolbox.DesktopEngine]::new()
    $remote=[EndpointToolbox.DesktopEngine]::new()
    $catalog=@(Get-EndpointCatalog)
    $script:Ui=@{
        Window=$window; Controls=$controls; Catalog=$catalog; Workflow=$null; Graph=$graph; Remote=$remote
        Active=$null; FieldControls=@{}; FieldRows=@{}; Selectors=@(); Inactive=@(); GraphContext=$null
        LogRoot=''; ActivityBuffer=$null; RemoteBuffer=$null; Choice=$null; TestMode=$false; Faulted=$false
    }
    $ui=$script:Ui
    $controls.DatasetSelector.Add_SelectionChanged({ Update-EndpointResults })
    function Save-LayoutSnapshot {
        param($Element,[string]$Name)
        if (-not $SnapshotDirectory) { return }
        $Element.UpdateLayout()
        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$Element.ActualWidth,[int]$Element.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($Element)
        $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream=[IO.File]::Create((Join-Path $SnapshotDirectory "$Name.png"))
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }
    try {
        if ($controls.Status.Text -cne 'Select a task. Sign-in and permissions not verified.') { throw 'Startup status implies task readiness before authentication has been verified.' }
        if ($controls.ContextLabel.Text -cne 'Sign-in and permissions not verified. Connect or check on Home.') { throw 'Initial connection guidance does not explain unverified authentication.' }
        Set-EndpointNavigation
        $window.Show()
        if ([Windows.Input.Keyboard]::FocusedElement -ne $controls.Search) { throw 'The task search is not the initial keyboard focus.' }
        foreach ($resource in @(
            @{Name='Control.Height.Default';Expected=32}
            @{Name='Font.Size.Body';Expected=14}
            @{Name='Font.Size.Console';Expected=13}
        )) {
            if ([double]$window.FindResource($resource.Name) -ne $resource.Expected) { throw "Unexpected value for UI token $($resource.Name)." }
        }
        if ($window.FindResource('CornerRadius.Default').TopLeft -ne 6) { throw 'Unexpected value for UI token CornerRadius.Default.' }
        if ([Windows.Automation.AutomationProperties]::GetName($controls.Progress) -ne 'Task progress') { throw 'Task progress has no accessible name.' }
        foreach ($control in @($controls.Status,$controls.RemoteStatus,$controls.RunSummary,$controls.RiskLabel,$controls.ExecutionHint)) {
            if ([Windows.Automation.AutomationProperties]::GetLiveSetting($control) -ne [Windows.Automation.AutomationLiveSetting]::Polite) { throw "Live status is not announced politely: $($control.Name)." }
        }
        if ([Windows.Automation.AutomationProperties]::GetName($controls.Status) -ne 'Task status') { throw 'Task status has no accessible name.' }
        if ([Windows.Automation.AutomationProperties]::GetName($controls.RemoteStatus) -ne 'Remote session status') { throw 'Remote status has no accessible name.' }
        if ([Windows.Input.KeyboardNavigation]::GetTabIndex($controls.Search) -ge [Windows.Input.KeyboardNavigation]::GetTabIndex($controls.WorkflowList) -or
            [Windows.Input.KeyboardNavigation]::GetTabIndex($controls.WorkflowList) -ge [Windows.Input.KeyboardNavigation]::GetTabIndex($controls.SettingsButton)) {
            throw 'Sidebar tab order does not follow visual order.'
        }
        foreach ($size in @(@{Width=1000;Height=700},@{Width=1400;Height=940})) {
            $window.Width=[Math]::Min($size.Width,[Windows.SystemParameters]::WorkArea.Width)
            $window.Height=[Math]::Min($size.Height,[Windows.SystemParameters]::WorkArea.Height)
            $window.UpdateLayout()
            foreach ($workflow in $catalog) {
                $controls.WorkflowList.SelectedItem=$workflow
                New-EndpointForm
                $window.UpdateLayout()
                foreach ($field in $workflow.Fields) {
                    if (-not $ui.FieldControls.ContainsKey($field.Name) -or -not $ui.FieldRows.ContainsKey($field.Name)) {
                        throw "The redesigned form is missing $($workflow.Id)/$($field.Name)."
                    }
                }
                if ($ui.Selectors.Count -ne @($workflow.Selectors).Count) { throw "The redesigned form is missing a source selector for $($workflow.Id)." }
                if ($controls.Status.Text -cne "Selected - $($workflow.Title). Sign-in and permissions not verified.") { throw "Task selection implies verified authentication or permissions: $($workflow.Id)." }
                if ($workflow.Id -in @('intune-script-device-status', 'quality-updates')) {
                    if ($controls.RunButton.IsEnabled) { throw 'The report must wait until a target is loaded and selected.' }
                }
                elseif (-not $controls.RunButton.IsEnabled) { throw 'The Run button must allow the access preflight to explain missing access.' }
                if (-not ([string]$controls.RunButton.Content).StartsWith('_')) { throw "Primary action has no access key: $($workflow.Id)." }
                foreach ($selector in $ui.Selectors) {
                    if ([Windows.Automation.AutomationProperties]::GetName($selector.Control) -ne $selector.Definition.Label) { throw "Selector has no matching accessible name: $($selector.Definition.Label)." }
                    if (-not [Windows.Automation.AutomationProperties]::GetLabeledBy($selector.Control)) { throw "Selector is not associated with its visible label: $($selector.Definition.Label)." }
                }
                Show-EndpointHome
                $window.UpdateLayout()
                if ($controls.HomePanel.Visibility -ne 'Visible' -or $controls.TaskPanel.Visibility -ne 'Collapsed') { throw 'Home navigation did not switch pages.' }
                if (-not $controls.HomeButton.IsEnabled -or -not $controls.GraphCheckButton.IsEnabled) { throw 'Home connection actions are not accessible while idle.' }
                if ($controls.GraphGuidance.IsExpanded) { throw 'Detailed Graph permissions should initially be collapsed.' }
                $controls.GraphGuidance.IsExpanded=$true
                if (-not $controls.GraphGuidance.Content) { throw 'Detailed Graph permissions are not available when expanded.' }
                $controls.GraphGuidance.IsExpanded=$false
                if (-not [Windows.Automation.AutomationProperties]::GetLabeledBy($controls.GraphTenant)) { throw 'Home tenant input has no associated label.' }
                $ui.Active=[pscustomobject]@{}
                Show-EndpointHome
                if (-not $controls.HomeButton.IsEnabled -or $controls.GraphCheckButton.IsEnabled -or $controls.GraphConnectButton.IsEnabled -or $controls.GraphDisconnectButton.IsEnabled) { throw 'Home must remain accessible while worker operations are serialized.' }
                $ui.Active=$null
                Update-EndpointHomeControls
                if (-not $controls.GraphCheckButton.IsEnabled) { throw 'Home connection checks did not recover after worker completion.' }
                Save-LayoutSnapshot $controls.HomePanel "graph-home-$($size.Width)"
                foreach ($name in $ui.FieldControls.Keys) {
                    $field=$ui.FieldControls[$name]
                    if (-not [Windows.Automation.AutomationProperties]::GetName($field)) { throw "Generated field has no accessible name: $($workflow.Id)/$name." }
                    if ($field -isnot [Windows.Controls.CheckBox] -and -not [Windows.Automation.AutomationProperties]::GetLabeledBy($field)) {
                        throw "Generated field is not associated with its visible label: $($workflow.Id)/$name."
                    }
                    if ($field -is [Windows.Controls.TextBox]) {
                        if ($field.Padding.Top -gt 4 -or $field.Padding.Bottom -gt 4) { throw "Excessive input padding in $($workflow.Id)/$name." }
                        if ($field.AcceptsReturn) {
                            if ($field.MinHeight -gt 56 -or $field.VerticalContentAlignment -ne 'Top') { throw "Multiline input is not compact/top aligned: $($workflow.Id)/$name." }
                        }
                        elseif ($field.MinHeight -ne 32) { throw "Inconsistent single-line input height: $name." }
                    }
                }
                if ($controls.FormScroll.ActualHeight -lt 100) { throw 'Configuration area is too small.' }
            }
            $ui.GraphContext=[pscustomobject]@{Account='fixture@example.invalid';TenantId='fixture-tenant'}
            New-EndpointForm
            if ($controls.Status.Text -cne "Selected - $($ui.Workflow.Title). Sign-in and permissions not verified.") { throw 'An observed Graph context incorrectly implies verified permissions.' }
            $ui.GraphContext=$null
            $ui.Active=[pscustomobject]@{}
            Set-EndpointLiveText $controls.Status 'Running fixture task'
            New-EndpointForm
            if ($controls.Status.Text -cne 'Running fixture task') { throw 'Task selection overwrote the active run status.' }
            $ui.Active=$null
            $recentRoot=Join-Path $env:TEMP "EndpointToolbox-layout-$([guid]::NewGuid())"
            $ui.RecentDevicesPath=Join-Path $recentRoot 'recent-devices.json'
            try {
                $null=Add-EndpointRecentDevice $ui.RecentDevicesPath 'Fixture-PC2'; $null=Add-EndpointRecentDevice $ui.RecentDevicesPath 'Fixture-PC1'
                $controls.WorkflowList.SelectedItem=$catalog | Where-Object Id -eq 'remote-endpoint'
                New-EndpointForm
                $deviceBox=$ui.FieldControls.Device
                if ($deviceBox -isnot [Windows.Controls.ComboBox] -or -not $deviceBox.IsEditable) { throw 'The remote computer name is not an editable dropdown.' }
                if ((@($deviceBox.Items) -join ',') -ne 'Fixture-PC1,Fixture-PC2' -or $deviceBox.Text) { throw 'Recent devices were not offered most recent first with an empty entry.' }
                if ([Windows.Automation.AutomationProperties]::GetName($deviceBox) -ne 'Computer name *') { throw 'The device dropdown lost its accessible name.' }
            }
            finally { $ui.RecentDevicesPath=''; Remove-Item -LiteralPath $recentRoot -Recurse -Force -ErrorAction Ignore }
            $controls.WorkflowList.SelectedItem=$catalog | Where-Object Id -eq 'remote-endpoint'
            New-EndpointForm
            $controls.OutputTab.IsSelected=$true
            $controls.RemoteTab.IsSelected=$true
            $commands=@(Get-EndpointRemoteCommands)
            $controls.RemoteCommandPicker.ItemsSource=$commands
            $command=$commands | Where-Object Name -like 'Profiles - Remove*'
            $controls.RemoteCommandPicker.SelectedItem=$command
            $controls.RemoteCommand.Text=$command.Command
            $controls.RemoteCommandDescription.Text=$command.Description
            $controls.RemoteOutput.Text="PS [Synthetic-PC]> Get-Date`r`nThursday, November 5, 2026`r`n"
            $controls.RunSummary.Text='A deliberately long run summary. ' * 25
            $controls.RunTiming.Text='A deliberately long timing detail. ' * 25
            $window.UpdateLayout()
            if ($controls.RemoteOutput.ActualHeight -lt 140) { throw "Remote output too thin at $($size.Width)x$($size.Height): $($controls.RemoteOutput.ActualHeight)." }
            if ($controls.RemoteCommand.ActualHeight -lt 56) { throw 'Remote editor is too small.' }
            if ($controls.RemoteOutput.VerticalContentAlignment -ne 'Top') { throw 'Remote output is not top aligned.' }
            $buttons=$controls.SendCommandButton.Parent
            $position=$buttons.TransformToAncestor($controls.RemoteTab.Content).Transform([Windows.Point]::new(0,0))
            if ($position.Y + $buttons.ActualHeight -gt $controls.RemoteTab.Content.ActualHeight + 1) { throw 'Remote command buttons are clipped.' }
            foreach ($button in $buttons.Children) {
                $position=$button.TransformToAncestor($controls.RemoteTab.Content).Transform([Windows.Point]::new(0,0))
                if ($position.X + $button.ActualWidth -gt $controls.RemoteTab.Content.ActualWidth + 1) { throw 'Remote command button extends beyond the right edge.' }
            }
            Save-LayoutSnapshot $window "compact-remote-$($size.Width)"
            $controls.ConfigureTab.IsSelected=$true
            $window.UpdateLayout()
            if ($controls.Description.Visibility -ne 'Visible') { throw 'Task description did not return when leaving Remote workspace.' }
            $controls.OutputTab.IsSelected=$true
            $controls.ActivityTab.IsSelected=$true
            $controls.RunSummary.Text='Completed.'
            $controls.RunTiming.Text='Timing details.'
            $window.UpdateLayout()
            if ($controls.Activity.ActualHeight -lt 120 -or $controls.Activity.VerticalContentAlignment -ne 'Top') { throw 'Script output is too small or vertically centered.' }
            $controls.WorkflowList.SelectedItem=$catalog | Where-Object Id -eq 'm365-cloud-update'
            New-EndpointForm
            if ($controls.ExecutionHint.Text -notmatch 'Home Graph is not required') { throw 'Office report incorrectly requires Home Graph sign-in.' }
            if ($ui.FieldControls.IncludeWaveGroups.IsChecked) { throw 'Wave group lookup must be opt-in.' }
            $ui.FieldControls.IncludeWaveGroups.IsChecked=$true
            if ($controls.ExecutionHint.Text -notmatch 'Connect on Home first') { throw 'Optional group lookup did not explain its Graph prerequisite.' }
            $ui.FieldControls.IncludeWaveGroups.IsChecked=$false
            if ($controls.ExecutionHint.Text -notmatch 'Home Graph is not required') { throw 'Unchecking group lookup did not restore the standalone Office report.' }
            $cloudRoot=Join-Path $env:TEMP "EndpointToolbox-cloud-layout-$([guid]::NewGuid())"
            try {
                $ui.HistoryPath=Join-Path $cloudRoot 'history.jsonl'
                $ui.Datasets=@{}; $ui.PendingBatches=[Collections.Generic.Queue[object]]::new()
                $ui.ActivitySummary=$null; $ui.ReceivingEvents=$false
                $controls.DatasetSelector.Items.Clear()
                $graph.Host.PrepareReportTables=$true
                $ui.Active=[pscustomobject]@{Engine=$graph;WorkflowId='m365-cloud-update';Start=[datetime]::UtcNow;RunId=[guid]::NewGuid().ToString();Failures=$false;Warnings=$false;PendingApproval=$false;IsRemote=$false;Completed=$false;State=''}
                $graph.RunFile((Join-Path $desktop 'Tests\Fixtures\CloudUpdateFixture.ps1'),@{NoExport=$true;IncludeWaveGroups=$true},$true)
                $deadline=[datetime]::UtcNow.AddSeconds(15)
                while ($ui.Active -and [datetime]::UtcNow -lt $deadline) { Receive-EndpointEvents; Start-Sleep -Milliseconds 10 }
                if ($ui.Active -or $ui.Faulted -or $graph.HasErrors) { throw "Cloud Update did not complete through the native event loop. $($controls.Activity.Text)" }
                if ($controls.RunSummary.Text -cne "$($ui.Workflow.Title): Script finished - review output.") { throw 'The Cloud Update top bar must show run status without report statistics.' }
                if ($controls.DatasetSelector.SelectedItem -ne 'Cloud Update devices' -or $ui.Datasets['Cloud Update devices'].Rows.Count -ne 3) { throw 'The portal-style device report was not selected first.' }
                $controls.OutputTab.IsSelected=$true
                $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background)
                $window.UpdateLayout()
                if ($controls.ResultsGrid.Items.Count -ne 3 -or -not $controls.ResultsTab.IsSelected) { throw 'The Cloud Update device rows were not bound to the visible results grid.' }
                if (-not @($controls.ResultsGrid.Columns | Where-Object Header -eq 'Group').Count) { throw 'The optional Group column is missing from the native report grid.' }
                $controls.DatasetSelector.SelectedItem='Rollout summary'
                if ($controls.ResultsGrid.Items.Count -ne 3 -or $ui.Datasets['Rollout summary'].Select("Status = 'Completed'")[0].Devices -ne '1') { throw 'Rollout statistics are not available in the results grid.' }
                $controls.DatasetSelector.SelectedItem='Cloud Update devices'
                $window.UpdateLayout()
                $minimumGridHeight = $controls.ResultsGrid.ColumnHeaderHeight + 2 * $controls.ResultsGrid.RowHeight + [Windows.SystemParameters]::HorizontalScrollBarHeight
                if ($controls.ResultsGrid.ActualHeight -lt $minimumGridHeight) { throw "The report grid cannot show two data rows at $($size.Width)x$($size.Height): $($controls.ResultsGrid.ActualHeight)." }
                $controls.RunTimingExpander.IsExpanded=$true
                $window.UpdateLayout()
                if (-not $controls.RunTiming.IsVisible) { throw 'Run timing is not available when the summary is expanded.' }
                $controls.RunTimingExpander.IsExpanded=$false
                if ($controls.RunButton.ActualHeight -lt 1 -or -not $controls.RunButton.IsVisible) { throw 'The primary action is hidden for Cloud Update.' }
                Save-LayoutSnapshot $window "cloud-update-$($size.Width)"
            }
            finally {
                $controls.Activity.Clear()
                if (Test-Path -LiteralPath $cloudRoot) { Remove-Item -LiteralPath $cloudRoot -Recurse -Force }
            }
            $controls.ConfigureTab.IsSelected=$true
            $controls.WorkflowList.SelectedItem=$catalog | Where-Object Id -eq 'delete-win32-apps'
            New-EndpointForm
            Save-LayoutSnapshot $window "compact-input-$($size.Width)"
        }
        foreach ($kind in @('Credential','Secure','Text','Choice','AppSelection')) {
            $requestKind=if ($kind -eq 'AppSelection') { 'Text' } else { $kind }
            $request=[EndpointToolbox.InputRequest]::new($requestKind,'Synthetic input','Enter the requested information.',@('Yes','No'))
            $engine=[pscustomobject]@{Cancelled=$false}
            $engine | Add-Member -MemberType ScriptMethod -Name Cancel -Value { $this.Cancelled=$true }
            $ui.Active=[pscustomobject]@{WorkflowId='delete-win32-apps';Engine=$engine}
            $ui.Choice=if ($kind -eq 'AppSelection') {
                [pscustomobject]@{Name='Multiple';Data=@(
                    [pscustomobject]@{displayName='Synthetic App';displayVersion='1.0';createdDateTime='2026-01-01';id='fixture-1'}
                    [pscustomobject]@{displayName='Synthetic App';displayVersion='2.0';createdDateTime='2026-02-01';id='fixture-2'}
                )}
            } else { $null }
            $timer=[Windows.Threading.DispatcherTimer]::new()
            $timer.Interval=[timespan]::FromMilliseconds(100)
            $timer.Tag=@{Ui=$ui;Kind=$kind;Error=$null}
            $timer.Add_Tick({
                param($sender)
                if (-not $sender.Tag.Ui.Window.OwnedWindows.Count) { return }
                $sender.Stop()
                $dialog=$sender.Tag.Ui.Window.OwnedWindows[0]
                try {
                    $dialog.UpdateLayout()
                    if ($dialog.Background.Color -ne $sender.Tag.Ui.Window.Background.Color -or $dialog.Foreground.Color -ne $sender.Tag.Ui.Window.Foreground.Color) { throw 'The input dialog did not inherit the active theme.' }
                    $panel=$dialog.Content.Content
                $validation=$panel.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] -and [Windows.Automation.AutomationProperties]::GetName($_) -eq 'Validation message' }
                if (-not $validation -or [Windows.Automation.AutomationProperties]::GetLiveSetting($validation) -ne [Windows.Automation.AutomationLiveSetting]::Polite) {
                    throw "The $($sender.Tag.Kind) prompt validation message is not accessible."
                }
                $dialogButtons=@($panel.Children | Where-Object { $_ -is [Windows.Controls.WrapPanel] } | ForEach-Object Children | Where-Object { $_ -is [Windows.Controls.Button] })
                if (-not @($dialogButtons | Where-Object IsCancel).Count) { throw "The $($sender.Tag.Kind) prompt has no Escape-to-cancel button." }
                if (-not $dialog.Tag.RefusalButton.IsKeyboardFocused) { throw "The $($sender.Tag.Kind) prompt does not focus its refusal option." }
                if (@($dialogButtons | Where-Object IsDefault).Count) { throw "The $($sender.Tag.Kind) prompt has an approval/action as its Enter default." }
                    if ($sender.Tag.Kind -in @('Credential','Secure') -and ($dialog.ActualWidth -gt 460 -or $dialog.ActualHeight -gt 370)) { throw "Oversized $($sender.Tag.Kind) dialog: $($dialog.ActualWidth)x$($dialog.ActualHeight)." }
                    $password=$panel.Children | Where-Object { $_ -is [Windows.Controls.PasswordBox] }
                    $text=$panel.Children | Where-Object { $_ -is [Windows.Controls.TextBox] }
                    if ($password -and ($password.ActualHeight -lt 32 -or $password.ActualHeight -gt 36)) { throw 'Password box has inconsistent height.' }
                    if ($password -and $text -and [math]::Abs($password.ActualHeight - $text.ActualHeight) -gt 1) { throw 'Username and password heights differ.' }
                    Save-LayoutSnapshot $dialog "compact-dialog-$($sender.Tag.Kind)"
                    if ($sender.Tag.Kind -eq 'Credential') {
                        $text.Text='fixture-user'
                        $password.Password='synthetic-only'
                        $button=$panel.Children | Where-Object { $_ -is [Windows.Controls.WrapPanel] } | ForEach-Object Children | Where-Object Content -eq 'Continue'
                        $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    }
                    elseif ($sender.Tag.Kind -eq 'AppSelection') {
                        if ($dialog.ActualWidth -lt 800) { throw 'App-selection dialog lost its wide layout.' }
                        $grid=$panel.Children | Where-Object { $_ -is [Windows.Controls.DataGrid] }
                        if ($grid.ActualHeight -lt 280) { throw 'App-selection grid is too small.' }
                        $grid.ItemsSource[1].Selected=$true
                        $button=$panel.Children | Where-Object { $_ -is [Windows.Controls.WrapPanel] } | ForEach-Object Children | Where-Object Content -eq 'Use selected apps'
                        $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    }
                    else { $dialog.Close() }
                }
                catch { $sender.Tag.Error=$_; $dialog.Close() }
            })
            $timer.Start()
            try {
                Show-EndpointInput $request
                if ($timer.Tag.Error) { throw $timer.Tag.Error }
                if ($kind -eq 'Credential') {
                    if ($request.Answer -isnot [pscredential] -or $request.Answer.UserName -ne 'fixture-user') { throw 'Compact credential dialog failed to return secure credentials.' }
                }
                elseif ($kind -eq 'AppSelection') {
                    if ($request.Answer -ne '1') { throw 'App-selection response changed.' }
                }
                elseif (-not $request.Cancelled -or -not $engine.Cancelled) { throw "Cancellation failed for $kind dialog." }
            }
            finally { $timer.Stop(); $request.Dispose() }
        }
        'Compact forms, usable output panes and credential dialogs passed at both window sizes.'
    }
    finally {
        $ui.Active=$null
        $window.Close()
        $graph.Dispose(); $remote.Dispose()
        $script:Ui=$previous
    }
} $desktop $SnapshotDirectory $Theme
