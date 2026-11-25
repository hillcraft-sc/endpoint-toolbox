[CmdletBinding()]
param([string]$SnapshotDirectory)
$ErrorActionPreference = 'Stop'
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs')
& (Get-Module EndpointToolboxUI) {
    param($desktop, $SnapshotDirectory)
    $previous = Get-Variable Ui -Scope Script -ValueOnly -ErrorAction Ignore
    $root = Join-Path $env:TEMP "EndpointToolbox-theme-$([guid]::NewGuid())"
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((Join-Path $desktop 'MainWindow.xaml')))
    $controls = @{}
    foreach ($node in ([xml](Get-Content -LiteralPath (Join-Path $desktop 'MainWindow.xaml') -Raw)).SelectNodes('//*[@Name]')) {
        $name = $node.GetAttribute('Name'); $controls[$name] = $window.FindName($name)
    }
    $graph = [EndpointToolbox.DesktopEngine]::new()
    $remote = [EndpointToolbox.DesktopEngine]::new()
    $script:Ui = @{
        Window=$window; Controls=$controls; Catalog=@(Get-EndpointCatalog); Workflow=$null
        Graph=$graph; Remote=$remote; Active=$null; FieldControls=@{}; FieldRows=@{}
        Selectors=@(); Inactive=@(); GraphContext=$null; LogRoot=''; Choice=$null; Faulted=$false
        TestMode=$true; Settings=$null; ThemePath=(Join-Path $root 'settings.json')
    }
    $ui = $script:Ui
    function Assert-Color($Actual, [string]$Expected, [string]$Message) {
        if ($Actual.ToString() -ne $Expected) { throw "$Message Expected $Expected, got $Actual." }
    }
    function Get-Luminance([Windows.Media.Color]$Color) {
        $channels = foreach ($value in @($Color.R, $Color.G, $Color.B)) {
            $channel = $value / 255.0
            if ($channel -le 0.04045) { $channel / 12.92 } else { [math]::Pow(($channel + 0.055) / 1.055, 2.4) }
        }
        return 0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
    }
    function Assert-UnfocusedInputChrome($Control) {
        if ($Control.IsKeyboardFocusWithin) { throw 'Input-border checks must run without input focus.' }
        $expected = $window.FindResource('Brush.Border.Input').Color
        if ($Control.BorderBrush.Color.A -ne 255) { throw 'An unfocused input has a transparent border brush.' }
        $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
            [int][math]::Ceiling($Control.ActualWidth), [int][math]::Ceiling($Control.ActualHeight),
            96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $visual = [Windows.Media.DrawingVisual]::new()
        $drawing = $visual.RenderOpen()
        try {
            $drawing.DrawRectangle([Windows.Media.VisualBrush]::new($Control), $null,
                [Windows.Rect]::new(0, 0, $Control.ActualWidth, $Control.ActualHeight))
        }
        finally { $drawing.Close() }
        $bitmap.Render($visual)
        $pixels = [byte[]]::new(16)
        $bitmap.CopyPixels([Windows.Int32Rect]::new(0, [int]($bitmap.PixelHeight / 2), 4, 1), $pixels, 16, 0)
        $found = $false
        for ($offset=0; $offset -lt $pixels.Length; $offset+=4) {
            if ($pixels[$offset+3] -eq 255 -and
                [math]::Abs($pixels[$offset] - $expected.B) -le 3 -and
                [math]::Abs($pixels[$offset+1] - $expected.G) -le 3 -and
                [math]::Abs($pixels[$offset+2] - $expected.R) -le 3) { $found=$true }
        }
        if (-not $found) { throw "The unfocused $($Control.GetType().Name) did not render its visible border in $($window.Resources['Theme.Current']) mode." }
    }
    function Save-ThemeSnapshot([string]$Name) {
        if (-not $SnapshotDirectory) { return }
        $window.UpdateLayout()
        $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($window)
        $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Create((Join-Path $SnapshotDirectory "$Name.png"))
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }
    try {
        Initialize-EndpointTheme
        foreach ($theme in @('Dark','Light','CatppuccinMocha','GruvboxDark')) {
            Set-EndpointTheme $window $theme
            $palette = if ($theme -eq 'Light') { $window.Resources['Theme.LightPalette'] } else { $window.Resources["Theme.${theme}Palette"] }
            foreach ($key in $window.Resources['Theme.LightPalette'].Keys) {
                if (-not $palette.Contains($key)) { throw "$theme is missing palette color $key." }
            }
            foreach ($pair in @(
                @('Text.Primary','Background.Primary'), @('Text.Primary','Background.Elevated'),
                @('Text.Secondary','Background.Primary'), @('Text.Muted','Background.Elevated'),
                @('Text.OnAccent','Accent'), @('Text.Selected','Selection'),
                @('Text.Primary','Success'), @('Text.Primary','Warning'), @('Text.Primary','Error'),
                @('Text.Error','Background.Primary'), @('Information.Text','Information'),
                @('Console.Text','Console.Background')
            )) {
                $foreground=Get-Luminance $window.FindResource("Brush.$($pair[0])").Color
                $background=Get-Luminance $window.FindResource("Brush.$($pair[1])").Color
                $contrast=([math]::Max($foreground,$background)+0.05)/([math]::Min($foreground,$background)+0.05)
                if ($contrast -lt 4.5) { throw "$theme text contrast is below 4.5:1 for $($pair -join ' / '): $contrast." }
            }
            foreach ($surface in @('Background.Primary','Background.Elevated')) {
                $border=Get-Luminance $window.FindResource('Brush.Border.Input').Color
                $background=Get-Luminance $window.FindResource("Brush.$surface").Color
                $contrast=([math]::Max($border,$background)+0.05)/([math]::Min($border,$background)+0.05)
                if ($contrast -lt 3) { throw "$theme input-border contrast against $surface is below 3:1: $contrast." }
                if ($theme -in @('CatppuccinMocha','GruvboxDark')) {
                    $focus=Get-Luminance $window.FindResource('Brush.Focus').Color
                    $contrast=([math]::Max($focus,$background)+0.05)/([math]::Min($focus,$background)+0.05)
                    if ($contrast -lt 3) { throw "$theme focus contrast against $surface is below 3:1: $contrast." }
                }
            }
        }
        Set-EndpointTheme $window Light
        $controls.WorkflowList.ItemsSource = $ui.Catalog
        $controls.WorkflowList.SelectedItem = $ui.Catalog | Where-Object Id -eq 'device-usage'
        New-EndpointForm
        $ui.FieldControls.Devices.Text = 'Synthetic-PC'
        $originalForm = $controls.Form.Children[0]
        $table = [Data.DataTable]::new('Synthetic report')
        $null = $table.Columns.Add('Result'); $null = $table.Rows.Add('Preserved')
        $controls.ResultsGrid.ItemsSource = $table.DefaultView
        $originalView = $controls.ResultsGrid.ItemsSource
        $controls.RunSummary.Text = 'Synthetic summary'
        $window.Show()
        $ui.HistoryPath = Join-Path $root 'history.jsonl'
        $ui.RemoteSettingsPath = $null
        if ($window.FindName('ThemeSelector') -or (Invoke-EndpointShortcut OemComma Control $controls.Search $false) -or $ui.Settings) {
            throw 'The theme selector was left in the sidebar or Ctrl+, captured text input.'
        }
        if (-not (Invoke-EndpointShortcut OemComma Control $controls.SettingsButton $false) -or -not $ui.Settings.Window.IsVisible) {
            throw 'Ctrl+, did not open settings.'
        }
        $settings = $ui.Settings
        $selector = $settings.Controls.ThemeSelector
        $settings.Controls.SettingsTabs.SelectedItem = $settings.Controls.RemoteTab
        $settings.Window.UpdateLayout()
        $dnsLabel = $settings.Controls.RemoteTab.Content.Children | Where-Object { $_ -is [Windows.Controls.Label] }
        if ($dnsLabel.Target -ne $settings.Controls.DnsSuffixBox) { throw 'The DNS suffix label does not target its input.' }
        Assert-Color $dnsLabel.Foreground.Color '#FF172B4D' 'Light DNS suffix label did not use themed text.'
        Assert-Color $window.Background.Color '#FFF5F7FB' 'Default light background changed.'
        if ($selector.SelectedValue -ne 'Light') { throw 'New users must start in light mode.' }
        if ([Windows.Automation.AutomationProperties]::GetName($selector) -ne 'Theme' -or
            -not [Windows.Automation.AutomationProperties]::GetLabeledBy($selector)) { throw 'Theme selector has no accessible label.' }
        $settings.Controls.AppearanceTab.IsSelected = $true
        $settings.Window.UpdateLayout()
        if (-not $selector.IsVisible -or $selector.ActualWidth -lt 150) { throw 'Theme selection is unavailable or clipped in Appearance.' }
        $selector.SelectedValue = 'Dark'
        $window.UpdateLayout(); $settings.Window.UpdateLayout()
        Assert-Color $window.Background.Color '#FF1E1E1E' 'Dark background did not apply.'
        Assert-Color $ui.FieldControls.Devices.Foreground.Color '#FFF0F0F0' 'Existing generated input did not update.'
        $controls.WorkflowList.IsEnabled = $false; $window.UpdateLayout()
        $listChrome = $controls.WorkflowList.Template.FindName('Bd', $controls.WorkflowList)
        if (-not $listChrome -or -not [object]::ReferenceEquals($listChrome.Background, $controls.WorkflowList.Background)) {
            throw "The locked task list replaced its themed background with $($listChrome.Background)."
        }
        $controls.WorkflowList.IsEnabled = $true
        Assert-Color $settings.Window.Background.Color '#FF1E1E1E' 'Open settings window did not update.'
        Assert-Color $dnsLabel.Foreground.Color '#FFF0F0F0' 'Dark DNS suffix label did not use themed text.'
        Assert-Color $settings.Controls.HistoryGrid.Background.Color '#FF2D2D30' 'History grid did not update.'
        Assert-Color $controls.ResultsGrid.Background.Color '#FF2D2D30' 'Report grid did not update.'
        Assert-Color $controls.Activity.Background.Color '#FF151515' 'Console did not update.'
        if ($controls.Form.Children[0] -ne $originalForm -or $ui.FieldControls.Devices.Text -ne 'Synthetic-PC' -or
            -not [object]::ReferenceEquals($originalView,$controls.ResultsGrid.ItemsSource) -or $controls.RunSummary.Text -ne 'Synthetic summary') { throw 'Changing theme rebuilt inputs or changed report state.' }
        if ((Get-EndpointThemePreference $ui.ThemePath) -ne 'Dark') { throw 'Dark mode was not persisted.' }
        $restored = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((Join-Path $desktop 'MainWindow.xaml')))
        try {
            $script:Ui = @{
                Window=$restored
                ThemePath=$ui.ThemePath
            }
            Initialize-EndpointTheme
            Assert-Color $restored.Background.Color '#FF1E1E1E' 'Saved dark mode did not restore in a fresh window.'
            $restoredSettings = New-EndpointSettingsWindow $restored
            try { if ($restoredSettings.Controls.ThemeSelector.SelectedValue -ne 'Dark') { throw 'Restored dark preference did not update the selector.' } }
            finally { $restoredSettings.Window.Close() }
        }
        finally { $restored.Close(); $script:Ui=$ui }
        $null = $controls.SettingsButton.Focus()
        foreach ($theme in @(
            @{ Name='CatppuccinMocha'; Background='#FF1E1E2E'; Foreground='#FFCDD6F4'; Elevated='#FF313244' }
            @{ Name='GruvboxDark'; Background='#FF282828'; Foreground='#FFEBDBB2'; Elevated='#FF3C3836' }
        )) {
            $selector.SelectedValue = $theme.Name
            $window.UpdateLayout(); $settings.Window.UpdateLayout()
            Assert-Color $window.Background.Color $theme.Background "$($theme.Name) background did not apply."
            Assert-Color $ui.FieldControls.Devices.Foreground.Color $theme.Foreground "$($theme.Name) generated input did not update."
            Assert-Color $settings.Window.Background.Color $theme.Background "$($theme.Name) open settings window did not update."
            Assert-Color $dnsLabel.Foreground.Color $theme.Foreground "$($theme.Name) DNS suffix label did not use themed text."
            Assert-Color $settings.Controls.HistoryGrid.Background.Color $theme.Elevated "$($theme.Name) history grid did not update."
            Assert-Color $controls.ResultsGrid.Background.Color $theme.Elevated "$($theme.Name) report grid did not update."
            Assert-UnfocusedInputChrome $ui.FieldControls.Devices
            Assert-UnfocusedInputChrome $ui.Selectors[0].Control
            $null = $settings.Window.Activate()
            $null = $selector.Focus()
            $selector.ApplyTemplate() | Out-Null
            $selector.IsDropDownOpen = $true
            $settings.Window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
            $settings.Window.UpdateLayout()
            $themePopup = $selector.Template.FindName('PART_Popup', $selector)
            if (-not $themePopup -or -not $themePopup.IsOpen -or $selector.Items.Count -ne 4) { throw 'The theme selector does not expose all choices.' }
            Assert-Color $themePopup.Child.Background.Color $theme.Elevated "$($theme.Name) selector popup did not update."
            $selector.IsDropDownOpen = $false
            if ($controls.Form.Children[0] -ne $originalForm -or $ui.FieldControls.Devices.Text -ne 'Synthetic-PC' -or
                -not [object]::ReferenceEquals($originalView,$controls.ResultsGrid.ItemsSource)) { throw "$($theme.Name) changed the form draft or results." }
            if ((Get-EndpointThemePreference $ui.ThemePath) -ne $theme.Name) { throw "$($theme.Name) was not persisted." }
            $restored = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((Join-Path $desktop 'MainWindow.xaml')))
            try {
                $script:Ui = @{ Window=$restored; ThemePath=$ui.ThemePath }
                Initialize-EndpointTheme
                Assert-Color $restored.Background.Color $theme.Background "$($theme.Name) did not restore."
            }
            finally { $restored.Close(); $script:Ui=$ui }
        }
        $target = $settings.Controls.CloseSettingsButton
        foreach ($blocked in @($controls.Search, $settings.Controls.DnsSuffixBox, $selector, [Windows.Controls.PasswordBox]::new())) {
            if (Invoke-EndpointShortcut T 0 $blocked $false) { throw 'T captured an editable control.' }
            $null = Invoke-EndpointShortcut T 0 $target $false
            if ((Invoke-EndpointShortcut C 0 $blocked $false) -or (Invoke-EndpointShortcut C 0 $target $false)) {
                throw 'Theme shortcut was not cancelled when typing in an editable control.'
            }
        }
        $null = Invoke-EndpointShortcut T 0 $target $false
        $ui.ThemeShortcutUntil = [Environment]::TickCount64 - 1
        if (Invoke-EndpointShortcut C 0 $target $false) { throw 'An expired theme shortcut was accepted.' }
        foreach ($pair in @(@('L','Light'), @('G','GruvboxDark'), @('C','CatppuccinMocha'), @('D','Dark'))) {
            foreach ($key in @('T', $pair[0])) {
                $event = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,
                    [Windows.PresentationSource]::FromVisual($target), 0, [Windows.Input.Key]$key)
                $event.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent
                $target.RaiseEvent($event)
                if (-not $event.Handled) { throw "Shortcut key $key was not handled by Settings." }
            }
            if ($selector.SelectedValue -ne $pair[1] -or (Get-EndpointThemePreference $ui.ThemePath) -ne $pair[1]) {
                throw "Theme shortcut $($pair[0]) did not update and persist $($pair[1])."
            }
        }
        'Settings appearance and keyboard shortcuts passed.'
        $settings.Window.Close()
        $null = $controls.SettingsButton.Focus()
        foreach ($size in @(@{Width=1000;Height=700},@{Width=1400;Height=940})) {
            $window.Width=[Math]::Min($size.Width,[Windows.SystemParameters]::WorkArea.Width)
            $window.Height=[Math]::Min($size.Height,[Windows.SystemParameters]::WorkArea.Height)
            foreach ($workflow in $ui.Catalog) {
                $controls.WorkflowList.SelectedItem = $workflow
                New-EndpointForm
                $window.UpdateLayout()
                $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
                foreach ($field in $ui.FieldControls.Values) {
                    if ($field.Foreground -is [Windows.Media.SolidColorBrush]) {
                        Assert-Color $field.Foreground.Color '#FFF0F0F0' "Generated $($workflow.Id) input did not inherit dark text."
                    }
                    if ($field -is [Windows.Controls.ComboBox] -and $field.IsVisible) {
                        $field.ApplyTemplate() | Out-Null
                        $field.IsDropDownOpen=$true; $window.UpdateLayout()
                        $popup=$field.Template.FindName('PART_Popup',$field)
                        if (-not $popup -or -not $popup.IsOpen) { throw "The themed $($workflow.Id) dropdown did not open." }
                        Assert-Color $popup.Child.Background.Color '#FF2D2D30' 'Dropdown popup is not dark.'
                        if ($field.IsEditable) {
                            $editor=$field.Template.FindName('PART_EditableTextBox',$field)
                            if (-not $editor -or $editor.Visibility -ne 'Visible') { throw 'The themed editable dropdown lost its editor.' }
                            $field.Text='Synthetic custom value'
                            if ($editor.Text -ne 'Synthetic custom value') { throw 'The editable dropdown no longer accepts custom text.' }
                        }
                        $field.IsDropDownOpen=$false
                    }
                    if ($field.IsVisible -and ($field -is [Windows.Controls.Primitives.TextBoxBase] -or $field -is [Windows.Controls.ComboBox])) {
                        foreach ($theme in @('Light','Dark')) {
                            Set-EndpointTheme $window $theme
                            $window.UpdateLayout()
                            $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
                            Assert-UnfocusedInputChrome $field
                        }
                    }
                }
            }
            $controls.WorkflowList.SelectedItem = $ui.Catalog | Where-Object Id -eq 'device-usage'
            New-EndpointForm
            Save-ThemeSnapshot "dark-$($size.Width)"
        }
        $passwordWindow = [Windows.Window]::new()
        $passwordWindow.Resources.MergedDictionaries.Add($window.Resources)
        $password = [Windows.Controls.PasswordBox]::new()
        $passwordWindow.Content = $password
        $passwordWindow.Width = 300; $passwordWindow.SizeToContent='Height'; $passwordWindow.ShowActivated=$false
        try {
            $passwordWindow.Show()
            foreach ($theme in @('Light','Dark','CatppuccinMocha','GruvboxDark')) {
                Set-EndpointTheme $window $theme
                $passwordWindow.UpdateLayout()
                $passwordWindow.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
                Assert-UnfocusedInputChrome $password
            }
        }
        finally { $passwordWindow.Close() }
        Set-EndpointTheme $window Dark
        Show-EndpointSettings
        $settings = $ui.Settings
        $selector = $settings.Controls.ThemeSelector
        Assert-Color $settings.Window.Foreground.Color '#FFF0F0F0' 'New settings window is not dark.'
        $selector.SelectedValue='Light'
        Assert-Color $window.Background.Color '#FFF5F7FB' 'Switching back did not restore light colors.'
        Assert-Color $ui.FieldControls.Devices.Foreground.Color '#FF172B4D' 'Generated input did not restore light text.'
        if ((Get-EndpointThemePreference $ui.ThemePath) -ne 'Light') { throw 'Light mode was not persisted.' }
        Save-ThemeSnapshot 'light-restored'
        Set-Content -LiteralPath $ui.ThemePath -Value '{"Theme":"dark"}'
        if ((Get-EndpointThemePreference $ui.ThemePath) -cne 'Dark') { throw 'A previously accepted case-insensitive preference was not preserved.' }
        Set-Content -LiteralPath $ui.ThemePath -Value '{"Theme":"Invalid"}'
        $rejected=$false
        try { $null = Get-EndpointThemePreference $ui.ThemePath } catch { $rejected=$true }
        if (-not $rejected) { throw 'Invalid saved theme was silently accepted.' }
        Set-Content -LiteralPath $ui.ThemePath -Value '{invalid json'
        $rejected=$false
        try { $null = Get-EndpointThemePreference $ui.ThemePath } catch { $rejected=$true }
        if (-not $rejected) { throw 'Corrupt preferences were silently accepted.' }
        $blockedPath=Join-Path $root 'blocked'
        Set-Content -LiteralPath $blockedPath -Value 'not a directory'
        $ui.ThemePath=Join-Path $blockedPath 'settings.json'
        $rejected=$false
        try { $selector.SelectedValue='CatppuccinMocha' } catch { $rejected=$true }
        if (-not $rejected -or $selector.SelectedValue -ne 'Light') { throw 'Preference-write failure was hidden or left the selector inconsistent.' }
        Assert-Color $window.Background.Color '#FFF5F7FB' 'A failed preference write changed the applied theme.'
        $settings.Window.Close()
        $controls.ReportVisualTab.Visibility = 'Visible'
        $controls.ReportVisualSelector.Add_SelectionChanged({ Update-EndpointReportVisual })
        . (Join-Path $desktop 'ReportVisuals.ps1')
        $updateRows = @(1..8 | ForEach-Object { [pscustomobject]@{ AggregateState = "Fixture status $_" } })
        $updateChart = New-EndpointUpdateStateChart 'Overall update status' $updateRows AggregateState
        $null = $controls.ReportVisualSelector.Items.Add([pscustomobject]@{ Title='Fixture report'; Charts=@(
            [pscustomobject]@{ Title='Device status'; Basis='Fixture rows'; Total=4; Bars=@(
                [pscustomobject]@{ Label='Installed'; Count=3; Color='Success' }
                [pscustomobject]@{ Label='Failed'; Count=1; Color='Failure' }
            ) }
            $updateChart
        ) })
        $controls.ReportVisualSelector.SelectedIndex = 0
        $controls.ReportVisualTab.IsSelected = $true
        $content = $controls.ReportVisualPanel.Children[0].Child
        $track = $content.Children[3]
        $fill = $track.Children[0]
        $updateTracks = @($controls.ReportVisualPanel.Children[1].Child.Children | Where-Object { $_ -is [Windows.Controls.Grid] })
        if ($updateTracks.Count -ne 8) { throw 'The update chart did not render all eight bars.' }
        if ($content.Children[2].Text -notmatch '^Installed: 3' -or
            $track.ColumnDefinitions[0].Width.Value -ne 0.75) { throw 'The chart did not show the count and proportion.' }
        foreach ($palette in @(
            @{ Theme='Light'; Fill='#FF18794E' }
            @{ Theme='Dark'; Fill='#FF75D79F' }
            @{ Theme='CatppuccinMocha'; Fill='#FFA6E3A1' }
            @{ Theme='GruvboxDark'; Fill='#FFB8BB26' }
        )) {
            Set-EndpointTheme $window $palette.Theme
            $window.UpdateLayout()
            Assert-Color $fill.Fill.Color $palette.Fill 'An existing chart did not recolor with its theme.'
            $updateColors = @(for ($i = 0; $i -lt $updateTracks.Count; $i++) {
                $color = $updateTracks[$i].Children[0].Fill.Color
                $expected = $window.FindResource("Brush.Chart.$($updateChart.Bars[$i].Color)").Color
                Assert-Color $color $expected.ToString() 'An update bar did not use its active theme color.'
                $color.ToString()
            })
            if (@($updateColors | Select-Object -Unique).Count -ne 8) { throw "$($palette.Theme) update bars are not distinctly colored." }
            foreach ($color in @('Success','Failure','Warning','Pending','Neutral','Accent1','Accent2','Accent3','Accent4')) {
                $relative = @((Get-Luminance $window.FindResource("Brush.Chart.$color").Color), (Get-Luminance $track.Background.Color)) | Sort-Object
                if (($relative[1] + 0.05) / ($relative[0] + 0.05) -lt 3) { throw "$($palette.Theme) chart $color and track do not meet 3:1 contrast." }
            }
        }
        Clear-EndpointReportVisuals
        if ($controls.ReportVisualTab.Visibility -ne 'Collapsed' -or $controls.ReportVisualPanel.Children.Count) {
            throw 'Resetting the report left stale charts.'
        }
        'Themed report bars, counts, proportions and reset passed.'
        'Native themes, generated forms, dropdowns, settings, persistence and errors passed.'
    }
    finally {
        $window.Close(); $graph.Dispose(); $remote.Dispose()
        $script:Ui=$previous
        foreach ($name in @('settings.json','blocked')) {
            $path=Join-Path $root $name
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root }
    }
} $desktop $SnapshotDirectory
