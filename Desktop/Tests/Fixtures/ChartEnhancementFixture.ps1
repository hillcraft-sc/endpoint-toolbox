$ErrorActionPreference = 'Stop'
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs')
. (Join-Path $desktop 'ReportVisuals.ps1')

& (Get-Module EndpointToolboxUI) {
    param($desktop)
    $xaml = Get-Content -LiteralPath (Join-Path $desktop 'MainWindow.xaml') -Raw
    $window = [Windows.Markup.XamlReader]::Parse($xaml)
    $controls = @{}
    foreach ($node in ([xml]$xaml).SelectNodes('//*[@Name]')) {
        $name = $node.GetAttribute('Name'); $controls[$name] = $window.FindName($name)
    }
    $table = [Data.DataTable]::new('All Cloud PCs')
    $null = $table.Columns.Add('CloudPCId'); $null = $table.Columns.Add('CloudPCName')
    $null = $table.Rows.Add('00000000-0000-0000-0000-000000000001','Fixture')
    $script:Ui = @{
        Window=$window; Controls=$controls; Workflow=[pscustomobject]@{Id='cloudpc-inventory'}
        Datasets=@{'All Cloud PCs'=$table}; Active=$null; PendingBatches=[Collections.Queue]::new()
    }
    $null = $controls.DatasetSelector.Items.Add('All Cloud PCs')
    $controls.DatasetSelector.SelectedItem = 'All Cloud PCs'
    $controls.ResultsGrid.AutoGenerateColumns = $false
    $column = [Windows.Controls.DataGridTextColumn]::new()
    $column.Header = 'Cloud PC ID'
    $column.Binding = [Windows.Data.Binding]::new('CloudPCId')
    $controls.ResultsGrid.Columns.Add($column)
    $controls.ResultsGrid.ItemsSource = $table.DefaultView
    $controls.HomePanel.Visibility = 'Collapsed'; $controls.TaskPanel.Visibility = 'Visible'
    $controls.ResultsTab.IsEnabled = $true
    $controls.OutputTab.IsSelected = $true
    $controls.ResultsTab.IsSelected = $true
    $window.Show()
    try {
        foreach ($size in @(@(1000,700),@(1400,940))) {
            $window.Width=$size[0]; $window.Height=$size[1]; $window.UpdateLayout()
            $column = $controls.ResultsGrid.Columns[0]
            $controls.ResultsGrid.SelectedCells.Clear()
            $controls.ResultsGrid.SelectedCells.Add([Windows.Controls.DataGridCellInfo]::new($table.DefaultView[0], $column))
            Update-EndpointCloudPcHistoryAction
            if (-not $controls.OpenCloudPcHistory.IsEnabled -or $controls.OpenCloudPcHistory.Visibility -ne 'Visible') {
                throw "Selected Cloud PC action was not enabled: grid=$($controls.ResultsGrid.IsEnabled), cells=$($controls.ResultsGrid.SelectedCells.Count), type=$($controls.ResultsGrid.SelectedCells[0].Item.GetType().FullName), dataset=$($controls.DatasetSelector.SelectedItem), visibility=$($controls.OpenCloudPcHistory.Visibility), selected=$(Get-EndpointSingleSelectedReportRow)."
            }
            $selected = Get-EndpointCloudPcHistoryRow
            if ($selected['CloudPCId'] -ne '00000000-0000-0000-0000-000000000001') { throw 'Incorrect selected Cloud PC.' }
            $script:Ui.Active = [pscustomobject]@{ WorkflowId='cloudpc-inventory' }
            Update-EndpointCloudPcHistoryAction
            if ($controls.OpenCloudPcHistory.IsEnabled) { throw 'Cloud PC history was enabled during another operation.' }
            $script:Ui.Active = $null
            Update-EndpointCloudPcHistoryAction
            if (-not $controls.OpenCloudPcHistory.IsEnabled) { throw 'Cloud PC history did not re-enable after the operation.' }
            $rows = @([pscustomobject]@{ SignInDateTime='2026-01-01T00:00:00Z'; UsageInHour=1; RoundTripTimeInMsP50=25; AvailableBandwidthInMbpsP50=$null; RemoteSignInTimeInSec=5 })
            $charts = @(Get-EndpointCloudPcHistoryCharts $rows 'Fixture')
            $controls.ReportVisualSelector.Items.Clear()
            $null = $controls.ReportVisualSelector.Items.Add([pscustomobject]@{Title='Fixture';Charts=$charts})
            $controls.ReportVisualSelector.SelectedIndex = 0
            Update-EndpointReportVisual
            $label = $controls.ReportVisualPanel.Children[0].Child.Children | Where-Object { $_ -is [Windows.Controls.TextBlock] -and $_.Text -like '*25.00 ms*' }
            if (-not $label) { throw 'Metric value or units were not rendered.' }
            if ($controls.ReportVisualPanel.Children.Count -ne 4) { throw 'Expected four metric charts.' }
        }
        $historyRows = @(1..168 | ForEach-Object { [pscustomobject]@{
            SignInDateTime=([datetime]::UtcNow.AddHours(-$_).ToString('o')); UsageInHour=1
            RoundTripTimeInMsP50=25; AvailableBandwidthInMbpsP50=3; RemoteSignInTimeInSec=5
        } })
        $historyCharts = @(Get-EndpointCloudPcHistoryCharts $historyRows 'Fixture')
        $controls.ReportVisualSelector.Items.Clear()
        $null = $controls.ReportVisualSelector.Items.Add([pscustomobject]@{Title='History';Charts=$historyCharts})
        $controls.ReportVisualSelector.SelectedIndex = 0
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Update-EndpointReportVisual
        $watch.Stop()
        if ($watch.ElapsedMilliseconds -gt 250) { throw "History visual processing exceeded 250 ms: $($watch.ElapsedMilliseconds) ms." }
        $signInRows = @(0..30 | ForEach-Object { [pscustomobject]@{
            CreatedDateTimeUtc=([datetime]::UtcNow.Date.AddDays(-$_).ToString('o'))
            Outcome='Success'; Application='Fixture'; ClientApp='Browser'
        } })
        $signInCharts = @(Get-EndpointSignInCharts $signInRows 30 $true 31 $false)
        $controls.ReportVisualSelector.Items.Clear()
        $null = $controls.ReportVisualSelector.Items.Add([pscustomobject]@{Title='Sign-in events';Charts=$signInCharts})
        $controls.ReportVisualSelector.SelectedIndex = 0
        $watch.Restart()
        Update-EndpointReportVisual
        $watch.Stop()
        if ($watch.ElapsedMilliseconds -gt 250) { throw "Sign-in visual processing exceeded 250 ms: $($watch.ElapsedMilliseconds) ms." }
        $script:Ui.Active = [pscustomobject]@{ WorkflowId='user-sign-in-history'; Operation='Report' }
        $updated = @(Get-EndpointSignInCharts $signInRows 30 $false 31 $false)
        Set-EndpointReportVisual 'Sign-in events' $updated
        if ($controls.ReportVisualSelector.Items.Count -ne 1 -or
            $controls.ReportVisualSelector.SelectedItem.Charts[0].Basis -notmatch 'No more pages returned') {
            throw 'Continuing sign-in results did not replace the selected visual group.'
        }
        $hostBridge = [EndpointToolbox.DesktopHost]::new()
        $prepared = [EndpointToolbox.PreparedReport]::new('Sign-in events', $signInRows, $hostBridge)
        $script:Ui.Datasets['Sign-in events'] = [Data.DataTable]::new('Sign-in events')
        $null = $controls.DatasetSelector.Items.Add('Sign-in events')
        $oldTable = $script:Ui.Datasets['Sign-in events']
        $oldVisual = $controls.ReportVisualSelector.SelectedItem
        $script:Ui.SignInPaging = @{ HasMore=$true; Received=1; ContinuationId='displayed-page' }
        $publication = @(
            [pscustomobject]@{Kind='Rows'; Name='Sign-in events'; Data=$prepared}
            [pscustomobject]@{Kind='Stage'; Name='Sign-in paging'; Data=[pscustomobject]@{HasMore=$false;Received=31;ContinuationId='next-page'}}
            [pscustomobject]@{Kind='ReportVisual'; Name='Sign-in events'; Data=$updated}
        )
        foreach ($cut in 1..3) {
            $script:Ui.Active = [pscustomobject]@{WorkflowId='user-sign-in-history';Operation='Report';State='Cancelled';Failures=$false;Warnings=$false;PendingApproval=$false}
            foreach ($event in $publication[0..($cut - 1)]) {
                if (-not (Save-EndpointReportPublication $event)) { throw 'Report event was not buffered.' }
            }
            Complete-EndpointReportPublication
            if (-not [object]::ReferenceEquals($oldTable, $script:Ui.Datasets['Sign-in events']) -or
                -not [object]::ReferenceEquals($oldVisual, $controls.ReportVisualSelector.SelectedItem) -or
                $script:Ui.SignInPaging.ContinuationId -ne 'displayed-page') {
                throw "Cancellation after publication part $cut changed the displayed report."
            }
        }
        $script:Ui.Active = [pscustomobject]@{WorkflowId='user-sign-in-history';Operation='Report';State='Completed';Failures=$false;Warnings=$false;PendingApproval=$false}
        foreach ($event in $publication) { $null = Save-EndpointReportPublication $event }
        $script:Ui.Active.Failures = $true
        Complete-EndpointReportPublication
        if (-not [object]::ReferenceEquals($oldTable, $script:Ui.Datasets['Sign-in events'])) { throw 'A failed refresh replaced the report.' }
        $script:Ui.Active.Failures = $false
        $watch.Restart()
        Complete-EndpointReportPublication
        $watch.Stop()
        if ($watch.ElapsedMilliseconds -gt 250) { throw "Sign-in refresh publication exceeded 250 ms: $($watch.ElapsedMilliseconds) ms." }
        if (-not [object]::ReferenceEquals($prepared.Table, $script:Ui.Datasets['Sign-in events']) -or
            [object]::ReferenceEquals($oldVisual, $controls.ReportVisualSelector.SelectedItem) -or
            $script:Ui.SignInPaging.ContinuationId -ne 'next-page') { throw 'Successful refresh did not commit rows, charts and paging together.' }
        $script:Ui.Active = [pscustomobject]@{WorkflowId='cloudpc-inventory';Operation='CloudPcHistory';State='Cancelled';Failures=$false;Warnings=$false;PendingApproval=$false}
        $historyPrepared = [EndpointToolbox.PreparedReport]::new('Cloud PC connection history', $historyRows, $hostBridge)
        $null = Save-EndpointReportPublication ([pscustomobject]@{Kind='Rows';Name='Cloud PC connection history';Data=$historyPrepared})
        Complete-EndpointReportPublication
        if ($script:Ui.Datasets.ContainsKey('Cloud PC connection history') -or
            -not [object]::ReferenceEquals($table, $script:Ui.Datasets['All Cloud PCs'])) { throw 'Cancelled history altered the inventory or published partial history.' }
        $null = Save-EndpointReportPublication ([pscustomobject]@{Kind='ReportVisual';Name='Cloud PC connection history';Data=$historyCharts})
        $script:Ui.Active.State = 'Completed'
        $watch.Restart()
        Complete-EndpointReportPublication
        $watch.Stop()
        if ($watch.ElapsedMilliseconds -gt 250) { throw "History refresh publication exceeded 250 ms: $($watch.ElapsedMilliseconds) ms." }
        if (-not [object]::ReferenceEquals($historyPrepared.Table, $script:Ui.Datasets['Cloud PC connection history']) -or
            $controls.ReportVisualSelector.SelectedItem.Title -ne 'Cloud PC connection history' -or
            -not [object]::ReferenceEquals($table, $script:Ui.Datasets['All Cloud PCs'])) { throw 'History publication did not preserve the inventory.' }
        $committedHistory = $script:Ui.Datasets['Cloud PC connection history']
        $committedVisual = $controls.ReportVisualSelector.SelectedItem
        $script:Ui.Active = [pscustomobject]@{WorkflowId='cloudpc-inventory';Operation='CloudPcHistory';State='Cancelled';Failures=$false}
        $null = Save-EndpointReportPublication ([pscustomobject]@{Kind='Rows';Name='Cloud PC connection history';Data=$historyPrepared})
        Complete-EndpointReportPublication
        if (-not [object]::ReferenceEquals($committedHistory, $script:Ui.Datasets['Cloud PC connection history']) -or
            -not [object]::ReferenceEquals($committedVisual, $controls.ReportVisualSelector.SelectedItem)) { throw 'Cancelling another history request replaced the last successful history.' }
        $script:Ui.Active = $null
        'Native chart metrics and selected Cloud PC action passed'
    }
    finally { $window.Close() }
} $desktop
