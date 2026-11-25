$desktop = Split-Path $PSScriptRoot -Parent
$cloudFixture = Join-Path $PSScriptRoot 'Fixtures\CloudUpdateFixture.ps1'
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force

Describe 'Offline Microsoft 365 Apps Cloud Update reporting' {
    It 'binds Office inputs independently of Graph with a report folder outside the repository' {
        $workflow = Get-EndpointCatalog | Where-Object Id -eq 'm365-cloud-update'
        $workflow.Kind | Should Be 'Office'
        ($workflow.Fields | Where-Object Name -eq ExportFolder).Default | Should Be (Join-Path $env:TEMP 'endpoint-toolbox')
        $arguments = Get-EndpointArguments $workflow @{TenantId='organizations';PageSize='200';ExportFolder=$env:TEMP;NoExport=$true}
        $arguments.NoExport | Should Be $true
        $arguments.PageSize | Should Be 200
        foreach ($value in @('0','201','invalid')) {
            $rejected = $false
            try { $null = Get-EndpointArguments $workflow @{PageSize=$value} } catch { $rejected=$true }
            $rejected | Should Be $true
        }
        . (Join-Path $desktop 'GraphSession.ps1')
        $policy = Get-EndpointGraphPolicy 'm365-cloud-update' @{IncludeWaveGroups=$true}
        ($policy.Scopes -contains 'Group.Read.All') | Should Be $true
        ($policy.Scopes -contains 'Device.Read.All') | Should Be $true
        $arguments = Get-EndpointArguments $workflow @{IncludeWaveGroups=$true}
        $arguments.IncludeWaveGroups | Should Be $true
        (Get-EndpointArguments $workflow @{IncludeWaveGroups=$false}).ContainsKey('IncludeWaveGroups') | Should Be $false
        $rejected = $false
        try { $null = Get-EndpointGraphPolicy 'm365-cloud-update' } catch { $rejected=$true }
        $rejected | Should Be $true
    }
    It 'uses explicitly supplied exact group names for standalone reporting' {
        $names = @('Fixture.Custom.CloudPC', 'Fixture.Custom.Pilot')
        $run = & $cloudFixture -Capture -NoExport -IncludeWaveGroups -WaveGroupNames $names -Scenario MultipleGroups
        $run.Error | Should BeNullOrEmpty
        ($run.GroupNames -join '|') | Should Be ($names -join '|')
        @($run.GraphCalls | Where-Object { $_ -like '*Fixture.Custom*' }).Count | Should Be 2
        @($run.GraphCalls | Where-Object { $_ -match 'displayName%20eq' }).Count | Should Be 2
    }
    It 'rejects missing group names before sign-in or service calls when membership is enabled' {
        $run = & $cloudFixture -Capture -Direct -NoExport -IncludeWaveGroups -WaveGroupNames @()
        $run.Error.Exception.Message | Should Match 'requires one or more exact Entra group display names'
        $run.Calls.Count | Should Be 0
        $run.GraphCalls.Count | Should Be 0
    }
    It 'passes saved desktop groups to the offline report and leaves the basic report independent' {
        $root = Join-Path $env:TEMP "EndpointToolbox-cloud-settings-$([guid]::NewGuid())"
        $path = Join-Path $root 'settings.json'
        try {
            $arguments = & (Get-Module EndpointToolboxUI) {
                param($path)
                $null = @(Save-EndpointCloudUpdateGroups $path "Fixture.Group.One`r`nFixture.Group.Two")
                $arguments = @{ IncludeWaveGroups=$true }
                Set-EndpointCloudUpdateGroupsArgument $arguments $path
                $arguments
            } $path
            $run = & $cloudFixture -Capture -NoExport @arguments
            $run.Error | Should BeNullOrEmpty
            ($run.GroupNames -join '|') | Should Be 'Fixture.Group.One|Fixture.Group.Two'
            $rows = @($run.Events | Where-Object Type -eq Rows)[0].Data
            $rows[0].Group | Should Be 'Fixture.Group.One'
            $rows[1].Group | Should Be 'Fixture.Group.Two'
            $run.GraphCalls.Count | Should BeGreaterThan 0
        }
        finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
    It 'exports three reports and displays the portal device schema first with accurate rollout statistics' {
        $root = Join-Path $env:TEMP "EndpointToolbox-cloud-$([guid]::NewGuid())"
        try {
            $run = & $cloudFixture -Capture -OutputRoot $root
            $run.Error | Should BeNullOrEmpty
            $artifacts = @($run.Events | Where-Object Type -eq Artifact)
            $artifacts.Count | Should Be 3
            $reports = @($run.Events | Where-Object Type -eq Rows)
            $reports[0].Name | Should Be 'Cloud Update devices'
            $reports[0].Data.Count | Should Be 3
            $portal = @($artifacts | Where-Object Name -like '*-Devices-*')[0].Data
            $csv = @(Import-Csv -LiteralPath $portal)
            ($csv[0].PSObject.Properties.Name -join ',') | Should Be ($reports[0].Data[0].PSObject.Properties.Name -join ',')
            $csv[2].ErrorCode | Should Be '50006'
            $reports.Count | Should Be 4
            $summary = @($run.Events | Where-Object Type -eq OperationSummary)[0].Data
            $summary.Succeeded | Should Be 3
            $summary.Failed | Should Be 0
            $summary.CountsComplete | Should Be $true
            ($summary.PSObject.Properties.Name -contains 'ReportSummary') | Should Be $false
            $release = @($reports | Where-Object Name -eq Release)[0].Data[0]
            $release.ReleaseVersion | Should Be '2601'
            $rollout = @($reports | Where-Object Name -eq 'Rollout summary')[0].Data
            ($rollout | Where-Object Status -eq Completed).Devices | Should Be 1
            ($rollout | Where-Object Status -eq Failed).Devices | Should Be 1
            @($run.Calls | Where-Object { $_ -like '*DevicesWithCloudManagementInfo*' }).Count | Should Be 2
        }
        finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
    It 'uses TEMP even when an adapter caller omits ExportFolder' {
        $run = & $cloudFixture -Capture
        $artifacts = @($run.Events | Where-Object Type -eq Artifact)
        try {
            $run.Error | Should BeNullOrEmpty
            $artifacts.Count | Should Be 3
            foreach ($artifact in $artifacts) { (Split-Path $artifact.Data -Parent) | Should Be ([IO.Path]::TrimEndingDirectorySeparator($env:TEMP)) }
        }
        finally { foreach ($artifact in $artifacts) { Remove-Item -LiteralPath $artifact.Data -Force } }
    }
    It 'keeps device rows and statistics with NoExport and preserves the standalone result contract' {
        $run = & $cloudFixture -Capture -NoExport
        $direct = & $cloudFixture -Capture -Direct -NoExport
        $run.Error | Should BeNullOrEmpty
        $direct.Error | Should BeNullOrEmpty
        @($run.Events | Where-Object Type -eq Artifact).Count | Should Be 0
        @($run.Events | Where-Object Type -eq Rows)[0].Data.Count | Should Be 3
        $chart = ($run.Events | Where-Object Type -eq ReportVisual).Data[0]
        $chart.Total | Should Be 3
        ($chart.Bars | Where-Object Label -eq 'In progress').Count | Should Be 1
        $result = @($direct.Output | Where-Object { $_.PSObject.Properties['RawDevices'] })[0]
        ($result.PSObject.Properties.Name -join ',') | Should Be 'Release,Summary,WaveSummary,Devices,RawDevices,ExportedFiles'
        $result.Devices.Count | Should Be 3
        @($result.ExportedFiles).Count | Should Be 0
        $run.GraphCalls.Count | Should Be 0
        $direct.GraphCalls.Count | Should Be 0
        ($result.Devices[0].PSObject.Properties.Name -contains 'Group') | Should Be $false
    }
    It 'reports an empty inventory without inventing failed updates or dividing by zero' {
        $run = & $cloudFixture -Capture -NoExport -Scenario Empty
        $run.Error | Should BeNullOrEmpty
        $summary = @($run.Events | Where-Object Type -eq OperationSummary)[0].Data
        $summary.Targeted | Should Be 0
        $summary.CountsComplete | Should Be $true
        $rollout = @($run.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Rollout summary' })[0].Data
        ($rollout | Where-Object Status -eq Completed).Devices | Should Be 0
        @($run.Events | Where-Object Type -eq Rows)[0].Name | Should Be 'Cloud Update devices'
        @($run.Events | Where-Object Type -eq Rows)[0].Data.Count | Should Be 0
    }
    It 'blocks missing MSAL without installation and surfaces cancelled sign-in, API and paging failures' {
        foreach ($scenario in @('MissingModule','AuthCancelled','ApiFailure','PagingFailure')) {
            $run = & $cloudFixture -Capture -NoExport -Scenario $scenario
            [bool]$run.Error | Should Be $true
            @($run.Events | Where-Object Type -eq Artifact).Count | Should Be 0
            @($run.Events | Where-Object Type -eq OperationSummary).Count | Should Be 0
            @($run.Events | Where-Object Type -eq ReportVisual).Count | Should Be 0
            if ($scenario -eq 'MissingModule') {
                $run.Error.Exception.Message | Should Match 'Install-Module MSAL.PS -Scope CurrentUser'
                $run.Calls.Count | Should Be 0
            }
        }
    }
    It 'retains a completed CSV and marks counts incomplete when a later export fails' {
        $root = Join-Path $env:TEMP "EndpointToolbox-cloud-$([guid]::NewGuid())"
        try {
            $run = & $cloudFixture -Capture -OutputRoot $root -Scenario ExportFailure
            $run.Error.Exception.Message | Should Match 'Synthetic inventory export failure'
            @($run.Events | Where-Object Type -eq Artifact).Count | Should Be 1
            @($run.Events | Where-Object Type -eq Rows)[0].Data.Count | Should Be 3
            @($run.Events | Where-Object Type -eq OperationSummary)[0].Data.CountsComplete | Should Be $false
        }
        finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
    It 'weights the rollout chart by device counts and retains unfamiliar statuses' {
        . (Join-Path (Split-Path $PSScriptRoot -Parent) 'ReportVisuals.ps1')
        $chart = Get-EndpointInventoryCharts 'm365-cloud-update' @(
            [pscustomobject]@{ Status='Completed'; Devices=700 }
            [pscustomobject]@{ Status='InProgress'; Devices=20 }
            [pscustomobject]@{ Status='NewServiceStatus'; Devices=3 }
        )
        $chart.Total | Should Be 723
        ($chart.Bars | Where-Object Label -eq 'Completed').Count | Should Be 700
        ($chart.Bars | Where-Object Label -eq 'Other or unknown').Count | Should Be 3
    }
    It 'adds only the reviewed rollout memberships to the device grid and CSV with semicolon-separated matches' {
        $root = Join-Path $env:TEMP "EndpointToolbox-cloud-groups-$([guid]::NewGuid())"
        try {
            $run = & $cloudFixture -Capture -OutputRoot $root -IncludeWaveGroups -Scenario MultipleGroups
            $run.Error | Should BeNullOrEmpty
            $rows = @($run.Events | Where-Object Type -eq Rows)[0].Data
            $rows[0].Group | Should Be "$($run.GroupNames[0]); $($run.GroupNames[4])"
            $rows[1].Group | Should Be $run.GroupNames[1]
            $rows[2].Group | Should Be 'No configured wave group'
            ($rows.Wave -join ',') | Should Be '1,2,3'
            @($run.GraphCalls | Where-Object { $_ -like '*fixture-members-next' }).Count | Should Be 1
            @($run.GraphCalls | Where-Object { $_ -like '*fixture-devices-next' }).Count | Should Be 1
            @($run.GraphCalls | Where-Object { $_ -like '*/memberOf*' -or $_ -like '*/transitiveMemberOf*' }).Count | Should Be 0
            $portal = @($run.Events | Where-Object { $_.Type -eq 'Artifact' -and $_.Name -like '*-Devices-*' })[0].Data
            @(Import-Csv -LiteralPath $portal)[0].Group | Should Be $rows[0].Group
            $raw = @($run.Events | Where-Object { $_.Type -eq 'Artifact' -and $_.Name -like '*-FullInventory-*' })[0].Data
            (@(Import-Csv -LiteralPath $raw)[0].PSObject.Properties.Name -contains 'Group') | Should Be $false
            $summary = @($run.Events | Where-Object Type -eq OperationSummary)[0].Data
            $summary.CountsComplete | Should Be $true
        }
        finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
    It 'marks missing and ambiguous computer names Unknown instead of attributing them to a group or the remaining wave' {
        foreach ($scenario in @('DuplicateEntraName','DuplicateOfficeName','MissingEntraDevice')) {
            $run = & $cloudFixture -Capture -NoExport -IncludeWaveGroups -Scenario $scenario 3>$null
            $run.Error | Should BeNullOrEmpty
            $rows = @($run.Events | Where-Object Type -eq Rows)[0].Data
            $unknownIndex = if ($scenario -eq 'MissingEntraDevice') { 2 } else { 0 }
            $rows[$unknownIndex].Group | Should Match '^Unknown'
            $run.Warnings.Count | Should BeGreaterThan 0
            @($run.Events | Where-Object Type -eq OperationSummary)[0].Data.CountsComplete | Should Be $false
        }
    }
    It 'exports every Office report with verified memberships and Unknown unmatched devices when a configured group is missing or ambiguous' {
        foreach ($scenario in @('GraphMissingGroup','GraphDuplicateGroup')) {
            $root = Join-Path $env:TEMP "EndpointToolbox-cloud-partial-$([guid]::NewGuid())"
            try {
                $run = & $cloudFixture -Capture -OutputRoot $root -IncludeWaveGroups -Scenario $scenario 3>$null
                $run.Error | Should BeNullOrEmpty
                $run.GroupNames.Count | Should Be 7
                ($run.Warnings -join "`n") | Should Match 'Continuing with the other configured groups and CSV export'
                ($run.Warnings -join "`n") | Should Match ([regex]::Escape($run.GroupNames[2]))
                $rows = @($run.Events | Where-Object Type -eq Rows)[0].Data
                $rows[0].Group | Should Be $run.GroupNames[0]
                $rows[1].Group | Should Be $run.GroupNames[1]
                $rows[2].Group | Should Be 'Unknown (group lookup incomplete)'
                @($rows | Where-Object Group -eq 'No configured wave group').Count | Should Be 0
                $artifacts = @($run.Events | Where-Object Type -eq Artifact)
                $artifacts.Count | Should Be 3
                foreach ($artifact in $artifacts) { @(Import-Csv -LiteralPath $artifact.Data).Count | Should Be 3 }
                $portal = @($artifacts | Where-Object Name -like '*-Devices-*')[0].Data
                (@(Import-Csv -LiteralPath $portal).Group -join '|') | Should Be ($rows.Group -join '|')
                $summary = @($run.Events | Where-Object Type -eq OperationSummary)[0].Data
                $summary.CountsComplete | Should Be $false
                $summary.Succeeded | Should Be 3
            }
            finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
        }
    }
    It 'keeps correlation incomplete when all devices have known memberships or every reviewed group is missing' {
        foreach ($scenario in @('GraphMissingGroupAllMatched','GraphAllGroupsMissing')) {
            $run = & $cloudFixture -Capture -NoExport -IncludeWaveGroups -Scenario $scenario 3>$null
            $run.Error | Should BeNullOrEmpty
            $rows = @($run.Events | Where-Object Type -eq Rows)[0].Data
            @($rows | Where-Object Group -eq 'No configured wave group').Count | Should Be 0
            $summary = @($run.Events | Where-Object Type -eq OperationSummary)[0].Data
            $summary.CountsComplete | Should Be $false
            if ($scenario -eq 'GraphMissingGroupAllMatched') {
                @($rows | Where-Object Group -like 'Unknown*').Count | Should Be 0
            }
            else {
                @($rows | Where-Object Group -eq 'Unknown (group lookup incomplete)').Count | Should Be 3
                @($run.Warnings | Where-Object { [string]$_ -like 'Expected exactly one Entra rollout group*' }).Count | Should Be 7
            }
            @($run.Events | Where-Object Type -eq Artifact).Count | Should Be 0
        }
    }
    It 'preserves base device rows as incomplete when Graph identity, membership or pagination cannot be verified' {
        $failures = [ordered]@{
            GraphDisconnected='existing delegated Global Graph connection'
            GraphDifferentTenant='same tenant'
            GraphFailure='Synthetic rollout membership lookup failure'
            GraphMalformedPage='invalid collection'
            GraphForeignPage='Unexpected Graph pagination address'
            GraphRepeatedPage='repeated a page'
            GraphMissingMemberId='valid object ID'
        }
        foreach ($scenario in $failures.Keys) {
            $run = & $cloudFixture -Capture -NoExport -IncludeWaveGroups -Scenario $scenario
            [bool]$run.Error | Should Be $true
            $run.Error.Exception.Message | Should Match $failures[$scenario]
            $rows = @($run.Events | Where-Object Type -eq Rows)[0].Data
            $rows.Count | Should Be 3
            foreach ($row in $rows) { $row.Group | Should Be 'Unknown (group lookup incomplete)' }
            @($run.Events | Where-Object Type -eq OperationSummary)[0].Data.CountsComplete | Should Be $false
            @($run.Events | Where-Object Type -eq Artifact).Count | Should Be 0
        }
    }
    It 'prepares portal rows in the hosting worker without treating Office update failures as report failures' {
        if (-not ('EndpointToolbox.DesktopEngine' -as [type])) { Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs') }
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.Host.PrepareReportTables = $true
            $engine.RunFile($cloudFixture, @{NoExport=$true;IncludeWaveGroups=$true}, $true)
            $events = [Collections.Generic.List[object]]::new()
            $deadline = [datetime]::UtcNow.AddSeconds(15)
            do {
                $null = $engine.Poll()
                $event = $null
                while ($engine.Host.Events.TryDequeue([ref]$event)) { $events.Add($event) }
                if ([datetime]::UtcNow -gt $deadline) { $engine.Cancel(); throw 'Offline Cloud Update fixture timed out.' }
                Start-Sleep -Milliseconds 10
            } while ($engine.Busy -or -not $engine.Host.Events.IsEmpty)
            @($events | Where-Object Kind -eq Error).Count | Should Be 0
            $rows = @($events | Where-Object Kind -eq Rows)[0].Data
            $rows.Table.Rows.Count | Should Be 3
            $rows.Table.Rows[2].ErrorCode | Should Be '50006'
            $rows.Table.Rows[0].Group | Should Not BeNullOrEmpty
            @($events | Where-Object Kind -eq OperationSummary)[0].Data.Failed | Should Be 0
        }
        finally { $engine.Dispose() }
    }
}
