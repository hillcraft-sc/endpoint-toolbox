$desktop = Split-Path $PSScriptRoot -Parent
. (Join-Path $desktop 'ActivityLogging.ps1')
$logRoot = Join-Path $env:TEMP "EndpointToolbox-activity-tests-$([guid]::NewGuid())"
$null = New-Item -Path $logRoot -ItemType Directory

Describe 'Compact persistent activity logging' {
    It 'writes matching master and task records with user, UTC time and run correlation' {
        Write-EndpointActivityRecord $logRoot 'RunStarted' -WorkflowId 'fixture' -RunId 'fixture-run'
        $day = [datetime]::UtcNow.ToString('yyyy-MM-dd')
        $master = Get-Content -LiteralPath (Join-Path $logRoot "master-$day.jsonl") | ConvertFrom-Json
        $task = Get-Content -LiteralPath (Join-Path $logRoot "task-fixture-$day.jsonl") | ConvertFrom-Json
        $master.RunId | Should Be 'fixture-run'
        $task.RunId | Should Be $master.RunId
        $master.User | Should Be ([Environment]::UserName)
        $master.TimestampUtc.Kind | Should Be 'Utc'
    }
    It 'bounds diagnostic text and redacts common credential formats without saving subsequent lines' {
        $message = 'Bearer synthetic.token https://fixture.invalid/?sig=synthetic-signature password=synthetic-password ' + ('x' * 1000) + "`nsecond-line-secret"
        Write-EndpointActivityRecord $logRoot 'TaskError' -WorkflowId 'fixture' -Message $message
        $record = Get-Content -LiteralPath (Join-Path $logRoot "task-fixture-$([datetime]::UtcNow.ToString('yyyy-MM-dd')).jsonl") | Select-Object -Last 1 | ConvertFrom-Json
        $record.Message | Should Not Match 'synthetic|second-line-secret'
        ($record.Message.Length -le 503) | Should Be $true
    }
    It 'persists connection metadata but excludes all remote command, credential and returned content' {
        Write-EndpointActivityRecord $logRoot 'RunEnded' -WorkflowId 'remote-endpoint' -Device 'Fixture-PC' -State 'ConnectionFailed' -Message 'synthetic-secret' -Summary @{Output='synthetic-output'}
        $path = Join-Path $logRoot "task-remote-endpoint-$([datetime]::UtcNow.ToString('yyyy-MM-dd')).jsonl"
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should Not Match 'synthetic|Message|Summary'
        $record = $text | ConvertFrom-Json
        $record.Device | Should Be 'Fixture-PC'
        $record.State | Should Be 'ConnectionFailed'
        $master = Join-Path $logRoot "master-$([datetime]::UtcNow.ToString('yyyy-MM-dd')).jsonl"
        $before = [IO.File]::ReadAllText($master)
        Write-EndpointActivityRecord $logRoot 'TaskError' -WorkflowId 'remote-command' -Message 'synthetic-command-and-output'
        [IO.File]::ReadAllText($master) | Should Be $before
    }
    It 'retains 30 UTC calendar days and never deletes CSV reports or unrelated files' {
        $oldDay = [datetime]::UtcNow.AddDays(-30).ToString('yyyy-MM-dd')
        $keptDay = [datetime]::UtcNow.AddDays(-29).ToString('yyyy-MM-dd')
        $old = Join-Path $logRoot "task-fixture-$oldDay-1.jsonl"
        $kept = Join-Path $logRoot "master-$keptDay.jsonl"
        $csv = Join-Path $logRoot "report-$oldDay.csv"
        $unrelated = Join-Path $logRoot "notes-$oldDay.jsonl"
        foreach ($path in @($old,$kept,$csv,$unrelated)) { Set-Content -LiteralPath $path -Value 'fixture' }
        Write-EndpointActivityRecord $logRoot 'RetentionCheck'
        Test-Path -LiteralPath $old | Should Be $false
        foreach ($path in @($kept,$csv,$unrelated)) { Test-Path -LiteralPath $path | Should Be $true }
    }
    It 'rolls a daily log over at 5 MB without overwriting existing records' {
        $day = [datetime]::UtcNow.ToString('yyyy-MM-dd')
        $path = Join-Path $logRoot "task-rollover-$day.jsonl"
        $stream = [IO.File]::Create($path)
        try { $stream.SetLength(5MB) } finally { $stream.Dispose() }
        Write-EndpointActivityRecord $logRoot 'RolloverCheck' -WorkflowId 'rollover'
        (Get-Item -LiteralPath $path).Length | Should Be 5MB
        $record = Get-Content -LiteralPath (Join-Path $logRoot "task-rollover-$day-1.jsonl") | ConvertFrom-Json
        $record.Event | Should Be 'RolloverCheck'
    }
    It 'reports unwritable log locations instead of silently claiming persistence' {
        $file = Join-Path $logRoot 'not-a-folder'
        Set-Content -LiteralPath $file -Value 'fixture'
        $rejected = $false
        try { Write-EndpointActivityRecord $file 'MustFail' } catch { $rejected = $true }
        $rejected | Should Be $true
    }
    It 'serializes simultaneous writers into complete JSON records' {
        $writers = @(); $handles = @()
        try {
            foreach ($id in @('writer-one','writer-two')) {
                $writer = [powershell]::Create()
                $null = $writer.AddScript({
                    param($helper,$root,$id)
                    . $helper
                    for ($i=0; $i -lt 10; $i++) { Write-EndpointActivityRecord $root 'ConcurrentWrite' -WorkflowId 'concurrent' -RunId $id }
                }).AddArgument((Join-Path $desktop 'ActivityLogging.ps1')).AddArgument($logRoot).AddArgument($id)
                $writers += $writer
                $handles += $writer.BeginInvoke()
            }
            for ($i=0; $i -lt $writers.Count; $i++) {
                $null = $writers[$i].EndInvoke($handles[$i])
                if ($writers[$i].HadErrors) { throw ($writers[$i].Streams.Error -join "`n") }
            }
            $records = @(Get-Content -LiteralPath (Join-Path $logRoot "task-concurrent-$([datetime]::UtcNow.ToString('yyyy-MM-dd')).jsonl") | ForEach-Object { $_ | ConvertFrom-Json })
            $records.Count | Should Be 20
            @($records | Where-Object RunId -eq 'writer-one').Count | Should Be 10
            @($records | Where-Object RunId -eq 'writer-two').Count | Should Be 10
        }
        finally { foreach ($writer in $writers) { $writer.Dispose() } }
    }
}

Describe 'Action count semantics' {
    It 'keeps failures, approvals, previews, unresolved and unprocessed targets out of success totals' {
        $rows = @('Deleted','Failed','PendingApproval','WhatIf','Declined','NotFound','NotProcessed') | ForEach-Object { [pscustomobject]@{Status=$_} }
        $summary = Get-EndpointOutcomeSummary 'Apps' $rows
        $summary.Targeted | Should Be 7
        $summary.Succeeded | Should Be 1
        $summary.Failed | Should Be 1
        $summary.PendingApproval | Should Be 1
        $summary.Skipped | Should Be 2
        $summary.NotFound | Should Be 1
        $summary.Unprocessed | Should Be 1
        $summary.Affected | Should Be 1
    }
    It 'does not classify a reported installation failure as a failure to run a read-only report' {
        $summary = Get-EndpointOutcomeSummary 'Report rows' @([pscustomobject]@{Status='Failed';InstallState='Failed'}) -ReadOnly
        $summary.Succeeded | Should Be 1
        $summary.Failed | Should Be 0
        $summary.Affected | Should Be 0
    }
    It 'counts a failed secondary cleanup action as a failure while retaining the accepted primary action count' {
        $summary = Get-EndpointOutcomeSummary 'Devices' @([pscustomobject]@{EntraAction='Deleted';AutopilotAction='Error'}) -StatusProperties @('EntraAction','AutopilotAction')
        $summary.Failed | Should Be 1
        $summary.Succeeded | Should Be 0
        $summary.Affected | Should Be 1
    }
    It 'does not let an absent optional Autopilot record hide a successful Entra deletion' {
        $summary = Get-EndpointOutcomeSummary 'Devices' @([pscustomobject]@{EntraAction='Deleted';AutopilotAction='NotFound'}) -StatusProperties @('EntraAction','AutopilotAction')
        $summary.Succeeded | Should Be 1
        $summary.NotFound | Should Be 0
        $summary.Affected | Should Be 1
    }
    It 'marks unknown action outcomes as incomplete instead of inventing success' {
        $summary = Get-EndpointOutcomeSummary 'Devices' @([pscustomobject]@{Status='Unrecognized'})
        $summary.Succeeded | Should Be 0
        $summary.Unprocessed | Should Be 1
        $summary.CountsComplete | Should Be $false
        Format-EndpointOutcomeSummary $summary | Should Match 'Incomplete counts'
    }
}

Describe 'Win32 deletion report safeguards' {
    It 'prevents deletion when the run CSV cannot be created' {
        $blockedPath = Join-Path $logRoot 'blocked-report-folder'
        Set-Content -LiteralPath $blockedPath -Value 'fixture'
        $writes = [Collections.Generic.List[string]]::new()
        function Get-MgContext { @{Account='fixture@example.invalid'} }
        function Invoke-MgGraphRequest {
            param($Method,$Uri)
            if ($Method -ne 'GET') { $writes.Add($Method); return }
            @{value=@(@{id='fixture';displayName='Fixture';displayVersion='1.0';'@odata.type'='#microsoft.graph.win32LobApp'})}
        }
        $rejected = $false
        try {
            & (Join-Path (Split-Path $desktop -Parent) 'Intune\Apps\Remove-Win32App.ps1') -AppId fixture -Justification 'Fixture' -OutputPath $blockedPath -Confirm:$false 6>$null
        }
        catch { $rejected = $true }
        $rejected | Should Be $true
        $writes.Count | Should Be 0
    }
    It 'extracts a short dependency reason from a nested Graph error envelope' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $desktop -Parent) 'Intune\Apps\Remove-Win32App.ps1'),[ref]$tokens,[ref]$errors)
        $definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-RemovalFailureReason'},$true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $errorRecord = [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('HTTP 400 Bad Request'),'Fixture',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
        $nested = @{Message='Cannot delete this app as it is the parent of another app: 00000000-0000-0000-0000-000000000010. - Operation ID: synthetic-long-diagnostics'} | ConvertTo-Json -Compress
        $envelope = @{error=@{message=$nested}} | ConvertTo-Json -Compress
        $errorRecord.ErrorDetails = [Management.Automation.ErrorDetails]::new($envelope)
        $reason = Get-RemovalFailureReason $errorRecord
        $reason | Should Match 'parent of another app: 00000000-0000-0000-0000-000000000010'
        $reason | Should Not Match 'Operation ID|HTTP|synthetic'
        ($reason.Length -lt 200) | Should Be $true
    }
}

Get-ChildItem -LiteralPath $logRoot -File | Remove-Item -Force
Remove-Item -LiteralPath $logRoot
