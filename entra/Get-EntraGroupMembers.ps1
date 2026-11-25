<#
.SYNOPSIS
    Gets all member types of an Entra group, optionally including nested members.
.DESCRIPTION
    Finds one group by exact display name or object ID and returns its direct
    members by default. ExpandNestedGroups returns a flat, deduplicated list of
    direct and indirect members, including nested group objects. All member types
    are retained. Duplicate group names are rejected; use GroupId to disambiguate.
.PARAMETER GroupName
    The exact display name of the group.
.PARAMETER GroupId
    The Entra group object ID, instead of its display name.
.PARAMETER ExpandNestedGroups
    Include members of nested groups at every depth. Off by default.
    Each object is returned once, not once per membership path.
.EXAMPLE
    .\Get-EntraGroupMembers.ps1 -GroupName 'Application Users'
.EXAMPLE
    .\Get-EntraGroupMembers.ps1 -GroupName 'Application Users' -ExpandNestedGroups
.NOTES
    Requires Microsoft.Graph.Authentication and an authorized Global Graph connection
    with Directory.Read.All. Hidden membership also requires Member.Read.Hidden and
    an appropriate role. Some object properties may be unavailable to the caller.
    Uses Graph beta members/transitiveMembers endpoints to include service principals;
    beta APIs can change and are not supported for production use by Microsoft.
#>
[CmdletBinding(DefaultParameterSetName='ByName')]
param(
    [Parameter(Mandatory, ParameterSetName='ByName')]
    [ValidateNotNullOrEmpty()]
    [string]$GroupName,

    [Parameter(Mandatory, ParameterSetName='ById')]
    [ValidateScript({ $_ -ne [guid]::Empty })]
    [guid]$GroupId,

    [switch]$ExpandNestedGroups
)

if ($PSCmdlet.ParameterSetName -eq 'ByName' -and [string]::IsNullOrWhiteSpace($GroupName)) { throw 'Supply an exact group display name.' }

$context = Get-MgContext -ErrorAction Stop
if (-not $context) {
    Connect-MgGraph -Scopes 'https://graph.microsoft.com/.default' -NoWelcome -ErrorAction Stop | Out-Null
    $context = Get-MgContext -ErrorAction Stop
}
if (-not $context -or $context.Environment -ne 'Global') { throw 'An active Global Microsoft Graph connection is required.' }

function Get-GroupMembersGraphCollection {
    param([string]$Uri)
    $expectedPath = ([uri]$Uri).AbsolutePath
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($Uri) {
        $address = [uri]$Uri
        if (-not $address.IsAbsoluteUri -or $address.Scheme -ne 'https' -or
            $address.Host -ne 'graph.microsoft.com' -or -not $address.IsDefaultPort -or
            $address.UserInfo -or $address.Fragment -or $address.AbsolutePath -cne $expectedPath -or
            -not $seen.Add($Uri)) {
            throw 'Graph returned an unexpected or repeated page; the report was not completed.'
        }
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType Hashtable -ErrorAction Stop
        if ($page -isnot [System.Collections.IDictionary] -or $page['value'] -isnot [array]) {
            throw 'Graph did not return a valid collection; the report was not completed.'
        }
        $page['value']
        $Uri = [string]$page['@odata.nextLink']
    }
}

if ($PSCmdlet.ParameterSetName -eq 'ById') {
    $group = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId`?`$select=id,displayName,visibility" -OutputType Hashtable -ErrorAction Stop
}
else {
    $filter = [uri]::EscapeDataString("displayName eq '$($GroupName.Replace("'", "''"))'")
    $groups = @(Get-GroupMembersGraphCollection "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName,visibility")
    if (-not $groups.Count) { throw "No group matched the exact name '$GroupName'." }
    if ($groups.Count -ne 1) { throw "Multiple groups matched the exact name '$GroupName'; supply GroupId instead." }
    $group = $groups[0]
}
$resolvedGroupId = [guid]::Empty
if ($group -isnot [System.Collections.IDictionary] -or
    -not [guid]::TryParse([string]$group['id'], [ref]$resolvedGroupId) -or $resolvedGroupId -eq [guid]::Empty -or
    ($PSCmdlet.ParameterSetName -eq 'ById' -and $resolvedGroupId -ne $GroupId) -or
    ($PSCmdlet.ParameterSetName -eq 'ByName' -and $group['displayName'] -ne $GroupName)) {
    throw 'Graph did not return a valid exact group match.'
}
if ($group['visibility'] -eq 'HiddenMembership' -and $context.AuthType -ne 'AppOnly' -and
    $context.Scopes -notcontains 'Member.Read.Hidden') {
    throw 'This group has hidden membership. Member.Read.Hidden consent and an appropriate Entra role are required.'
}

$relationship = if ($ExpandNestedGroups) { 'transitiveMembers' } else { 'members' }
$members = @(Get-GroupMembersGraphCollection "https://graph.microsoft.com/beta/groups/$resolvedGroupId/$relationship`?`$top=999")
$seenMembers = [Collections.Generic.HashSet[guid]]::new()
$results = @(foreach ($member in $members) {
    $memberId = [guid]::Empty
    if ($member -isnot [System.Collections.IDictionary] -or
        -not [guid]::TryParse([string]$member['id'], [ref]$memberId) -or $memberId -eq [guid]::Empty -or
        [string]::IsNullOrWhiteSpace([string]$member['@odata.type'])) {
        throw 'Graph returned a member without a valid object ID or type; the report was not completed.'
    }
    if ($ExpandNestedGroups -and -not $seenMembers.Add($memberId)) { continue }
    [pscustomobject]@{
        DisplayName = [string]$member['displayName']
        MemberType = ([string]$member['@odata.type'] -replace '^#microsoft\.graph\.', '')
        UserPrincipalName = [string]$member['userPrincipalName']
        Mail = [string]$member['mail']
        ObjectId = $memberId.ToString()
    }
})
if (@($results | Where-Object { [string]::IsNullOrWhiteSpace($_.DisplayName) }).Count) {
    Write-Warning 'Some members have no readable display name. Graph may return limited information for objects the caller cannot read; use the object ID and check permissions.'
}
if ($ExpandNestedGroups) {
    Write-Host "Found $($results.Count) unique direct and indirect member(s) in '$($group['displayName'])'. Nested groups are expanded into a flat list, including group objects."
}
else {
    Write-Host "Found $($results.Count) direct member(s) in '$($group['displayName'])'. Nested groups are not expanded."
}
$results
