param([switch]$NavigationOnly, [switch]$ExpanderFocusOnly, [switch]$ReportSettingsOnly, [switch]$WUfBOnly, [switch]$GroupMembersOnly)

$ErrorActionPreference = 'Stop'
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs')

& (Get-Module EndpointToolboxUI) {
    param($desktop, $NavigationOnly, $ExpanderFocusOnly, $ReportSettingsOnly, $WUfBOnly, $GroupMembersOnly)
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((Join-Path $desktop 'MainWindow.xaml')))
    $controls = @{}
    foreach ($node in ([xml](Get-Content -LiteralPath (Join-Path $desktop 'MainWindow.xaml') -Raw)).SelectNodes('//*[@Name]')) {
        $name = $node.GetAttribute('Name'); $controls[$name] = $window.FindName($name)
    }
    $catalog = @(Get-EndpointCatalog)
    $script:Ui = @{
        Window=$window; Controls=$controls; Catalog=$catalog; Workflow=$null; GraphContext=$null; Settings=$null; FormDrafts=@{}
        Remote=[pscustomobject]@{Connected=$false}; Active=$null; Faulted=$false; LogRoot=''
        FieldControls=@{}; FieldRows=@{}; Selectors=@(); Inactive=@(); ScriptPicker=$null
        PendingBatches=[Collections.Generic.Queue[object]]::new()
        RemoteCommandSelection=$null; RemoteCommandSelectionChanging=$false; TestMode=$true; CloudUpdateSettingsPath=''
    }
    $ui = $script:Ui
    $script:FixtureConfirm = $false
    function script:Confirm-EndpointAction { param($Owner, $Message, $Title) return $script:FixtureConfirm }
    $controls.WorkflowList.Add_SelectionChanged({ New-EndpointForm })
    $controls.RemoteCommandPicker.Add_SelectionChanged({ Update-EndpointRemoteCommandSelection })
    function Get-FixtureCategoryExpanders {
        param([Windows.DependencyObject]$Parent)
        for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent); $i++) {
            $child = [Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
            if ($child -is [Windows.Controls.Expander] -and $child.Tag -eq 'WorkflowCategory') { $child }
            Get-FixtureCategoryExpanders $child
        }
    }
    function Wait-FixtureResultFilter {
        $deadline = [datetime]::UtcNow.AddSeconds(15)
        do {
            Receive-EndpointResultFilter
            if (-not $ui.ResultFilterState.Timer.IsEnabled) { return }
            Start-Sleep -Milliseconds 20
        } while ([datetime]::UtcNow -lt $deadline)
        throw 'Report filtering did not finish.'
    }
    $window.Show()
    try {
        if ($GroupMembersOnly) {
            Set-EndpointNavigation
            if (@($catalog | Where-Object Id -eq 'group-devices').Count) { throw 'The redundant device-only group task is still present.' }
            $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'get-entra-group-members'
            $expand = $ui.FieldControls.ExpandNestedGroups
            if ($controls.WorkflowTitle.Text -ne 'View Entra group membership' -or
                -not $expand -or $expand.IsChecked -or
                [Windows.Automation.AutomationProperties]::GetName($expand) -ne 'Expand nested groups' -or
                $ui.Selectors.Count -ne 1 -or $ui.FieldControls.ContainsKey('MemberType')) {
                throw 'The consolidated membership form has incorrect controls, accessibility or defaults.'
            }
            $ui.FieldControls.GroupName.Text = 'Fixture Group'
            $arguments = Get-EndpointArguments $ui.Workflow @{GroupName=$ui.FieldControls.GroupName.Text;ExpandNestedGroups=$expand.IsChecked} $ui.Inactive
            if ($arguments.GroupName -ne 'Fixture Group' -or $arguments['ExpandNestedGroups'] -or $arguments.ContainsKey('GroupId')) {
                throw 'Direct membership inputs were not bound correctly.'
            }
            $ui.Selectors[0].Control.SelectedIndex = 1
            $ui.FieldControls.GroupId.Text = '00000000-0000-0000-0000-000000000001'
            $expand.IsChecked = $true
            $arguments = Get-EndpointArguments $ui.Workflow @{GroupId=$ui.FieldControls.GroupId.Text;ExpandNestedGroups=$expand.IsChecked} $ui.Inactive
            if (-not $arguments.ExpandNestedGroups -or $arguments.ContainsKey('GroupName') -or
                $ui.FieldRows.GroupName.Visibility -ne 'Collapsed' -or $ui.FieldRows.GroupId.Visibility -ne 'Visible') {
                throw 'Expanded membership by ID did not hide or omit the inactive group name.'
            }
            foreach ($size in @(@{Width=1000;Height=700},@{Width=1400;Height=940})) {
                $window.Width = $size.Width; $window.Height = $size.Height; $window.UpdateLayout()
                if (-not $controls.RunButton.IsVisible -or
                    $controls.RunButton.TranslatePoint([Windows.Point]::new(0,$controls.RunButton.ActualHeight),$window).Y -gt $window.ActualHeight) {
                    throw 'Membership Run report is hidden at a supported window size.'
                }
                if (-not $expand.Focusable -or -not $expand.Focus()) { throw 'Nested group expansion cannot receive keyboard focus.' }
            }
            Write-Output 'Native unified group membership, optional expansion, accessible inputs and supported layouts passed'
            return
        }
        if ($WUfBOnly) {
            $root = Join-Path $env:TEMP "EndpointToolbox-wufb-settings-$([guid]::NewGuid())"
            try {
                $ui.WUfBSettingsPath = Join-Path $root 'settings.json'
                $ui.ThemePath = $ui.WUfBSettingsPath; $ui.RemoteSettingsPath = $ui.ThemePath; $ui.HistoryPath = Join-Path $root 'history.jsonl'
                $ui.Datasets = @{}
                Set-EndpointNavigation
                $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'wufb-report'
                if ($controls.ExecutionHint.Text -notmatch 'Separate Azure sign-in' -or $ui.FieldControls.ContainsKey('OutputPath')) { throw 'WUfB form requires Graph or an offline import.' }
                $resolveNames = $ui.FieldControls.ResolveDeviceNames
                if (-not $resolveNames -or $resolveNames.IsChecked -or
                    [Windows.Automation.AutomationProperties]::GetName($resolveNames) -ne 'Resolve missing computer names using Graph') {
                    throw 'Optional Graph name lookup is missing, enabled by default or inaccessible.'
                }
                $resolveNames.IsChecked = $true
                if ($controls.ExecutionHint.Text -notmatch 'Graph name lookup' -or $controls.ExecutionHint.Text -notmatch 'same tenant') {
                    throw 'Enabling Graph name lookup did not expose its authentication requirements.'
                }
                $resolveNames.IsChecked = $false
                if ($controls.ExecutionHint.Text -notmatch 'Home Graph is not used') { throw 'Disabling name lookup retained the Graph requirement.' }
                Show-EndpointSettings
                $settings = $ui.Settings
                $settings.Controls.WUfBTab.IsSelected = $true
                $settings.Controls.WUfBWorkspaceBox.Text = '00000000-0000-0000-0000-000000000002'
                $settings.Controls.SaveWUfBSettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                if ((Get-EndpointWUfBSettings $ui.WUfBSettingsPath).WorkspaceId -ne '00000000-0000-0000-0000-000000000002' -or
                    $ui.FieldControls.WorkspaceId.Text -ne '00000000-0000-0000-0000-000000000002') { throw 'WUfB defaults did not persist and populate the task.' }
                $settings.Controls.WUfBWorkspaceBox.Text = 'invalid'
                $settings.Controls.SaveWUfBSettingsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                if ($settings.Controls.WUfBSettingsStatus.Text -notmatch 'Not saved' -or
                    (Get-EndpointWUfBSettings $ui.WUfBSettingsPath).WorkspaceId -ne '00000000-0000-0000-0000-000000000002') { throw 'Invalid settings overwrote the saved workspace.' }
                $settings.Window.Close()
                foreach ($size in @(@{Width=1000;Height=700},@{Width=1400;Height=940})) {
                    $window.Width = $size.Width; $window.Height = $size.Height; $window.UpdateLayout()
                    if (-not $controls.RunButton.IsVisible -or
                        $controls.RunButton.TranslatePoint([Windows.Point]::new(0,$controls.RunButton.ActualHeight),$window).Y -gt $window.ActualHeight) {
                        throw 'WUfB Run report is hidden at a supported window size.'
                    }
                }
                foreach ($name in @('Devices','Update records','Alerts')) {
                    $table = [Data.DataTable]::new($name)
                    foreach ($column in @('DeviceName','DeviceId','State')) { $null = $table.Columns.Add($column) }
                    $ui.Datasets[$name] = $table
                    $null = $controls.DatasetSelector.Items.Add($name)
                }
                $null = $ui.Datasets.Devices.Rows.Add('Same-Fixture-Name','fixture-id-1','Compliant')
                $null = $ui.Datasets.Devices.Rows.Add('Same-Fixture-Name','fixture-id-2','Not compliant')
                $null = $ui.Datasets['Update records'].Rows.Add('Same-Fixture-Name','fixture-id-1','Installed')
                $null = $ui.Datasets['Update records'].Rows.Add('Same-Fixture-Name','fixture-id-2','Failed')
                $null = $ui.Datasets.Alerts.Rows.Add('Same-Fixture-Name','fixture-id-2','Error')
                $controls.DatasetSelector.Add_SelectionChanged({ Update-EndpointResults })
                Register-EndpointWUfBActions
                $controls.ResultsTab.IsEnabled = $true; $controls.OutputTab.IsSelected = $true; $controls.ResultsTab.IsSelected = $true
                $controls.DatasetSelector.SelectedItem = 'Devices'
                $window.UpdateLayout()
                $controls.ResultsGrid.SelectedCells.Add([Windows.Controls.DataGridCellInfo]::new($controls.ResultsGrid.Items[1],$controls.ResultsGrid.Columns[0]))
                if (-not $controls.OpenWUfBUpdates.IsEnabled -or -not $controls.OpenWUfBAlerts.IsEnabled) { throw 'Device drill-down is not available for a selected WUfB row.' }
                $controls.OpenWUfBUpdates.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                Wait-FixtureResultFilter
                if ($controls.ResultsGrid.Items.Count -ne 1 -or $controls.ResultsGrid.Items[0].DeviceId -ne 'fixture-id-2') {
                    throw 'WUfB drill-down conflated devices with duplicate names.'
                }
                $controls.ResultsGrid.SelectedCells.Add([Windows.Controls.DataGridCellInfo]::new($controls.ResultsGrid.Items[0],$controls.ResultsGrid.Columns[0]))
                $controls.OpenWUfBAlerts.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                Wait-FixtureResultFilter
                if ($controls.DatasetSelector.SelectedItem -ne 'Alerts' -or $controls.ResultsGrid.Items.Count -ne 1) { throw 'WUfB alert drill-down lost the selected device.' }
                Write-Output 'Native WUfB settings, input validation, supported layouts and ID-based device drill-down passed'
                return
            }
            finally {
                if ($ui.Settings) { $ui.Settings.Window.Close() }
                if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
            }
        }
        if ($ReportSettingsOnly) {
            $root = Join-Path $env:TEMP "EndpointToolbox-report-settings-$([guid]::NewGuid())"
            $null = New-Item -Path $root -ItemType Directory
            try {
                $ui.ThemePath = Join-Path $root 'settings.json'
                $ui.HistoryPath = Join-Path $root 'history.jsonl'
                $ui.RemoteSettingsPath = ''
                $default = Join-Path $env:TEMP 'endpoint-toolbox'
                $ui.ReportFolder = Get-EndpointReportFolderPreference $ui.ThemePath
                if ($ui.ReportFolder -ne $default) { throw 'New users do not default to %TEMP%\endpoint-toolbox.' }
                '{"Theme":"Dark","TenantId":"example.invalid"}' | Set-Content -LiteralPath $ui.ThemePath
                if ((Get-EndpointReportFolderPreference $ui.ThemePath) -ne $default) { throw 'Legacy preferences do not receive the new default folder.' }
                Set-EndpointNavigation
                $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'mobile-inventory'
                $ui.FormDrafts['cloudpc-last-login'] = @{ Values=@{OutputPath=(Join-Path $root 'override')} }
                $ui.FormDrafts['stale-synced-devices'] = @{ Values=@{OutputPath=$default} }
                Show-EndpointSettings
                $settings = $ui.Settings
                $settings.Controls.ReportsTab.IsSelected = $true
                $settings.Window.UpdateLayout()
                if ($settings.Controls.ReportFolderBox.Text -ne $default -or
                    [Windows.Automation.AutomationProperties]::GetName($settings.Controls.ReportFolderBox) -ne 'Default report folder' -or
                    -not $settings.Controls.SaveReportFolderButton.IsVisible) { throw 'Reports settings are not populated or accessible.' }
                $settings.Controls.ReportFolderBox.Text = 'relative-folder'
                $settings.Controls.SaveReportFolderButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                if ($settings.Controls.ReportFolderStatus.Text -notmatch 'full local or UNC' -or
                    (Get-EndpointReportFolderPreference $ui.ThemePath) -ne $default -or $ui.FieldControls.OutputPath.Text -ne $default) {
                    throw 'Invalid report settings were persisted or changed current report paths.'
                }
                $folder = Join-Path $root 'reports'
                $settings.Controls.ReportFolderBox.Text = $folder
                $settings.Controls.SaveReportFolderButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                if ((Get-EndpointReportFolderPreference $ui.ThemePath) -ne $folder -or
                    -not (Test-Path -LiteralPath $folder -PathType Container) -or
                    $ui.FieldControls.OutputPath.Text -ne $folder -or
                    $ui.FormDrafts['cloudpc-last-login'].Values.OutputPath -ne (Join-Path $root 'override') -or
                    $ui.FormDrafts['stale-synced-devices'].Values.OutputPath -ne $folder) {
                    throw 'Saving the folder did not update defaults, create the directory or preserve overrides.'
                }
                $saveStatus = $settings.Controls.ReportFolderStatus.Text
                $settings.Controls.DeleteReportsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                if ($settings.Controls.ReportFolderStatus.Text -cne $saveStatus -or
                    $settings.Controls.DeleteReportsStatus.Text -notmatch 'No CSV reports') { throw 'Deletion feedback overwrote the folder-save status.' }
                foreach ($size in @(@{Width=1000;Height=700}, @{Width=600;Height=400})) {
                    $settings.Window.Width = $size.Width; $settings.Window.Height = $size.Height
                    $settings.Window.UpdateLayout()
                    $box = $settings.Controls.ReportFolderBox
                    $browse = $settings.Controls.BrowseReportFolderButton
                    $save = $settings.Controls.SaveReportFolderButton
                    $boxPoint = $box.TranslatePoint([Windows.Point]::new(0,0), $settings.Window)
                    $browsePoint = $browse.TranslatePoint([Windows.Point]::new(0,0), $settings.Window)
                    $savePoint = $save.TranslatePoint([Windows.Point]::new(0,0), $settings.Window)
                    $folderStatusPoint = $settings.Controls.ReportFolderStatus.TranslatePoint([Windows.Point]::new(0,0), $settings.Window)
                    $deletePoint = $settings.Controls.DeleteReportsButton.TranslatePoint([Windows.Point]::new(0,0), $settings.Window)
                    $deleteStatusPoint = $settings.Controls.DeleteReportsStatus.TranslatePoint([Windows.Point]::new(0,0), $settings.Window)
                    if ($box.ActualWidth -gt 560 -or $box.ActualWidth -lt 200 -or
                        $browsePoint.X - ($boxPoint.X + $box.ActualWidth) -lt 8 -or [Math]::Abs($browsePoint.Y - $boxPoint.Y) -gt 1 -or
                        $savePoint.X - ($browsePoint.X + $browse.ActualWidth) -lt 8 -or
                        [Math]::Abs($savePoint.Y - $boxPoint.Y) -gt 1 -or
                        $folderStatusPoint.Y - ($savePoint.Y + $save.ActualHeight) -lt 6 -or
                        $deleteStatusPoint.Y - ($deletePoint.Y + $settings.Controls.DeleteReportsButton.ActualHeight) -lt 6) {
                        throw "Reports controls are too wide, misaligned or have insufficient spacing at $($size.Width)x$($size.Height)."
                    }
                    $settings.Controls.ReportsTab.Content.ScrollToBottom()
                    $settings.Window.UpdateLayout()
                    $deletePoint = $settings.Controls.DeleteReportsButton.TranslatePoint([Windows.Point]::new(0,0), $settings.Window)
                    $closePoint = $settings.Controls.CloseSettingsButton.TranslatePoint([Windows.Point]::new(0,0), $settings.Window)
                    if ($deletePoint.Y + $settings.Controls.DeleteReportsButton.ActualHeight -gt $closePoint.Y) {
                        throw 'The delete action cannot be reached in the smaller Settings window.'
                    }
                    foreach ($editor in @(
                        @{Tab='RemoteTab';Field='DnsSuffixBox';Save='SaveRemoteSettingsButton';Status='RemoteSettingsStatus'}
                        @{Tab='GraphTab';Field='TenantIdBox';Save='SaveTenantSettingsButton';Status='TenantSettingsStatus'}
                    )) {
                        $settings.Controls[$editor.Tab].IsSelected = $true
                        $settings.Window.UpdateLayout()
                        $input = $settings.Controls[$editor.Field]
                        $button = $settings.Controls[$editor.Save]
                        $inputPoint = $input.TranslatePoint([Windows.Point]::new(0,0), $settings.Window)
                        $buttonPoint = $button.TranslatePoint([Windows.Point]::new(0,0), $settings.Window)
                        $statusPoint = $settings.Controls[$editor.Status].TranslatePoint([Windows.Point]::new(0,0), $settings.Window)
                        if ($buttonPoint.X - ($inputPoint.X + $input.ActualWidth) -lt 8 -or
                            [Math]::Abs($buttonPoint.Y - $inputPoint.Y) -gt 1 -or
                            $buttonPoint.X + $button.ActualWidth -gt $settings.Window.ActualWidth -or
                            $statusPoint.Y - ($buttonPoint.Y + $button.ActualHeight) -lt 6) {
                            throw "$($editor.Tab) Save is not beside its field, is clipped, or overlaps feedback."
                        }
                    }
                    $settings.Controls.ReportsTab.IsSelected = $true
                }
                $settings.Window.Width = 1000; $settings.Window.Height = 700
                $settings.Controls.ReportsTab.Content.ScrollToTop()
                $settings.Window.UpdateLayout()
                if ((Get-EndpointThemePreference $ui.ThemePath) -ne 'Dark' -or (Get-EndpointTenantPreference $ui.ThemePath) -ne 'example.invalid') {
                    throw 'Saving report settings overwrote appearance or tenant preferences.'
                }
                Save-EndpointThemePreference $ui.ThemePath 'Light'
                $null = Save-EndpointTenantPreference $ui.ThemePath 'other.example.invalid'
                if ((Get-EndpointReportFolderPreference $ui.ThemePath) -ne $folder) { throw 'Other settings overwrote the report folder.' }
                $reloaded = @(Get-EndpointCatalog -ReportFolder (Get-EndpointReportFolderPreference $ui.ThemePath))
                foreach ($workflow in $reloaded) {
                    foreach ($field in $workflow.Fields | Where-Object { $_.Name -in @('OutputPath','ExportFolder') -and $_.Default }) {
                        if ($field.Default -ne $folder) { throw "The saved folder was not applied to $($workflow.Id)." }
                    }
                }
                $file = ($reloaded | Where-Object Id -eq 'add-primary-devices-to-group').Fields | Where-Object Name -eq 'OutputFile'
                if ($file.Default -ne (Join-Path $folder 'PrimaryUserDeviceGroupResults.csv') -or
                    (($reloaded | Where-Object Id -eq 'primary-users').Fields | Where-Object Name -eq 'CsvPath').Default) {
                    throw 'CSV filenames were not retained or optional exports became enabled.'
                }
                $mobile = $reloaded | Where-Object Id -eq 'mobile-inventory'
                if ((Get-EndpointArguments $mobile @{OutputPath=''}).OutputPath -ne $folder -or
                    (Get-EndpointArguments $mobile @{OutputPath=(Join-Path $root 'override')}).OutputPath -ne (Join-Path $root 'override')) {
                    throw 'Blank report paths reverted to script defaults or explicit overrides were ignored.'
                }
                $picker = New-EndpointReportSaveDialog
                if ($picker.InitialDirectory -ne $folder) { throw 'Export view does not start in the saved folder.' }
                $override = Join-Path $root 'override'
                $null = New-Item -Path $override -ItemType Directory
                $picker = New-EndpointReportSaveDialog (Join-Path $override 'chosen.csv')
                if ($picker.InitialDirectory -ne $override -or $picker.FileName -ne 'chosen.csv') { throw 'A per-run CSV path was overridden by the default folder.' }
                function script:Confirm-EndpointAction {
                    param($Owner, $Message, $Title)
                    $script:FixtureConfirmationMessage = $Message
                    if ($script:FixtureStartRunDuringConfirmation) { $script:Ui.Active = [pscustomobject]@{WorkflowId='offline-fixture'} }
                    return $script:FixtureConfirm
                }
                $script:FixtureStartRunDuringConfirmation = $false
                $firstCsv = Join-Path $folder 'a.csv'
                $lockedCsv = Join-Path $folder 'b.CSV'
                $notes = Join-Path $folder 'notes.txt'
                $nested = Join-Path $folder 'nested'
                $null = New-Item -Path $nested -ItemType Directory
                $nestedCsv = Join-Path $nested 'keep.csv'
                $outsideCsv = Join-Path $override 'keep.csv'
                foreach ($path in @($firstCsv, $lockedCsv, $notes, $nestedCsv, $outsideCsv)) { Set-Content -LiteralPath $path -Value 'Synthetic report' }
                $settings.Controls.ReportFolderBox.Text = $override
                $settings.Controls.DeleteReportsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                if ($settings.Controls.DeleteReportsStatus.Text -notmatch 'Save or discard' -or -not (Test-Path -LiteralPath $firstCsv)) {
                    throw 'Report deletion accepted an unsaved folder edit.'
                }
                $settings.Controls.ReportFolderBox.Text = $folder
                $ui.Active = [pscustomobject]@{WorkflowId='offline-fixture'}
                $settings.Controls.DeleteReportsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                $ui.Active = $null
                if ($settings.Controls.DeleteReportsStatus.Text -notmatch 'Wait for the running operation' -or -not (Test-Path -LiteralPath $firstCsv)) {
                    throw 'Report deletion was allowed during an active run.'
                }
                $script:FixtureConfirm = $false
                $settings.Controls.DeleteReportsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                if (-not (Test-Path -LiteralPath $firstCsv) -or -not (Test-Path -LiteralPath $lockedCsv) -or
                    $settings.Controls.DeleteReportsStatus.Text -notmatch 'Cancelled' -or
                    $script:FixtureConfirmationMessage -notmatch '2 CSV report' -or
                    -not $script:FixtureConfirmationMessage.Contains($folder)) { throw 'Deletion confirmation did not show the folder/count or cancellation deleted reports.' }
                $script:FixtureConfirm = $true
                $script:FixtureStartRunDuringConfirmation = $true
                $settings.Controls.DeleteReportsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                $script:FixtureStartRunDuringConfirmation = $false
                $ui.Active = $null
                if ($settings.Controls.DeleteReportsStatus.Text -notmatch 'started during confirmation' -or
                    -not (Test-Path -LiteralPath $firstCsv)) { throw 'Report deletion was allowed when a run started during confirmation.' }
                $lock = [IO.File]::Open($lockedCsv, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                try {
                    $settings.Controls.DeleteReportsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                    if ($settings.Controls.DeleteReportsStatus.Text -notmatch 'Deleted 1 of 2.*stopped' -or
                        (Test-Path -LiteralPath $firstCsv) -or -not (Test-Path -LiteralPath $lockedCsv)) { throw 'A locked report was silently ignored or partial deletion was not reported.' }
                }
                finally { $lock.Dispose() }
                $settings.Controls.DeleteReportsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                if ((Test-Path -LiteralPath $lockedCsv) -or $settings.Controls.DeleteReportsStatus.Text -notmatch 'Deleted 1 CSV' -or
                    -not (Test-Path -LiteralPath $notes) -or -not (Test-Path -LiteralPath $nestedCsv) -or
                    -not (Test-Path -LiteralPath $outsideCsv) -or -not (Test-Path -LiteralPath $folder -PathType Container)) {
                    throw 'Report deletion left CSVs behind or deleted files outside the agreed scope.'
                }
                $script:FixtureConfirmationMessage = ''
                $settings.Controls.DeleteReportsButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                if ($script:FixtureConfirmationMessage -or $settings.Controls.DeleteReportsStatus.Text -notmatch 'No CSV reports') { throw 'An empty report folder prompted for deletion or was misreported.' }
                $settings.Window.Close(); $ui.Settings = $null
                Show-EndpointSettings
                if ($ui.Settings.Controls.ReportFolderBox.Text -ne $folder) { throw 'Reopening Settings lost the saved report folder.' }
                $ui.Settings.Window.Close(); $ui.Settings = $null
                'Native report folder persistence, validation, defaults, overrides and export dialogs passed.'
                'Native report deletion confirmation, cancellation, scope, active-run blocking and partial errors passed.'
            }
            finally {
                $script:FixtureConfirm = $true
                if ($ui.Settings) { $ui.Settings.Window.Close(); $ui.Settings = $null }
                Remove-Item -LiteralPath $root -Recurse -Force
            }
            return
        }
        if ($ExpanderFocusOnly) {
            Set-EndpointNavigation
            $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'device-investigation'
            $window.UpdateLayout()
            $sidebar = Get-FixtureCategoryExpanders $controls.WorkflowList | Where-Object Header -eq 'Inventory'
            $details = $controls.Form.Children | Where-Object { $_ -is [Windows.Controls.Expander] -and $_.Header -eq 'Script permissions & details' }
            if (-not $sidebar -or -not $details) { throw 'Expected sidebar and task-detail expanders were not rendered.' }
            foreach ($expander in @($sidebar, $details)) {
                $expander.ApplyTemplate() | Out-Null
                $header = $expander.Template.FindName('HeaderToggle', $expander)
                if (-not $header.Focus() -or -not $header.IsKeyboardFocused -or -not $header.FocusVisualStyle) {
                    throw 'An expander heading cannot receive focus or has lost its keyboard focus cue.'
                }
                $window.UpdateLayout()
                $border = $header.Template.FindName('HeaderBorder', $header)
                if ($border.BorderBrush.Color.A -ne 0) { throw 'Focusing an expander heading still adds a persistent border.' }
                $wasExpanded = $expander.IsExpanded
                $peer = [Windows.Automation.Peers.ToggleButtonAutomationPeer]::new($header)
                ([Windows.Automation.Provider.IToggleProvider]$peer.GetPattern([Windows.Automation.Peers.PatternInterface]::Toggle)).Toggle()
                $window.UpdateLayout()
                if ($expander.IsExpanded -eq $wasExpanded -or $border.BorderBrush.Color.A -ne 0) {
                    throw 'Toggling an expander failed or added a persistent border.'
                }
            }
            'Native expander toggling without persistent borders and preserved keyboard focus cues passed.'
            return
        }
        if ($NavigationOnly) {
            Set-EndpointNavigation -InitiallyCollapsed
            Show-EndpointHome
            $window.UpdateLayout()
            $groups = @(Get-FixtureCategoryExpanders $controls.WorkflowList)
            if ($groups.Count -ne @($catalog.Category | Select-Object -Unique).Count -or
                @($groups | Where-Object IsExpanded).Count -ne 0 -or $ui.NavigationNeedsExpansion -or
                $controls.HomePanel.Visibility -ne 'Visible') {
                throw 'Startup did not show Home with every sidebar category collapsed.'
            }
            'Native collapsed startup menus passed.'
            foreach ($placement in @(
                @{ Id='user-sign-in-history'; Category='Inventory'; Previous='Device reports' }
                @{ Id='get-entra-group-members'; Category='Groups'; Previous='Inventory' }
            )) {
                Set-EndpointNavigation
                $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq $placement.Id
                $window.UpdateLayout()
                $groups = @(Get-FixtureCategoryExpanders $controls.WorkflowList)
                if ($ui.Workflow.Id -ne $placement.Id -or $controls.CategoryLabel.Text -ne $placement.Category.ToUpperInvariant() -or
                    @($groups | Where-Object IsExpanded).Count -ne 1 -or
                    @($groups | Where-Object { $_.IsExpanded -and $_.Header -eq $placement.Category }).Count -ne 1) {
                    throw "Selecting $($placement.Id) did not open its $($placement.Category) menu and category heading."
                }
                Set-EndpointNavigation $placement.Category
                if (@($controls.WorkflowList.Items | Where-Object Id -eq $placement.Id).Count -ne 1) {
                    throw "Searching the $($placement.Category) menu did not find $($placement.Id)."
                }
                $window.UpdateLayout()
                if (@(Get-FixtureCategoryExpanders $controls.WorkflowList | Where-Object { -not $_.IsExpanded }).Count) {
                    throw 'Search results are hidden in a collapsed category.'
                }
                Set-EndpointNavigation $placement.Previous
                if (@($controls.WorkflowList.Items | Where-Object Id -eq $placement.Id).Count -ne 0) {
                    throw "$($placement.Id) is still listed under its previous menu."
                }
            }
            'Native workflow menu placement, expansion, heading and search passed.'
            return
        }
        Set-EndpointNavigation
        $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'user-sign-in-history'
        if (-not $ui.FieldControls.UserIdentity -or $ui.FieldControls.LookbackDays.Text -ne '30' -or
            $ui.FieldControls.FailuresOnly.IsChecked -or $ui.FieldControls.ReportMode.SelectedItem -ne 'Paged events' -or
            [Windows.Automation.AutomationProperties]::GetName($ui.FieldControls.UserIdentity) -ne 'User UPN or primary email address *') {
            throw 'The user sign-in history form is missing accessible inputs or has incorrect defaults.'
        }
        $ui.FieldControls.UserIdentity.Text = 'fixture@example.invalid'
        $ui.FieldControls.LookbackDays.Text = '1'
        $ui.FieldControls.FailuresOnly.IsChecked = $true
        $ui.FieldControls.ReportMode.SelectedItem = 'Detailed events'
        $signInArguments = Get-EndpointArguments $ui.Workflow @{ UserIdentity=$ui.FieldControls.UserIdentity.Text; LookbackDays=$ui.FieldControls.LookbackDays.Text; FailuresOnly=$ui.FieldControls.FailuresOnly.IsChecked; ReportMode=$ui.FieldControls.ReportMode.SelectedItem }
        if ($signInArguments.LookbackDays -ne 1 -or -not $signInArguments.FailuresOnly -or $signInArguments.ReportMode -ne 'Detailed events') { throw 'User sign-in history form inputs were not bound.' }
        $ui.SignInPaging = @{ Arguments=$signInArguments; HasMore=$true; Received=100 }
        Update-EndpointSignInPagingControls
        if (-not $controls.LoadMoreSignIns.IsEnabled -or -not $controls.RetrieveAllSignIns.IsEnabled -or
            $controls.SignInPagingStatus.Text -notmatch 'Incomplete') { throw 'An incomplete sign-in report cannot be continued or is not marked incomplete.' }
        $ui.Graph = [pscustomobject]@{ Invocation=$null }
        $ui.Graph | Add-Member -MemberType ScriptMethod -Name RunFile -Value {
            param($path,$invocation,$requireGraph,$requiredCommands)
            $this.Invocation = $invocation
        }
        $ui.FieldControls.UserIdentity.Text = ''
        $ui.FieldControls.LookbackDays.Text = 'not a number'
        Invoke-EndpointRun -SignInAction More
        if ($ui.Graph.Invocation.SignInAction -ne 'More' -or
            $ui.Graph.Invocation.ScriptArguments.UserIdentity -ne 'fixture@example.invalid' -or
            $ui.Graph.Invocation.ScriptArguments.LookbackDays -ne 1) { throw 'Continuing a report validated edited inputs or did not preserve the original inputs.' }
        $ui.Active = $null
        $controls.Form.IsEnabled = $true; $controls.WorkflowList.IsEnabled = $true; $controls.Search.IsEnabled = $true
        $ui.FieldControls.UserIdentity.Text = 'fixture@example.invalid'
        $ui.FieldControls.LookbackDays.Text = '1'
        $ui.Active = [pscustomobject]@{ WorkflowId='user-sign-in-history'; Failures=$false; Warnings=$false; PendingApproval=$false }
        Update-EndpointSignInPagingControls
        if ($controls.LoadMoreSignIns.IsEnabled -or $controls.RetrieveAllSignIns.IsEnabled) { throw 'Paging controls allow concurrent requests.' }
        $hostBridge = [EndpointToolbox.DesktopHost]::new()
        $ui.Datasets = @{}
        $first = [EndpointToolbox.PreparedReport]::new('Sign-in events', @([pscustomobject]@{SignInId='first'}), $hostBridge)
        Add-EndpointRows 'Sign-in events' $first
        $controls.DatasetSelector.SelectedItem = 'Sign-in events'
        $combined = [EndpointToolbox.PreparedReport]::new('Sign-in events', @([pscustomobject]@{SignInId='first'}, [pscustomobject]@{SignInId='next'}), $hostBridge)
        Add-EndpointRows 'Sign-in events' $combined
        if ($controls.DatasetSelector.Items.Count -ne 1 -or $ui.Datasets['Sign-in events'].Rows.Count -ne 2 -or
            $controls.ResultsGrid.Items.Count -ne 2) { throw 'Continuing a sign-in report duplicated the dataset or failed to replace the displayed cumulative rows.' }
        $ui.Active = $null; $ui.SignInPaging.HasMore = $false
        Update-EndpointSignInPagingControls
        if ($controls.LoadMoreSignIns.IsEnabled -or $controls.RetrieveAllSignIns.IsEnabled -or
            $controls.SignInPagingStatus.Text -notmatch 'no more pages') { throw 'Completed paging is not marked complete.' }
        $ui.Datasets = @{}; $controls.DatasetSelector.Items.Clear(); $controls.ResultsGrid.ItemsSource = $null
        $ui.SignInPaging = $null
        $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'device-usage'
        $ui.Selectors[0].Control.SelectedIndex = 2
        $ui.FieldControls.EntraGroup.Text = 'Synthetic group'
        $ui.FieldControls.Devices.Text = 'Synthetic-PC'
        $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'm365-cloud-update'
        $ui.FieldControls.IncludeWaveGroups.IsChecked = $true
        $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'device-usage'
        if ($ui.Selectors[0].Control.SelectedIndex -ne 2 -or $ui.FieldControls.EntraGroup.Text -ne 'Synthetic group' -or
            $ui.FieldControls.Devices.Text -ne 'Synthetic-PC') { throw 'Changing tasks lost the selected source or active/inactive draft inputs.' }
        $controls.OutputTab.IsSelected = $true
        Set-EndpointNavigation 'no-such-task-offline-fixture'
        if ($ui.Workflow.Id -ne 'device-usage' -or $controls.SearchEmpty.Visibility -ne 'Visible' -or
            -not $controls.OutputTab.IsSelected -or $ui.FieldControls.EntraGroup.Text -ne 'Synthetic group') {
            throw 'An empty search changed the selected task, results view or draft, or failed to show its empty state.'
        }
        Set-EndpointNavigation 'Cloud Update'
        if ($ui.Workflow.Id -ne 'device-usage' -or $controls.WorkflowList.SelectedItem -or -not $controls.OutputTab.IsSelected) {
            throw 'Filtering to another task navigated away from the selected task or results.'
        }
        Set-EndpointNavigation 'device user usage'
        if ($ui.Workflow.Id -ne 'device-usage' -or $ui.Selectors[0].Control.SelectedIndex -ne 2 -or
            $ui.FieldControls.EntraGroup.Text -ne 'Synthetic group') { throw 'Searching with no matches lost the task draft.' }
        Set-EndpointNavigation
        $window.UpdateLayout()
        $groups = @(Get-FixtureCategoryExpanders $controls.WorkflowList)
        if ($groups.Count -ne @($catalog.Category | Select-Object -Unique).Count -or
            @($groups | Where-Object IsExpanded).Count -ne 1 -or
            @($groups | Where-Object { $_.IsExpanded -and $_.Header -eq 'Device reports' }).Count -ne 1) {
            throw 'Clearing search must show every category and expand only the active category.'
        }
        $header = $groups[0].Template.FindName('HeaderToggle', $groups[0])
        if (-not $header -or -not $header.Focusable) { throw 'Category expansion is not keyboard focusable.' }
        foreach ($key in @([Windows.Input.Key]::Right, [Windows.Input.Key]::Left)) {
            $event = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, [Windows.PresentationSource]::FromVisual($window), 0, $key)
            $event.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent
            $header.RaiseEvent($event)
            if (-not $event.Handled -or $groups[0].IsExpanded -ne ($key -eq [Windows.Input.Key]::Right)) {
                throw "Category header did not handle $key to expand or collapse."
            }
        }
        $controls.HomePanel.Visibility = 'Visible'; $controls.TaskPanel.Visibility = 'Collapsed'
        Set-EndpointNavigation 'Cloud Update'
        if ($controls.HomePanel.Visibility -ne 'Visible' -or $controls.TaskPanel.Visibility -ne 'Collapsed') { throw 'Searching while on Home navigated away from Home.' }
        Set-EndpointNavigation
        $controls.HomePanel.Visibility = 'Collapsed'; $controls.TaskPanel.Visibility = 'Visible'
        foreach ($workflow in $catalog) {
            Set-EndpointNavigation $workflow.Title
            if (@($controls.WorkflowList.Items | Where-Object Id -eq $workflow.Id).Count -ne 1 -or $ui.Workflow.Id -ne 'device-usage') {
                throw "Searching did not find $($workflow.Id) without changing the selected task."
            }
        }
        Set-EndpointNavigation 'Get-DeviceUserUsage.ps1'
        if (@($controls.WorkflowList.Items | Where-Object Id -eq 'device-usage').Count -ne 1) { throw 'Searching by script path did not find the task.' }
        Set-EndpointNavigation 'Device reports'
        if (@($controls.WorkflowList.Items).Count -ne @($catalog | Where-Object Category -eq 'Device reports').Count) { throw 'Searching by category did not find every task in it.' }
        $window.UpdateLayout()
        if (@(Get-FixtureCategoryExpanders $controls.WorkflowList | Where-Object { -not $_.IsExpanded }).Count) { throw 'Search results are hidden in a collapsed category.' }
        Set-EndpointNavigation
        $table = [Data.DataTable]::new('Fixture')
        $null = $table.Columns.Add('Name')
        $null = $table.Columns.Add('Device')
        $null = $table.Rows.Add("Fixture's [100%]", 'Device-A')
        $null = $table.Rows.Add('Other', 'Device-B')
        $ui.Datasets = @{ Fixture = $table }
        $null = $controls.DatasetSelector.Items.Add('Fixture')
        $controls.DatasetSelector.SelectedItem = 'Fixture'
        $script:FixtureViewResets = 0
        $handler = [ComponentModel.ListChangedEventHandler]{
            param($sender, $eventArgs)
            if ($eventArgs.ListChangedType -eq [ComponentModel.ListChangedType]::Reset) { $script:FixtureViewResets++ }
        }
        $table.DefaultView.add_ListChanged($handler)
        try {
            Update-EndpointResults
            if ($script:FixtureViewResets -ne 0 -or $controls.ResultsGrid.Items.Count -ne 2) { throw 'Opening an unfiltered report unnecessarily rebuilt its view or lost rows.' }
            $controls.ResultFilter.Text = "Fixture's [100%]"
            Update-EndpointResults
            if ($controls.SaveResultsButton.IsEnabled -or $controls.ResultsGrid.IsEnabled) { throw 'Pending filter left stale results available.' }
            Wait-FixtureResultFilter
            if ($controls.ResultsGrid.Items.Count -ne 1 -or $controls.ResultsGrid.Items[0].Name -ne "Fixture's [100%]") { throw 'Filtering did not preserve literal special characters.' }
            $script:FixtureViewResets = 0
            Update-EndpointResults
            if ($script:FixtureViewResets -ne 0) { throw 'Refreshing an unchanged filter unnecessarily rebuilt its view.' }
            $controls.ResultFilter.Clear()
            Update-EndpointResults
            if ($controls.ResultsGrid.Items.Count -ne 2) { throw 'Clearing the report filter did not restore all rows.' }
            $controls.ResultFilter.Text = 'missing'
            Update-EndpointResults
            Wait-FixtureResultFilter
            if ($controls.ResultsGrid.Items.Count -ne 0 -or -not $controls.SaveResultsButton.IsEnabled) { throw 'A filter with no matches did not finish correctly.' }
            $controls.ResultFilter.Clear()
            Update-EndpointResults
            $ui.Active = [pscustomobject]@{}
            $controls.ResultFilter.Text = 'Late'
            Update-EndpointResults
            $ui.ResultFilterState.Due = [datetime]::UtcNow.AddSeconds(-1)
            Receive-EndpointResultFilter
            if ($ui.ResultFilterState.Task -or $controls.ResultFilterStatus.Text -notmatch 'finish loading') { throw 'Filtering raced with a report still receiving rows.' }
            $null = $table.Rows.Add('Late arrival', 'Device-Late')
            $ui.Active = $null
            Wait-FixtureResultFilter
            if ($controls.ResultsGrid.Items.Count -ne 1 -or $controls.ResultsGrid.Items[0].Name -ne 'Late arrival') { throw 'Filtering omitted a row added while the report was loading.' }
            $table.Rows.RemoveAt(2)
            $controls.ResultFilter.Text = 'Other'
            Update-EndpointResults
            $ui.ResultFilterState.Due = [datetime]::UtcNow.AddSeconds(-1)
            Receive-EndpointResultFilter
            $controls.ResultFilter.Text = 'Device-A'
            Update-EndpointResults
            Wait-FixtureResultFilter
            if ($controls.ResultsGrid.Items.Count -ne 1 -or $controls.ResultsGrid.Items[0].Device -ne 'Device-A' -or
                $ui.ResultFilterState.View.Count -ne 1 -or $ui.ResultFilterState.View[0].Device -ne 'Device-A') {
                throw 'An obsolete filter replaced the latest grid or export view.'
            }
            $otherTable = [Data.DataTable]::new('Other fixture')
            $null = $otherTable.Columns.Add('Device')
            $null = $otherTable.Rows.Add('Device-Other')
            $ui.Datasets['Other fixture'] = $otherTable
            $null = $controls.DatasetSelector.Items.Add('Other fixture')
            $controls.ResultFilter.Text = 'Device'
            Update-EndpointResults
            $ui.ResultFilterState.Due = [datetime]::UtcNow.AddSeconds(-1)
            Receive-EndpointResultFilter
            $controls.DatasetSelector.SelectedItem = 'Other fixture'
            Update-EndpointResults
            Wait-FixtureResultFilter
            if ($controls.ResultsGrid.Items.Count -ne 1 -or $controls.ResultsGrid.Items[0].Device -ne 'Device-Other' -or
                $ui.ResultFilterState.View[0].Device -ne 'Device-Other') { throw 'Changing datasets applied a stale filter result.' }
            $controls.DatasetSelector.SelectedItem = 'Fixture'
            $controls.ResultFilter.Clear()
            Update-EndpointResults
            $table.DefaultView.Sort = 'Name DESC'
            $controls.ResultFilter.Text = 'device-'
            Update-EndpointResults
            Wait-FixtureResultFilter
            if ($controls.ResultsGrid.Items.Count -ne 2 -or $controls.ResultsGrid.Items[0].Name -ne 'Other') {
                throw 'Filtering did not preserve the source view order.'
            }
            $controls.ResultFilter.Clear()
            Update-EndpointResults
            $table.DefaultView.Sort = ''
            $controls.ResultsTab.IsEnabled = $true
            $controls.ResultsTab.IsSelected = $true
            $window.UpdateLayout()
            $grid = $controls.ResultsGrid
            if ($grid.SelectionUnit -ne 'Cell' -or $grid.SelectionMode -ne 'Extended' -or $grid.ClipboardCopyMode -ne 'ExcludeHeader') {
                throw 'Report grid does not support copying selected cells without headers.'
            }
            $null = $table.Rows.Add('Last', 'Device-C')
            $controls.ResultFilter.Text = 'device-'
            Update-EndpointResults
            Wait-FixtureResultFilter
            if ($grid.Items.Count -ne 3) { throw 'Case-insensitive filtering did not include all matching rows.' }
            $grid.Items.SortDescriptions.Add([ComponentModel.SortDescription]::new('Name', [ComponentModel.ListSortDirection]::Descending))
            if ($grid.Items[0].Name -ne 'Other') { throw 'Filtered report rows could not be sorted.' }
            $grid.Items.SortDescriptions.Clear()
            $script:CopiedRows = [Collections.Generic.List[string]]::new()
            $script:ExpectedCopyRows = 1
            # Stop the native copy command after formatting so the user's clipboard is untouched.
            $copyHandler = [EventHandler[Windows.Controls.DataGridRowClipboardEventArgs]]{
                param($sender, $eventArgs)
                $script:CopiedRows.Add($eventArgs.FormatClipboardCellValues('UnicodeText'))
                if ($script:CopiedRows.Count -eq $script:ExpectedCopyRows) { throw 'Stop before changing the clipboard' }
            }
            $grid.add_CopyingRowClipboardContent($copyHandler)
            try {
                foreach ($case in @(
                    @{ Cells=@(@{Row=0; Column=0}); Expected="Fixture's [100%]`r`n"; Rows=1 }
                    @{ Cells=@(@{Row=0; Column=0}, @{Row=2; Column=0}); Expected="Fixture's [100%]`r`nLast`r`n"; Rows=2 }
                    @{ Cells=@(@{Row=0; Column=0}, @{Row=0; Column=1}); Expected="Fixture's [100%]`tDevice-A`r`n"; Rows=1 }
                )) {
                    $script:CopiedRows.Clear()
                    $script:ExpectedCopyRows = $case.Rows
                    $grid.SelectedCells.Clear()
                    foreach ($cell in $case.Cells) {
                        $grid.SelectedCells.Add([Windows.Controls.DataGridCellInfo]::new($grid.Items[$cell.Row], $grid.Columns[$cell.Column]))
                    }
                    try { [Windows.Input.ApplicationCommands]::Copy.Execute($null, $grid) }
                    catch {
                        if ($_ -notmatch 'Stop before changing the clipboard') { throw }
                    }
                    if (($script:CopiedRows -join '') -ne $case.Expected) {
                        throw "Copy did not produce only the selected cells: $($script:CopiedRows -join '|')"
                    }
                }
            }
            finally {
                $grid.remove_CopyingRowClipboardContent($copyHandler)
                $grid.SelectedCells.Clear()
            }
            'Native report cell selection and copy passed.'
        }
        finally {
            if ($ui.ResultFilterState) { $ui.ResultFilterState.Timer.Stop() }
            $table.DefaultView.remove_ListChanged($handler)
            $controls.ResultsGrid.ItemsSource = $null; $controls.DatasetSelector.Items.Clear()
        }
        $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'add-members-to-group'
        $targetPanel = $ui.FieldRows.GroupId.Parent
        if ($targetPanel.Children.IndexOf($ui.Selectors[0].Control) -ge $targetPanel.Children.IndexOf($ui.FieldRows.GroupId) -or
            $targetPanel.Children.IndexOf($ui.Selectors[1].Control) -le $targetPanel.Children.IndexOf($ui.FieldRows.GroupName) -or
            $targetPanel.Children.IndexOf($ui.Selectors[1].Control) -ge $targetPanel.Children.IndexOf($ui.FieldRows.Users)) {
            throw 'Source selectors are not adjacent to their corresponding target and member fields.'
        }
        $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'delete-win32-apps'
        $targetSection = $ui.FieldRows.AppName.Parent.Parent
        $modeSection = $ui.FieldRows.WhatIf.Parent.Parent
        if ($controls.Form.Children.IndexOf($targetSection) -ge $controls.Form.Children.IndexOf($modeSection)) {
            throw 'Execution mode must follow the target inputs.'
        }
        $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'intune-script-device-status'
        Set-EndpointScriptChoices ([pscustomobject]@{
            ScriptType='All'
            Choices=@([pscustomobject]@{Id='00000000-0000-0000-0000-000000000001';ScriptType='Remediation';DisplayName='Fixture script';Display='Remediation | Fixture script'})
        })
        $ui.ScriptPicker.Search.Text = 'Fixture'
        $ui.ScriptPicker.List.SelectedIndex = 0
        $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'm365-cloud-update'
        if (-not $ui.FieldControls.IncludeWaveGroups.IsChecked -or $ui.FieldControls.ContainsKey('WaveGroupNames')) { throw 'The Cloud Update switch draft was not restored or group names escaped Settings.' }
        $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'intune-script-device-status'
        if ($ui.ScriptPicker.Search.Text -ne 'Fixture' -or -not $ui.ScriptPicker.Selected -or -not $controls.RunButton.IsEnabled) { throw 'Loaded script selection was not restored with the task draft.' }
        $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'm365-cloud-update'
        Clear-EndpointScriptPickerDrafts
        $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'intune-script-device-status'
        if ($ui.ScriptPicker.Selected -or $ui.ScriptPicker.LoadedType -or $controls.RunButton.IsEnabled) { throw 'Changing Graph connection did not invalidate saved script choices.' }
        $controls.WorkflowList.SelectedItem = $catalog | Where-Object Id -eq 'm365-cloud-update'

        $ui.FieldControls.PageSize.Text = '201'
        Invoke-EndpointRun
        if ($ui.FieldErrors.PageSize.Visibility -ne 'Visible' -or $ui.FieldErrors.PageSize.Text -notmatch 'Devices per API page' -or
            -not $ui.FieldControls.PageSize.IsKeyboardFocusWithin -or
            [Windows.Automation.AutomationProperties]::GetLiveSetting($ui.FieldErrors.PageSize) -ne 'Polite') {
            throw "Invalid page size error: visibility=$($ui.FieldErrors.PageSize.Visibility), text=$($ui.FieldErrors.PageSize.Text), focused=$($ui.FieldControls.PageSize.IsKeyboardFocusWithin), controlVisible=$($ui.FieldControls.PageSize.IsVisible), task=$($controls.TaskPanel.Visibility), tab=$($controls.ConfigureTab.IsSelected), live=$([Windows.Automation.AutomationProperties]::GetLiveSetting($ui.FieldErrors.PageSize))."
        }
        $ui.FieldControls.PageSize.Text = '200'
        if ($ui.FieldErrors.PageSize.Visibility -ne 'Collapsed') { throw 'Editing a field did not clear the prior validation message.' }
        Invoke-EndpointRun
        if ($ui.FieldErrors.IncludeWaveGroups.Visibility -ne 'Visible' -or
            $ui.FieldErrors.IncludeWaveGroups.Text -notmatch 'Settings > Cloud Update' -or
            -not $ui.FieldControls.IncludeWaveGroups.IsKeyboardFocusWithin) {
            throw 'An empty enabled rollout list was not rejected beside the option before execution.'
        }

        $commands = @(Get-EndpointRemoteCommands)
        $controls.RemoteCommandPicker.ItemsSource = $commands
        $controls.RemoteCommand.Text = 'Write-Output "custom"'
        $controls.RemoteCommandPicker.SelectedIndex = 0
        if ($controls.RemoteCommandPicker.SelectedIndex -ne -1 -or $controls.RemoteCommand.Text -ne 'Write-Output "custom"') {
            throw 'Declining to replace a manually entered command did not preserve it.'
        }
        $script:FixtureConfirm = $true
        $controls.RemoteCommandPicker.SelectedIndex = 0
        $first = $controls.RemoteCommandPicker.SelectedItem
        if ($controls.RemoteCommand.Text -cne $first.Command) { throw 'Approving command replacement did not load the saved command.' }
        $controls.RemoteCommand.Text = 'Write-Output "edited"'
        $script:FixtureConfirm = $false
        $controls.RemoteCommandPicker.SelectedIndex = 1
        if ($controls.RemoteCommandPicker.SelectedItem -ne $first -or $controls.RemoteCommand.Text -ne 'Write-Output "edited"') {
            throw 'Declining to replace an edited saved command did not restore the selection and text.'
        }
        $script:FixtureConfirm = $true
        $controls.RemoteCommandPicker.SelectedIndex = 1
        if ($controls.RemoteCommand.Text -cne $controls.RemoteCommandPicker.SelectedItem.Command) { throw 'Approving replacement did not load the next command.' }
        'Task drafts, inline validation and remote command confirmation passed.'
    }
    finally { $window.Close() }
} $desktop $NavigationOnly $ExpanderFocusOnly $ReportSettingsOnly $WUfBOnly $GroupMembersOnly
