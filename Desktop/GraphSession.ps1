# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

function Get-EndpointGraphPolicy {
    param([Parameter(Mandatory)][string]$WorkflowId, [hashtable]$Arguments = @{})
    $catalog = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'WorkflowCatalog.psd1')
    $workflow = @($catalog.Workflows | Where-Object Id -eq $WorkflowId)
    $officeGroups = $WorkflowId -eq 'm365-cloud-update' -and $Arguments['IncludeWaveGroups']
    if ($workflow.Count -ne 1 -or ($workflow[0]['Kind'] -and $workflow[0]['Kind'] -ne 'Graph' -and -not $officeGroups)) { throw "No Graph access policy for '$WorkflowId'." }
    $entry = $workflow[0]
    if (-not $entry.GraphScopes -or -not $entry.GraphRole) { throw "Incomplete Graph access policy for '$WorkflowId'." }
    $role = $entry.GraphRole
    if ($Arguments['WhatIf'] -or ($WorkflowId -eq 'primary-users' -and -not $Arguments['NewPrimaryUser'] -and -not $Arguments['RemovePrimaryUser'])) { $role = 'Reader' }
    $groups = switch ($role) {
        'Reader' { [pscustomobject]@{ AnyOf = @('Global Reader', 'Intune Administrator') } }
        'Intune' { [pscustomobject]@{ AnyOf = @('Intune Administrator') } }
        'Groups' { [pscustomobject]@{ AnyOf = @('Groups Administrator', 'Intune Administrator') } }
        'Cleanup' { [pscustomobject]@{ AnyOf = @('Intune Administrator') }; [pscustomobject]@{ AnyOf = @('Cloud Device Administrator') } }
        default { throw "Unknown Graph role policy '$role'." }
    }
    $scopes = [string[]]$entry.GraphScopes
    if ($WorkflowId -eq 'primary-users' -and ($Arguments['NewPrimaryUser'] -or $Arguments['RemovePrimaryUser'])) { $scopes += 'DeviceManagementManagedDevices.ReadWrite.All' }
    if ($WorkflowId -in @('add-members-to-group','remove-members-from-group')) {
        if ($Arguments['Users'] -or $Arguments['UserListPath']) { $scopes += 'User.Read.All' }
        if ($Arguments['DeviceNames'] -or $Arguments['DeviceListPath']) { $scopes += 'Device.Read.All' }
        if ($WorkflowId -eq 'remove-members-from-group' -and -not $Arguments['WhatIf']) { $scopes += 'GroupMember.ReadWrite.All' }
    }
    [pscustomobject]@{ Scopes = $scopes; RoleGroups = @($groups) }
}

function Get-EndpointGraphCollection {
    param([Parameter(Mandatory)][string]$Uri)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($Uri) {
        $address = [uri]$Uri
        if ($address.Scheme -ne 'https' -or $address.Host -ne 'graph.microsoft.com' -or -not $address.AbsolutePath.StartsWith('/v1.0/')) {
            throw 'Unexpected Graph pagination address. Verification stopped.'
        }
        if (-not $seen.Add($Uri)) { throw 'Graph returned a repeated page. Verification stopped.' }
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType Hashtable -ErrorAction Stop
        if ($page -isnot [System.Collections.IDictionary] -or -not $page.Contains('value') -or $null -eq $page['value']) { throw 'Graph returned an invalid collection. Verification stopped.' }
        $page['value']
        $Uri = [string]$page['@odata.nextLink']
    }
}

function Get-EndpointGraphSession {
    [CmdletBinding()]
    param()
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context) { throw 'Not connected. Open Home and connect to Microsoft Graph first.' }
    if ($context.AuthType -ne 'Delegated' -or $context.Environment -ne 'Global') { throw 'Home verification requires a delegated user connection to the Global Microsoft Graph environment.' }
    $me = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName' -OutputType Hashtable -ErrorAction Stop
    if (-not $me['id'] -or -not $me['userPrincipalName']) { throw 'The live Graph response did not identify a signed-in user.' }
    $session = [pscustomobject]@{
        State = 'RolesUnverified'; Account = [string]$me['userPrincipalName']; TenantId = [string]$context.TenantId
        CheckedUtc = [datetime]::UtcNow.ToString('o'); Roles = [string[]]@(); Scopes = [string[]]@($context.Scopes)
        Message = ''
    }
    try {
        $session.Roles = [string[]]@(Get-EndpointActiveGraphRoles ([string]$me['id']))
        $session.State = 'Checked'
        $session.Message = 'Live Graph request succeeded. Active tenant-wide built-in roles checked; this is not a guarantee of every operation.'
    }
    catch {
        $session.Message = "Live sign-in confirmed, but active roles could not be verified. Graph tasks are blocked. $($_.Exception.Message)"
        Write-Warning $session.Message
    }
    $session
}

function Get-EndpointActiveGraphRoles {
    param([Parameter(Mandatory)][string]$UserId)
    $principals = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $null = $principals.Add($UserId)
    foreach ($member in @(Get-EndpointGraphCollection 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf?$select=id')) {
        if ($member['@odata.type'] -eq '#microsoft.graph.group') {
            if (-not $member['id']) { throw 'Graph returned a group without an identifier. Role verification stopped.' }
            $null = $principals.Add([string]$member['id'])
        }
    }
    $templates = @{
        '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'
        'f2ef992c-3afb-46b9-b7cf-a126ee74c451' = 'Global Reader'
        '3a2c62db-5318-420d-8d74-23affee5d9d5' = 'Intune Administrator'
        'fdd7a751-b60b-444a-984c-02652fe8fa1c' = 'Groups Administrator'
        '7698a772-787b-4ac8-901f-60d6b08affd2' = 'Cloud Device Administrator'
    }
    $roles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # roleAssignments contains active assignments, not PIM eligibility. Include active group membership, but not scoped roles.
    foreach ($assignment in @(Get-EndpointGraphCollection 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?$expand=roleDefinition')) {
        if (-not $principals.Contains([string]$assignment['principalId']) -or $assignment['directoryScopeId'] -ne '/' -or $assignment['appScopeId']) { continue }
        if (-not $assignment['roleDefinition']) { throw 'Graph returned an unreadable role definition. Role verification stopped.' }
        if ($assignment['roleDefinition']['isBuiltIn'] -eq $false) { continue }
        if (-not $assignment['roleDefinition']['templateId']) { throw 'Graph returned an unreadable built-in role definition. Role verification stopped.' }
        $name = $templates[[string]$assignment['roleDefinition']['templateId']]
        if ($name) { $null = $roles.Add($name) }
    }
    [string[]]@($roles | Sort-Object)
}

function Assert-EndpointGraphAccess {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Policy, [string]$RequiredTenant = '')
    if ($Session.State -ne 'Checked') { throw "Graph access is not verified. Open Home and check the connection. $($Session.Message)" }
    if ($RequiredTenant -and $Session.TenantId -ne $RequiredTenant) { throw 'The signed-in tenant differs from the script-configured tenant. Reconnect from Home to the required tenant before running.' }
    $missing = @($Policy.Scopes | Where-Object { $_ -notin $Session.Scopes })
    if ($missing.Count) { throw "Missing delegated Graph scopes: $($missing -join ', '). Home uses existing consent and cannot grant permissions. Ask the tenant administrator to review the Microsoft Graph Command Line Tools grant. PIM activation does not grant application consent." }
    foreach ($group in $Policy.RoleGroups) {
        if ('Global Administrator' -in $Session.Roles) { continue }
        if (-not @($group.AnyOf | Where-Object { $_ -in $Session.Roles }).Count) {
            throw "Required active tenant-wide role: $($group.AnyOf -join ' or '). Activate it in PIM, wait for propagation, then Check connection on Home and retry. Eligibility alone is not activation. Scoped/custom roles and group ownership are not verified."
        }
    }
    if (@($Policy.RoleGroups | Where-Object { 'Groups Administrator' -in $_.AnyOf }).Count -and
        'Intune Administrator' -in $Session.Roles -and 'Groups Administrator' -notin $Session.Roles -and 'Global Administrator' -notin $Session.Roles) {
        Write-Warning 'Intune Administrator elevation satisfies the app group-task preflight, but does not prove permission to modify the target Entra group. Graph still enforces group ownership, delegated permissions and group-specific restrictions; service errors remain authoritative.'
    }
}
