[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$CloudPcId,
    [Parameter(Mandatory)][string]$CloudPcName,
    [Func[bool]]$CancellationCheck,
    [scriptblock]$UiEventSink
)

. (Join-Path $PSScriptRoot 'ReportVisuals.ps1')
if ($CloudPcId -eq [guid]::Empty) { throw 'Select a Cloud PC with a valid Cloud PC ID.' }
$end = [datetime]::UtcNow
$start = $end.AddDays(-7)
$format = "yyyy-MM-ddTHH:mm:ss.fffZ"
$filter = "CloudPcId eq '$CloudPcId' and SignInDateTime ge datetime'$($start.ToString($format))' and SignInDateTime le datetime'$($end.ToString($format))'"
$columns = @('SignInDateTime','SignOutDateTime','UsageInHour','RoundTripTimeInMsP50','AvailableBandwidthInMbpsP50','RemoteSignInTimeInSec')
$rows = [Collections.Generic.List[object]]::new()
$skip = 0
$top = 200
$total = $null
do {
    if ($CancellationCheck -and $CancellationCheck.Invoke()) { throw 'Cloud PC history was cancelled.' }
    $body = @{ filter=$filter; select=$columns; orderBy=@('SignInDateTime asc'); skip=$skip; top=$top } | ConvertTo-Json -Depth 4 -Compress
    $response = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/reports/getRemoteConnectionHistoricalReports' -Body $body -ContentType 'application/json' -OutputType HttpResponseMessage -ErrorAction Stop
    if ($response -isnot [Net.Http.HttpResponseMessage]) { throw 'Graph returned an invalid Cloud PC history response.' }
    try {
        if (-not $response.IsSuccessStatusCode) { throw "Cloud PC history request failed with HTTP $([int]$response.StatusCode)." }
        $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $page = ConvertFrom-Json -InputObject $json -AsHashtable -ErrorAction Stop
    }
    finally { $response.Dispose() }
    $pageTotal = 0
    if ($page -isnot [Collections.IDictionary] -or -not [int]::TryParse([string]$page['TotalRowCount'], [ref]$pageTotal) -or
        $pageTotal -lt 0 -or $pageTotal -gt 10000 -or $page['Schema'] -isnot [array] -or $page['Values'] -isnot [array]) {
        throw 'Graph returned an invalid or oversized Cloud PC history report.'
    }
    if ($null -ne $total -and $pageTotal -ne $total) { throw 'The Cloud PC history report changed during paging; retry the request.' }
    $total = $pageTotal
    $indexes = @{}
    for ($i = 0; $i -lt $page['Schema'].Count; $i++) {
        $name = [string]$page['Schema'][$i]['Column']
        if (-not $name -or $indexes.ContainsKey($name)) { throw 'Graph returned an invalid Cloud PC history schema.' }
        $indexes[$name] = $i
    }
    foreach ($column in $columns) {
        if (-not $indexes.ContainsKey($column)) { throw "Graph omitted Cloud PC history column '$column'." }
    }
    foreach ($values in $page['Values']) {
        if ($values -isnot [array] -or $values.Count -ne $page['Schema'].Count) { throw 'Graph returned an invalid Cloud PC history row.' }
        $item = [ordered]@{}
        foreach ($column in $columns) { $item[$column] = $values[$indexes[$column]] }
        $rows.Add([pscustomobject]$item)
    }
    $count = $page['Values'].Count
    $skip += $count
    if ($skip -gt $total -or ($skip -lt $total -and $count -eq 0)) { throw 'Graph returned incomplete Cloud PC history paging.' }
} while ($skip -lt $total)

if ($CancellationCheck -and $CancellationCheck.Invoke()) { throw 'Cloud PC history was cancelled.' }
$basis = "Cloud PC: $CloudPcName. Requested $($start.ToString('u')) through $($end.ToString('u')). Graph beta; values are service-reported aggregates, subject to availability and retention."
$charts = @(Get-EndpointCloudPcHistoryCharts $rows.ToArray() $basis)
if ($UiEventSink) {
    & $UiEventSink ([pscustomobject]@{ Type='Rows'; Name='Cloud PC connection history'; Data=$rows.ToArray() }) | Out-Null
    & $UiEventSink ([pscustomobject]@{ Type='ReportVisual'; Name='Cloud PC connection history'; Data=$charts }) | Out-Null
}
Write-Host "Cloud PC connection history: $total row(s) returned. $basis"
