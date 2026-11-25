$ErrorActionPreference = 'Stop'
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$originalLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $env:TEMP "EndpointToolbox-shutdown-fixture-$([guid]::NewGuid())"
try {
    & (Get-Module EndpointToolboxUI) {
        function script:Write-EndpointActivityRecord {
            param($LogRoot, $Event, $WorkflowId, $RunId, $State, $Device, $Message, $Summary)
            $script:ShutdownEvents.Add($Event)
            if ($LogRoot -ne (Join-Path $env:LOCALAPPDATA 'EndpointToolbox\Logs')) { throw "Unexpected log root: $LogRoot" }
        }
        foreach ($withFilter in @($false, $true)) {
            $script:ShutdownEvents = [Collections.Generic.List[string]]::new()
            $script:ShutdownFixtureError = $null
            $script:ShutdownFilter = $null
            $timer = [Windows.Threading.DispatcherTimer]::new()
            $timer.Interval = [timespan]::FromMilliseconds(100)
            $timer.Tag = $withFilter
            $timer.Add_Tick({
                param($sender)
                $sender.Stop()
                try {
                    $dataRoot = Join-Path $env:LOCALAPPDATA 'EndpointToolbox'
                    foreach ($entry in @(
                        @('HistoryPath','history.jsonl'), @('ThemePath','settings.json'),
                        @('RecentDevicesPath','recent-devices.json'), @('RemoteSettingsPath','settings.json')
                    )) {
                        if ($script:Ui[$entry[0]] -ne (Join-Path $dataRoot $entry[1])) {
                            throw "Unexpected $($entry[0]): $($script:Ui[$entry[0]])"
                        }
                    }
                    if ($sender.Tag) {
                        $table = [Data.DataTable]::new('Fixture')
                        $null = $table.Columns.Add('Device')
                        $null = $table.Rows.Add('Fixture-PC')
                        $table.ExtendedProperties['PreparedForDesktop'] = $true
                        $script:Ui.Datasets['Fixture'] = $table
                        $null = $script:Ui.Controls.DatasetSelector.Items.Add('Fixture')
                        $script:Ui.Controls.DatasetSelector.SelectedItem = 'Fixture'
                        $script:Ui.Controls.ResultFilter.Text = 'Fixture'
                        $script:Ui.ResultFilterState.Due = [datetime]::UtcNow.AddSeconds(-1)
                        Receive-EndpointResultFilter
                        if (-not $script:Ui.ResultFilterState.Task) { throw 'The filter did not start.' }
                        $script:ShutdownFilter = $script:Ui.ResultFilterState
                    }
                    elseif ($script:Ui.ContainsKey('ResultFilterState')) {
                        throw 'Filter state unexpectedly exists before opening a report.'
                    }
                }
                catch { $script:ShutdownFixtureError = $_ }
                finally { $script:Ui.Window.Close() }
            })
            $timer.Start()
            try { Start-EndpointToolboxUI }
            finally { $timer.Stop() }
            if ($script:ShutdownFixtureError) { throw $script:ShutdownFixtureError }
            if ('AppClosed' -notin $script:ShutdownEvents) { throw 'Shutdown did not record AppClosed.' }
            if ($withFilter -and ($script:ShutdownFilter.Timer.IsEnabled -or -not $script:ShutdownFilter.Cancellation.IsCancellationRequested)) {
                throw 'Shutdown did not stop and cancel the active report filter.'
            }
        }
        'Native shutdown without a report and with an active filter passed.'
    }
}
finally { $env:LOCALAPPDATA = $originalLocalAppData }
