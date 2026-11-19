# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

$ErrorActionPreference = 'Stop'
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs')
& (Get-Module EndpointToolboxUI) {
    param($desktop)
    $previous = Get-Variable -Name Ui -Scope Script -ValueOnly -ErrorAction Ignore
    $xml = [xml](Get-Content -LiteralPath (Join-Path $desktop 'MainWindow.xaml') -Raw)
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
    $controls = @{}
    foreach ($node in $xml.SelectNodes('//*[@Name]')) {
        $name=$node.GetAttribute('Name')
        $controls[$name] = $window.FindName($name)
    }
    $graph = [EndpointToolbox.DesktopEngine]::new()
    $remote = [EndpointToolbox.DesktopEngine]::new()
    $syntheticRemote = [runspacefactory]::CreateRunspace()
    $syntheticRemote.Open()
    $historyPath = Join-Path $env:TEMP "EndpointToolbox-remote-output-$([guid]::NewGuid()).jsonl"
    $script:Ui = @{
        Window=$window; Controls=$controls; Catalog=@(); Workflow=$null
        Graph=$graph; Remote=$remote; RemoteTarget='Synthetic-PC'; LogRoot=''
        Active=$null; ReceivingEvents=$false; Faulted=$false; TestMode=$false
        Datasets=@{}; PendingBatches=[Collections.Generic.Queue[object]]::new()
        ActivityBuffer=$null; RemoteBuffer=$null; ActivitySummary=$null; DiagnosticCount=0
        HistoryPath=$historyPath; Choice=$null
    }
    $ui = $script:Ui
    $remote.FormatPipelineOutput=$true
    $remote.Host.PushRunspace($syntheticRemote)
    try {
        foreach ($mode in @('Success','Failure','Cancel')) {
            $command = switch ($mode) {
                'Success' { 'Start-Sleep -Seconds 1; Write-Output "Synthetic result"' }
                'Failure' { 'Start-Sleep -Seconds 1; throw "Synthetic remote failure"' }
                'Cancel' { 'Start-Sleep -Seconds 30' }
            }
            $ui.Active = [pscustomobject]@{
                Engine=$remote; WorkflowId='remote-command'; Start=[datetime]::UtcNow
                RunId=[guid]::NewGuid().ToString(); Failures=$false; Warnings=$false
                PendingApproval=$false; IsRemote=$true; Completed=$false; State=''
            }
            $remote.RunCommand($command)
            Add-EndpointActivity 'Remote command submitted' $command -Remote
            Receive-EndpointEvents
            if ($controls.RemoteBusyIndicator.Visibility -ne 'Visible') { throw "Remote running indicator missing for $mode." }
            $firstFrame=$controls.RemoteBusyIndicator.Text
            Start-Sleep -Milliseconds 270
            Receive-EndpointEvents
            if ($controls.RemoteBusyIndicator.Text -eq $firstFrame) { throw 'Remote running indicator did not animate.' }
            if ($mode -eq 'Cancel') {
                Stop-EndpointOperation
                Update-EndpointRemoteIndicator
                if ($remote.Busy -and $controls.RemoteBusyIndicator.Text -notmatch 'Stopping') { throw 'Cancellation indicator did not show stopping.' }
            }
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while ($ui.Active -and $watch.Elapsed.TotalSeconds -lt 10) { Receive-EndpointEvents; Start-Sleep -Milliseconds 10 }
            if ($ui.Active -or $ui.Faulted) { throw "Synthetic remote $mode did not finish." }
            if ($controls.RemoteBusyIndicator.Visibility -ne 'Collapsed' -or $controls.RemoteBusyIndicator.Text) { throw 'Remote running indicator remained after completion.' }
        }
        $transcript=$controls.RemoteOutput.Text
        if ($transcript -notmatch 'PS \[Synthetic-PC\]> Start-Sleep' -or $transcript -notmatch 'Synthetic result') { throw 'Remote commands or results were lost.' }
        if ($transcript -notmatch 'Synthetic remote failure') { throw 'Remote failures were hidden.' }
        if ($transcript -match 'Run timing|Output:|Remote command submitted:|\[\d{2}:\d{2}:\d{2}\]|Running\.\.\.') { throw 'Remote output retained activity prefixes or temporary indicator text.' }
        if ($controls.Activity.Text -notmatch 'Run timing:') { throw 'Detailed timing was removed from Script output.' }
        $before=$controls.RemoteOutput.Text
        Add-EndpointActivity 'Remote session' 'Synthetic connection details' -Remote
        if ($controls.RemoteOutput.Text -cne $before) { throw 'Connection metadata was duplicated in the remote transcript.' }
        $ui.ActivityBuffer=[Text.StringBuilder]::new()
        $ui.RemoteBuffer=[Text.StringBuilder]::new()
        Add-EndpointActivity 'Output' 'Buffered result' -Remote
        Add-EndpointActivity 'Warning' 'Synthetic warning' -Remote
        Add-EndpointActivity 'Run timing' 'Synthetic timing' -Remote
        if ($ui.RemoteBuffer.ToString() -cne "Buffered result`r`nWarning: Synthetic warning`r`n") { throw 'Buffered remote formatting differed from direct output.' }
        if ($ui.ActivityBuffer.ToString() -notmatch 'Run timing: Synthetic timing') { throw 'Buffered Script output lost detailed timings.' }
        'Native terminal-style remote output and running indicator passed.'
    }
    finally {
        $remote.Host.PopRunspace()
        $remote.Dispose(); $graph.Dispose(); $syntheticRemote.Dispose()
        $window.Close()
        if (Test-Path -LiteralPath $historyPath) { Remove-Item -LiteralPath $historyPath }
        $script:Ui=$previous
    }
} $desktop
