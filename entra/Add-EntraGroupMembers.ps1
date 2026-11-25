<#
.SYNOPSIS
    Adds explicitly listed users or devices to an Entra group.
.DESCRIPTION
    Choose one input source. Matches exact user principal names or Entra device
    display names, skips existing direct members, and reports each outcome.
    If several devices share a hostname, all matching directory objects are added.
    If several users are returned for a UPN, none are added for that UPN.
.PARAMETER GroupId
    The target group's Entra object ID.
.PARAMETER GroupName
    The target group's exact display name. Duplicate names require -GroupId.
.PARAMETER Users
    One or more user principal names.
.PARAMETER UserListPath
    Text file with one UPN per line, or a CSV/XLSX file with a header row.
.PARAMETER UserColumn
    Column containing UPNs in the CSV/XLSX file.
.PARAMETER DeviceNames
    One or more device hostnames (Entra display names).
.PARAMETER DeviceListPath
    Text file with one device hostname per line.
.EXAMPLE
    .\Add-EntraGroupMembers.ps1 -GroupName 'Application Users' -UserListPath .\users.csv -UserColumn UPN
.EXAMPLE
    .\Add-EntraGroupMembers.ps1 -GroupId '00000000-0000-0000-0000-000000000001' -DeviceNames 'PC-1','PC-2'
.NOTES
    Requires Microsoft.Graph.Authentication and permission to update the group.
    Reuses the existing Graph connection or signs in to an organizational account
    using existing consent. Requires Group.Read.All, GroupMember.ReadWrite.All, and
    User.Read.All or Device.Read.All. XLSX input also requires ImportExcel.
#>
[CmdletBinding(DefaultParameterSetName = 'ById')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [guid]$GroupId,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [ValidateNotNullOrEmpty()]
    [string]$GroupName,

    [string[]]$Users,
    [string]$UserListPath,
    [string]$UserColumn,
    [string[]]$DeviceNames,
    [string]$DeviceListPath
)

$sources = @('Users','UserListPath','DeviceNames','DeviceListPath' | Where-Object { $PSBoundParameters.ContainsKey($_) })
if ($sources.Count -ne 1) { throw 'Specify exactly one input: Users, UserListPath, DeviceNames or DeviceListPath.' }
$isUser = $sources[0] -in @('Users','UserListPath')
$path = if ($isUser) { $UserListPath } else { $DeviceListPath }
$tabular = $UserListPath -and [IO.Path]::GetExtension($UserListPath) -in @('.csv','.xlsx')
if ($tabular -and [string]::IsNullOrWhiteSpace($UserColumn)) { throw 'Specify UserColumn for CSV or XLSX user input.' }
if (-not $tabular -and $PSBoundParameters.ContainsKey('UserColumn')) { throw 'UserColumn is only supported with CSV or XLSX user input.' }

$rawNames = switch ($sources[0]) {
    'Users' { $Users }
    'DeviceNames' { $DeviceNames }
    default {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Input file not found: $path" }
        if (-not $tabular) { Get-Content -LiteralPath $path -ErrorAction Stop }
        else {
            $entries = @(if ([IO.Path]::GetExtension($path) -eq '.csv') { Import-Csv -LiteralPath $path -ErrorAction Stop }
                else {
                    if (-not (Get-Module -ListAvailable -Name ImportExcel)) { throw 'XLSX input requires ImportExcel. Install-Module ImportExcel -Scope CurrentUser' }
                    Import-Excel -Path $path -ErrorAction Stop
                })
            if ($entries.Count -and $UserColumn -notin $entries[0].PSObject.Properties.Name) { throw "User column '$UserColumn' was not found." }
            $entries | ForEach-Object { $_.$UserColumn }
        }
    }
}
$names = @($rawNames | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Sort-Object -Unique)
if (-not $names.Count) { throw 'Supply at least one user UPN or device hostname.' }

if (-not (Get-MgContext -ErrorAction Stop)) { Connect-MgGraph -NoWelcome -ErrorAction Stop | Out-Null }

function Get-AddMemberGraphCollection {
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
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
        if ($null -eq $page.value) { throw 'Graph did not return a valid collection.' }
        $page.value
        $Uri = $page.'@odata.nextLink'
    }
}

$base = 'https://graph.microsoft.com/v1.0'
if ($PSCmdlet.ParameterSetName -eq 'ByName') {
    $filter = [uri]::EscapeDataString("displayName eq '$($GroupName.Replace("'", "''"))'")
    $groups = @(Get-AddMemberGraphCollection "$base/groups?`$filter=$filter&`$select=id,displayName")
    if ($groups.Count -ne 1 -or $groups[0].displayName -ne $GroupName) {
        throw 'Group name did not resolve to exactly one group. Check the name or use its object ID.'
    }
    $group = $groups[0]
}
else {
    $group = Invoke-MgGraphRequest -Method GET -Uri "$base/groups/${GroupId}?`$select=id,displayName" -OutputType PSObject -ErrorAction Stop
}
$targetId = [guid]::Empty
if (-not [guid]::TryParse([string]$group.id, [ref]$targetId) -or $targetId -eq [guid]::Empty -or
    ($PSCmdlet.ParameterSetName -eq 'ById' -and $targetId -ne $GroupId) -or -not $group.displayName) {
    throw 'Graph did not return a valid target group.'
}

$existing = [Collections.Generic.HashSet[guid]]::new()
Get-AddMemberGraphCollection "$base/groups/$targetId/members?`$select=id&`$top=999" | ForEach-Object {
    $null = $existing.Add([guid]$_.id)
}
$kind = if ($isUser) { 'user' } else { 'device' }
$endpoint = if ($isUser) { 'users' } else { 'devices' }
$key = if ($isUser) { 'userPrincipalName' } else { 'displayName' }
$results = [Collections.Generic.List[object]]::new()

foreach ($name in $names) {
    $filter = [uri]::EscapeDataString("$key eq '$($name.Replace("'", "''"))'")
    try {
        $memberIds = @(
            Get-AddMemberGraphCollection "$base/${endpoint}?`$filter=$filter&`$select=id,$key" | ForEach-Object {
                if ($_.$key -ne $name) { throw "Graph returned a $kind that does not match the input." }
                $id = [guid]::Empty
                if (-not [guid]::TryParse([string]$_.id, [ref]$id) -or $id -eq [guid]::Empty) { throw "Graph returned a $kind without a valid object ID." }
                $id
            } | Select-Object -Unique
        )
        if ($isUser -and $memberIds.Count -gt 1) { throw 'Multiple users returned for this UPN; no user was added.' }
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch {
        $result = [pscustomobject]@{
            Input=$name; MemberType=$kind; ObjectId=$null; Group=$group.displayName; GroupId=$targetId
            Status='Failed'; Detail=$_.Exception.Message
        }
        $results.Add($result)
        $result
        continue
    }

    if (-not $memberIds.Count) { $memberIds = @($null) }
    elseif (-not $isUser -and $memberIds.Count -gt 1) {
        Write-Warning "$name matches $($memberIds.Count) Entra device objects. All matching devices will be processed."
    }
    foreach ($memberId in $memberIds) {
        $detail = ''
        $status = if ($null -eq $memberId) {
            $detail = "No matching $kind found in Entra."
            'NotFound'
        }
        elseif ($existing.Contains($memberId)) { 'AlreadyMember' }
        else {
            try {
                $body = @{ '@odata.id' = "$base/directoryObjects/$memberId" } | ConvertTo-Json -Compress
                Invoke-MgGraphRequest -Method POST -Uri "$base/groups/$targetId/members/`$ref" -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
                $null = $existing.Add($memberId)
                'Added'
            }
            catch [System.Management.Automation.PipelineStoppedException] { throw }
            catch {
                if (-not $isUser -and $_.Exception.Message -like '*added object references already exist*') {
                    $null = $existing.Add($memberId)
                    'AlreadyMember'
                }
                else {
                    $detail = $_.Exception.Message
                    'Failed'
                }
            }
        }
        $result = [pscustomobject]@{
            Input=$name; MemberType=$kind; ObjectId=$memberId; Group=$group.displayName; GroupId=$targetId
            Status=$status; Detail=$detail
        }
        $results.Add($result)
        $result
    }
}
