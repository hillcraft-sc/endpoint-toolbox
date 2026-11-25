$desktop = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
$catalog = @(Get-EndpointCatalog)

function Test-RejectedInput {
    param([scriptblock]$Action)
    try { $null = & $Action; return $false } catch { return $true }
}

Describe 'Endpoint workflow catalog and binding' {
    It 'covers app workflows with consolidated deployment and group membership reports' {
        $catalog.Count | Should Be 28
        Test-EndpointCatalogCoverage $catalog
        @($catalog | Where-Object Id -eq 'group-devices').Count | Should Be 0
        @($catalog | Where-Object { $_.Path -like '*Get-Win32AppDeploymentStatus.ps1' }).Count | Should Be 1
        @($catalog.Id | Select-Object -Unique).Count | Should Be $catalog.Count
    }
    It 'preserves the legacy device-only group export as a standalone CLI' {
        $repository = Split-Path $desktop -Parent
        $path = Join-Path $repository 'Intune\Devices\Get-EntraGroupDevices.ps1'
        $baseline = ((& git -C $repository --no-pager show 'HEAD:Intune/Devices/Get-EntraGroupDevices.ps1') -join "`n").TrimStart([char]0xFEFF)
        if ($LASTEXITCODE -ne 0) { throw 'Cannot read committed device-only group export.' }
        (([IO.File]::ReadAllText($path)).TrimStart([char]0xFEFF) -replace '\r\n?', "`n").TrimEnd() | Should Be $baseline.TrimEnd()
        @($catalog | Where-Object FullPath -eq $path).Count | Should Be 0
    }
    It 'keeps business scripts free of UI parameters' {
        foreach ($workflow in $catalog) {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($workflow.FullPath, [ref]$tokens, [ref]$errors)
            $errors.Count | Should Be 0
            ($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'UiEventSink') | Should Be $false
        }
    }
    It 'binds literal arrays and omits inactive parameter sources' {
        $workflow = $catalog | Where-Object Id -eq 'device-usage'
        $arguments = Get-EndpointArguments $workflow @{ Devices = "PC-1`nPC-2"; LookbackDays = '30' } @('EntraGroup','DeviceListPath')
        $arguments.Devices.Count | Should Be 2
        $arguments.LookbackDays | Should Be 30
        $arguments.ContainsKey('EntraGroup') | Should Be $false
    }
    It 'requires a target in scoped discovered-app runs and omits values from other scopes' {
        $workflow = $catalog | Where-Object Id -eq 'discovered-apps'
        $values = @{ Platform='Windows'; Device=' Fixture-PC '; EntraGroup='Fixture Group' }
        $single = Get-EndpointArguments $workflow $values @('EntraGroup')
        $single.Device | Should Be 'Fixture-PC'
        $single.ContainsKey('EntraGroup') | Should Be $false
        $group = Get-EndpointArguments $workflow $values @('Device')
        $group.EntraGroup | Should Be 'Fixture Group'
        $group.ContainsKey('Device') | Should Be $false
        $all = Get-EndpointArguments $workflow $values @('Device','EntraGroup')
        $all.ContainsKey('Device') | Should Be $false
        $all.ContainsKey('EntraGroup') | Should Be $false
        (Test-RejectedInput { Get-EndpointArguments $workflow @{Platform='Windows'} @('EntraGroup') }) | Should Be $true
        (Test-RejectedInput { Get-EndpointArguments $workflow @{Platform='Windows'} @('Device') }) | Should Be $true
    }
    It 'distinguishes default Confirm from explicit false and preserves WhatIf' {
        $workflow = $catalog | Where-Object Id -eq 'primary-users'
        $arguments = Get-EndpointArguments $workflow @{ Devices = 'PC-1'; Confirm = 'Script default'; WhatIf = $true } @('GroupName','ManagedDeviceId','DeviceListPath')
        $arguments.ContainsKey('Confirm') | Should Be $false
        $arguments.WhatIf | Should Be $true
        $arguments = Get-EndpointArguments $workflow @{ Devices = 'PC-1'; Confirm = 'Suppress ShouldProcess prompts' } @('GroupName','ManagedDeviceId','DeviceListPath')
        $arguments.ContainsKey('Confirm') | Should Be $true
        $arguments.Confirm | Should Be $false
    }
    It 'rejects switch dependencies and unsafe numeric inputs' {
        $workflow = $catalog | Where-Object Id -eq 'entra-cleanup'
        (Test-RejectedInput { Get-EndpointArguments $workflow @{ Devices='PC-1'; AutoDeleteAutopilot=$true } @('DeviceListPath') }) | Should Be $true
        $workflow = $catalog | Where-Object Id -eq 'stale-synced-devices'
        (Test-RejectedInput { Get-EndpointArguments $workflow @{ Days='0' } }) | Should Be $true
        (Test-RejectedInput { Get-EndpointArguments $workflow @{ Days='3651' } }) | Should Be $true
        $workflow = $catalog | Where-Object Id -eq 'user-sign-in-history'
        (Test-RejectedInput { Get-EndpointArguments $workflow @{ UserIdentity='fixture@example.invalid'; LookbackDays='0' } }) | Should Be $true
        (Test-RejectedInput { Get-EndpointArguments $workflow @{ UserIdentity='fixture@example.invalid'; LookbackDays='31' } }) | Should Be $true
        (Get-EndpointArguments $workflow @{ UserIdentity='fixture@example.invalid'; LookbackDays='1'; FailuresOnly=$true }).FailuresOnly | Should Be $true
    }
    It 'binds one explicit member source in the combined add workflow without an embedded option' {
        $workflow = $catalog | Where-Object Id -eq 'add-members-to-group'
        $options = ($workflow.Selectors | Where-Object Label -eq 'Members to add').Options
        @($options | Where-Object { -not $_.Parameters }).Count | Should Be 0
        $group = [guid]::NewGuid()
        $inactive = @('GroupName','Users','UserListPath','UserColumn','DeviceListPath')
        $arguments = Get-EndpointArguments $workflow @{ GroupId=$group; DeviceNames="PC-1`nPC-2"; Users='ignored@example.invalid' } $inactive
        $arguments.DeviceNames.Count | Should Be 2
        $arguments.ContainsKey('Users') | Should Be $false
        (Test-RejectedInput { Get-EndpointArguments $workflow @{ GroupId=$group } $inactive }) | Should Be $true
        (Test-RejectedInput { Get-EndpointArguments $workflow @{ GroupId=$group; Users='user@example.invalid'; DeviceNames='PC-1' } }) | Should Be $true
        ($workflow.Fields.Name -contains 'WhatIf') | Should Be $false
    }
    It 'binds removal only for the chosen group and member source' {
        $workflow = $catalog | Where-Object Id -eq 'remove-members-from-group'
        $inactive = @('GroupId','Users','UserListPath','UserColumn','DeviceListPath')
        $arguments = Get-EndpointArguments $workflow @{ GroupName='Fixture Group'; DeviceNames="Fixture-PC`nOther-PC"; Users='ignored@example.invalid'; WhatIf=$true } $inactive
        $arguments.DeviceNames.Count | Should Be 2
        $arguments.WhatIf | Should Be $true
        $arguments.ContainsKey('Users') | Should Be $false
        (Test-RejectedInput { Get-EndpointArguments $workflow @{ GroupName='Fixture Group' } $inactive }) | Should Be $true
    }
    It 'uses the agreed explicit UI output default for multi-app exports' {
        $workflow = $catalog | Where-Object Id -eq 'intune-assignment-win32-deployment-exports'
        ($workflow.Fields | Where-Object Name -eq 'OutputPath').Default | Should Be (Join-Path $env:TEMP 'endpoint-toolbox')
    }
    It 'keeps remote DNS and Cloud Update group settings out of workflow forms' {
        $remote = $catalog | Where-Object Id -eq 'remote-endpoint'
        ($remote.Fields.Name -contains 'DnsSuffix') | Should Be $false
        $remoteAst = [Management.Automation.Language.Parser]::ParseFile($remote.FullPath, [ref]$null, [ref]$null)
        ($remoteAst.ParamBlock.Parameters.Name.VariablePath.UserPath -contains 'DnsSuffix') | Should Be $true

        $cloud = $catalog | Where-Object Id -eq 'm365-cloud-update'
        ($cloud.Fields.Name -contains 'WaveGroupNames') | Should Be $false
        $cloudAst = [Management.Automation.Language.Parser]::ParseFile($cloud.FullPath, [ref]$null, [ref]$null)
        $scriptDefault = [string[]](($cloudAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'WaveGroupNames' }).DefaultValue.SafeGetValue())
        $scriptDefault.Count | Should Be 0
        (Get-EndpointArguments $cloud @{IncludeWaveGroups=$true}).ContainsKey('WaveGroupNames') | Should Be $false
    }
    It 'rejects incomplete future catalog integrations' {
        (Test-RejectedInput { Test-EndpointCatalogCoverage @($catalog | Where-Object Id -ne 'remote-endpoint') }) | Should Be $true
    }
    It 'redacts credential-bearing URLs and bearer tokens' {
        (Protect-EndpointText 'https://example.invalid/?token=synthetic-secret&sig=synthetic-signature') | Should Not Match 'synthetic-'
        (Protect-EndpointText 'Bearer synthetic.token.value') | Should Not Match 'synthetic.token'
    }
    It 'preserves committed authentication, Graph request and original parameter contracts' {
        $repository = Split-Path $desktop -Parent
        foreach ($workflow in $catalog) {
            # New workflows have no pre-existing CLI contract; their offline suites cover them.
            if ($workflow.Id -in @('create-direct-reports-group','intune-script-device-status','remove-members-from-group','add-members-to-group','entra-user-lookup','get-entra-group-members','device-investigation','app-install-investigation','cloudpc-inventory','compare-win32-runs','user-sign-in-history','wufb-report')) { continue }
            $objectPath = 'HEAD:' + $workflow.Path.Replace('\', '/')
            $baseline = ((& git -C $repository --no-pager show $objectPath) -join "`n").TrimStart([char]0xFEFF)
            if ($LASTEXITCODE -ne 0) { throw "Cannot read committed baseline for $($workflow.Id)." }
            $tokens = $null; $errors = $null
            $before = [Management.Automation.Language.Parser]::ParseInput($baseline,[ref]$tokens,[ref]$errors)
            if ($errors.Count) { throw "Committed baseline does not parse for $($workflow.Id)." }
            $after = [Management.Automation.Language.Parser]::ParseFile($workflow.FullPath,[ref]$tokens,[ref]$errors)
            $addedParameters = switch ($workflow.Id) {
                'quality-updates' { @('PolicyId', 'ListPolicies'); break }
                'discovered-apps' { @('Device'); break }
                'remote-endpoint' { @('DnsSuffix'); break }
                'm365-cloud-update' { @('IncludeWaveGroups', 'WaveGroupNames'); break }
                default { @() }
            }
            $beforeParameters = @($before.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -notin $addedParameters } |
                ForEach-Object { "$($_.Name.VariablePath.UserPath):$($_.StaticType):$($_.DefaultValue.Extent.Text)" })
            $afterParameters = @($after.ParamBlock.Parameters | Where-Object {
                $_.Name.VariablePath.UserPath -ne 'UiEventSink' -and
                $_.Name.VariablePath.UserPath -notin $addedParameters
            } | ForEach-Object { "$($_.Name.VariablePath.UserPath):$($_.StaticType):$($_.DefaultValue.Extent.Text)" })
            if ($workflow.Id -ne 'intune-assignment-win32-deployment-exports' -and @(Compare-Object $beforeParameters $afterParameters).Count) { throw "Original parameter contract changed for $($workflow.Id)." }
            $commands = @('Connect-MgGraph','Disconnect-MgGraph','Get-MgContext','Invoke-MgGraphRequest','New-PSSession','Enter-PSSession','Get-Credential')
            # Optional Cloud Update enrichment adds Graph reads; its default path is covered offline.
            if ($workflow.Id -eq 'm365-cloud-update') { $commands = @($commands | Where-Object { $_ -notin @('Get-MgContext','Invoke-MgGraphRequest') }) }
            $beforeCalls = @($before.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in $commands},$true) | ForEach-Object { $_.Extent.Text -replace '\r\n?', "`n" })
            $afterCalls = @($after.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in $commands},$true) | ForEach-Object { $_.Extent.Text -replace '\r\n?', "`n" })
            if ($workflow.Id -eq 'intune-assignment-win32-deployment-exports') {
                # Optional device context adds one specific managed-device read.
                $contextRead = 'Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$id`?`$select=id,osVersion,lastSyncDateTime" -OutputType Hashtable -ErrorAction Stop'
                $beforeCalls = @($beforeCalls | Where-Object { $_ -cne $contextRead })
                $afterCalls = @($afterCalls | Where-Object { $_ -cne $contextRead })
            }
            if ($workflow.Id -eq 'remote-endpoint') {
                # The credential prompt message is intentionally organization-neutral.
                $beforeCalls = @($beforeCalls | ForEach-Object {
                    if ($_ -cmatch "^Get-Credential -Message '[^']*' -Title 'Credentials Needed for Elevation\.\.\.'$") {
                        "Get-Credential -Message 'Enter device administrator credentials' -Title 'Credentials Needed for Elevation...'"
                    } else { $_ }
                })
            }
            if ($workflow.Id -in @('add-members-to-group','entra-user-lookup','add-primary-devices-to-group')) {
                $beforeCalls = @($beforeCalls | Where-Object { $_ -notmatch '^\s*Connect-MgGraph\b' })
                $afterCalls = @($afterCalls | Where-Object { $_ -notmatch '^\s*Connect-MgGraph\b' })
                $source = [IO.File]::ReadAllText($workflow.FullPath)
                if ($source -match '(?im)^\s*\$tenantId\s*=\s*[''"][0-9a-f-]{36}[''"]' -or
                    $source -match '(?im)\bConnect-MgGraph\b[^\r\n]*-TenantId\s+[''"][^''"]+[''"]') {
                    throw "Tenant-specific sign-in value remains in $($workflow.Id)."
                }
            }
            if (@(Compare-Object $beforeCalls $afterCalls).Count) { throw "Authentication or service request contract changed for $($workflow.Id)." }
            if ($workflow.Id -notin @('entra-cleanup','intune-assignment-win32-deployment-exports','delete-win32-apps','intune-sync','device-usage','all-device-assignments','group-app-assignments','m365-cloud-update','quality-updates','remote-endpoint','discovered-apps','add-primary-devices-to-group')) {
                $current = ([IO.File]::ReadAllText($workflow.FullPath)).TrimStart([char]0xFEFF) -replace '\r\n?', "`n"
                if ($current.TrimEnd() -cne $baseline.TrimEnd()) { throw "Original business script was changed: $($workflow.Id)." }
            }
        }
    }
    It 'keeps preview explicit and binds the consolidated report user-status default both ways' {
        foreach ($workflow in @($catalog | Where-Object { $_.Fields.Name -contains 'WhatIf' })) {
            ($workflow.Fields | Where-Object Name -eq 'WhatIf').Default | Should Be $false
        }
        $workflow = $catalog | Where-Object Id -eq 'intune-assignment-win32-deployment-exports'
        ($workflow.Fields | Where-Object Name -eq 'AppName').Type | Should Be ([string[]])
        ($workflow.Fields | Where-Object Name -eq 'IncludeUserStatus').Default | Should Be $true
        (Get-EndpointArguments $workflow @{AppName='Chrome';IncludeUserStatus=$false}).IncludeUserStatus | Should Be $false
        (Get-EndpointArguments $workflow @{AppName='Chrome';IncludeUserStatus=$true}).IncludeUserStatus | Should Be $true
        (Get-EndpointArguments $workflow @{AppName='Chrome'}).ContainsKey('IncludeUserStatus') | Should Be $false
    }
    It 'catalogs script status as a read-only Graph report with script discovery defaults' {
        $workflow = $catalog | Where-Object Id -eq 'intune-script-device-status'
        $manifest = Import-PowerShellDataFile (Join-Path $desktop 'WorkflowCatalog.psd1')
        $entry = $manifest.Workflows | Where-Object Id -eq 'intune-script-device-status'
        $workflow.Path | Should Be 'Intune\Devices\Get-IntuneScriptDeviceStatus.ps1'
        $workflow.Risk | Should Be 'Read only'
        (@($entry.GraphScopes) -contains 'DeviceManagementScripts.Read.All') | Should Be $true
        ((($workflow.Fields | Where-Object Name -eq 'ScriptType').Choices) -contains 'Remediation') | Should Be $true
        ($workflow.Fields | Where-Object Name -eq 'ScriptType').Default | Should Be 'All'
        @($workflow.Fields | Where-Object Name -in @('ScriptName','ScriptId','ListScripts')).Count | Should Be 0
        @($entry.HiddenParameters | Where-Object { $_ -in @('ScriptName','ScriptId','ListScripts') }).Count | Should Be 3
        ($workflow.Fields | Where-Object Name -eq 'OutputPath').Default | Should Be (Join-Path $env:TEMP 'endpoint-toolbox')
    }
    It 'binds one group source and optional expansion without a member-type selector' {
        $workflow = $catalog | Where-Object Id -eq 'get-entra-group-members'
        $workflow.Path | Should Be 'entra\Get-EntraGroupMembers.ps1'
        $workflow.Risk | Should Be 'Read only'
        ($workflow.Fields | Where-Object Name -eq 'GroupName').Required | Should Be $true
        (Get-EndpointArguments $workflow @{ GroupName = 'Fixture Group' } @('GroupId')).GroupName | Should Be 'Fixture Group'
        ($workflow.Fields | Where-Object Name -eq 'ExpandNestedGroups').Default | Should Be $false
        $arguments = Get-EndpointArguments $workflow @{GroupId='00000000-0000-0000-0000-000000000001';ExpandNestedGroups=$true} @('GroupName')
        $arguments.GroupId | Should Be '00000000-0000-0000-0000-000000000001'
        $arguments.ExpandNestedGroups | Should Be $true
        $arguments.ContainsKey('GroupName') | Should Be $false
        @($workflow.Selectors).Count | Should Be 1
        ($workflow.Fields.Name -contains 'MemberType') | Should Be $false
        (Test-RejectedInput { Get-EndpointArguments $workflow @{} }) | Should Be $true
    }
    It 'catalogs the read-only Cloud PC inventory with its own Graph permission' {
        $workflow = $catalog | Where-Object Id -eq 'cloudpc-inventory'
        $entry = (Import-PowerShellDataFile (Join-Path $desktop 'WorkflowCatalog.psd1')).Workflows | Where-Object Id -eq 'cloudpc-inventory'
        $workflow.Path | Should Be 'Intune\Devices\Get-IntuneCloudPCs.ps1'
        $workflow.Risk | Should Be 'Read only'
        $entry.GraphScopes.Count | Should Be 1
        $entry.GraphScopes[0] | Should Be 'CloudPC.Read.All'
        $workflow.Fields.Count | Should Be 0
    }
    It 'binds a required exact device investigation search and its choices' {
        $workflow = $catalog | Where-Object Id -eq 'device-investigation'
        $workflow.Risk | Should Be 'Read only'
        ($workflow.Fields | Where-Object Name -eq 'SearchBy').Default | Should Be 'Device name'
        ((Get-EndpointArguments $workflow @{SearchBy='Serial number';SearchValue='SYNTHETIC'}).SearchValue) | Should Be 'SYNTHETIC'
        (Test-RejectedInput { Get-EndpointArguments $workflow @{SearchBy='User UPN'} }) | Should Be $true
        (Test-RejectedInput { Get-EndpointArguments $workflow @{SearchBy='Other';SearchValue='SYNTHETIC'} }) | Should Be $true
    }
    It 'binds both exact app investigation searches and rejects incomplete forms' {
        $workflow = $catalog | Where-Object Id -eq 'app-install-investigation'
        ($workflow.Fields | Where-Object Name -eq 'DeviceSearchBy').Default | Should Be 'Device name'
        ($workflow.Fields | Where-Object Name -eq 'AppSearchBy').Default | Should Be 'App name'
        $values = @{DeviceSearchBy='Device name';DeviceSearchValue=' Fixture-PC ';AppSearchBy='App name';AppSearchValue=' Fixture App '}
        $arguments = Get-EndpointArguments $workflow $values
        $arguments.DeviceSearchValue | Should Be 'Fixture-PC'
        $arguments.AppSearchValue | Should Be 'Fixture App'
        $values.AppSearchValue = ''
        (Test-RejectedInput { Get-EndpointArguments $workflow $values }) | Should Be $true
        $values.AppSearchValue = 'Fixture App'
        $values.DeviceSearchBy = 'Serial'
        (Test-RejectedInput { Get-EndpointArguments $workflow $values }) | Should Be $true
    }
}
