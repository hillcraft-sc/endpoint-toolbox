<#
.SYNOPSIS
    Reports interactive and non-interactive Entra user sign-ins.
.DESCRIPTION
    Resolves one user by exact UPN or primary email, then reads sign-ins within a
    rolling UTC window. Paged events retrieves one API page; Detailed events reads
    every page. Results are limited by retention and access. Read-only.
.PARAMETER UserIdentity
    Exact UPN or primary email address. Ambiguous matches are rejected.
.PARAMETER LookbackDays
    Rolling lookback from 1 to 30 days. Defaults to 30.
.PARAMETER FailuresOnly
    Show only records with a valid nonzero error code. Unclassifiable records are
    excluded with a warning. Filtering is local and does not skip API pages.
.PARAMETER ReportMode
    Detailed events (CLI default) retrieves everything. Paged events retrieves
    one page of up to 100 events; the app provides Load more and Retrieve all.
.PARAMETER Continuation
    In-memory continuation from a prior page. Must match the tenant and inputs.
.EXAMPLE
    .\Get-EntraUserSignInHistory.ps1 -UserIdentity 'user@example.invalid' -LookbackDays 1
.NOTES
    Requires existing delegated Global Microsoft Graph access with AuditLog.Read.All
    and User.Read.All, an authorized Entra role, and appropriate licensing.
    Uses Graph beta for both user event types. Beta APIs can change and are not
    supported by Microsoft for production applications. No automatic CSV export.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$UserIdentity,
    [ValidateRange(1, 30)][int]$LookbackDays = 30,
    [switch]$FailuresOnly,
    [ValidateSet('Detailed events', 'Paged events')][string]$ReportMode = 'Detailed events',
    [hashtable]$Continuation
)

$UserIdentity = $UserIdentity.Trim()
if (-not $UserIdentity) { throw 'Enter an exact user principal name or primary email address.' }
$context = Get-MgContext -ErrorAction Stop
if (-not $context -or $context.AuthType -ne 'Delegated' -or $context.Environment -ne 'Global') {
    throw 'Connect to Global Microsoft Graph with a delegated work or school account before running this report.'
}

function Get-SignInHistoryCollection {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Stage,
        [hashtable]$Headers = @{},
        [hashtable]$State = @{ NextLink=''; Seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) },
        [switch]$OnePage
    )
    $initial = [uri]$Uri
    $pageNumber = 0
    $total = 0
    while ($Uri) {
        $address = [uri]$Uri
        if (-not $address.IsAbsoluteUri -or $address.Scheme -ne 'https' -or
            $address.Authority -ne 'graph.microsoft.com' -or $address.UserInfo -or $address.Fragment -or
            $address.AbsolutePath -cne $initial.AbsolutePath -or -not $State.Seen.Add($Uri)) {
            throw 'Graph returned an unexpected or repeated page. The sign-in report is incomplete.'
        }
        $pageNumber++
        $message = "Requesting $Stage page $pageNumber from Microsoft Graph ($total records received in this request)."
        Write-Progress -Activity 'User sign-in history' -Status $message
        Write-Host $message
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -Headers $Headers -OutputType Hashtable -ErrorAction Stop
        $timer.Stop()
        if ($page -isnot [System.Collections.IDictionary] -or -not $page.Contains('value') -or $page['value'] -isnot [array]) {
            throw 'Graph returned an invalid collection. The sign-in report is incomplete.'
        }
        $total += $page['value'].Count
        Write-Host ("Received {0} page {1}: {2} records in {3:N1} seconds; {4} records received in this request." -f $Stage, $pageNumber, $page['value'].Count, $timer.Elapsed.TotalSeconds, $total)
        $Uri = [string]$page['@odata.nextLink']
        if ($Uri) {
            $next = [uri]$Uri
            if (-not $next.IsAbsoluteUri -or $next.Scheme -ne 'https' -or
                $next.Authority -ne 'graph.microsoft.com' -or $next.UserInfo -or $next.Fragment -or
                $next.AbsolutePath -cne $initial.AbsolutePath -or $State.Seen.Contains($Uri)) {
                throw 'Graph returned an unexpected or repeated page. The sign-in report is incomplete.'
            }
        }
        $State.NextLink = $Uri
        $page['value']
        if ($OnePage) { break }
    }
}

if ($Continuation) {
    if ($Continuation.TenantId -ne $context.TenantId -or $Continuation.Account -ne $context.Account -or
        $Continuation.UserIdentity -ne $UserIdentity -or $Continuation.LookbackDays -ne $LookbackDays -or
        $Continuation.FailuresOnly -ne [bool]$FailuresOnly -or -not $Continuation.NextLink -or
        $Continuation.Seen -isnot [Collections.Generic.HashSet[string]]) {
        throw 'The sign-in continuation no longer matches the account, tenant or report inputs. Run a new report.'
    }
    $uri = [string]$Continuation.NextLink
    if ([uri]::new($uri).AbsolutePath -cne '/beta/auditLogs/signIns') { throw 'Invalid sign-in continuation address.' }
    $signInPage = $Continuation.Clone()
    $signInPage.Seen = [Collections.Generic.HashSet[string]]::new($Continuation.Seen, [StringComparer]::Ordinal)
}
else {
    $literal = "'$($UserIdentity.Replace("'", "''"))'"
    $userFilter = "userPrincipalName eq $literal or mail eq $literal"
    $userUri = 'https://graph.microsoft.com/v1.0/users?$filter=' + [uri]::EscapeDataString($userFilter) + '&$select=id&$count=true'
    $users = @(Get-SignInHistoryCollection $userUri -Stage 'user lookup' -Headers @{ ConsistencyLevel = 'eventual' })
    if ($users.Count -ne 1) {
        throw "Expected one user matching the supplied UPN or primary email address; found $($users.Count). Check the identifier and tenant."
    }
    $userId = [guid]::Empty
    if (-not [guid]::TryParse([string]$users[0]['id'], [ref]$userId) -or $userId -eq [guid]::Empty) { throw 'Graph returned a user without a valid object ID.' }
    $end = [datetime]::UtcNow
    $start = $end.AddDays(-$LookbackDays)
    $filter = "createdDateTime ge $($start.ToString('yyyy-MM-ddTHH:mm:ssZ')) and createdDateTime le $($end.ToString('yyyy-MM-ddTHH:mm:ssZ')) and userId eq '$userId' and signInEventTypes/any(t: t eq 'interactiveUser' or t eq 'nonInteractiveUser')"
    $pageSize = if ($ReportMode -eq 'Paged events') { 100 } else { 1000 }
    $uri = 'https://graph.microsoft.com/beta/auditLogs/signIns?$filter=' + [uri]::EscapeDataString($filter) + "&`$top=$pageSize"
    $signInPage = @{
        TenantId=[string]$context.TenantId; Account=[string]$context.Account
        UserIdentity=$UserIdentity; LookbackDays=$LookbackDays; FailuresOnly=[bool]$FailuresOnly
        NextLink=''; Seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        Received=0
    }
}
$events = @(Get-SignInHistoryCollection $uri -Stage 'sign-in' -State $signInPage -OnePage:($ReportMode -eq 'Paged events'))
$signInPage.Received += $events.Count
Write-Progress -Activity 'User sign-in history' -Status "Preparing $($events.Count) sign-in records."
$processingTimer = [Diagnostics.Stopwatch]::StartNew()
$unknownCount = 0
$results = @(foreach ($event in $events) {
    if ($event -isnot [System.Collections.IDictionary]) { throw 'Graph returned an invalid sign-in record. The report is incomplete.' }
    $status = $event['status']
    $code = 0
    $knownCode = $status -is [System.Collections.IDictionary] -and $null -ne $status['errorCode'] -and
        [int]::TryParse([string]$status['errorCode'], [ref]$code)
    if (-not $knownCode) { $unknownCount++ }
    if ($FailuresOnly -and (-not $knownCode -or $code -eq 0)) { continue }
    $device = $event['deviceDetail']
    $location = $event['location']
    [pscustomobject]@{
        CreatedDateTimeUtc = if ($event['createdDateTime'] -is [datetime]) { $event['createdDateTime'].ToUniversalTime().ToString('o') } else { [string]$event['createdDateTime'] }
        UserPrincipalName = [string]$event['userPrincipalName']
        UserDisplayName = [string]$event['userDisplayName']
        SignInType = if ($event['isInteractive'] -eq $true) { 'Interactive' } elseif ($event['isInteractive'] -eq $false) { 'Non-interactive' } else { 'Unknown' }
        Outcome = if (-not $knownCode) { 'Unknown' } elseif ($code -eq 0) { 'Success' } else { 'Failure' }
        ErrorCode = if ($knownCode) { $code } else { $null }
        FailureReason = if ($status -is [System.Collections.IDictionary]) { [string]$status['failureReason'] } else { '' }
        AdditionalDetails = if ($status -is [System.Collections.IDictionary]) { [string]$status['additionalDetails'] } else { '' }
        Application = [string]$event['appDisplayName']
        Resource = [string]$event['resourceDisplayName']
        IpAddress = [string]$event['ipAddress']
        City = if ($location -is [System.Collections.IDictionary]) { [string]$location['city'] } else { '' }
        CountryOrRegion = if ($location -is [System.Collections.IDictionary]) { [string]$location['countryOrRegion'] } else { '' }
        DeviceName = if ($device -is [System.Collections.IDictionary]) { [string]$device['displayName'] } else { '' }
        OperatingSystem = if ($device -is [System.Collections.IDictionary]) { [string]$device['operatingSystem'] } else { '' }
        Browser = if ($device -is [System.Collections.IDictionary]) { [string]$device['browser'] } else { '' }
        ClientApp = [string]$event['clientAppUsed']
        ConditionalAccessStatus = [string]$event['conditionalAccessStatus']
        AuthenticationRequirement = [string]$event['authenticationRequirement']
        CorrelationId = [string]$event['correlationId']
        SignInId = [string]$event['id']
    }
})
$processingTimer.Stop()
Write-Host ("Prepared sign-in records in {0:N1} seconds." -f $processingTimer.Elapsed.TotalSeconds)
Write-Progress -Activity 'User sign-in history' -Completed
if ($unknownCount) {
    Write-Warning "$unknownCount sign-in record(s) had no valid error code and could not be classified.$(if ($FailuresOnly) { ' They are excluded from failures-only results.' })"
}
Write-Host "Received $($signInPage.Received) event(s) so far; showing $($results.Count) rows from this request. The rolling $LookbackDays-day window is subject to retention and permissions."
if ($signInPage.NextLink) { Write-Host 'Incomplete report: more pages are available. Load more or Retrieve all to continue.' }
$results
