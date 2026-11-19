# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Looks up Entra users by person name.
.DESCRIPTION
    Read-only. For each name ("First Last" or "Last, First"), finds users whose
    display name matches either form exactly, or whose given name and surname both
    match. When there is no exact match, users with the same surname and first
    initial are returned as possible matches (for example Mike / Michael) so the
    result can be reviewed. Each match is returned as a row; unmatched names are
    returned with status NotFound.
.PARAMETER Names
    One or more person names, for example 'Jane Doe' or 'Doe, Jane'.
.PARAMETER UserListPath
    Text file with one person name per line. Blank lines and lines starting with # are ignored.
.EXAMPLE
    .\Find-EntraUsersByName.ps1 -Names 'Jane Doe','Sam Smith' | Format-Table Input,Status,DisplayName,UserPrincipalName
.EXAMPLE
    .\Find-EntraUsersByName.ps1 -UserListPath .\names.txt | Export-Csv .\user-lookup.csv -NoTypeInformation
.NOTES
    Requires Microsoft.Graph.Authentication and existing User.Read.All consent.
    Reuses the current Graph connection or signs in to the configured tenant.
    Name matching is case-insensitive. Possible matches are suggestions, not confirmed identities.
#>
[CmdletBinding(DefaultParameterSetName = 'ByNames')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByNames')]
    [string[]]$Names,

    [Parameter(Mandatory, ParameterSetName = 'ByFile')]
    [string]$UserListPath
)

if ($PSCmdlet.ParameterSetName -eq 'ByFile') {
    if (-not (Test-Path -LiteralPath $UserListPath -PathType Leaf)) { throw "Input file not found: $UserListPath" }
    $rawNames = Get-Content -LiteralPath $UserListPath -ErrorAction Stop
}
else { $rawNames = $Names }
$inputNames = @($rawNames | ForEach-Object { ([string]$_).Trim() -replace '\s+', ' ' } |
    Where-Object { $_ -and -not $_.StartsWith('#') } | Sort-Object -Unique)
if (-not $inputNames.Count) { throw 'Supply at least one person name.' }

if (-not (Get-MgContext -ErrorAction Stop)) { Connect-MgGraph -NoWelcome -ErrorAction Stop | Out-Null }

function Get-LookupGraphCollection {
    param([string]$Uri)
    $initial = [uri]$Uri
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($Uri) {
        $address = [uri]$Uri
        if (-not $address.IsAbsoluteUri -or $address.Scheme -ne 'https' -or
            $address.Authority -ne $initial.Authority -or $address.AbsolutePath -cne $initial.AbsolutePath -or
            -not $seen.Add($Uri)) {
            throw 'Graph returned an unexpected or repeated page.'
        }
        # Advanced queries (or/startswith combinations) require eventual consistency and $count.
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -Headers @{ ConsistencyLevel = 'eventual' } -OutputType PSObject -ErrorAction Stop
        if ($null -eq $page.value) { throw 'Graph did not return a valid collection.' }
        $page.value
        $Uri = $page.'@odata.nextLink'
    }
}

function ConvertTo-ODataLiteral {
    param([string]$Value)
    "'$($Value.Replace("'", "''"))'"
}

$select = 'id,displayName,givenName,surname,userPrincipalName,mail,jobTitle,department,officeLocation,accountEnabled,userType'
$base = 'https://graph.microsoft.com/v1.0/users'
$results = [Collections.Generic.List[object]]::new()

foreach ($name in $inputNames) {
    if ($name -match '^(?<last>[^,]+),\s*(?<first>.+)$') {
        $first = $Matches['first'].Trim(); $last = $Matches['last'].Trim()
    }
    elseif ($name -match '^(?<first>.+)\s(?<last>\S+)$') {
        $first = $Matches['first']; $last = $Matches['last']
    }
    else { $first = ''; $last = '' }

    $exact = if ($last) {
        "displayName eq $(ConvertTo-ODataLiteral "$first $last") or displayName eq $(ConvertTo-ODataLiteral "$last, $first") or " +
        "(givenName eq $(ConvertTo-ODataLiteral $first) and surname eq $(ConvertTo-ODataLiteral $last))"
    }
    else { "displayName eq $(ConvertTo-ODataLiteral $name)" }
    $possible = if ($last) {
        $initial = $first.Substring(0, 1)
        "(surname eq $(ConvertTo-ODataLiteral $last) and startswith(givenName,$(ConvertTo-ODataLiteral $initial))) or " +
        "startswith(displayName,$(ConvertTo-ODataLiteral "$last, $initial"))"
    }
    else { "startswith(displayName,$(ConvertTo-ODataLiteral $name))" }

    try {
        $status = 'Found'
        $users = @(Get-LookupGraphCollection "${base}?`$filter=$([uri]::EscapeDataString($exact))&`$select=$select&`$count=true")
        if ($users.Count -gt 1) { $status = 'Multiple' }
        elseif (-not $users.Count) {
            $status = 'PossibleMatch'
            $users = @(Get-LookupGraphCollection "${base}?`$filter=$([uri]::EscapeDataString($possible))&`$select=$select&`$count=true")
        }
        $users = @($users | Sort-Object id -Unique | Sort-Object displayName)
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch {
        $row = [pscustomobject]@{
            Input = $name; Status = 'Failed'; DisplayName = $null; UserPrincipalName = $null; Mail = $null
            JobTitle = $null; Department = $null; OfficeLocation = $null; AccountEnabled = $null; UserType = $null
            ObjectId = $null; Detail = $_.Exception.Message
        }
        $results.Add($row)
        $row
        continue
    }

    if (-not $users.Count) {
        $row = [pscustomobject]@{
            Input = $name; Status = 'NotFound'; DisplayName = $null; UserPrincipalName = $null; Mail = $null
            JobTitle = $null; Department = $null; OfficeLocation = $null; AccountEnabled = $null; UserType = $null
            ObjectId = $null; Detail = 'No exact or same-surname, same-initial user was returned.'
        }
        $results.Add($row)
        $row
        continue
    }
    $detail = switch ($status) {
        'Multiple' { "$($users.Count) users match this name exactly; confirm by UPN or department." }
        'PossibleMatch' { 'No exact match; same surname and first initial. Review before use.' }
        default { '' }
    }
    foreach ($user in $users) {
        $row = [pscustomobject]@{
            Input = $name; Status = $status; DisplayName = $user.displayName; UserPrincipalName = $user.userPrincipalName
            Mail = $user.mail; JobTitle = $user.jobTitle; Department = $user.department; OfficeLocation = $user.officeLocation
            AccountEnabled = $user.accountEnabled; UserType = $user.userType; ObjectId = $user.id; Detail = $detail
        }
        $results.Add($row)
        $row
    }
}
