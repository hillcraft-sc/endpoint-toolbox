function Write-EndpointActivityRecord {
    param(
        [Parameter(Mandatory)][string]$LogRoot,
        [Parameter(Mandatory)][string]$Event,
        [string]$WorkflowId = '',
        [string]$RunId = '',
        [string]$State = '',
        [string]$Device = '',
        [string]$Message = '',
        [AllowNull()][object]$Summary
    )
    if ($WorkflowId -and $WorkflowId -notmatch '^[a-z0-9-]+$') { throw 'Invalid activity log workflow ID.' }
    # Remote activity records never accept command text, output, credentials or errors.
    if ($WorkflowId -eq 'remote-command') { return }
    if ($WorkflowId -in @('remote-endpoint','remote-disconnect')) {
        if ($Event -notin @('RunRequested','RunStarted','RunEnded','RunFinished','CancellationRequested','DisconnectRequested','AppError','RunStartFailed')) { return }
        $Message = ''; $Summary = $null
    }
    $record = [ordered]@{
        TimestampUtc = [datetime]::UtcNow.ToString('o')
        User = [Environment]::UserName
        Event = $Event; WorkflowId = $WorkflowId; RunId = $RunId; State = $State
    }
    if ($Device) { $record.Device = $Device }
    if ($Message) {
        $text = ($Message -split '\r?\n', 2)[0]
        $text = $text -replace '(?i)([?&](?:token|sig|signature|access_token|code)=)[^&\s"<>]+', '$1[redacted]'
        $text = $text -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/-]+=*', '$1[redacted]'
        $text = $text -replace '(?i)((?:password|secret|credential|authorization|token)\s*[:=]\s*)\S+', '$1[redacted]'
        $record.Message = if ($text.Length -gt 500) { $text.Substring(0,500) + '...' } else { $text }
    }
    if ($null -ne $Summary) { $record.Summary = $Summary }
    $line = ($record | ConvertTo-Json -Depth 5 -Compress) + [Environment]::NewLine
    $root = [IO.Path]::GetFullPath($LogRoot)
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($root.ToUpperInvariant())))
    $mutex = [Threading.Mutex]::new($false, "Local\EndpointToolboxLogs-$hash")
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(5000) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Timed out waiting to write Endpoint Toolbox activity logs.' }
        $null = [IO.Directory]::CreateDirectory($root)
        $now = [datetime]::UtcNow
        foreach ($file in [IO.Directory]::EnumerateFiles($root, '*.jsonl')) {
            $name = [IO.Path]::GetFileName($file)
            if ($name -match '^(master|task-[a-z0-9-]+)-(\d{4}-\d{2}-\d{2})(-\d+)?\.jsonl$') {
                $day = [datetime]::MinValue
                if (-not [datetime]::TryParseExact($Matches[2], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$day)) { continue }
                if ($day -lt $now.Date.AddDays(-29)) { [IO.File]::Delete($file) }
            }
        }
        $prefixes = @('master')
        if ($WorkflowId) { $prefixes += "task-$WorkflowId" }
        foreach ($prefix in $prefixes) {
            $base = "$prefix-$($now.ToString('yyyy-MM-dd'))"
            $path = Join-Path $root "$base.jsonl"
            $segment = 0
            while ([IO.File]::Exists($path) -and ([IO.FileInfo]::new($path)).Length -ge 5MB) {
                $segment++
                $path = Join-Path $root "$base-$segment.jsonl"
            }
            [IO.File]::AppendAllText($path, $line, [Text.UTF8Encoding]::new($false))
        }
    }
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-EndpointOutcomeSummary {
    param(
        [string]$Entity,
        [object[]]$Rows = @(),
        [string[]]$StatusProperties = @(),
        [switch]$ReadOnly
    )
    $Rows = @($Rows | Where-Object { $null -ne $_ })
    if (-not $ReadOnly -and -not $StatusProperties.Count) { $StatusProperties = @('Status') }
    $summary = [ordered]@{
        Entity = $Entity; Targeted = $Rows.Count; Succeeded = 0; Failed = 0
        PendingApproval = 0; Skipped = 0; NotFound = 0; Unprocessed = 0; Affected = 0
        CountsComplete = $true
    }
    foreach ($row in $Rows) {
        $statuses = @(
            foreach ($property in $StatusProperties) {
                if ($row.PSObject.Properties[$property] -and $row.$property) { [string]$row.$property }
            }
        )
        $primaryStatus = if ($statuses.Count) { $statuses[0] } else { '' }
        if (@($statuses | Where-Object { $_ -in @('Failed','Error','Lookup failed','DirectoryDeviceNotFound') }).Count) { $summary.Failed++ }
        elseif ($statuses -contains 'PendingApproval') { $summary.PendingApproval++ }
        elseif ($primaryStatus -in @('NotFound','NoEligibleDevice','Unresolved')) { $summary.NotFound++ }
        elseif ($primaryStatus -in @('WhatIf','Declined','Skipped')) { $summary.Skipped++ }
        elseif ($primaryStatus -eq 'NotProcessed') { $summary.Unprocessed++ }
        elseif ($ReadOnly -or $primaryStatus -in @('Created','Deleted','Added','Removed','AlreadyMember','AlreadyAssigned','Read','NoPrimaryUser','ChangeRequested','RemovalRequested','Requested','Reported')) { $summary.Succeeded++ }
        else { $summary.Unprocessed++; $summary.CountsComplete = $false }
        if (@($statuses | Where-Object { $_ -in @('Created','Deleted','Added','Removed','ChangeRequested','RemovalRequested','Requested') }).Count) { $summary.Affected++ }
    }
    [pscustomobject]$summary
}

function Format-EndpointOutcomeSummary {
    param([Parameter(Mandatory)][object]$Summary)
    $text = "$($Summary.Entity) targeted: $($Summary.Targeted) | Succeeded: $($Summary.Succeeded) | Failed: $($Summary.Failed) | Pending approval: $($Summary.PendingApproval) | Skipped/preview: $($Summary.Skipped) | Not found: $($Summary.NotFound) | Not processed/unknown: $($Summary.Unprocessed) | Affected/requested: $($Summary.Affected)"
    if (-not $Summary.CountsComplete) { $text += ' | Incomplete counts; review output.' }
    $text
}
