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
    It 'requires Graph reader preflight for WUfB only when name resolution is explicitly enabled' {
        (Test-GraphRejected { Get-EndpointGraphPolicy wufb-report }) | Should Be $true
        (Test-GraphRejected { Get-EndpointGraphPolicy wufb-report @{ResolveDeviceNames=$false} }) | Should Be $true
        $policy = Get-EndpointGraphPolicy wufb-report @{ResolveDeviceNames=$true}
        ($policy.Scopes -join ',') | Should Be 'Device.Read.All'
        $session = [pscustomobject]@{State='Checked';TenantId='fixture-tenant';Scopes=@('Device.Read.All');Roles=@('Global Reader')}
        Assert-EndpointGraphAccess $session $policy
        $session.Scopes = @('User.Read')
        (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy }) | Should Be $true
        $session.Scopes = @('Device.Read.All'); $session.Roles = @()
        (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy }) | Should Be $true
    }
    It 'allows supported sign-in readers only with both required delegated scopes' {
        $policy = Get-EndpointGraphPolicy user-sign-in-history
        ($policy.Scopes -contains 'AuditLog.Read.All') | Should Be $true
        ($policy.Scopes -contains 'User.Read.All') | Should Be $true
        foreach ($role in @('Global Reader','Reports Reader','Security Reader','Security Operator','Security Administrator')) {
            $session = [pscustomobject]@{ State='Checked'; TenantId='fixture-tenant'; Scopes=$policy.Scopes; Roles=@($role) }
            Assert-EndpointGraphAccess $session $policy
        }
        $session.Roles = @('Intune Administrator')
        (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy }) | Should Be $true
        $session.Roles = @('Reports Reader'); $session.Scopes = @('AuditLog.Read.All')
        (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy }) | Should Be $true
    }
    It 'preserves the original sign-in access policy in paged mode' {
        $policy = Get-EndpointGraphPolicy user-sign-in-history @{ReportMode='Paged events'}
        ($policy.Scopes | Sort-Object) -join ',' | Should Be 'AuditLog.Read.All,User.Read.All'
        foreach ($role in @('Global Reader','Security Operator','Reports Reader','Security Reader','Security Administrator','Global Administrator')) {
            $session = [pscustomobject]@{ State='Checked'; TenantId='fixture-tenant'; Scopes=$policy.Scopes; Roles=@($role) }
            Assert-EndpointGraphAccess $session $policy
        }
        $session.Roles = @('Intune Administrator')
        (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy }) | Should Be $true
        $session.Roles = @('Global Reader'); $session.Scopes = @('AuditLog.Read.All')
        (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy }) | Should Be $true
    }
    It 'recognizes active built-in sign-in roles in live role verification' {
        & {
            . $graphFixture -Mode Bootstrap
            try {
                & $graphRunner -Action Connect
                foreach ($role in @(
                    @{ Id='4a5d8f65-41da-4de4-8968-e035b65339cf'; Name='Reports Reader' }
                    @{ Id='5d6b6bb7-de71-4623-b4af-96380a352509'; Name='Security Reader' }
                    @{ Id='5f2222b1-57c3-48ba-8ad5-d4759f1fde6f'; Name='Security Operator' }
                    @{ Id='194ae4cb-b126-40b2-bd5b-6091b380977d'; Name='Security Administrator' }
                )) {
                    $global:GraphFixture.Role = $role.Id
                    $session = Get-EndpointGraphSession
                    ($session.Roles -contains $role.Name) | Should Be $true
                    Assert-EndpointGraphAccess $session (Get-EndpointGraphPolicy user-sign-in-history)
                }
            }
            finally {
                foreach ($name in @('Get-MgContext','Connect-MgGraph','Disconnect-MgGraph','Invoke-MgGraphRequest')) { Remove-Item -LiteralPath "Function:\$name" -ErrorAction Ignore }
                Remove-Variable -Name GraphFixture -Scope Global -ErrorAction Ignore
            }
        }
    }
    It 'requires Cloud PC read consent for the Cloud PC inventory' {
        $policy = Get-EndpointGraphPolicy cloudpc-inventory
        $policy.Scopes.Count | Should Be 1
        $policy.Scopes[0] | Should Be 'CloudPC.Read.All'
        ($policy.RoleGroups[0].AnyOf -contains 'Global Reader') | Should Be $true
    }
    It 'accepts existing Cloud PC read or read-write consent without accepting unrelated scopes' {
        $policy = Get-EndpointGraphPolicy cloudpc-inventory
        $session = [pscustomobject]@{ State='Checked'; TenantId='fixture-tenant'; Scopes=@('CloudPC.Read.All'); Roles=@('Global Reader') }
        Assert-EndpointGraphAccess $session $policy
        $session.Scopes = @('CloudPC.ReadWrite.All')
        Assert-EndpointGraphAccess $session $policy
        $session.Scopes = @('DeviceManagementManagedDevices.Read.All')
        $message = ''
        try { Assert-EndpointGraphAccess $session $policy } catch { $message = $_.Exception.Message }
        $message | Should Match 'CloudPC.Read.All \(or CloudPC.ReadWrite.All\)'
        $session.Scopes = @()
        (Test-GraphRejected { Assert-EndpointGraphAccess $session $policy }) | Should Be $true
    }
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
    It 'clears existing authentication before explicit reconnect but leaves checks connected' {
        & {
            . $graphFixture -Mode Bootstrap
            try {
                & $graphRunner -Action Connect -TenantId 'fixture-tenant'
                $global:GraphFixture.Disconnects | Should Be 0
                & $graphRunner -Action Check
                ($global:GraphFixture.AuthCalls -join ',') | Should Be 'Connect'
                & $graphRunner -Action Connect -TenantId 'fixture-tenant'
                ($global:GraphFixture.AuthCalls -join ',') | Should Be 'Connect,Disconnect,Connect'
                $global:GraphFixture.Disconnects | Should Be 1
                $global:GraphFixture.Context.TenantId | Should Be 'fixture-tenant'
                $global:GraphFixture.RequestedScopes[0] | Should Be 'https://graph.microsoft.com/.default'
            }
            finally {
                foreach ($name in @('Get-MgContext','Connect-MgGraph','Disconnect-MgGraph','Invoke-MgGraphRequest')) { Remove-Item -LiteralPath "Function:\$name" -ErrorAction Ignore }
                Remove-Variable -Name GraphFixture -Scope Global -ErrorAction Ignore
            }
        }
    }
    It 'blocks reconnect and marks access unverified when clearing authentication fails' {
        & {
            . $graphFixture -Mode Bootstrap
            try {
                & $graphRunner -Action Connect
                $global:GraphFixture.DisconnectFailure = $true
                $events = [Collections.Generic.List[object]]::new()
                $message = ''
                try { & $graphRunner -Action Connect -UiEventSink { param($event) $events.Add($event) } }
                catch { $message = $_.Exception.Message }
                $message | Should Match 'Synthetic Graph sign-out failure'
                $global:GraphFixture.Connects | Should Be 1
                $events.Count | Should Be 1
                $events[0].Data.State | Should Be 'Unverified'
                $events[0].Data.Roles.Count | Should Be 0
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
    It 'requires directory read access and a reader role for the group member report' {
        $policy = Get-EndpointGraphPolicy get-entra-group-members
        ($policy.Scopes -contains 'Directory.Read.All') | Should Be $true
        ($policy.Scopes -contains 'GroupMember.ReadWrite.All') | Should Be $false
        ($policy.RoleGroups[0].AnyOf -contains 'Global Reader') | Should Be $true
    }
    It 'requires read-only Intune, Entra, primary-user and Autopilot scopes for device investigation' {
        $policy = Get-EndpointGraphPolicy device-investigation
        foreach ($scope in @('DeviceManagementManagedDevices.Read.All','Device.Read.All','User.Read.All','DeviceManagementServiceConfig.Read.All')) {
            ($policy.Scopes -contains $scope) | Should Be $true
        }
        @($policy.Scopes | Where-Object { $_ -like '*ReadWrite*' }).Count | Should Be 0
        ($policy.RoleGroups[0].AnyOf -contains 'Global Reader') | Should Be $true
    }
    It 'requires only reader authorization for app installation evidence' {
        $policy = Get-EndpointGraphPolicy app-install-investigation
        foreach ($scope in @('DeviceManagementManagedDevices.Read.All','DeviceManagementApps.Read.All','Group.Read.All','DeviceManagementConfiguration.Read.All')) {
            ($policy.Scopes -contains $scope) | Should Be $true
        }
        @($policy.Scopes | Where-Object { $_ -like '*ReadWrite*' }).Count | Should Be 0
        ($policy.RoleGroups[0].AnyOf -contains 'Global Reader') | Should Be $true
    }
    It 'requires managed-device read scope only when Win32 triage device context is enabled' {
        $id = 'intune-assignment-win32-deployment-exports'
        ((Get-EndpointGraphPolicy $id).Scopes -contains 'DeviceManagementManagedDevices.Read.All') | Should Be $false
        ((Get-EndpointGraphPolicy $id @{IncludeDeviceContext=$true}).Scopes -contains 'DeviceManagementManagedDevices.Read.All') | Should Be $true
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

Describe 'Cloud PC history preflight' {
    It 'publishes selected Cloud PC history in the existing authenticated worker' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.Host.PrepareReportTables = $true
            $engine.RunFile($graphFixture, @{Mode='Bootstrap'}, $false)
            $null = Complete-GraphFixture $engine
            $engine.RunFile($graphRunner, @{Action='Connect'}, $true)
            $null = Complete-GraphFixture $engine
            $engine.RunFile($graphFixture, @{Mode='CloudPcHistory'}, $false)
            $null = Complete-GraphFixture $engine
            $engine.RunFile($graphRunner, @{
                Action='CloudPcHistory';CloudPcId='00000000-0000-0000-0000-000000000001'
                CloudPcName='Fixture';InventoryTenant='fixture-tenant'
            }, $true)
            $events = @(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $false
            @($events | Where-Object Kind -eq 'Rows')[0].Data.Table.Rows.Count | Should Be 1
            @($events | Where-Object Kind -eq 'ReportVisual')[0].Data.Count | Should Be 4
            $engine.RunFile($graphFixture, @{Mode='Observe'}, $false)
            $events = @(Complete-GraphFixture $engine)
            (@($events | Where-Object Kind -eq 'Output').Data -join ' ') | Should Match 'Connects=1'
        }
        finally { $engine.Dispose() }
    }

    It 'rejects missing existing consent and a changed tenant without reconnecting' {
        & {
            . $graphFixture -Mode Bootstrap
            try {
                & $graphRunner -Action Connect
                $global:GraphFixture.Context.Scopes = @('User.Read','RoleManagement.Read.Directory')
                $arguments = @{Action='CloudPcHistory';CloudPcId='00000000-0000-0000-0000-000000000001';CloudPcName='Fixture';InventoryTenant='fixture-tenant'}
                $message = ''
                try { & $graphRunner @arguments } catch { $message = $_.Exception.Message }
                $message | Should Match 'CloudPC.Read.All'
                $global:GraphFixture.Context.Scopes += 'CloudPC.Read.All'
                $arguments.InventoryTenant = 'other-tenant'
                $message = ''
                try { & $graphRunner @arguments } catch { $message = $_.Exception.Message }
                $message | Should Match 'tenant no longer matches'
                $global:GraphFixture.Connects | Should Be 1
                $global:GraphFixture.RequestedScopes[0] | Should Be 'https://graph.microsoft.com/.default'
            }
            finally {
                foreach ($name in @('Get-MgContext','Connect-MgGraph','Disconnect-MgGraph','Invoke-MgGraphRequest')) { Remove-Item -LiteralPath "Function:\$name" -ErrorAction Ignore }
                Remove-Variable -Name GraphFixture -Scope Global -ErrorAction Ignore
            }
        }
    }
}

Describe 'Persistent sign-in continuation' {
    It 'continues sign-in pages in the same worker without reconnecting or requesting scopes' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.Host.PrepareReportTables = $true
            $engine.RunFile($graphFixture, @{Mode='Bootstrap'}, $false)
            $null = Complete-GraphFixture $engine
            $engine.RunFile($graphRunner, @{Action='Connect'}, $true)
            $null = Complete-GraphFixture $engine
            $engine.RunFile($graphFixture, @{Mode='SignInPages'}, $false)
            $null = Complete-GraphFixture $engine
            $invocation = @{
                Action='Run'; WorkflowId='user-sign-in-history'
                ScriptPath=(Join-Path (Split-Path $desktop -Parent) 'entra\Get-EntraUserSignInHistory.ps1')
                ScriptArguments=@{UserIdentity='fixture@example.invalid';LookbackDays=1;ReportMode='Paged events'}
            }
            $engine.RunFile($graphRunner, $invocation, $true)
            $events = @(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $false
            @($events | Where-Object Kind -eq 'Rows')[0].Data.Table.Rows.Count | Should Be 1
            @($events | Where-Object Name -eq 'Sign-in paging')[0].Data.HasMore | Should Be $true
            $firstPageId = @($events | Where-Object Name -eq 'Sign-in paging')[0].Data.ContinuationId
            [string]::IsNullOrWhiteSpace($firstPageId) | Should Be $false
            $invocation.SignInAction = 'More'
            $invocation.SignInContinuationId = $firstPageId
            $engine.RunFile($graphRunner, $invocation, $true)
            $events = @(Complete-GraphFixture $engine)
            $engine.HasErrors | Should Be $false
            @($events | Where-Object Kind -eq 'Rows')[0].Data.Table.Rows.Count | Should Be 2
            @($events | Where-Object Name -eq 'Sign-in paging')[0].Data.HasMore | Should Be $false
            # Simulate cancellation after the worker completed, before the UI committed that page.
            foreach ($retry in 1..2) {
                $engine.RunFile($graphRunner, $invocation, $true)
                $events = @(Complete-GraphFixture $engine)
                $engine.HasErrors | Should Be $false
                @($events | Where-Object Kind -eq 'Rows')[0].Data.Table.Rows.Count | Should Be 2
                @($events | Where-Object Name -eq 'Sign-in paging')[0].Data.HasMore | Should Be $false
                @($events | Where-Object Name -eq 'Sign-in paging')[0].Data.ContinuationId | Should Not Be $firstPageId
            }
            $engine.RunFile($graphFixture, @{Mode='Observe'}, $false)
            $events = @(Complete-GraphFixture $engine)
            (@($events | Where-Object Kind -eq 'Output').Data -join ' ') | Should Match 'Connects=1'
        }
        finally { $engine.Dispose() }
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
