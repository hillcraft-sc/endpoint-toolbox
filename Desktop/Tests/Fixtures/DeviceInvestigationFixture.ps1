$ErrorActionPreference = 'Stop'
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs')

$xml = [xml](Get-Content -LiteralPath (Join-Path $desktop 'MainWindow.xaml') -Raw)
$window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
$controls = @{}
foreach ($node in $xml.SelectNodes('//*[@Name]')) {
    $name = $node.GetAttribute('Name')
    $controls[$name] = $window.FindName($name)
}
$workflow = Get-EndpointCatalog | Where-Object Id -eq 'device-investigation'
$null = $controls.WorkflowList.Items.Add($workflow)
$controls.WorkflowList.SelectedItem = $workflow

& (Get-Module EndpointToolboxUI) {
    param($Window, $Controls, $Workflow)
    $script:Ui = @{
        Window = $Window; Controls = $Controls; Workflow = $null; GraphContext = $null
        Remote = [pscustomobject]@{ Connected = $false }; Active = $null; Faulted = $false
        FieldControls = @{}; FieldRows = @{}; Selectors = @(); Inactive = @()
        ScriptPicker = $null; LogRoot = ''
    }
    try {
        Set-EndpointTheme $Window Light
        New-EndpointForm
        $type = $script:Ui.FieldControls.SearchBy
        $value = $script:Ui.FieldControls.SearchValue
        if ($type.SelectedItem -ne 'Device name' -or $type.Items.Count -ne 3) { throw 'Device investigation search choices or default are incorrect.' }
        if ([Windows.Automation.AutomationProperties]::GetName($type) -ne 'Search by *' -or
            [Windows.Automation.AutomationProperties]::GetName($value) -ne 'Search value *') {
            throw 'Device investigation search inputs lack accessible labels.'
        }
        $type.SelectedItem = 'Serial number'
        $value.Text = 'SYNTHETIC'
        $arguments = Get-EndpointArguments $Workflow @{SearchBy=$type.SelectedItem;SearchValue=$value.Text}
        if ($arguments.SearchBy -ne 'Serial number' -or $arguments.SearchValue -ne 'SYNTHETIC') { throw 'Device investigation inputs did not bind.' }
        'Device investigation form and accessible search passed.'

        $appWorkflow = Get-EndpointCatalog | Where-Object Id -eq 'app-install-investigation'
        $null = $Controls.WorkflowList.Items.Add($appWorkflow)
        $Controls.WorkflowList.SelectedItem = $appWorkflow
        New-EndpointForm
        if ($script:Ui.FieldControls.DeviceSearchBy.SelectedItem -ne 'Device name' -or
            $script:Ui.FieldControls.AppSearchBy.SelectedItem -ne 'App name') { throw 'App investigation search defaults are incorrect.' }
        foreach ($name in @('DeviceSearchBy','DeviceSearchValue','AppSearchBy','AppSearchValue')) {
            if (-not [Windows.Automation.AutomationProperties]::GetName($script:Ui.FieldControls[$name]).EndsWith(' *')) {
                throw "App investigation field $name lacks an accessible required label."
            }
        }
        $script:Ui.FieldControls.DeviceSearchBy.SelectedItem = 'Intune device ID'
        $script:Ui.FieldControls.AppSearchBy.SelectedItem = 'App ID'
        $script:Ui.FieldControls.DeviceSearchValue.Text = '00000000-0000-0000-0000-000000000004'
        $script:Ui.FieldControls.AppSearchValue.Text = '00000000-0000-0000-0000-000000000006'
        $values = @{}
        foreach ($name in @('DeviceSearchBy','AppSearchBy')) { $values[$name] = $script:Ui.FieldControls[$name].SelectedItem }
        foreach ($name in @('DeviceSearchValue','AppSearchValue')) { $values[$name] = $script:Ui.FieldControls[$name].Text }
        $bound = Get-EndpointArguments $appWorkflow $values
        if ($bound.DeviceSearchBy -ne 'Intune device ID' -or $bound.AppSearchBy -ne 'App ID' -or
            $bound.AppSearchValue -ne $values.AppSearchValue) { throw 'App investigation object-ID searches did not bind.' }
        'App investigation form and accessible searches passed.'

        $rollout = Get-EndpointCatalog | Where-Object Id -eq 'intune-assignment-win32-deployment-exports'
        $script:Ui.Catalog = @($Workflow, $appWorkflow, $rollout)
        $script:Ui.PendingBatches = [Collections.Generic.Queue[object]]::new()
        $script:Ui.ReportWorkspace = 'Shared'
        $script:Ui.ReportWorkspaces = @{}
        $script:Ui.Datasets = @{}
        $Controls.DatasetSelector.Add_SelectionChanged({ Update-EndpointResults })
        $Controls.ResultFilter.Add_TextChanged({ Update-EndpointResults })
        $Controls.ReportVisualSelector.Add_SelectionChanged({ Update-EndpointReportVisual })
        $Controls.WorkflowList.Items.Clear()
        $Controls.WorkflowList.Add_SelectionChanged({ New-EndpointForm })
        $Controls.Search.Add_TextChanged({ Set-EndpointNavigation $script:Ui.Controls.Search.Text })
        Set-EndpointNavigation
        $Controls.WorkflowList.SelectedItem = $rollout
        $Controls.Search.Text = $rollout.Title
        $triage = [Data.DataTable]::new()
        $null = $triage.Columns.Add('ManagedDeviceId')
        $null = $triage.Columns.Add('ApplicationId')
        $null = $triage.Columns.Add('ErrorByOS')
        $null = $triage.Rows.Add('00000000-0000-0000-0000-000000000014','00000000-0000-0000-0000-000000000016','Fixture cluster')
        $null = $triage.Rows.Add('','00000000-0000-0000-0000-000000000016','')
        $snapshot = [Data.DataTable]::new()
        $script:Ui.Datasets = @{
            'Failure triage' = $triage
            'Fixture_00000000-0000-0000-0000-000000000016_20260101-010101-0123456789abcdef0123456789abcdef_DeviceStatus' = $snapshot
        }
        $script:Ui.RolloutTenantId = 'fixture-tenant'
        $null = $Controls.DatasetSelector.Items.Add('Failure triage')
        $Controls.DatasetSelector.SelectedItem = 'Failure triage'
        Register-EndpointFailureInvestigationAction
        Register-EndpointErrorCodeActions
        $grid = $Controls.ResultsGrid
        $grid.ItemsSource = $triage.DefaultView
        $Controls.ResultsTab.IsEnabled = $true
        $Controls.OutputTab.IsSelected = $true
        $Controls.ResultsTab.IsSelected = $true
        $Controls.OpenFailureInvestigation.Visibility = 'Visible'
        $Window.Show()
        $Window.UpdateLayout()
        $identified = [Windows.Controls.DataGridCellInfo]::new($grid.Items[0], $grid.Columns[0])
        $unidentified = [Windows.Controls.DataGridCellInfo]::new($grid.Items[1], $grid.Columns[0])
        $grid.SelectedCells.Clear()
        $grid.SelectedCells.Add($unidentified)
        if ($Controls.OpenFailureInvestigation.IsEnabled) { throw 'Unidentified rows cannot open an investigation.' }
        $grid.SelectedCells.Add($identified)
        if ($Controls.OpenFailureInvestigation.IsEnabled) { throw 'Multiple selected rows cannot open an investigation.' }
        $grid.SelectedCells.Remove($unidentified) | Out-Null
        if (-not $Controls.OpenFailureInvestigation.IsEnabled) { throw 'The shortcut was not enabled for a single selected device.' }
        $script:Ui.ReportCategory = [pscustomobject]@{ Dataset='Failure triage'; Column='ErrorByOS'; Label='Fixture cluster' }
        $Controls.ResultFilter.Text = '0014'
        $deadline = [datetime]::UtcNow.AddSeconds(5)
        while ($script:Ui.ResultFilterState.Timer.IsEnabled -and [datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 25
            Receive-EndpointResultFilter
        }
        $Window.UpdateLayout()
        $grid.SelectedCells.Clear()
        $grid.SelectedCells.Add([Windows.Controls.DataGridCellInfo]::new($grid.Items[0], $grid.Columns[0]))
        $null = $Controls.OpenFailureInvestigation.Focus()
        $Controls.OpenFailureInvestigation.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if ($script:Ui.Workflow.Id -ne 'app-install-investigation' -or
            -not $Controls.ConfigureTab.IsSelected -or $Controls.Status.Text -notmatch 'Choose Run report' -or
            $script:Ui.FieldControls.DeviceSearchBy.SelectedItem -ne 'Intune device ID' -or
            $script:Ui.FieldControls.AppSearchBy.SelectedItem -ne 'App ID' -or
            $script:Ui.FieldControls.DeviceSearchValue.Text -ne '00000000-0000-0000-0000-000000000014' -or
            $script:Ui.FieldControls.AppSearchValue.Text -ne '00000000-0000-0000-0000-000000000016' -or $script:Ui.Active) {
            throw 'Failure investigation did not open with the selected app and device IDs without running.'
        }
        if (-not [object]::ReferenceEquals($script:Ui.DiagnosticSnapshot.Tables['00000000-0000-0000-0000-000000000016'], $snapshot)) {
            throw 'The original deployment snapshot was not retained.'
        }
        if ($script:Ui.Datasets.Count -or $Controls.DatasetSelector.Items.Count -or $grid.Items.Count -or
            $Controls.BackToRollout.Visibility -ne 'Visible') { throw 'Diagnostics showed rollout results before its own run.' }
        $diagnostics = [Data.DataTable]::new()
        $null = $diagnostics.Columns.Add('Finding')
        $null = $diagnostics.Rows.Add('Synthetic finding')
        $script:Ui.Datasets['Diagnostic findings'] = $diagnostics
        $null = $Controls.DatasetSelector.Items.Add('Diagnostic findings')
        $Controls.DatasetSelector.SelectedItem = 'Diagnostic findings'
        $Controls.ResultsTab.IsEnabled = $true
        $Controls.OutputTab.IsSelected = $true
        $Controls.ResultsTab.IsSelected = $true
        $codes = [Data.DataTable]::new()
        foreach ($column in @('HexCode','Reference')) { $null = $codes.Columns.Add($column) }
        $null = $codes.Rows.Add('0x87D1041C','https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/app-install-error-codes')
        $null = $codes.Rows.Add('0x87D1041C&device=test','https://learn.microsoft.com.example.invalid/')
        $script:Ui.Datasets['Error code details'] = $codes
        $null = $Controls.DatasetSelector.Items.Add('Error code details')
        $Controls.DatasetSelector.SelectedItem = 'Error code details'
        $Window.UpdateLayout()
        $valid = [Windows.Controls.DataGridCellInfo]::new($grid.Items[0], $grid.Columns[0])
        $invalid = [Windows.Controls.DataGridCellInfo]::new($grid.Items[1], $grid.Columns[0])
        $grid.SelectedCells.Clear()
        $grid.SelectedCells.Add($valid)
        if ($Controls.ErrorCodeActions.Visibility -ne 'Visible' -or -not $Controls.CopyErrorCode.IsEnabled -or
            -not $Controls.SearchErrorCode.IsEnabled -or -not $Controls.OpenErrorCodeReference.IsEnabled) {
            throw 'A selected error-code row did not enable the contextual actions.'
        }
        $grid.SelectedCells.Add($invalid)
        if ($Controls.CopyErrorCode.IsEnabled -or $Controls.SearchErrorCode.IsEnabled -or $Controls.OpenErrorCodeReference.IsEnabled) {
            throw 'Code actions were not disabled for multiple selected rows.'
        }
        $grid.SelectedCells.Remove($valid) | Out-Null
        if ($Controls.CopyErrorCode.IsEnabled -or $Controls.SearchErrorCode.IsEnabled -or $Controls.OpenErrorCodeReference.IsEnabled) {
            throw 'Invalid report text enabled a code action.'
        }
        $Controls.DatasetSelector.SelectedItem = 'Diagnostic findings'
        if ($Controls.ErrorCodeActions.Visibility -ne 'Collapsed') { throw 'Code actions were not hidden on another dataset.' }
        Update-EndpointResults
        $Controls.WorkflowList.SelectedItem = $rollout
        $deadline = [datetime]::UtcNow.AddSeconds(5)
        while ($script:Ui.ResultFilterState.Timer.IsEnabled -and [datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 25
            Receive-EndpointResultFilter
        }
        if ($script:Ui.Workflow.Id -ne $rollout.Id -or $Controls.DatasetSelector.SelectedItem -ne 'Failure triage' -or
            -not [object]::ReferenceEquals($script:Ui.Datasets['Failure triage'], $triage) -or
            $Controls.ResultFilter.Text -ne '0014' -or $script:Ui.ReportCategory.Label -ne 'Fixture cluster' -or
            $Controls.ResultsGrid.Items.Count -ne 1 -or -not $Controls.OutputTab.IsSelected -or $script:Ui.Active) {
            throw 'Sidebar navigation did not restore the retained rollout report without running it.'
        }
        $Controls.WorkflowList.SelectedItem = $Workflow
        if ($grid.Items.Count -or $Controls.DatasetSelector.Items.Count) {
            throw 'An unrelated task displayed results from the rollout or diagnostics workspace.'
        }
        $Controls.WorkflowList.SelectedItem = $appWorkflow
        if ($Controls.DatasetSelector.SelectedItem -ne 'Diagnostic findings' -or
            -not [object]::ReferenceEquals($script:Ui.Datasets['Diagnostic findings'], $diagnostics) -or
            $grid.Items.Count -ne 1 -or $grid.Items[0]['Finding'] -ne 'Synthetic finding') {
            throw 'Diagnostics results were not restored after switching away.'
        }
        Restore-EndpointRollout
        if ($Controls.DatasetSelector.SelectedItem -ne 'Failure triage' -or $Controls.ResultFilter.Text -ne '0014') {
            throw 'Back to rollout did not restore the same report as sidebar navigation.'
        }
        'Win32 triage investigation shortcut passed.'
    }
    finally {
        if ($script:Ui['ResultFilterState']) { $script:Ui.ResultFilterState.Timer.Stop() }
        $Window.Close()
    }
} $window $controls $workflow
