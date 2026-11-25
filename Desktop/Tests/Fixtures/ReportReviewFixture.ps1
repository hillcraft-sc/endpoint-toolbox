$ErrorActionPreference = 'Stop'
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs')

& (Get-Module EndpointToolboxUI) {
    param($desktop)
    $xaml = Get-Content -LiteralPath (Join-Path $desktop 'MainWindow.xaml') -Raw
    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    $controls = @{}
    foreach ($node in ([xml]$xaml).SelectNodes('//*[@Name]')) {
        $name = $node.GetAttribute('Name'); $controls[$name] = $window.FindName($name)
    }
    $table = [Data.DataTable]::new('Devices')
    foreach ($name in @('DeviceName','ReviewCategory','IntunePrimaryUser','ObservedTopUser','AssignedSignInDaysUtc','ObservedSignInDaysUtc')) {
        $null = $table.Columns.Add($name)
    }
    $null = $table.Rows.Add('Fixture-PC','Mismatch','assigned@example.invalid','observed@example.invalid','2026-01-01','2026-01-02;2026-02-03')
    $null = $table.Rows.Add('Fixture-VM','Mismatch','','','','')
    $null = $table.Rows.Add('Fixture-PC-2','Match','','','','')
    $script:Ui = @{ Window=$window; Controls=$controls; Datasets=@{Devices=$table}; Active=$null; Workflow=$null; PendingBatches=[Collections.Queue]::new() }
    $null = $controls.DatasetSelector.Items.Add('Devices')
    $controls.DatasetSelector.SelectedItem = 'Devices'
    $controls.ResultFilter.Text = 'Fixture-PC'
    $chart = @{ Title='Primary-user review'; Basis='Fixture'; Total=3; Bars=@(
        [pscustomobject]@{Label='Mismatch'; Color='Warning'; Count=2; Dataset='Devices'; Column='ReviewCategory'}
    ) }
    $null = $controls.ReportVisualSelector.Items.Add([pscustomobject]@{Charts=@($chart)})
    $controls.ReportVisualSelector.SelectedIndex = 0
    $controls.ResultsTab.IsEnabled = $true
    $window.Show()
    try {
        Update-EndpointReportVisual
        $button = $controls.ReportVisualPanel.Children[0].Child.Children | Where-Object { $_ -is [Windows.Controls.Button] }
        $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        $deadline = [datetime]::UtcNow.AddSeconds(5)
        while ($script:Ui.ResultFilterState.Timer.IsEnabled -and [datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 25
            Receive-EndpointResultFilter
        }
        if (-not $controls.ResultsTab.IsSelected -or $controls.ResultsGrid.Items.Count -ne 1 -or
            $controls.ResultsGrid.Items[0]['DeviceName'] -ne 'Fixture-PC') { throw 'Chart drill-through did not combine category and text filters.' }
        if ($controls.OpenSignInDays.Visibility -ne 'Visible') { throw 'The sign-in day action was not available in Devices.' }
        $timer = [Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [timespan]::FromMilliseconds(50)
        $timer.Tag = @{ Owner=$window; Dates=$null }
        $timer.Add_Tick({
            param($sender)
            $sender.Stop()
            $dialog = $sender.Tag.Owner.OwnedWindows | Where-Object Title -like 'Sign-in days -*'
            if (-not $dialog) { return }
            try {
                $sender.Tag.Dates = @(foreach ($side in $dialog.Content.Children[1].Children) {
                    ($side.Children[1].SelectedDates | ForEach-Object { $_.ToString('yyyy-MM-dd') }) -join ';'
                }) -join '|'
            } finally { $dialog.Close() }
        })
        $timer.Start()
        try { Show-EndpointSignInDays $controls.ResultsGrid.Items[0] } finally { $timer.Stop() }
        if ($timer.Tag.Dates -ne '2026-01-01|2026-01-02;2026-02-03') { throw "Unexpected calendar evidence: $($timer.Tag.Dates)" }
        'Native chart drill-through and sign-in calendar passed'
    }
    finally {
        if ($script:Ui.ResultFilterState) { $script:Ui.ResultFilterState.Timer.Stop() }
        $window.Close()
    }
} $desktop
