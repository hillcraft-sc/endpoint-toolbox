# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

$desktop = Split-Path $PSScriptRoot -Parent
. (Join-Path $desktop 'GraphSession.ps1')
if (-not ('EndpointToolbox.DesktopEngine' -as [type])) { Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs') }
$graphFixture = Join-Path $PSScriptRoot 'Fixtures\GraphSessionFixture.ps1'
$graphRunner = Join-Path $desktop 'Invoke-GraphSession.ps1'

function Test-GraphRejected {
    param([scriptblock]$Action)
    try { $null = & $Action; return $false } catch { return $true }
}

function Complete-GraphFixture {
    param($Engine)
    $events = [Collections.Generic.List[object]]::new()
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    do {
        $null = $Engine.Poll()
        $event = $null
        while ($Engine.Host.Events.TryDequeue([ref]$event)) { $events.Add($event) }
        if ([datetime]::UtcNow -gt $deadline) { $Engine.Cancel(); throw 'Offline Graph fixture timed out.' }
        Start-Sleep -Milliseconds 10
    } while ($Engine.Busy -or -not $Engine.Host.Events.IsEmpty)
    $events.ToArray()
}

Describe 'Shared Graph access policy' {
    It 'defines an explicit scope and role policy for every Graph workflow, but never remote commands' {
        $manifest=Import-PowerShellDataFile (Join-Path $desktop 'WorkflowCatalog.psd1')
        foreach ($entry in $manifest.Workflows) {
            if ($entry['Kind'] -and $entry['Kind'] -ne 'Graph') { continue }
            $policy=Get-EndpointGraphPolicy $entry.Id
            ($policy.Scopes.Count -gt 0) | Should Be $true
            ($policy.RoleGroups.Count -gt 0) | Should Be $true
        }
        (Test-GraphRejected { Get-EndpointGraphPolicy remote-endpoint }) | Should Be $true
        (Test-GraphRejected { Get-EndpointGraphPolicy unknown-task }) | Should Be $true
    }
    It 'connects using existing delegated consent without requesting workflow or role-management scope bundles' {
        & {
            . $graphFixture -Mode Bootstrap
            try {
                & $graphRunner -Action Connect -TenantId 'fixture-tenant'
                $global:GraphFixture.RequestedScopes.Count | Should Be 1
                $global:GraphFixture.RequestedScopes[0] | Should Be 'https://graph.microsoft.com/.default'
                $global:GraphFixture.Context.TenantId | Should Be 'fixture-tenant'
                ($global:GraphFixture.Context.Scopes -contains 'https://graph.microsoft.com/.default') | Should Be $false
                $global:GraphFixture.Connects | Should Be 1
            }
            finally {
                foreach ($name in @('Get-MgContext','Connect-MgGraph','Disconnect-MgGraph','Invoke-MgGraphRequest')) { Remove-Item -LiteralPath "Function:\$name" -ErrorAction Ignore }
                Remove-Variable -Name GraphFixture -Scope Global -ErrorAction Ignore
            }
        }
    }
    It 'requires Intune Administrator for primary-user changes but a reader role for read mode and preview' {
        ((Get-EndpointGraphPolicy primary-users).RoleGroups[0].AnyOf -contains 'Global Reader') | Should Be $true
        $change=Get-EndpointGraphPolicy primary-users @{NewPrimaryUser='fixture@example.invalid'}
        $change.RoleGroups[0].AnyOf.Count | Should Be 1
        $change.RoleGroups[0].AnyOf[0] | Should Be 'Intune Administrator'
        ($change.Scopes -contains 'DeviceManagementManagedDevices.ReadWrite.All') | Should Be $true
        ((Get-EndpointGraphPolicy primary-users @{RemovePrimaryUser=$true;WhatIf=$true}).RoleGroups[0].AnyOf -contains 'Global Reader') | Should Be $true
    }
    It 'requires membership write permission only for real removals and reads only the selected member type' {
        $preview = Get-EndpointGraphPolicy remove-members-from-group @{ Users='fixture@example.invalid'; WhatIf=$true }
        ($preview.Scopes -contains 'User.Read.All') | Should Be $true
        ($preview.Scopes -contains 'Device.Read.All') | Should Be $false
        ($preview.Scopes -contains 'GroupMember.ReadWrite.All') | Should Be $false
        ($preview.RoleGroups[0].AnyOf -contains 'Global Reader') | Should Be $true
        $change = Get-EndpointGraphPolicy remove-members-from-group @{ DeviceListPath='fixture.txt' }
        ($change.Scopes -contains 'Device.Read.All') | Should Be $true
        ($change.Scopes -contains 'User.Read.All') | Should Be $false
        ($change.Scopes -contains 'GroupMember.ReadWrite.All') | Should Be $true
    }
    It 'does not mistake Intune administration for Entra group or device-delete authorization' {
        (Get-EndpointGraphPolicy add-members-to-group).RoleGroups[0].AnyOf[0] | Should Be 'Groups Administrator'
        (Get-EndpointGraphPolicy entra-cleanup).RoleGroups.Count | Should Be 2
        foreach ($id in @('add-members-to-group','add-primary-devices-to-group','create-direct-reports-group','remove-members-from-group')) {
            $policy=Get-EndpointGraphPolicy $id
            $session=[pscustomobject]@{State='Checked';TenantId='fixture-tenant';Scopes=$policy.Scopes;Roles=@('Intune Administrator')}
            $warnings=@()
            Assert-EndpointGraphAccess $session $policy -WarningVariable warnings -WarningAction SilentlyContinue
            ($warnings -join ' ') | Should Match 'does not prove permission'
            $session.Roles=@('Global Reader')
            (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy }) | Should Be $true
            $session.Roles=@('Groups Administrator')
            Assert-EndpointGraphAccess $session $policy
        }
    }
    It 'refuses a missing role, missing scopes, a mismatched tenant or an unverified session' {
        $policy=Get-EndpointGraphPolicy intune-sync
        $session=[pscustomobject]@{State='Checked';TenantId='fixture-tenant';Scopes=$policy.Scopes;Roles=@('Global Reader')}
        (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy }) | Should Be $true
        $session.Roles=@('Intune Administrator')
        Assert-EndpointGraphAccess $session $policy
        (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy 'other-tenant' }) | Should Be $true
        $session.Scopes=@()
        (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy }) | Should Be $true
        $session.Scopes=$policy.Scopes; $session.State='Unverified'
        (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy }) | Should Be $true
    }
    It 'requires both cleanup roles and accepts Global Administrator without recommending it' {
        $policy=Get-EndpointGraphPolicy entra-cleanup
        $session=[pscustomobject]@{State='Checked';TenantId='fixture-tenant';Scopes=$policy.Scopes;Roles=@('Intune Administrator')}
        (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy }) | Should Be $true
        $session.Roles+= 'Cloud Device Administrator'
        Assert-EndpointGraphAccess $session $policy
        $session.Roles=@('Global Administrator')
        Assert-EndpointGraphAccess $session $policy
    }
}

Describe 'Live Graph verification without network access' {
    BeforeEach {
        . $graphFixture -Mode Bootstrap
        Connect-MgGraph -Scopes @('https://graph.microsoft.com/.default') -ContextScope Process
    }
    AfterEach {
        foreach ($name in @('Get-MgContext','Connect-MgGraph','Disconnect-MgGraph','Invoke-MgGraphRequest')) { Remove-Item -LiteralPath "Function:\$name" -ErrorAction Ignore }
        Remove-Variable -Name GraphFixture -Scope Global -ErrorAction Ignore
    }
    It 'performs live requests rather than trusting Get-MgContext alone' {
        $session=Get-EndpointGraphSession
        $session.State | Should Be 'Checked'
        ($session.Roles -contains 'Intune Administrator') | Should Be $true
        $global:GraphFixture.Forbidden=$true
        (Test-GraphRejected { Get-EndpointGraphSession }) | Should Be $true
    }
    It 'refuses disconnected and application-only contexts' {
        $global:GraphFixture.Context.AuthType='AppOnly'
        (Test-GraphRejected { Get-EndpointGraphSession }) | Should Be $true
        $global:GraphFixture.Context=$null
        (Test-GraphRejected { Get-EndpointGraphSession }) | Should Be $true
    }
    It 'keeps live sign-in visible but blocks tasks when role-reading authorization is denied' {
        $global:GraphFixture.Response = {
            param($Method,$Uri,$OutputType)
            if ($Uri -like '*me[?]*') { return @{id='fixture-user';userPrincipalName='fixture@example.invalid'} }
            throw 'Synthetic role-read permission denied.'
        }
        $warnings=@()
        $session=Get-EndpointGraphSession -WarningVariable warnings -WarningAction SilentlyContinue
        $session.State | Should Be 'RolesUnverified'
        $session.Account | Should Be 'fixture@example.invalid'
        $session.Roles.Count | Should Be 0
        ($warnings.Count -gt 0) | Should Be $true
        (Test-GraphRejected { Assert-EndpointGraphAccess $session (Get-EndpointGraphPolicy intune-sync) }) | Should Be $true
    }
    It 'handles paged active group role assignments and excludes other users and scoped roles' {
        $global:GraphFixture.Response = {
            param($Method,$Uri,$OutputType)
            switch -Wildcard ($Uri) {
                '*me[?]*' { return @{id='fixture-user';userPrincipalName='fixture@example.invalid'} }
                '*transitiveMemberOf*' { return @{value=@(@{id='active-group';'@odata.type'='#microsoft.graph.group'})} }
                '*roleAssignments*' {
                    return @{value=@(
                        @{principalId='other-user';directoryScopeId='/';appScopeId=$null;roleDefinition=@{templateId='62e90394-69f5-4237-9190-012177145e10'}}
                        @{principalId='fixture-user';directoryScopeId='/administrativeUnits/fixture';appScopeId=$null;roleDefinition=@{templateId='f2ef992c-3afb-46b9-b7cf-a126ee74c451'}}
                    );'@odata.nextLink'='https://graph.microsoft.com/v1.0/next'}
                }
                '*/next' { return @{value=@(@{principalId='active-group';directoryScopeId='/';appScopeId=$null;roleDefinition=@{templateId='3a2c62db-5318-420d-8d74-23affee5d9d5'}})} }
                default { throw 'Unexpected offline request.' }
            }
        }
        $session=Get-EndpointGraphSession
        $session.Roles.Count | Should Be 1
        $session.Roles[0] | Should Be 'Intune Administrator'
    }
    It 'does not count eligibility or expired roles as active roles' {
        $global:GraphFixture.Role=''
        $session=Get-EndpointGraphSession
        $session.Roles.Count | Should Be 0
        (Test-GraphRejected { Assert-EndpointGraphAccess $session (Get-EndpointGraphPolicy intune-sync) }) | Should Be $true
    }
    It 'rejects malformed, repeated and foreign-host pagination instead of assuming missing roles' {
        $global:GraphFixture.Response = { @{value=@();'@odata.nextLink'='https://example.invalid/stolen-page'} }
        (Test-GraphRejected { Get-EndpointGraphCollection 'https://graph.microsoft.com/v1.0/test' }) | Should Be $true
        $global:GraphFixture.Response = { @{value=@();'@odata.nextLink'='https://graph.microsoft.com/v1.0/test'} }
        (Test-GraphRejected { Get-EndpointGraphCollection 'https://graph.microsoft.com/v1.0/test' }) | Should Be $true
        $global:GraphFixture.Response = { @{} }
        (Test-GraphRejected { Get-EndpointGraphCollection 'https://graph.microsoft.com/v1.0/test' }) | Should Be $true
    }
}

Describe 'Persistent Graph worker and preflight' {
    It 'allows group tasks with Intune elevation while retaining authoritative service errors' {
        $engine=[EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($graphFixture,@{Mode='Bootstrap'},$false)
            $null=Complete-GraphFixture $engine
            $engine.RunFile($graphRunner,@{Action='Connect'},$true)
            $null=Complete-GraphFixture $engine
            foreach ($id in @('add-members-to-group','add-primary-devices-to-group')) {
                $engine.RunFile($graphRunner,@{Action='Run';WorkflowId=$id;ScriptPath=$graphFixture;ScriptArguments=@{}},$true)
                $events=@(Complete-GraphFixture $engine)
                $engine.HasErrors | Should Be $false
                (@($events | Where-Object Kind -eq 'Warning').Data -join ' ') | Should Match 'does not prove permission'
                (@($events | Where-Object Kind -eq 'Output').Data -join ' ') | Should Match 'Business fixture ran'
            }
            $engine.RunFile($graphRunner,@{Action='Run';WorkflowId='add-members-to-group';ScriptPath=$graphFixture;ScriptArguments=@{Mode='DeniedBusiness'}},$true)
            $events=@(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $true
            (@($events | Where-Object Kind -eq 'Error').Data -join ' ') | Should Match 'Synthetic target-group authorization denied'
        }
        finally { $engine.Dispose() }
    }
    It 'shares Home authentication across successive tasks and blocks an expired role before business execution' {
        $engine=[EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($graphFixture,@{Mode='Bootstrap'},$false)
            $null=Complete-GraphFixture $engine
            $engine.RunFile($graphRunner,@{Action='Connect'},$true)
            $events=@(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $false
            @($events | Where-Object Kind -eq 'GraphSession')[0].Data.State | Should Be 'Checked'
            for ($i=0; $i -lt 2; $i++) {
                $engine.RunFile($graphRunner,@{Action='Run';WorkflowId='intune-sync';ScriptPath=$graphFixture;ScriptArguments=@{}},$true)
                $null=Complete-GraphFixture $engine
                $engine.HasErrors | Should Be $false
            }
            $engine.RunFile($graphFixture,@{Mode='Expire'},$false)
            $null=Complete-GraphFixture $engine
            $engine.RunFile($graphRunner,@{Action='Run';WorkflowId='intune-sync';ScriptPath=$graphFixture;ScriptArguments=@{}},$true)
            $events=@(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $true
            @($events | Where-Object Kind -eq 'GraphSession')[-1].Data.State | Should Be 'Unverified'
            $engine.RunFile($graphFixture,@{Mode='Observe'},$false)
            $events=@(Complete-GraphFixture $engine)
            (@($events | Where-Object Kind -eq 'Output').Data -join ' ') | Should Match 'Connects=1;Runs=2'
            $engine.RunFile($graphFixture,@{Mode='Activate'},$false)
            $null=Complete-GraphFixture $engine
            $engine.RunFile($graphRunner,@{Action='Check'},$true)
            $events=@(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $false
            @($events | Where-Object Kind -eq 'GraphSession')[0].Data.State | Should Be 'Checked'
            $engine.RunFile($graphRunner,@{Action='Run';WorkflowId='intune-sync';ScriptPath=$graphFixture;ScriptArguments=@{}},$true)
            $null=Complete-GraphFixture $engine
            $engine.HasErrors | Should Be $false
            $engine.RunFile($graphFixture,@{Mode='Observe'},$false)
            $events=@(Complete-GraphFixture $engine)
            (@($events | Where-Object Kind -eq 'Output').Data -join ' ') | Should Match 'Connects=1;Runs=3'
            $engine.RunFile($graphRunner,@{Action='Disconnect'},$true)
            $events=@(Complete-GraphFixture $engine)
            @($events | Where-Object Kind -eq 'GraphSession')[0].Data.State | Should Be 'Disconnected'
            $engine.RunFile($graphRunner,@{Action='Check'},$true)
            $events=@(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $true
            @($events | Where-Object Kind -eq 'GraphSession')[-1].Data.State | Should Be 'Unverified'
        }
        finally { $engine.Dispose() }
    }
    It 'blocks a disconnected task before its script can prompt or make changes' {
        $engine=[EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($graphFixture,@{Mode='Bootstrap'},$false)
            $null=Complete-GraphFixture $engine
            $engine.RunFile($graphRunner,@{Action='Run';WorkflowId='intune-sync';ScriptPath=$graphFixture;ScriptArguments=@{}},$true)
            $events=@(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $true
            @($events | Where-Object Kind -eq 'Prompt').Count | Should Be 0
            $engine.RunFile($graphFixture,@{Mode='Observe'},$false)
            $events=@(Complete-GraphFixture $engine)
            (@($events | Where-Object Kind -eq 'Output').Data -join ' ') | Should Match 'Connects=0;Runs=0'
        }
        finally { $engine.Dispose() }
    }
    It 'blocks missing scopes, tenant mismatch, interactive identity changes and denied verification before business execution' {
        $engine=[EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($graphFixture,@{Mode='Bootstrap'},$false)
            $null=Complete-GraphFixture $engine
            $engine.RunFile($graphFixture,@{Mode='LimitConsent'},$false)
            $null=Complete-GraphFixture $engine
            $engine.RunFile($graphRunner,@{Action='Connect'},$true)
            $null=Complete-GraphFixture $engine
            $engine.RunFile($graphRunner,@{Action='Run';WorkflowId='intune-sync';ScriptPath=$graphFixture;ScriptArguments=@{}},$true)
            $events=@(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $true
            (@($events | Where-Object Kind -eq 'Error').Data -join ' ') | Should Match 'Missing delegated Graph scopes'
            $engine.RunFile($graphFixture,@{Mode='Bootstrap'},$false)
            $null=Complete-GraphFixture $engine
            $engine.RunFile($graphRunner,@{Action='Connect'},$true)
            $null=Complete-GraphFixture $engine
            $engine.RunFile($graphRunner,@{Action='Run';WorkflowId='intune-sync';RequiredTenant='other-tenant';ScriptPath=$graphFixture;ScriptArguments=@{}},$true)
            $events=@(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $true
            (@($events | Where-Object Kind -eq 'Error').Data -join ' ') | Should Match 'tenant'
            $engine.RunFile($graphRunner,@{Action='Run';WorkflowId='mobile-inventory';ScriptPath=$graphFixture;ScriptArguments=@{ForceInteractive=$true}},$true)
            $events=@(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $true
            (@($events | Where-Object Kind -eq 'Error').Data -join ' ') | Should Match 'ForceInteractive'
            $engine.RunFile($graphFixture,@{Mode='Forbidden'},$false)
            $null=Complete-GraphFixture $engine
            $engine.RunFile($graphRunner,@{Action='Run';WorkflowId='intune-sync';ScriptPath=$graphFixture;ScriptArguments=@{}},$true)
            $events=@(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $true
            @($events | Where-Object Kind -eq 'GraphSession')[-1].Data.State | Should Be 'Unverified'
            $engine.RunFile($graphFixture,@{Mode='Observe'},$false)
            $events=@(Complete-GraphFixture $engine)
            (@($events | Where-Object Kind -eq 'Output').Data -join ' ') | Should Match 'Connects=1;Runs=0'
        }
        finally { $engine.Dispose() }
    }
}
