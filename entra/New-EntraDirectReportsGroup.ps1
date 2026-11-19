# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Creates a dynamic Entra security group for a manager's direct reports.
.DESCRIPTION
    Resolves one manager by exact display name or UPN. Creates a non-mail-enabled
    dynamic security group named Entra.Users.DirectReports.<FirstLast> using the
    manager's givenName and surname without whitespace, not the display name.
    Missing name fields, duplicate manager names and existing group names stop creation.
    The description identifies the manager, signed-in creator and UTC creation date.
    Entra's Direct Reports rule includes the manager and immediate reports, not
    nested reports. Membership processing is asynchronous.
.PARAMETER Manager
    The manager's exact Entra display name or user principal name (UPN).
.EXAMPLE
    .\New-EntraDirectReportsGroup.ps1 -Manager 'manager@example.invalid' -WhatIf
.EXAMPLE
    .\New-EntraDirectReportsGroup.ps1 -Manager 'Example Manager'
.NOTES
    Requires PowerShell 7.6+ and Microsoft.Graph.Authentication. Reuses the current
    delegated Global Graph connection, or connects using existing consent (.default)
    in the selected tenant. Does not request additional scopes or switch tenants.
    Requires User.Read.All and Group.ReadWrite.All and authorization to create
    dynamic security groups (typically Groups Administrator). Dynamic user membership
    requires suitable Microsoft Entra ID P1 licensing for each unique member.
    No existing groups are updated, and failed/uncertain creates are never retried.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Manager
)

$managerInput = $Manager.Trim()
if (-not $managerInput) { throw 'Supply the manager exact display name or UPN.' }
if (-not (Get-Command Get-MgContext -ErrorAction Ignore)) {
    throw 'Microsoft.Graph.Authentication is required. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
$context = Get-MgContext -ErrorAction Stop
if (-not $context) {
    Connect-MgGraph -Scopes 'https://graph.microsoft.com/.default' -ContextScope Process -NoWelcome -ErrorAction Stop | Out-Null
    $context = Get-MgContext -ErrorAction Stop
}
if (-not $context -or $context.AuthType -ne 'Delegated' -or $context.Environment -ne 'Global') {
    throw 'A delegated user connection to Global Microsoft Graph is required.'
}

function Get-DirectReportsGraphCollection {
    param([string]$Uri)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($Uri) {
        $address = [uri]$Uri
        if ($address.Scheme -ne 'https' -or $address.Host -ne 'graph.microsoft.com' -or
            -not $address.AbsolutePath.StartsWith('/v1.0/')) {
            throw 'Unexpected Graph pagination address. Group creation stopped.'
        }
        if (-not $seen.Add($Uri)) { throw 'Graph returned a repeated page. Group creation stopped.' }
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType Hashtable -ErrorAction Stop
        if ($page -isnot [Collections.IDictionary] -or -not $page.Contains('value') -or $null -eq $page['value']) {
            throw 'Graph returned an invalid collection. Group creation stopped.'
        }
        $page['value']
        $Uri = [string]$page['@odata.nextLink']
    }
}

$property = if ($managerInput.Contains('@')) { 'userPrincipalName' } else { 'displayName' }
$filter = [uri]::EscapeDataString("$property eq '$($managerInput.Replace("'", "''"))'")
$managers = @(Get-DirectReportsGraphCollection "https://graph.microsoft.com/v1.0/users?`$filter=$filter&`$select=id,displayName,userPrincipalName,givenName,surname")
if ($managers.Count -eq 0) { throw "No manager found for '$managerInput'. Supply the exact display name or UPN." }
if ($managers.Count -ne 1) { throw "Multiple managers match '$managerInput'. Supply a unique manager UPN." }
$resolvedManager = $managers[0]
$managerId = [guid]::Empty
if (-not [guid]::TryParse([string]$resolvedManager.id, [ref]$managerId) -or $managerId -eq [guid]::Empty -or
    [string]::IsNullOrWhiteSpace($resolvedManager.displayName) -or [string]::IsNullOrWhiteSpace($resolvedManager.userPrincipalName)) {
    throw 'The manager response is missing a valid object ID, display name or UPN. Group creation stopped.'
}
$firstName = [string]$resolvedManager.givenName -replace '\s', ''
$lastName = [string]$resolvedManager.surname -replace '\s', ''
if (-not $firstName -or -not $lastName) {
    throw 'The manager must have both givenName (first name) and surname (last name) in Entra. Group creation stopped.'
}
$groupName = 'Entra.Users.DirectReports.' + $firstName + $lastName
if ($groupName.Length -gt 256) { throw 'The generated group name exceeds the Entra limit of 256 characters.' }
$filter = [uri]::EscapeDataString("displayName eq '$($groupName.Replace("'", "''"))'")
$existingGroups = @(Get-DirectReportsGraphCollection "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName")
if ($existingGroups.Count) { throw "Group '$groupName' already exists. No group was created or updated." }

$creator = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,displayName,userPrincipalName' -OutputType Hashtable -ErrorAction Stop
if (-not $creator.id -or [string]::IsNullOrWhiteSpace($creator.userPrincipalName)) {
    throw 'Could not identify the signed-in creator. Group creation stopped.'
}
$rule = 'Direct Reports for "{0}"' -f $managerId
$description = "Dynamic direct reports group for $($resolvedManager.displayName). Created by $($creator.userPrincipalName) on $([datetime]::UtcNow.ToString('yyyy-MM-dd'))."
if ($description.Length -gt 1024) { throw 'The generated description exceeds the Entra limit of 1024 characters.' }
$body = @{
    displayName = $groupName
    description = $description
    mailEnabled = $false
    mailNickname = 'DirectReports' + $managerId.ToString('N')
    securityEnabled = $true
    groupTypes = @('DynamicMembership')
    membershipRule = $rule
    membershipRuleProcessingState = 'On'
}
$results = @([pscustomobject]@{
    GroupName = $groupName; GroupId = ''; Manager = $resolvedManager.displayName
    ManagerUPN = $resolvedManager.userPrincipalName; ManagerId = $managerId.ToString()
    MembershipRule = $rule; Description = $description; Status = 'NotProcessed'
})
Write-Host "Group: $groupName`nRule: $rule`nDescription: $description"
if ($PSCmdlet.ShouldProcess("$groupName`n$rule`n$description", 'Create dynamic Entra security group')) {
    try {
        $created = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -Body ($body | ConvertTo-Json -Depth 4) -ContentType 'application/json' -OutputType Hashtable -ErrorAction Stop
        if (-not $created.id) { throw 'Graph did not return a created group ID. Check Entra before retrying; the request may have been accepted.' }
        $results[0].GroupId = [string]$created.id
        $results[0].Status = 'Created'
        Write-Host "Created group '$groupName' ($($created.id)). Dynamic membership processing is pending."
    }
    catch {
        $results[0].Status = 'NotConfirmed'
        Write-Warning 'Group creation was not confirmed. Check Entra before retrying; no automatic retry or rollback was performed.'
        throw
    }
}
else {
    $results[0].Status = if ($WhatIfPreference) { 'WhatIf' } else { 'Declined' }
}
$results
