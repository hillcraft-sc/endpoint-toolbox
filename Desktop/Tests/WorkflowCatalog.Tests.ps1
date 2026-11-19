# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

$desktop = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
$catalog = @(Get-EndpointCatalog)

function Test-RejectedInput {
    param([scriptblock]$Action)
    try { $null = & $Action; return $false } catch { return $true }
}

Describe 'Endpoint workflow catalog and binding' {
    It 'covers every business script with one consolidated deployment report' {
        $catalog.Count | Should Be 22
        Test-EndpointCatalogCoverage $catalog
        @($catalog | Where-Object { $_.Path -like '*Get-Win32AppDeploymentStatus.ps1' }).Count | Should Be 1
        @($catalog.Id | Select-Object -Unique).Count | Should Be $catalog.Count
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
        ($workflow.Fields | Where-Object Name -eq 'OutputPath').Default | Should Be $env:TEMP
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
            if ($workflow.Id -in @('create-direct-reports-group','intune-script-device-status','remove-members-from-group','add-members-to-group','entra-user-lookup')) { continue }
            $objectPath = 'HEAD:' + $workflow.Path.Replace('\', '/')
            $baseline = ((& git -C $repository --no-pager show $objectPath) -join "`n").TrimStart([char]0xFEFF)
            if ($LASTEXITCODE -ne 0) { throw "Cannot read committed baseline for $($workflow.Id)." }
            $tokens = $null; $errors = $null
            $before = [Management.Automation.Language.Parser]::ParseInput($baseline,[ref]$tokens,[ref]$errors)
            if ($errors.Count) { throw "Committed baseline does not parse for $($workflow.Id)." }
            $after = [Management.Automation.Language.Parser]::ParseFile($workflow.FullPath,[ref]$tokens,[ref]$errors)
            $addedParameters = if ($workflow.Id -eq 'quality-updates') { @('PolicyId', 'ListPolicies') } else { @() }
            $beforeParameters = @($before.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -notin $addedParameters } |
                ForEach-Object { "$($_.Name.VariablePath.UserPath):$($_.StaticType):$($_.DefaultValue.Extent.Text)" })
            $afterParameters = @($after.ParamBlock.Parameters | Where-Object {
                $_.Name.VariablePath.UserPath -ne 'UiEventSink' -and
                $_.Name.VariablePath.UserPath -notin $addedParameters -and
                -not ($workflow.Id -eq 'm365-cloud-update' -and $_.Name.VariablePath.UserPath -in @('IncludeWaveGroups','WaveGroupNames'))
            } | ForEach-Object { "$($_.Name.VariablePath.UserPath):$($_.StaticType):$($_.DefaultValue.Extent.Text)" })
            if ($workflow.Id -ne 'intune-assignment-win32-deployment-exports' -and @(Compare-Object $beforeParameters $afterParameters).Count) { throw "Original parameter contract changed for $($workflow.Id)." }
            $commands = @('Connect-MgGraph','Disconnect-MgGraph','Get-MgContext','Invoke-MgGraphRequest','New-PSSession','Enter-PSSession','Get-Credential')
            # Optional Cloud Update enrichment adds Graph reads; its default path is covered offline.
            if ($workflow.Id -eq 'm365-cloud-update') { $commands = @($commands | Where-Object { $_ -notin @('Get-MgContext','Invoke-MgGraphRequest') }) }
            $beforeCalls = @($before.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in $commands},$true) | ForEach-Object { $_.Extent.Text -replace '\r\n?', "`n" })
            $afterCalls = @($after.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in $commands},$true) | ForEach-Object { $_.Extent.Text -replace '\r\n?', "`n" })
            if (@(Compare-Object $beforeCalls $afterCalls).Count) { throw "Authentication or service request contract changed for $($workflow.Id)." }
            if ($workflow.Id -notin @('entra-cleanup','intune-assignment-win32-deployment-exports','delete-win32-apps','intune-sync','device-usage','all-device-assignments','group-app-assignments','m365-cloud-update','quality-updates')) {
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
        ($workflow.Fields | Where-Object Name -eq 'OutputPath').Default | Should Be $env:TEMP
    }
}
