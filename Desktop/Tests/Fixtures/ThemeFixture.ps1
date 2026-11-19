# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

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
        foreach ($theme in @('Dark','Light')) {
            Set-EndpointTheme $window $theme
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
            }
        }
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
        $settings = New-EndpointSettingsWindow $window
        $settings.Window.Show()
        Assert-Color $window.Background.Color '#FFF5F7FB' 'Default light background changed.'
        if ($controls.DarkModeToggle.IsChecked) { throw 'New users must start in light mode.' }
        if ([Windows.Automation.AutomationProperties]::GetName($controls.DarkModeToggle) -ne 'Dark mode') { throw 'Theme toggle has no accessible name.' }
        if ([Windows.Input.KeyboardNavigation]::GetTabIndex($controls.WorkflowList) -ge [Windows.Input.KeyboardNavigation]::GetTabIndex($controls.DarkModeToggle) -or
            [Windows.Input.KeyboardNavigation]::GetTabIndex($controls.DarkModeToggle) -ge [Windows.Input.KeyboardNavigation]::GetTabIndex($controls.SettingsButton)) { throw 'Theme toggle tab order does not follow visual order.' }
        $controls.DarkModeToggle.IsChecked = $true
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
        Assert-Color $settings.Controls.HistoryGrid.Background.Color '#FF2D2D30' 'History grid did not update.'
        Assert-Color $controls.ResultsGrid.Background.Color '#FF2D2D30' 'Report grid did not update.'
        Assert-Color $controls.Activity.Background.Color '#FF151515' 'Console did not update.'
        if ($controls.Form.Children[0] -ne $originalForm -or $ui.FieldControls.Devices.Text -ne 'Synthetic-PC' -or
            -not [object]::ReferenceEquals($originalView,$controls.ResultsGrid.ItemsSource) -or $controls.RunSummary.Text -ne 'Synthetic summary') { throw 'Changing theme rebuilt inputs or changed report state.' }
        if ((Get-EndpointThemePreference $ui.ThemePath) -ne 'Dark') { throw 'Dark mode was not persisted.' }
        $restored = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((Join-Path $desktop 'MainWindow.xaml')))
        try {
            $script:Ui = @{
                Window=$restored; Controls=@{DarkModeToggle=$restored.FindName('DarkModeToggle')}
                ThemePath=$ui.ThemePath
            }
            Initialize-EndpointTheme
            Assert-Color $restored.Background.Color '#FF1E1E1E' 'Saved dark mode did not restore in a fresh window.'
            if (-not $script:Ui.Controls.DarkModeToggle.IsChecked) { throw 'Restored dark preference did not update the toggle.' }
        }
        finally { $restored.Close(); $script:Ui=$ui }
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
            foreach ($theme in @('Light','Dark')) {
                Set-EndpointTheme $window $theme
                $passwordWindow.UpdateLayout()
                $passwordWindow.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
                Assert-UnfocusedInputChrome $password
            }
        }
        finally { $passwordWindow.Close() }
        $settings = New-EndpointSettingsWindow $window
        try { Assert-Color $settings.Window.Foreground.Color '#FFF0F0F0' 'New settings window is not dark.' }
        finally { $settings.Window.Close() }
        $controls.DarkModeToggle.IsChecked=$false
        Assert-Color $window.Background.Color '#FFF5F7FB' 'Switching back did not restore light colors.'
        Assert-Color $ui.FieldControls.Devices.Foreground.Color '#FF172B4D' 'Generated input did not restore light text.'
        if ((Get-EndpointThemePreference $ui.ThemePath) -ne 'Light') { throw 'Light mode was not persisted.' }
        Save-ThemeSnapshot 'light-restored'
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
        try { $controls.DarkModeToggle.IsChecked=$true } catch { $rejected=$true }
        if (-not $rejected -or $controls.DarkModeToggle.IsChecked) { throw 'Preference-write failure was hidden or left the toggle inconsistent.' }
        Assert-Color $window.Background.Color '#FFF5F7FB' 'A failed preference write changed the applied theme.'
        'Native dark/light themes, generated forms, dropdowns, settings, persistence and errors passed.'
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
