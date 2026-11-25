$desktop = Split-Path $PSScriptRoot -Parent
. (Join-Path $desktop 'ReportVisuals.ps1')

Describe 'Selected chart calculations' {
    It 'counts UTC sign-in days and keeps missing values and incomplete pages explicit' {
        $rows = @(
            [pscustomobject]@{CreatedDateTimeUtc='2026-01-02T00:30:00+02:00';Outcome='Success';Application='App';ClientApp='Browser'}
            [pscustomobject]@{CreatedDateTimeUtc='2026-01-02T12:00:00Z';Outcome='Failure';ErrorCode=50126;Application='App';ClientApp=''}
            [pscustomobject]@{CreatedDateTimeUtc='invalid';Outcome='Unknown';Application='';ClientApp='Browser'}
        )
        $charts = @(Get-EndpointSignInCharts $rows 7 $true 100 $false)
        $charts.Count | Should Be 6
        $charts[0].Bars[0].Label | Should Be '2026-01-01'
        $charts[0].Bars[0].Count | Should Be 1
        $charts[1].Bars[1].Count | Should Be 1
        $charts[0].Basis | Should Match '1 event\(s\) have an invalid'
        $charts[0].Basis | Should Match 'Incomplete'
        ($charts[3].Bars | Where-Object Label -eq '50126').Count | Should Be 1
        ($charts[4].Bars | Where-Object Label -eq 'Not reported').Count | Should Be 1
        $filtered = @(Get-EndpointSignInCharts @($rows[1]) 7 $false 100 $true)
        $filtered[0].Basis | Should Match 'Failures-only excludes successful and unclassifiable'
    }

    It 'separates mobile platforms and missing versions' {
        $rows = @(
            [pscustomobject]@{OperatingSystem='iOS';OSVersion='17'}
            [pscustomobject]@{OperatingSystem='Android';OSVersion='17'}
            [pscustomobject]@{OperatingSystem='';OSVersion=''}
        )
        $chart = Get-EndpointMobileVersionChart $rows
        $chart.Total | Should Be 3
        ($chart.Bars | Where-Object Label -eq 'iOS | 17').Count | Should Be 1
        ($chart.Bars | Where-Object Label -eq 'Android | 17').Count | Should Be 1
        ($chart.Bars | Where-Object Label -eq 'Platform not reported | Version not reported').Count | Should Be 1
    }

    It 'uses all failure entries for cumulative contributions even beyond the displayed eight' {
        $rows = @(1..10 | ForEach-Object { [pscustomobject]@{ErrorCode="code$_"} })
        $chart = @(Get-EndpointFailureTriageCharts $rows 'Failure triage')[0]
        $chart.Total | Should Be 10
        $chart.Bars.Count | Should Be 8
        $chart.Bars[7].Cumulative | Should Be 0.8
        $chart.Bars[0].Dataset | Should Be 'Failure triage'
    }

    It 'samples metric values without treating missing values as zero' {
        $rows = @(1..100 | ForEach-Object { [pscustomobject]@{
            SignInDateTime=([datetime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime().AddHours($_).ToString('o')); RoundTripTimeInMsP50=$_; AvailableBandwidthInMbpsP50=$null
            RemoteSignInTimeInSec=-1; UsageInHour=0
        } })
        $charts = @(Get-EndpointCloudPcHistoryCharts $rows 'Fixture')
        $charts[0].Total | Should Be 100
        $charts[0].Bars.Count | Should Be 40
        $charts[0].Bars[39].Value | Should Be 100
        $charts[1].Total | Should Be 0
        $charts[1].Basis | Should Match '100 row\(s\) lack'
        $charts[2].Total | Should Be 0
        $charts[3].Total | Should Be 100
    }
}

Describe 'Cloud PC history worker' {
    It 'pages the selected device and publishes rows and metrics without requesting consent' {
        & {
            param($desktop)
            $global:chartFixtureCalls = [Collections.Generic.List[object]]::new()
            $global:chartFixtureEvents = [Collections.Generic.List[object]]::new()
            function Connect-MgGraph { throw 'Unexpected authentication.' }
            function Invoke-MgGraphRequest {
                param($Method,$Uri,$Body,$ContentType,$OutputType)
                $request = $Body | ConvertFrom-Json
                $global:chartFixtureCalls.Add([pscustomobject]@{Method=$Method;Uri=$Uri;Request=$request;OutputType=$OutputType})
                $schema = @('SignInDateTime','SignOutDateTime','UsageInHour','RoundTripTimeInMsP50','AvailableBandwidthInMbpsP50','RemoteSignInTimeInSec' | ForEach-Object { @{Column=$_} })
                $values = if ($request.skip -eq 0) { @('2026-01-01T00:00:00Z','2026-01-01T01:00:00Z',1,20,3,5) }
                    else { @('2026-01-02T00:00:00Z','2026-01-02T01:00:00Z',2,30,$null,7) }
                $bodyJson = @{TotalRowCount=2;Schema=$schema;Values=,@($values)} | ConvertTo-Json -Depth 8 -Compress
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
                $response.Content = [Net.Http.StringContent]::new($bodyJson)
                return $response
            }

            $sink = { param($event) $global:chartFixtureEvents.Add($event) }
            try {
                & (Join-Path $desktop 'Get-CloudPcConnectionHistory.ps1') -CloudPcId '00000000-0000-0000-0000-000000000001' -CloudPcName 'Fixture' -UiEventSink $sink
                $global:chartFixtureCalls.Count | Should Be 2
                $global:chartFixtureCalls[0].Method | Should Be 'POST'
                $global:chartFixtureCalls[0].Request.filter | Should Match 'CloudPcId eq'
                $global:chartFixtureCalls[1].Request.skip | Should Be 1
                @($global:chartFixtureEvents | Where-Object Type -eq 'Rows')[0].Data.Count | Should Be 2
                @($global:chartFixtureEvents | Where-Object Type -eq 'ReportVisual')[0].Data.Count | Should Be 4
            }
            finally { Remove-Variable chartFixtureCalls,chartFixtureEvents -Scope Global -ErrorAction Ignore }
        } $desktop
    }

    It 'distinguishes no data from invalid responses, denied access and cancellation' {
        & {
            param($desktop)
            $global:historyMode = 'Empty'
            $global:historyEvents = [Collections.Generic.List[object]]::new()
            $global:historyCalls = 0
            function Invoke-MgGraphRequest {
                param($Method,$Uri,$Body,$ContentType,$OutputType)
                $global:historyCalls++
                if ($global:historyMode -eq 'Denied') { throw 'Synthetic authorization denied.' }
                $columns = @('SignInDateTime','SignOutDateTime','UsageInHour','RoundTripTimeInMsP50','AvailableBandwidthInMbpsP50','RemoteSignInTimeInSec')
                $schema = @($columns | ForEach-Object { @{Column=$_} })
                $bodyJson = if ($global:historyMode -eq 'Malformed') { '{"TotalRowCount":1,"Schema":[],"Values":[]}' }
                    else { @{TotalRowCount=0;Schema=$schema;Values=@()} | ConvertTo-Json -Depth 6 -Compress }
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
                $response.Content = [Net.Http.StringContent]::new($bodyJson)
                return $response
            }
            $sink = { param($event) $global:historyEvents.Add($event) }
            $arguments = @{CloudPcId='00000000-0000-0000-0000-000000000001';CloudPcName='Fixture';UiEventSink=$sink}
            try {
                & (Join-Path $desktop 'Get-CloudPcConnectionHistory.ps1') @arguments
                @($global:historyEvents | Where-Object Type -eq 'Rows')[0].Data.Count | Should Be 0
                @($global:historyEvents | Where-Object Type -eq 'ReportVisual')[0].Data[0].Total | Should Be 0
                foreach ($mode in @('Malformed','Denied')) {
                    $global:historyMode = $mode; $global:historyEvents.Clear()
                    $message = ''
                    try { & (Join-Path $desktop 'Get-CloudPcConnectionHistory.ps1') @arguments } catch { $message = $_.Exception.Message }
                    ($message.Length -gt 0) | Should Be $true
                    $global:historyEvents.Count | Should Be 0
                }
                $global:historyMode = 'Empty'; $global:historyEvents.Clear(); $before = $global:historyCalls
                $cancelled = $false
                try { & (Join-Path $desktop 'Get-CloudPcConnectionHistory.ps1') @arguments -CancellationCheck ([Func[bool]]{ $true }) }
                catch { $cancelled = $true }
                $cancelled | Should Be $true
                $global:historyCalls | Should Be $before
                $global:historyEvents.Count | Should Be 0
            }
            finally { Remove-Variable historyMode,historyEvents,historyCalls -Scope Global -ErrorAction Ignore }
        } $desktop
    }
}

Describe 'Selected chart native UI' {
    It 'renders metric values and enables a selected Cloud PC at both window sizes' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\ChartEnhancementFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native chart fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native chart metrics and selected Cloud PC action passed'
    }
}
