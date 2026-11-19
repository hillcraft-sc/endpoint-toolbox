# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Removes explicitly listed users or devices from an Entra group.
.DESCRIPTION
    Resolves one cloud-managed group by exact name or object ID. Matches UPNs or
    device hostnames against direct membership only and skips ambiguous matches.
    Removes membership references, never the directory objects. Supports -WhatIf.
.PARAMETER GroupId
    The target group's Entra object ID.
.PARAMETER GroupName
    The target group's exact display name. Duplicate names require -GroupId.
.PARAMETER Users
    User principal names, one per array entry.
.PARAMETER UserListPath
    Text file with one UPN per line, or a CSV/XLSX file with a header.
.PARAMETER UserColumn
    Column containing UPNs in the CSV/XLSX file.
.PARAMETER DeviceNames
    Entra device display names (hostnames), one per array entry.
.PARAMETER DeviceListPath
    Text file with one device hostname per line.
.EXAMPLE
    .\Remove-EntraGroupMembers.ps1 -GroupName 'Application Users' -Users 'user@example.invalid' -WhatIf
.EXAMPLE
    .\Remove-EntraGroupMembers.ps1 -GroupId '00000000-0000-0000-0000-000000000001' -DeviceListPath .\devices.txt
.NOTES
    Requires Microsoft.Graph.Authentication and an authorized Global Graph connection.
    Use Group.Read.All and User.Read.All or Device.Read.All for the selected member
    type. Real removals also require GroupMember.ReadWrite.All. XLSX input requires ImportExcel.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'ById')]
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

$sources = @('Users', 'UserListPath', 'DeviceNames', 'DeviceListPath' | Where-Object { $PSBoundParameters.ContainsKey($_) })
if ($sources.Count -ne 1) { throw 'Specify exactly one input: Users, UserListPath, DeviceNames or DeviceListPath.' }
$isUser = $sources[0] -in @('Users', 'UserListPath')
$path = if ($isUser) { $UserListPath } else { $DeviceListPath }
$extension = [IO.Path]::GetExtension($path)
$tabular = $UserListPath -and $extension -in @('.csv', '.xlsx')
if ($tabular -and [string]::IsNullOrWhiteSpace($UserColumn)) { throw 'Specify UserColumn for CSV or XLSX user input.' }
if (-not $tabular -and $PSBoundParameters.ContainsKey('UserColumn')) { throw 'UserColumn is only supported with CSV or XLSX user input.' }
if ($path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Input file not found: $path" }
    if ($tabular) {
        $entries = @(if ($extension -eq '.csv') { Import-Csv -LiteralPath $path -ErrorAction Stop }
            else {
                if (-not (Get-Module -ListAvailable ImportExcel)) { throw 'Install the ImportExcel module before using XLSX input.' }
                Import-Excel -Path $path -ErrorAction Stop
            })
        if ($entries.Count -and $UserColumn -notin $entries[0].PSObject.Properties.Name) { throw "User column '$UserColumn' was not found." }
        $inputNames = $entries | ForEach-Object { $_.$UserColumn }
    }
    else { $inputNames = Get-Content -LiteralPath $path -ErrorAction Stop }
}
elseif ($isUser) { $inputNames = $Users }
else { $inputNames = $DeviceNames }
$names = @($inputNames | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Sort-Object -Unique)
if (-not $names.Count) { throw 'Supply at least one user UPN or device hostname.' }

$context = Get-MgContext -ErrorAction Stop
if (-not $context) {
    Connect-MgGraph -NoWelcome -ErrorAction Stop | Out-Null
    $context = Get-MgContext -ErrorAction Stop
}
if (-not $context -or $context.Environment -ne 'Global') { throw 'An active Global Microsoft Graph connection is required.' }

function Get-RemovalGraphCollection {
    param([string]$Uri, [hashtable]$Headers = @{})
    $expectedPath = ([uri]$Uri).AbsolutePath
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($Uri) {
        $address = [uri]$Uri
        if (-not $address.IsAbsoluteUri -or $address.Scheme -ne 'https' -or
            $address.Host -ne 'graph.microsoft.com' -or -not $address.IsDefaultPort -or
            $address.AbsolutePath -cne $expectedPath -or -not $seen.Add($Uri)) {
            throw 'Graph returned an unexpected or repeated page. No removals were attempted.'
        }
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -Headers $Headers -OutputType Hashtable -ErrorAction Stop
        if ($page -isnot [System.Collections.IDictionary] -or $null -eq $page['value']) { throw 'Graph did not return a valid collection.' }
        $page['value']
        $Uri = [string]$page['@odata.nextLink']
    }
}

$base = 'https://graph.microsoft.com/v1.0/groups'
$properties = 'id,displayName,groupTypes,mailEnabled,isAssignableToRole,onPremisesSyncEnabled,visibility'
if ($PSCmdlet.ParameterSetName -eq 'ByName') {
    $filter = [uri]::EscapeDataString("displayName eq '$($GroupName.Replace("'", "''"))'")
    $matchedGroups = @(Get-RemovalGraphCollection "${base}?`$filter=$filter&`$select=$properties")
    if ($matchedGroups.Count -ne 1 -or $matchedGroups[0] -isnot [System.Collections.IDictionary] -or
        $matchedGroups[0]['displayName'] -ne $GroupName) {
        throw 'Group name did not resolve to exactly one group. Check the name or use its object ID.'
    }
    $group = $matchedGroups[0]
}
else {
    $group = Invoke-MgGraphRequest -Method GET -Uri "$base/${GroupId}?`$select=$properties" -OutputType Hashtable -ErrorAction Stop
}
$targetId = [guid]::Empty
if ($group -isnot [System.Collections.IDictionary] -or
    -not [guid]::TryParse([string]$group['id'], [ref]$targetId) -or
    $targetId -eq [guid]::Empty -or
    ($PSCmdlet.ParameterSetName -eq 'ById' -and $targetId -ne $GroupId) -or
    -not $group['displayName'] -or $null -eq $group['groupTypes'] -or $group['mailEnabled'] -isnot [bool]) {
    throw 'Graph did not return enough information to verify the target group.'
}
if ($group['groupTypes'] -contains 'DynamicMembership' -or $group['isAssignableToRole'] -or
    $group['onPremisesSyncEnabled'] -or $group['visibility'] -eq 'HiddenMembership' -or
    ($group['mailEnabled'] -and $group['groupTypes'] -notcontains 'Unified')) {
    throw 'Dynamic, role-assignable, synchronized, hidden-membership and Exchange-managed groups are not supported.'
}
if (-not $isUser -and $group['groupTypes'] -contains 'Unified') { throw 'Microsoft 365 groups do not support device membership.' }

$kind = if ($isUser) { 'user' } else { 'device' }
$key = if ($isUser) { 'userPrincipalName' } else { 'displayName' }
$requestedNames = [Collections.Generic.HashSet[string]]::new([string[]]$names, [StringComparer]::OrdinalIgnoreCase)
$direct = @{}
$memberUri = "$base/$targetId/members/microsoft.graph.${kind}?`$select=id,$key&`$count=true"
Get-RemovalGraphCollection $memberUri @{ ConsistencyLevel = 'eventual' } | ForEach-Object {
    if ($_ -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace([string]$_[$key])) {
        throw "Graph did not return readable $kind membership details. Check the required read permissions."
    }
    $name = [string]$_[$key]
    if ($requestedNames.Contains($name)) {
        $memberId = [guid]::Empty
        if (-not [guid]::TryParse([string]$_['id'], [ref]$memberId) -or $memberId -eq [guid]::Empty) {
            throw 'Graph returned a direct member without a valid object ID.'
        }
        if (-not $direct.ContainsKey($name)) { $direct[$name] = [Collections.Generic.HashSet[guid]]::new() }
        $null = $direct[$name].Add($memberId)
    }
}

$results = [Collections.Generic.List[object]]::new()
foreach ($name in $names) {
    $ids = $direct[$name]
    $detail = ''
    $objectId = $null
    $status = if (-not $ids -or -not $ids.Count) {
        $detail = 'No matching direct member was returned; inherited membership is not changed.'
        'NotFound'
    }
    elseif ($ids.Count -gt 1) {
        $detail = 'Multiple direct members match; no membership was removed for this entry.'
        'Unresolved'
    }
    else {
        $objectId = @($ids)[0]
        if ($PSCmdlet.ShouldProcess("$name ($objectId) in $($group['displayName']) ($targetId)", 'Remove direct Entra group membership')) {
            try {
                # The $ref suffix removes the relationship, not the directory object.
                Invoke-MgGraphRequest -Method DELETE -Uri "$base/$targetId/members/$objectId/`$ref" -ErrorAction Stop | Out-Null
                'Removed'
            }
            catch [System.Management.Automation.PipelineStoppedException] { throw }
            catch {
                $detail = $_.Exception.Message
                'Failed'
            }
        }
        elseif ($WhatIfPreference) { 'WhatIf' }
        else { 'Declined' }
    }
    $result = [pscustomobject]@{
        Input = $name; MemberType = $kind; ObjectId = $objectId
        Group = $group['displayName']; GroupId = $targetId; Status = $status; Detail = $detail
    }
    $results.Add($result)
    $result
}
