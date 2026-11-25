$ErrorActionPreference = 'Stop'
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs')

& (Get-Module EndpointToolboxUI) {
    param($desktop)
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((Join-Path $desktop 'MainWindow.xaml')))
    $controls = @{}
    foreach ($node in ([xml](Get-Content -LiteralPath (Join-Path $desktop 'MainWindow.xaml') -Raw)).SelectNodes('//*[@Name]')) {
        $name = $node.GetAttribute('Name'); $controls[$name] = $window.FindName($name)
    }
    $table = [Data.DataTable]::new('Large fixture')
    for ($column = 0; $column -lt 20; $column++) { $null = $table.Columns.Add("Column$column") }
    $table.BeginLoadData()
    $values = [object[]]::new(20)
    for ($column = 1; $column -lt 20; $column++) { $values[$column] = 'Synthetic value' }
    for ($row = 0; $row -lt 100000; $row++) {
        $values[0] = "Fixture-device-$row"
        $null = $table.Rows.Add($values)
    }
    $table.EndLoadData()
    $table.ExtendedProperties['PreparedForDesktop'] = $true
    $null = $table.DefaultView.Count
    $script:Ui = @{ Window=$window; Controls=$controls; Datasets=@{'Large fixture'=$table}; Active=$null; FilterTickTiming=0 }
    $controls.DatasetSelector.Add_SelectionChanged({ Update-EndpointResults })
    $controls.ResultFilter.Add_TextChanged({ Update-EndpointResults })
    $null = $controls.DatasetSelector.Items.Add('Large fixture')
    $controls.DatasetSelector.SelectedItem = 'Large fixture'
    $controls.HomePanel.Visibility = 'Collapsed'; $controls.TaskPanel.Visibility = 'Visible'
    $controls.ResultsTab.IsEnabled = $true; $controls.OutputTab.IsSelected = $true; $controls.ResultsTab.IsSelected = $true
    $window.Show(); $window.UpdateLayout()
    $startupFrame = [Windows.Threading.DispatcherFrame]::new()
    $startupTimer = [Windows.Threading.DispatcherTimer]::new()
    $startupTimer.Interval = [timespan]::FromMilliseconds(500)
    $startupTimer.Tag = $startupFrame
    $startupTimer.Add_Tick({ param($sender) $sender.Stop(); $sender.Tag.Continue = $false })
    $startupTimer.Start()
    [Windows.Threading.Dispatcher]::PushFrame($startupFrame)
    $frame = [Windows.Threading.DispatcherFrame]::new()
    $pulse = [Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Input)
    $pulse.Interval = [timespan]::FromMilliseconds(20)
    $pulse.Tag = @{ Ui=$script:Ui; Frame=$frame; Total=[Diagnostics.Stopwatch]::StartNew(); Gap=[Diagnostics.Stopwatch]::StartNew(); MaxGap=0; Ticks=0; Changed=$false; Error=$null }
    $pulse.Add_Tick({
        param($sender)
        $state = $sender.Tag
        if ($state.Gap.ElapsedMilliseconds -gt $state.MaxGap) {
            $state.MaxGap = $state.Gap.ElapsedMilliseconds
        }
        $state.Gap.Restart(); $state.Ticks++
        if (-not $state.Changed -and $state.Ui.ResultFilterState.Task) {
            $state.Ui.Controls.ResultFilter.Text = 'Fixture-device-1'
            $state.Changed = $true
        }
        if ($state.Changed -and -not $state.Ui.ResultFilterState.Timer.IsEnabled) { $state.Frame.Continue = $false }
        if ($state.Total.Elapsed.TotalSeconds -gt 30) { $state.Error = 'Large report filtering timed out.'; $state.Frame.Continue = $false }
    })
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $controls.ResultFilter.Text = 'does-not-match'
        if ($watch.ElapsedMilliseconds -gt 250) { throw "Typing blocked the UI for $($watch.ElapsedMilliseconds) ms." }
        if ($controls.ResultsGrid.IsEnabled -or $controls.SaveResultsButton.IsEnabled) { throw 'Stale results were available while filtering.' }
        $pulse.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
        if ($pulse.Tag.Error) { throw $pulse.Tag.Error }
        if (-not $pulse.Tag.Changed -or $pulse.Tag.Ticks -lt 5 -or $pulse.Tag.MaxGap -gt 250 -or $script:Ui.FilterTickTiming -gt 250) {
            throw "Filtering stalled the dispatcher for $($pulse.Tag.MaxGap) ms; filter tick $($script:Ui.FilterTickTiming) ms."
        }
        if ($controls.ResultsGrid.Items.Count -ne 11111 -or $controls.ResultsGrid.Items[0].Column0 -ne 'Fixture-device-1' -or
            $script:Ui.ResultFilterState.View.Count -ne 11111 -or -not $controls.SaveResultsButton.IsEnabled) {
            throw 'The latest filter did not produce the expected grid and export view.'
        }
        $largestGap = $pulse.Tag.MaxGap
        $pulse.Stop()
        $frame = [Windows.Threading.DispatcherFrame]::new()
        $pulse.Tag = @{ Ui=$script:Ui; Frame=$frame; Total=[Diagnostics.Stopwatch]::StartNew(); Gap=[Diagnostics.Stopwatch]::StartNew(); MaxGap=0; Ticks=0; Changed=$true; Error=$null }
        $controls.ResultFilter.Text = 'does-not-match-any-column'
        $pulse.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
        if ($pulse.Tag.Error) { throw $pulse.Tag.Error }
        if ($pulse.Tag.Ticks -lt 5 -or $pulse.Tag.MaxGap -gt 250 -or $script:Ui.FilterTickTiming -gt 250) {
            throw "Nonmatching filter stalled the dispatcher for $($pulse.Tag.MaxGap) ms; filter tick $($script:Ui.FilterTickTiming) ms."
        }
        if ($controls.ResultsGrid.Items.Count -ne 0 -or -not $controls.SaveResultsButton.IsEnabled) { throw 'Nonmatching filter did not finish with an empty view.' }
        $largestGap = [Math]::Max($largestGap, $pulse.Tag.MaxGap)
        $pulse.Stop()
        $frame = [Windows.Threading.DispatcherFrame]::new()
        $pulse.Tag = @{ Ui=$script:Ui; Frame=$frame; Total=[Diagnostics.Stopwatch]::StartNew(); Gap=[Diagnostics.Stopwatch]::StartNew(); MaxGap=0; Ticks=0; Changed=$true; Error=$null }
        $controls.ResultFilter.Text = 'Fixture-device-'
        $pulse.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
        if ($pulse.Tag.Error) { throw $pulse.Tag.Error }
        if ($pulse.Tag.Ticks -lt 5 -or $pulse.Tag.MaxGap -gt 250 -or $script:Ui.FilterTickTiming -gt 250) {
            throw "Broad filter stalled the dispatcher for $($pulse.Tag.MaxGap) ms; filter tick $($script:Ui.FilterTickTiming) ms."
        }
        if ($controls.ResultsGrid.Items.Count -ne 100000 -or $script:Ui.ResultFilterState.View.Count -ne 100000) { throw 'Broad filter lost matching rows.' }
        $largestGap = [Math]::Max($largestGap, $pulse.Tag.MaxGap)
        "Large report filtering remained responsive; maximum overall heartbeat gap $largestGap ms."
    }
    finally {
        $pulse.Stop()
        $script:Ui.ResultFilterState.Timer.Stop()
        $window.Close()
    }
} $desktop
