# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

$desktop = Split-Path $PSScriptRoot -Parent
$directReportsFixture = Join-Path $PSScriptRoot 'Fixtures\DirectReportsFixture.ps1'

Describe 'Offline direct reports group creation' {
    It 'uses FirstLast rather than a comma-separated display name and identifies the creator' {
        $run = & $directReportsFixture -Capture -Manager 'manager@example.invalid'
        $run.Error | Should BeNullOrEmpty
        $post = @($run.Calls | Where-Object Method -eq POST)
        $post.Count | Should Be 1
        $body = $post[0].Body | ConvertFrom-Json
        $body.displayName | Should Be 'Entra.Users.DirectReports.ExampleManager'
        $body.membershipRule | Should Be 'Direct Reports for "00000000-0000-0000-0000-000000000001"'
        $body.groupTypes.Count | Should Be 1
        $body.groupTypes[0] | Should Be 'DynamicMembership'
        $body.mailEnabled | Should Be $false
        $body.securityEnabled | Should Be $true
        $body.membershipRuleProcessingState | Should Be 'On'
        $body.mailNickname | Should Match '^[A-Za-z0-9]{1,64}$'
        $body.description | Should Match '^Dynamic direct reports group for Manager, Example\. Created by creator@example\.invalid on \d{4}-\d{2}-\d{2}\.$'
        [uri]::UnescapeDataString($run.Calls[0].Uri) | Should Match "userPrincipalName eq 'manager@example.invalid'"
        $run.Calls[0].Uri | Should Match '\$select=id,displayName,userPrincipalName,givenName,surname'
        $summary = @($run.Events | Where-Object Type -eq OperationSummary)[0].Data
        $summary.Entity | Should Be 'Groups'
        $summary.Succeeded | Should Be 1
        $summary.Affected | Should Be 1
        $summary.CountsComplete | Should Be $true
        @($run.Events | Where-Object Type -eq Rows)[0].Data[0].Status | Should Be 'Created'
    }
    It 'escapes exact display-name filters and removes whitespace from givenName and surname' {
        $run = & $directReportsFixture -Capture -Scenario Whitespace -Manager "Example O'Manager"
        $run.Error | Should BeNullOrEmpty
        [uri]::UnescapeDataString($run.Calls[0].Uri) | Should Match "displayName eq 'Example O''Manager'"
        ($run.Output[0]).GroupName | Should Be 'Entra.Users.DirectReports.ExampleManager'
    }
    It 'returns the same structured result when invoked directly without the desktop adapter' {
        $run = & $directReportsFixture -Capture -Direct
        $run.Error | Should BeNullOrEmpty
        $run.Output.Count | Should Be 1
        $run.Output[0].Status | Should Be 'Created'
        $run.Output[0].GroupId | Should Be '00000000-0000-0000-0000-000000000003'
    }
    It 'previews the complete rule and description without creating a group or counting success' {
        $run = & $directReportsFixture -Capture -Preview
        $run.Error | Should BeNullOrEmpty
        @($run.Calls | Where-Object Method -eq POST).Count | Should Be 0
        $run.Output[0].Status | Should Be 'WhatIf'
        $summary = @($run.Events | Where-Object Type -eq OperationSummary)[0].Data
        $summary.Succeeded | Should Be 0
        $summary.Affected | Should Be 0
        $summary.Skipped | Should Be 1
    }
    It 'blocks missing or ambiguous managers, existing groups and unsafe lookup responses before writing' {
        foreach ($scenario in @('NotFound','PagedDuplicate','Existing','LookupFailure','Malformed','ForeignPage','MissingId','MissingCreator','LongName')) {
            $run = & $directReportsFixture -Capture -Scenario $scenario
            [bool]$run.Error | Should Be $true
            @($run.Calls | Where-Object Method -eq POST).Count | Should Be 0
        }
    }
    It 'rejects missing first or last names instead of falling back to the display name' {
        foreach ($scenario in @('MissingFirstName','MissingLastName')) {
            $run = & $directReportsFixture -Capture -Scenario $scenario
            $run.Error.Exception.Message | Should Match 'both givenName.*and surname'
            @($run.Calls | Where-Object Method -eq POST).Count | Should Be 0
        }
    }
    It 'reports an uncertain create as incomplete, surfaces the error and never retries' {
        foreach ($scenario in @('CreateFailure','MissingCreateId')) {
            $run = & $directReportsFixture -Capture -Scenario $scenario 3>$null
            [bool]$run.Error | Should Be $true
            @($run.Calls | Where-Object Method -eq POST).Count | Should Be 1
            $summary = @($run.Events | Where-Object Type -eq OperationSummary)[0].Data
            $summary.Succeeded | Should Be 0
            $summary.Affected | Should Be 0
            $summary.Unprocessed | Should Be 1
            $summary.CountsComplete | Should Be $false
        }
    }
    It 'binds the required manager and preserves explicit preview and three-state Confirm' {
        Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
        $workflow = Get-EndpointCatalog | Where-Object Id -eq create-direct-reports-group
        (Get-EndpointArguments $workflow @{Manager='Example Manager';Confirm='Script default'}).ContainsKey('Confirm') | Should Be $false
        (Get-EndpointArguments $workflow @{Manager='Example Manager';Confirm='Prompt'}).Confirm | Should Be $true
        $arguments = Get-EndpointArguments $workflow @{Manager='manager@example.invalid';WhatIf=$true;Confirm='Suppress ShouldProcess prompts'}
        $arguments.Manager | Should Be 'manager@example.invalid'
        $arguments.WhatIf | Should Be $true
        $arguments.Confirm | Should Be $false
        $rejected = $false
        try { $null = Get-EndpointArguments $workflow @{} } catch { $rejected = $_.Exception.Message -eq 'Manager is required.' }
        $rejected | Should Be $true
        . (Join-Path $desktop 'GraphSession.ps1')
        $policy = Get-EndpointGraphPolicy create-direct-reports-group
        ($policy.Scopes -contains 'Group.ReadWrite.All') | Should Be $true
        ($policy.RoleGroups[0].AnyOf -contains 'Groups Administrator') | Should Be $true
        ((Get-EndpointGraphPolicy create-direct-reports-group @{WhatIf=$true}).RoleGroups[0].AnyOf -contains 'Global Reader') | Should Be $true
    }
    It 'refuses a declined or closed native confirmation and creates only after approval' {
        if (-not ('EndpointToolbox.DesktopEngine' -as [type])) { Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs') }
        foreach ($answer in @('No','Cancel','Yes')) {
            $engine = [EndpointToolbox.DesktopEngine]::new()
            try {
                $engine.RunFile($directReportsFixture, @{Prompt=$true}, $true)
                $events = [Collections.Generic.List[object]]::new()
                $deadline = [datetime]::UtcNow.AddSeconds(15)
                do {
                    $null = $engine.Poll()
                    $event = $null
                    while ($engine.Host.Events.TryDequeue([ref]$event)) {
                        $events.Add($event)
                        if ($event.Kind -eq 'Prompt') {
                            if ($answer -eq 'Cancel') { $event.Data.Cancel() }
                            else { $event.Data.Complete([array]::IndexOf($event.Data.Choices, $answer)) }
                        }
                    }
                    if ([datetime]::UtcNow -gt $deadline) { $engine.Cancel(); throw 'Direct reports confirmation fixture timed out.' }
                    Start-Sleep -Milliseconds 10
                } while ($engine.Busy -or -not $engine.Host.Events.IsEmpty)
                @($events | Where-Object Kind -eq Prompt).Count | Should Be 1
                @($events | Where-Object Name -eq 'Group POST').Count | Should Be $(if ($answer -eq 'Yes') { 1 } else { 0 })
                if ($answer -eq 'No') {
                    $summary = @($events | Where-Object Kind -eq OperationSummary)[0].Data
                    $summary.Succeeded | Should Be 0
                    $summary.Skipped | Should Be 1
                }
                if ($answer -eq 'Yes') { $engine.HasErrors | Should Be $false }
            }
            finally { $engine.Dispose() }
        }
    }
}
