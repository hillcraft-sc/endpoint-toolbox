# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

$desktop = Split-Path $PSScriptRoot -Parent
if (-not ('EndpointToolbox.DesktopEngine' -as [type])) { Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs') }
$fixture = Join-Path $PSScriptRoot 'Fixtures\HostFixture.ps1'

function Complete-Fixture {
    param($Engine, [scriptblock]$Answer)
    $events = [Collections.Generic.List[object]]::new()
    $deadline = [datetime]::Now.AddSeconds(15)
    do {
        $null = $Engine.Poll()
        $event = $null
        while ($Engine.Host.Events.TryDequeue([ref]$event)) {
            $events.Add($event)
            if ($event.Kind -eq 'Prompt') {
                if ($Answer) { & $Answer $event.Data } else { $event.Data.Cancel() }
            }
        }
        if ([datetime]::Now -gt $deadline) { $Engine.Cancel(); throw 'Fixture timed out.' }
        Start-Sleep -Milliseconds 10
    } while ($Engine.Busy -or -not $Engine.Host.Events.IsEmpty)
    return $events.ToArray()
}

Describe 'Desktop PowerShell host' {
    It 'publishes script-discovery choices as a structured presentation event' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($fixture, @{Mode='Choices'}, $true)
            $events = @(Complete-Fixture $engine)
            $engine.HasErrors | Should Be $false
            $choiceEvent = @($events | Where-Object { $_.Kind -eq 'ScriptChoices' -and $_.Name -eq 'Intune scripts' })
            $choiceEvent.Count | Should Be 1
            $choiceEvent[0].Data.ScriptType | Should Be 'All'
            @($choiceEvent[0].Data.Choices).Count | Should Be 1
        }
        finally { $engine.Dispose() }
    }

    It 'publishes a Win32 deletion report and exact counts through the native worker' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        $outputPath = Join-Path $env:TEMP "EndpointToolbox-removal-$([guid]::NewGuid())"
        try {
            $engine.Host.PrepareReportTables = $true
            $engine.RunFile((Join-Path $PSScriptRoot 'Fixtures\Win32RemovalFixture.ps1'), @{OutputPath=$outputPath}, $true)
            $events = @(Complete-Fixture $engine)
            $engine.HasErrors | Should Be $false
            $summary = @($events | Where-Object Kind -eq 'OperationSummary')[0].Data
            $summary.Targeted | Should Be 3
            $summary.Succeeded | Should Be 3
            $summary.Affected | Should Be 3
            $report = @($events | Where-Object Kind -eq 'Artifact')[0].Data
            @(Import-Csv -LiteralPath $report).Count | Should Be 3
            @($events | Where-Object Kind -eq 'Rows')[0].Data.Table.Rows.Count | Should Be 3
        }
        finally {
            $engine.Dispose()
            if (Test-Path -LiteralPath $outputPath) {
                Get-ChildItem -LiteralPath $outputPath -File | Remove-Item -Force
                Remove-Item -LiteralPath $outputPath
            }
        }
    }
    It 'records declined confirmations without calling them successful deletions' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        $outputPath = Join-Path $env:TEMP "EndpointToolbox-declined-$([guid]::NewGuid())"
        try {
            $engine.RunFile((Join-Path $PSScriptRoot 'Fixtures\Win32RemovalFixture.ps1'), @{OutputPath=$outputPath;Mode='Decline'}, $true)
            $events = @(Complete-Fixture $engine { param($request) $request.Complete([array]::IndexOf($request.Choices, 'No')) })
            $engine.HasErrors | Should Be $false
            $summary = @($events | Where-Object Kind -eq 'OperationSummary')[0].Data
            $summary.Succeeded | Should Be 0
            $summary.Skipped | Should Be 3
            $report = @(Import-Csv -LiteralPath @($events | Where-Object Kind -eq 'Artifact')[0].Data)
            @($report | Where-Object Status -eq 'Declined').Count | Should Be 3
        }
        finally {
            $engine.Dispose()
            if (Test-Path -LiteralPath $outputPath) {
                Get-ChildItem -LiteralPath $outputPath -File | Remove-Item -Force
                Remove-Item -LiteralPath $outputPath
            }
        }
    }
    It 'persists completed deletions and marks an interrupted request as unknown after cancellation' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        $outputPath = Join-Path $env:TEMP "EndpointToolbox-cancel-removal-$([guid]::NewGuid())"
        try {
            $engine.RunFile((Join-Path $PSScriptRoot 'Fixtures\Win32RemovalFixture.ps1'), @{OutputPath=$outputPath;Mode='Cancel'}, $true)
            $deadline = [datetime]::UtcNow.AddSeconds(15)
            $cancelled = $false
            while (-not $cancelled -and [datetime]::UtcNow -lt $deadline) {
                $null = $engine.Poll()
                $event = $null
                while ($engine.Host.Events.TryDequeue([ref]$event)) {
                    if ($event.Kind -eq 'Stage' -and $event.Name -eq 'In-flight deletion') { $engine.Cancel(); $cancelled = $true }
                }
                Start-Sleep -Milliseconds 10
            }
            $cancelled | Should Be $true
            $null = Complete-Fixture $engine
            $engine.LastState | Should Be 'Cancelled'
            $path = (Get-ChildItem -LiteralPath $outputPath -Filter 'Win32AppRemoval_*.csv')[0].FullName
            $report = @(Import-Csv -LiteralPath $path)
            $report.Count | Should Be 3
            $report[0].Status | Should Be 'Deleted'
            $report[1].Status | Should Be 'NotConfirmed'
            $report[2].Status | Should Be 'NotProcessed'
            $records = @(Get-Content -LiteralPath (Join-Path $outputPath "task-delete-win32-apps-$([datetime]::UtcNow.ToString('yyyy-MM-dd')).jsonl") | ForEach-Object { $_ | ConvertFrom-Json })
            $records[-1].State | Should Be 'Cancelled'
            $records[-1].Summary.Succeeded | Should Be 1
            $records[-1].Summary.CountsComplete | Should Be $false
        }
        finally {
            $engine.Dispose()
            if (Test-Path -LiteralPath $outputPath) {
                Get-ChildItem -LiteralPath $outputPath -File | Remove-Item -Force
                Remove-Item -LiteralPath $outputPath
            }
        }
    }
    It 'keeps report rows out of scrolling output while preparing the complete grid in the worker' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.Host.PrepareReportTables = $true
            $engine.FormatPipelineOutput = $true
            $engine.SuppressScriptObjectOutput = $true
            $engine.RunFile((Join-Path $desktop 'Invoke-WorkflowPresentation.ps1'), @{
                ScriptPath=$fixture; WorkflowId='offline-report'; ScriptArguments=@{Mode='ReportOutput';Count=10000}
            }, $true)
            $events=@(Complete-Fixture $engine)
            $engine.HasErrors | Should Be $false
            $reports=@($events | Where-Object Kind -eq 'Rows')
            $reports.Count | Should Be 1
            $reports[0].Data.Table.Rows.Count | Should Be 10000
            $reports[0].Data.Table.Rows[9999].DeviceName | Should Be 'Report-device-9999'
            $reports[0].Data.Table.Rows[9999].RawVersion | Should Be '123.456'
            $log=($events | Where-Object Kind -in @('Output','Activity') | ForEach-Object Data) -join "`n"
            $log | Should Match 'Generating report fixture'
            $log | Should Match 'Report generation finished'
            $log | Should Not Match 'Report-device-'
            @($events | Where-Object Kind -eq 'Warning').Count | Should Be 1
        }
        finally { $engine.Dispose() }
    }
    It 'preserves schema, redaction and outcome flags when preparing a report table' {
        $hostBridge=[EndpointToolbox.DesktopHost]::new()
        $rows=@(
            [pscustomobject]@{Status='Failed';Link='https://fixture.invalid/?sig=secret';Token='Bearer abc.def';Empty=$null}
            [pscustomobject]@{Status='PendingApproval';Extra='extra column'}
            [pscustomobject]@{Status='NotConfirmed';Extra='last value'}
        )
        $report=[EndpointToolbox.PreparedReport]::new('Fixture', $rows, $hostBridge)
        $report.Table.Rows.Count | Should Be 3
        $report.Table.Columns.Count | Should Be 5
        $report.Table.Rows[0].Link | Should Be 'https://fixture.invalid/?sig=[redacted]'
        $report.Table.Rows[0].Token | Should Be 'Bearer [redacted]'
        $report.Table.Rows[0].Empty | Should Be ''
        $report.Table.Rows[2].Extra | Should Be 'last value'
        $report.HasFailures | Should Be $true
        $report.HasWarnings | Should Be $true
        $report.PendingApproval | Should Be $true
    }
    It 'records worker times independently of UI polling and resets them for the next run' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($fixture, @{ Mode='Output' }, $false)
            $deadline=[datetime]::UtcNow.AddSeconds(10)
            while (-not $engine.FinishedUtc -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
            ($null -ne $engine.FinishedUtc) | Should Be $true
            ($engine.FinishedUtc -ge $engine.StartedUtc) | Should Be $true
            $elapsed=$engine.Elapsed
            $end=$engine.FinishedUtc
            Start-Sleep -Milliseconds 250
            $engine.Elapsed | Should Be $elapsed
            $engine.FinishedUtc | Should Be $end
            $null=Complete-Fixture $engine
            $engine.RunFile($fixture, @{Mode='Wait'}, $false)
            ($null -eq $engine.FinishedUtc) | Should Be $true
            ($engine.StartedUtc -gt $end) | Should Be $true
            $engine.Cancel()
            $null=Complete-Fixture $engine
            ($null -ne $engine.FinishedUtc) | Should Be $true
            $engine.LastState | Should Be 'Cancelled'
        }
        finally { $engine.Dispose() }
    }
    It 'cancels display processing even when the worker already completed' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($fixture, @{ Mode='Rows'; Count=100 }, $true)
            $deadline=[datetime]::UtcNow.AddSeconds(5)
            while ($engine.Busy -and [datetime]::UtcNow -lt $deadline) { $null=$engine.Poll(); Start-Sleep -Milliseconds 10 }
            $engine.Busy | Should Be $false
            $engine.Cancel()
            $engine.LastState | Should Be 'Cancelled'
            $event=$null; $rows=0
            while ($engine.Host.Events.TryDequeue([ref]$event)) { if ($event.Kind -eq 'Rows') { $rows++ } }
            $rows | Should Be 0
        }
        finally { $engine.Dispose() }
    }
    It 'discards queued presentation data on cancel but preserves diagnostics and saved-file references' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($fixture, @{ Mode='Wait' }, $false)
            for ($i=0; $i -lt 10000; $i++) { $engine.Host.Emit('Output','Backlog',"Line $i") }
            $engine.Host.Emit('Rows','Backlog',@([pscustomobject]@{Name='Queued row'}))
            $engine.Host.Emit('Artifact','Saved report','fixture.csv')
            $engine.Host.Emit('Error','Diagnostic','Preserve failure')
            $engine.Cancel()
            $engine.Cancel()
            $engine.Host.Emit('Output','Late output','Should not render')
            $events = @(Complete-Fixture $engine)
            @($events | Where-Object Kind -in @('Output','Rows')).Count | Should Be 0
            @($events | Where-Object Kind -eq 'Artifact').Count | Should Be 1
            @($events | Where-Object Kind -eq 'Error').Count | Should Be 1
            $engine.LastState | Should Be 'Cancelled'
            $engine.RunFile($fixture, @{Mode='Output'}, $false)
            $next = @(Complete-Fixture $engine)
            @($next | Where-Object Kind -eq 'Output').Count | Should Be 1
            $engine.LastState | Should Be 'Completed with warnings'
        }
        finally { $engine.Dispose() }
    }
    It 'formats pipeline output in the worker while preserving structured report events' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.FormatPipelineOutput = $true
            $engine.RunFile($fixture, @{ Mode = 'Output'; Literal = 'Worker formatted value' }, $true)
            $events = @(Complete-Fixture $engine)
            $output = @($events | Where-Object Kind -eq 'Output')
            @($output | Where-Object { $_.Data -isnot [string] }).Count | Should Be 0
            ($output.Data -join "`n") | Should Match 'Worker formatted value'
            @($events | Where-Object Kind -eq 'Rows').Count | Should Be 1
            $engine.HasErrors | Should Be $false
        }
        finally { $engine.Dispose() }
    }
    It 'presents deployment matches and reports on just one selected app' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile((Join-Path $PSScriptRoot 'Fixtures\Win32SelectionFixture.ps1'), @{ WorkflowId='intune-assignment-win32-deployment-exports' }, $true)
            $events = @(Complete-Fixture $engine { param($request) $request.Complete('1') })
            $choice = @($events | Where-Object Kind -eq 'Choice')
            $choice.Count | Should Be 1
            $choice[0].Name | Should Be 'Multiple'
            $choice[0].Data.Count | Should Be 2
            $request = @($events | Where-Object { $_.Kind -eq 'Stage' -and $_.Name -eq 'Requested report' })
            $request.Count | Should Be 1
            [string]$request[0].Data | Should Match '00000000-0000-0000-0000-000000000002'
        }
        finally { $engine.Dispose() }
    }
    It 'presents a searchable script choice and passes one selected remediation to the report' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile((Join-Path $PSScriptRoot 'Fixtures\ScriptSelectionFixture.ps1'), @{ WorkflowId='intune-script-device-status' }, $true)
            $events = @(Complete-Fixture $engine { param($request) $request.Complete('1') })
            $choice = @($events | Where-Object { $_.Kind -eq 'Choice' -and $_.Name -eq 'Script' })
            $choice.Count | Should Be 1
            $choice[0].Data.Count | Should Be 2
            $choice[0].Data[1].DisplayName | Should Be 'Beta remediation'
            $endpoint = @($events | Where-Object { $_.Kind -eq 'Stage' -and $_.Name -eq 'Selected run-state endpoint' })
            $endpoint.Count | Should Be 1
            [string]$endpoint[0].Data | Should Match '00000000-0000-0000-0000-000000000014/deviceRunStates'
            $engine.HasErrors | Should Be $false
        }
        finally { $engine.Dispose() }
    }
    It 'preserves multi-app selection and permits skipping a deletion pattern without mutations' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile((Join-Path $PSScriptRoot 'Fixtures\Win32SelectionFixture.ps1'), @{ WorkflowId='intune-assignment-win32-deployment-exports' }, $true)
            $events = @(Complete-Fixture $engine { param($request) $request.Complete('0,1') })
            @($events | Where-Object { $_.Kind -eq 'Choice' -and $_.Name -eq 'Multiple' }).Count | Should Be 1
            @($events | Where-Object { $_.Kind -eq 'Stage' -and $_.Name -eq 'Requested report' }).Count | Should Be 2
            $engine.RunFile((Join-Path $PSScriptRoot 'Fixtures\Win32SelectionFixture.ps1'), @{ WorkflowId='delete-win32-apps' }, $true)
            $events = @(Complete-Fixture $engine { param($request) $request.Complete('') })
            @($events | Where-Object { $_.Kind -eq 'Choice' -and $_.Name -eq 'Multiple' }).Count | Should Be 1
            @($events | Where-Object { $_.Kind -eq 'Warning' -and [string]$_.Data -eq "Skipping 'Fixture*'." }).Count | Should Be 1
            @($events | Where-Object { $_.Kind -eq 'Error' -and [string]$_.Data -match 'No Win32 apps were resolved. Nothing to delete.' }).Count | Should Be 1
        }
        finally { $engine.Dispose() }
    }
    It 'checks commands in the persistent worker without requiring a module name or executing them' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($fixture, @{ Mode = 'DefineCommand' }, $false)
            $null = Complete-Fixture $engine
            $engine.RunFile($fixture, @{ Mode = 'Output' }, $false, [string[]]@('Test-EndpointWorkerCommand'))
            $events = @(Complete-Fixture $engine)
            $engine.HasErrors | Should Be $false
            @($events | Where-Object Kind -eq 'Output').Count | Should Be 1
        }
        finally { $engine.Dispose() }
    }
    It 'blocks missing commands before script execution and permits a later invocation' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($fixture, @{ Mode = 'Output' }, $false, [string[]]@('Test-EndpointMissingCommand'))
            $events = @(Complete-Fixture $engine)
            $engine.HasErrors | Should Be $true
            @($events | Where-Object Kind -eq 'Output').Count | Should Be 0
            @($events | Where-Object { $_.Kind -eq 'Error' -and [string]$_.Data -like "*Required command 'Test-EndpointMissingCommand'*" }).Count | Should Be 1
            $engine.RunFile($fixture, @{ Mode = 'Output' }, $false)
            $null = Complete-Fixture $engine
            $engine.HasErrors | Should Be $false
        }
        finally { $engine.Dispose() }
    }
    It 'captures streams and structured data without executing literal parameters' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $literal = '$(throw "injection")'
            $engine.RunFile($fixture, @{ Mode = 'Output'; Literal = $literal }, $true)
            $events = @(Complete-Fixture $engine)
            @($events | Where-Object Kind -eq 'Rows').Count | Should Be 1
            @($events | Where-Object { $_.Kind -eq 'Output' -and $_.Data.Literal -eq $literal }).Count | Should Be 1
            @($events | Where-Object { $_.Kind -eq 'Activity' -and [string]$_.Data -match 'host message' }).Count | Should Be 1
        }
        finally { $engine.Dispose() }
    }
    It 'handles Read-Host and mandatory ShouldContinue prompts' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($fixture, @{ Mode = 'Prompt' }, $true)
            $events = @(Complete-Fixture $engine { param($request) $request.Complete('fixture reply') })
            @($events | Where-Object { $_.Kind -eq 'Output' -and [string]$_.Data -eq 'Answer: fixture reply' }).Count | Should Be 1
            $engine.RunFile($fixture, @{ Mode = 'Confirm'; Confirm = $false }, $true)
            $events = @(Complete-Fixture $engine { param($request) $request.Complete(1) })
            @($events | Where-Object { $_.Kind -eq 'Output' -and [string]$_.Data -eq 'Declined' }).Count | Should Be 1
        }
        finally { $engine.Dispose() }
    }
    It 'isolates exit 1 and permits the next invocation' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($fixture, @{ Mode = 'Exit' }, $true)
            $events = @(Complete-Fixture $engine)
            $engine.Host.ExitCode | Should Be 1
            $engine.RunFile($fixture, @{ Mode = 'Rows'; Count = 2 }, $true)
            $events = @(Complete-Fixture $engine)
            @($events | Where-Object Kind -eq 'Rows')[0].Data.Count | Should Be 2
            $engine.Host.ExitCode | Should Be 0
        }
        finally { $engine.Dispose() }
    }
    It 'captures an original script exit code through the presentation adapter' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile((Join-Path $desktop 'Invoke-WorkflowPresentation.ps1'), @{
                ScriptPath=$fixture; WorkflowId='offline-exit'; ScriptArguments=@{Mode='Exit'}
            }, $true)
            $events = @(Complete-Fixture $engine)
            if ($engine.Host.ExitCode -ne 1) { throw "Adapter exit failed for $fixture. Events: $(($events | ForEach-Object { $_.Kind + ': ' + [string]$_.Data }) -join '; ')" }
            $engine.Host.ExitCode | Should Be 1
        }
        finally { $engine.Dispose() }
    }
    It 'cancels a pending prompt without approval' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($fixture, @{ Mode = 'Confirm' }, $true)
            $events = @(Complete-Fixture $engine { param($request) $request.Cancel() })
            $engine.LastState | Should Be 'Cancelled'
            @($events | Where-Object { $_.Kind -eq 'Output' -and [string]$_.Data -eq 'Approved' }).Count | Should Be 0
        }
        finally { $engine.Dispose() }
    }
    It 'stops a running operation asynchronously' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($fixture, @{ Mode = 'Wait' }, $true)
            $engine.Cancel()
            $null = Complete-Fixture $engine
            $engine.LastState | Should Be 'Cancelled'
        }
        finally { $engine.Dispose() }
    }
    It 'never falls back to local execution for remote command input' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $rejected = $false
            try { $engine.RunCommand("'must not run locally'") } catch { $rejected = $true }
            $rejected | Should Be $true
        }
        finally { $engine.Dispose() }
    }
}
