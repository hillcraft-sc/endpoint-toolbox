$ErrorActionPreference = 'Stop'
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs')
$root = Join-Path $env:TEMP "EndpointToolbox-chart-export-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $root
try {
    & (Get-Module EndpointToolboxUI) {
        param($desktop, $root)
        function Wait-ExportWorker {
            param($Engine)
            $events = [Collections.Generic.List[object]]::new()
            $deadline = [datetime]::UtcNow.AddSeconds(30)
            $maxTick = 0
            do {
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $null = $Engine.Poll()
                $event = $null
                while ($Engine.Host.Events.TryDequeue([ref]$event)) { $events.Add($event) }
                $watch.Stop()
                $maxTick = [Math]::Max($maxTick, $watch.ElapsedMilliseconds)
                if ([datetime]::UtcNow -gt $deadline) { $Engine.Cancel(); throw 'PNG export worker timed out.' }
                Start-Sleep -Milliseconds 10
            } while ($Engine.Busy -or -not $Engine.Host.Events.IsEmpty)
            if ($maxTick -gt 250) { throw "PNG export UI polling exceeded 250 ms: $maxTick ms." }
            return $events.ToArray()
        }
        $window = [Windows.Markup.XamlReader]::Parse((Get-Content -LiteralPath (Join-Path $desktop 'MainWindow.xaml') -Raw))
        Set-EndpointTheme $window Light
        $controls = @{}
        foreach ($node in ([xml](Get-Content -LiteralPath (Join-Path $desktop 'MainWindow.xaml') -Raw)).SelectNodes('//*[@Name]')) {
            $controls[$node.GetAttribute('Name')] = $window.FindName($node.GetAttribute('Name'))
        }
        $engine = [EndpointToolbox.DesktopEngine]::new()
        $remote = [EndpointToolbox.DesktopEngine]::new()
        $table = [Data.DataTable]::new('Fixture')
        $null = $table.Columns.Add('Category'); $null = $table.Rows.Add('Preserved')
        $null = $controls.DatasetSelector.Items.Add('Fixture'); $controls.DatasetSelector.SelectedItem='Fixture'
        $script:Ui = @{
            Window=$window; Controls=$controls; Active=$null; Graph=$engine; PendingBatches=[Collections.Queue]::new()
            ReportFolder=$root; Faulted=$false; LogRoot=''; TestMode=$true
            Workflow=$null; Catalog=@(); Datasets=@{Fixture=$table}; Remote=$remote; RemoteTarget=''
            HistoryPath=(Join-Path $root 'history.jsonl'); ReceivingEvents=$false; ActivityBuffer=$null; RemoteBuffer=$null
            Timings=@{Events=0;Rows=0;Binding=0;Completion=0}
        }
        $originalDialog = ${function:New-EndpointReportSaveDialog}
        try {
            $csvDialog = New-EndpointReportSaveDialog
            $pngDialog = New-EndpointReportSaveDialog -Format Png
            if ($pngDialog.InitialDirectory -ne $root -or $pngDialog.Filter -notmatch '\*\.png' -or
                $pngDialog.DefaultExt -ne 'png' -or -not $pngDialog.AddExtension -or -not $pngDialog.OverwritePrompt -or
                $csvDialog.Filter -ne 'CSV report (*.csv)|*.csv') { throw 'PNG save defaults or existing CSV defaults are incorrect.' }
            $charts = @(
                [pscustomobject]@{
                    Title='Fixture count chart'; Basis='Incomplete: more pages remain. Returned records only.'; Total=32
                    Bars=@(1..16 | ForEach-Object { [pscustomobject]@{Label="Fixture category $_";Count=2;Color='Failure';Dataset='Fixture';Column='Category';Cumulative=($_/16)} })
                }
                [pscustomobject]@{
                    Title='Fixture latency'; Basis='Fixture service P50, not an average of medians.'; Total=16
                    Metric=$true; Scale=100; Unit='ms'
                    Bars=@(1..16 | ForEach-Object { [pscustomobject]@{Label="2026-01-01T$($_.ToString('00')):00:00Z";Value=25;Color='Success'} })
                }
            )
            $visual = [pscustomobject]@{Title='Fixture summary';Charts=$charts}
            $null = $controls.ReportVisualSelector.Items.Add($visual)
            $controls.ReportVisualSelector.SelectedItem = $visual
            $controls.HomePanel.Visibility='Collapsed'; $controls.TaskPanel.Visibility='Visible'
            $controls.OutputTab.IsSelected=$true; $controls.ReportVisualTab.Visibility='Visible'; $controls.ReportVisualTab.IsSelected=$true
            $controls.RunButton.IsEnabled=$true
            $window.Show()
            foreach ($size in @(@(1000,700),@(1400,940))) {
                $window.Width=$size[0]; $window.Height=$size[1]
                Update-EndpointReportVisual
                $window.UpdateLayout()
                $button = $controls.ExportReportVisualButton
                $point = $button.TranslatePoint([Windows.Point]::new(0,0), $window)
                if (-not $button.IsEnabled -or $button.ActualWidth -le 0 -or $point.X -lt 0 -or
                    $point.X + $button.ActualWidth -gt $window.ActualWidth -or $point.Y + $button.ActualHeight -gt $window.ActualHeight) {
                    throw "PNG export action is unavailable or clipped at $($size[0])x$($size[1])."
                }
                if (-not $button.Focus()) { throw 'PNG export cannot receive keyboard focus.' }
            }
            $controls.RunButton.IsEnabled=$false
            $window.UpdateLayout()
            if (-not $controls.ExportReportVisualButton.IsEnabled) { throw 'Incomplete task configuration blocked export of an existing summary.' }
            $controls.RunButton.IsEnabled=$true
            $exportPanel = [Windows.Controls.StackPanel]::new()
            $exportPanel.Resources=$window.Resources
            Add-EndpointReportCharts $exportPanel $charts -ForExport
            $texts = @($exportPanel.Children | ForEach-Object { $_.Child.Children } | Where-Object { $_ -is [Windows.Controls.TextBlock] })
            if (-not ($texts.Text -like '*Incomplete: more pages remain*') -or -not ($texts.Text -like '*25.00 ms*') -or
                -not ($texts.Text -like '*Cumulative: 100.0%*') -or
                @($exportPanel.Children | ForEach-Object { $_.Child.Children } | Where-Object { $_ -is [Windows.Controls.Button] }).Count) {
                throw 'PNG content lost coverage notes, units or percentages, or included navigation buttons.'
            }
            $script:Ui.ExportDialog = [pscustomobject]@{FileName='';Accept=$false;Path=(Join-Path $root 'Light.png')}
            $script:Ui.ExportDialog | Add-Member -MemberType ScriptMethod -Name ShowDialog -Value { param($owner) $this.FileName=$this.Path; return $this.Accept }
            function New-EndpointReportSaveDialog { param($Format) if ($Format -ne 'Png') { throw 'Expected PNG format.' }; return $script:Ui.ExportDialog }
            Invoke-EndpointReportVisualExport
            if ($script:Ui.Active -or $engine.Busy -or (Test-Path -LiteralPath $script:Ui.ExportDialog.Path)) { throw 'Cancelling the save dialog started an export.' }
            $engine.RunFile((Join-Path $PSScriptRoot 'GraphSessionFixture.ps1'), @{Mode='Bootstrap'}, $false)
            $null = Wait-ExportWorker $engine
            foreach ($theme in @('Light','Dark')) {
                Set-EndpointTheme $window $theme
                $script:Ui.ExportDialog.Accept=$true
                $script:Ui.ExportDialog.Path=Join-Path $root "$theme.png"
                $watch = [Diagnostics.Stopwatch]::StartNew()
                Invoke-EndpointReportVisualExport
                $watch.Stop()
                if ($watch.ElapsedMilliseconds -gt 250) { throw "Starting PNG export exceeded 250 ms: $($watch.ElapsedMilliseconds) ms." }
                if (-not $script:Ui.Active -or $controls.RunButton.IsEnabled) { throw 'PNG export did not use the background worker and block overlapping operations.' }
                $window.UpdateLayout()
                if ($controls.ExportReportVisualButton.IsEnabled) { throw 'An overlapping PNG export remained enabled.' }
                $events = @(Wait-ExportWorker $engine)
                if ($engine.HasErrors) { throw "PNG worker failed: $((@($events | Where-Object Kind -eq 'Error').Data) -join '; ')" }
                $artifacts = @($events | Where-Object Kind -eq 'Artifact')
                if ($artifacts.Count -ne 1 -or $artifacts[0].Data -ne $script:Ui.ExportDialog.Path) { throw 'PNG export did not publish its saved artifact.' }
                foreach ($event in $events) { $engine.Host.Events.Enqueue($event) }
                while ($script:Ui.Active) { Receive-EndpointEvents }
                if (-not $controls.RunButton.IsEnabled -or $controls.Artifacts.Items.Count -ne @('Light','Dark').IndexOf($theme)+1 -or
                    -not [object]::ReferenceEquals($table, $script:Ui.Datasets['Fixture'])) { throw 'PNG completion did not restore controls, retain the report and list the image.' }
                $stream = [IO.File]::OpenRead($script:Ui.ExportDialog.Path)
                try { $image = [Windows.Media.Imaging.BitmapDecoder]::Create($stream, [Windows.Media.Imaging.BitmapCreateOptions]::None, [Windows.Media.Imaging.BitmapCacheOption]::OnLoad).Frames[0] }
                finally { $stream.Dispose() }
                if ($image.PixelWidth -ne 1200 -or $image.PixelHeight -le $window.ActualHeight) { throw 'PNG captured only the visible viewport instead of the full summary.' }
                $column = [byte[]]::new($image.PixelHeight * 4)
                $image.CopyPixels([Windows.Int32Rect]::new(50,0,1,$image.PixelHeight), $column, 4, 0)
                $background = $window.FindResource('Brush.Background.Primary').Color
                if ($column[0] -ne $background.B -or $column[1] -ne $background.G -or $column[2] -ne $background.R -or $column[3] -ne 255) {
                    throw 'PNG background is transparent or does not use the selected theme.'
                }
                $color = $window.FindResource('Brush.Chart.Success').Color
                $lastBar = 0
                for ($y=0; $y -lt $image.PixelHeight; $y++) {
                    $i=$y*4
                    if ($column[$i] -eq $color.B -and $column[$i+1] -eq $color.G -and $column[$i+2] -eq $color.R) { $lastBar=$y }
                }
                if ($lastBar -lt $image.PixelHeight - 80) { throw 'The last chart was missing or clipped in the exported PNG.' }
                if ($controls.ReportVisualSelector.SelectedItem -ne $visual -or -not $controls.ReportVisualTab.IsSelected) { throw 'PNG export changed the selected summary.' }
            }
            $engine.RunFile((Join-Path $PSScriptRoot 'GraphSessionFixture.ps1'), @{Mode='Observe'}, $false)
            $events = @(Wait-ExportWorker $engine)
            if ((@($events | Where-Object Kind -eq 'Output').Data -join ' ') -notmatch 'Connects=0') { throw 'PNG export unexpectedly authenticated.' }
            $path = Join-Path $root 'Light.png'
            $before = (Get-FileHash -LiteralPath $path).Hash
            $lock = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try {
                $engine.RunFile((Join-Path $desktop 'Export-ReportVisual.ps1'), @{Path=$path;Title=$visual.Title;Charts=$charts;Theme='Light'}, $true)
                $events = @(Wait-ExportWorker $engine)
                if (-not $engine.HasErrors -or @($events | Where-Object Kind -eq 'Artifact').Count) { throw 'A locked destination was reported as a successful PNG export.' }
            }
            finally { $lock.Dispose() }
            if ((Get-FileHash -LiteralPath $path).Hash -ne $before -or @(Get-ChildItem -LiteralPath $root -Filter '*.tmp' -Force).Count) { throw 'Failed PNG export damaged the previous file or left temporary files.' }
            $global:exportCancelChecks=0
            $cancelled=$false
            try {
                Export-EndpointReportVisualPng -Path $path -Title $visual.Title -Charts $charts -CancellationCheck ([Func[bool]]{ $global:exportCancelChecks++; return $global:exportCancelChecks -eq 3 })
            }
            catch { if ($_.Exception.Message -notmatch 'cancelled') { throw }; $cancelled=$true }
            finally { Remove-Variable exportCancelChecks -Scope Global }
            if (-not $cancelled -or (Get-FileHash -LiteralPath $path).Hash -ne $before -or
                @(Get-ChildItem -LiteralPath $root -Filter '*.tmp' -Force).Count) { throw 'Cancelled PNG export replaced the existing file or left temporary files.' }
            $controls.ReportVisualSelector.Items.Clear()
            Update-EndpointReportVisual
            if ($controls.ExportReportVisualButton.IsEnabled) { throw 'PNG export remained enabled without a selected summary.' }
            'Native full-summary PNG, theme, labels, save defaults, cancellation, failure safety and background export passed'
        }
        finally {
            Set-Item Function:\New-EndpointReportSaveDialog $originalDialog
            $remote.Dispose()
            $engine.Dispose()
            $script:Ui.Active=$null
            $window.Close()
        }
    } $desktop $root
}
finally { Remove-Item -LiteralPath $root -Recurse -Force }
