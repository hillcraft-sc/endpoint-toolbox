$desktop = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $PSScriptRoot 'Fixtures\WUfBFixture.ps1'
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force

function Get-WUfBFixtureSet {
    param($Run,[string]$Name)
    foreach ($event in $Run.Events) {
        if ($event.Type -eq 'Rows' -and $event.Name -eq $Name) { $event.Data | ForEach-Object { $_ } }
    }
}

Describe 'Offline WUfB reporting' {
    It 'does not query Graph or add a name-resolution dataset unless explicitly enabled' {
        $run = & $fixture -Scenario GraphNames
        if ($run.Error) { throw $run.Error }
        $run.GraphRequests.Count | Should Be 0
        $devices = @(Get-WUfBFixtureSet $run 'Devices')
        $devices[0].DeviceName | Should BeNullOrEmpty
        $devices[1].DeviceName | Should Be '#'
        @($run.Events | Where-Object Name -eq 'Device name resolution').Count | Should Be 0
    }
    It 'fills only missing names by device ID and propagates names to related datasets with provenance' {
        $run = & $fixture -Scenario GraphNames -ResolveDeviceNames
        if ($run.Error) { throw $run.Error }
        $run.GraphRequests.Count | Should Be 1
        $devices = @(Get-WUfBFixtureSet $run 'Devices')
        $devices[0].DeviceName | Should Be 'Graph-PC-1'
        $devices[1].DeviceName | Should Be 'Graph-PC-2'
        $devices[2].DeviceName | Should Be 'Fixture-PC-3'
        @(Get-WUfBFixtureSet $run 'Update records')[0].DeviceName | Should Be 'Graph-PC-1'
        @(Get-WUfBFixtureSet $run 'KB investigation')[0].DeviceName | Should Be 'Graph-PC-1'
        $sources = @(Get-WUfBFixtureSet $run 'Device name resolution')
        $sources[0].ReportedDeviceName | Should BeNullOrEmpty
        $sources[0].NameSource | Should Be 'Microsoft Graph (Entra)'
        $sources[1].ReportedDeviceName | Should Be '#'
        $sources[2].NameSource | Should Be 'WUfB telemetry'
        $scoped = & $fixture -Scenario GraphNames -ResolveDeviceNames -DeviceNames 'Graph-PC-2'
        if ($scoped.Error) { throw $scoped.Error }
        @(Get-WUfBFixtureSet $scoped 'Devices').Count | Should Be 1
        @(Get-WUfBFixtureSet $scoped 'Device name resolution').Count | Should Be 1
        $direct = & $fixture -Scenario GraphNames -ResolveDeviceNames -Direct
        if ($direct.Error) { throw $direct.Error }
        $direct.Output[0].DeviceName | Should Be 'Graph-PC-1'
        $complete = & $fixture -ResolveDeviceNames
        if ($complete.Error) { throw $complete.Error }
        $complete.GraphRequests.Count | Should Be 0
        @((Get-WUfBFixtureSet $complete 'Device name resolution') | Where-Object NameSource -eq 'WUfB telemetry').Count | Should Be 8
    }
    It 'batches and pages exact device-ID lookups without conflating identical display names' {
        $paged = & $fixture -Scenario GraphPages -ResolveDeviceNames
        if ($paged.Error) { throw $paged.Error }
        $paged.GraphRequests.Count | Should Be 2
        @(Get-WUfBFixtureSet $paged 'Devices')[1].DeviceName | Should Be 'Graph-PC-2'
        $batch = & $fixture -Scenario GraphBatching -ResolveDeviceNames
        if ($batch.Error) { throw $batch.Error }
        $batch.GraphRequests.Count | Should Be 2
        @((Get-WUfBFixtureSet $batch 'Device name resolution') | Where-Object NameSource -eq 'Microsoft Graph (Entra)').Count | Should Be 20
        $same = & $fixture -Scenario GraphSameNames -ResolveDeviceNames
        if ($same.Error) { throw $same.Error }
        @((Get-WUfBFixtureSet $same 'Devices') | Where-Object DeviceName -eq 'Shared-Graph-Name').Count | Should Be 2
    }
    It 'leaves unmatched, ambiguous and non-Entra identities unresolved with explicit warnings' {
        foreach ($scenario in @('GraphNoMatch','GraphDuplicate','GraphGlobalIdentity','GraphBlankName')) {
            $run = & $fixture -Scenario $scenario -ResolveDeviceNames
            if ($run.Error) { throw $run.Error }
            $sources = @(Get-WUfBFixtureSet $run 'Device name resolution')
            $sources[0].NameSource | Should Be 'Unresolved'
            ($run.Warnings -join '|') | Should Match 'could not be resolved'
        }
    }
    It 'rejects disconnected, app-only, cross-tenant or unconsented Graph sessions before workspace queries' {
        foreach ($scenario in @('GraphDisconnected','GraphAppOnly','GraphOtherTenant','GraphNoConsent')) {
            $run = & $fixture -Scenario $scenario -ResolveDeviceNames
            $run.Error | Should Not BeNullOrEmpty
            $run.Queries.Count | Should Be 0
            $run.GraphRequests.Count | Should Be 0
            @($run.Events | Where-Object Type -eq 'Rows').Count | Should Be 0
        }
    }
    It 'fails visibly on Graph errors and invalid pagination without publishing partial reports' {
        foreach ($scenario in @('GraphDenied','GraphMalformed','GraphUnexpectedId','GraphRepeatedPage','GraphForeignPage')) {
            $run = & $fixture -Scenario $scenario -ResolveDeviceNames
            $run.Error | Should Not BeNullOrEmpty
            @($run.Events | Where-Object Type -eq 'Rows').Count | Should Be 0
            @($run.Events | Where-Object Type -eq 'ReportVisual').Count | Should Be 0
        }
    }
    It 'signs in once across consecutive reports and reuses an existing user session without changing login settings' {
        $repeat = & $fixture -Repeat
        if ($repeat.Error) { throw $repeat.Error }
        $repeat.ContextChecks | Should Be 2
        $repeat.Logins.Count | Should Be 1
        $repeat.ConfigCalls.Count | Should Be 2
        $repeat.Queries.Count | Should Be 22
        @(Get-WUfBFixtureSet $repeat 'Devices').Count | Should Be 16
        $existing = & $fixture -Scenario ExistingSession -UseDeviceAuthentication
        if ($existing.Error) { throw $existing.Error }
        $existing.Logins.Count | Should Be 0
        $existing.ConfigCalls.Count | Should Be 0
        $existing.Queries.Count | Should Be 11
        $direct = & $fixture -Direct -Repeat
        if ($direct.Error) { throw $direct.Error }
        $direct.Logins.Count | Should Be 1
        $direct.Output.Count | Should Be 8
    }
    It 'signs in instead of reusing a different tenant, cloud, app-only identity or invalid context' {
        foreach ($scenario in @('OtherTenant','OtherCloud','ServicePrincipal','InvalidContext')) {
            $run = & $fixture -Scenario $scenario
            if ($run.Error) { throw $run.Error }
            $run.Logins.Count | Should Be 1
            $run.Queries.Count | Should Be 11
            if ($scenario -eq 'OtherTenant') { $run.Logins[0].Tenant | Should Be '00000000-0000-0000-0000-000000000001' }
        }
    }
    It 'renews authentication once for the same account and tenant when silent token acquisition requires sign-in' {
        $run = & $fixture -Scenario RenewalRequired -UseDeviceAuthentication
        if ($run.Error) { throw $run.Error }
        $run.Logins.Count | Should Be 1
        $run.Logins[0].AccountId | Should Be 'fixture@example.invalid'
        $run.Logins[0].Tenant | Should Be '00000000-0000-0000-0000-000000000001'
        $run.Logins[0].DeviceCode | Should Be $true
        $run.Queries.Count | Should Be 11
        ($run.Warnings -join '|') | Should Match 'authentication renewal'
        foreach ($scenario in @('RenewalCancelled','RenewalWrongAccount','RenewalWrongTenant')) {
            $failed = & $fixture -Scenario $scenario
            $failed.Error | Should Not BeNullOrEmpty
            $failed.Logins.Count | Should Be 1
            $failed.Queries.Count | Should Be 0
            $failed.ConfigCalls[1].Operation | Should Be 'Clear'
            @($failed.Events | Where-Object Type -eq 'Rows').Count | Should Be 0
        }
    }
    It 'surfaces token and query failures without launching an unrelated interactive sign-in' {
        foreach ($scenario in @('TokenFailure','TokenTlsFailure','ExistingPlainToken','ExistingAccessDenied')) {
            $run = & $fixture -Scenario $scenario
            $run.Error | Should Not BeNullOrEmpty
            $run.Logins.Count | Should Be 0
            $run.ConfigCalls.Count | Should Be 0
            @($run.Events | Where-Object Type -eq 'Rows').Count | Should Be 0
        }
    }
    It 'suppresses the console subscription prompt only during sign-in and restores process configuration' {
        $run = & $fixture
        if ($run.Error) { throw $run.Error }
        $run.ConfigCalls.Count | Should Be 2
        $run.ConfigCalls[0].Value | Should Be 'Off'
        $run.ConfigCalls[1].Operation | Should Be 'Clear'
        $run.LoginExperience | Should BeNullOrEmpty
        $existing = & $fixture -Scenario ExistingLoginConfig
        if ($existing.Error) { throw $existing.Error }
        $existing.ConfigCalls[1].Operation | Should Be 'Update'
        $existing.ConfigCalls[1].Value | Should Be 'On'
        $existing.LoginExperience | Should Be 'On'
        $cancelled = & $fixture -Scenario AuthCancelled
        $cancelled.Error.Exception.Message | Should Match 'sign-in cancelled'
        $cancelled.ConfigCalls[1].Operation | Should Be 'Clear'
        $cancelled.LoginExperience | Should BeNullOrEmpty
        $cancelled.Queries.Count | Should Be 0
    }
    It 'queries Azure independently and calculates security compliance with explicit exclusions' {
        $run = & $fixture
        if ($run.Error) { throw $run.Error }
        $run.Logins.Count | Should Be 1
        $run.Logins[0].Scope | Should Be 'Process'
        $run.Logins[0].SkipContextPopulation | Should Be $true
        $run.Queries.Count | Should Be 11
        $devices = Get-WUfBFixtureSet $run 'Devices'
        $devices.Count | Should Be 8
        $overview = @(Get-WUfBFixtureSet $run 'Fleet overview')[0]
        $overview.EvaluatedDevices | Should Be 6
        $overview.CompliantDevices | Should Be 3
        $overview.SecurityCompliancePercent | Should Be 50
        $overview.StaleDevices | Should Be 1
        $overview.UnknownDevices | Should Be 1
        @($run.Events | Where-Object Type -eq 'ReportVisual').Count | Should Be 2
        @(Get-WUfBFixtureSet $run 'Data health').Count | Should Be 5
        @(Get-WUfBFixtureSet $run 'Compliance trend').Count | Should Be 1
    }
    It 'distinguishes exact KB installation, missing evidence, failure, restart and inferred coverage' {
        $run = & $fixture
        if ($run.Error) { throw $run.Error }
        $kb = @(Get-WUfBFixtureSet $run 'KB investigation')
        $kb[0].KBStatus | Should Be 'Installed'
        $kb[1].KBStatus | Should Be 'Unknown'
        $kb[2].KBStatus | Should Be 'Failed'
        $kb[2].ActiveErrorCodes | Should Be '0x80070005'
        $kb[3].KBStatus | Should Be 'Pending restart'
        $kb[4].KBStatus | Should Be 'Newer build (inferred coverage)'
        $kb[5].KBStatus | Should Be 'Unknown'
        $kb[7].KBStatus | Should Be 'Unknown'
        $devices = @(Get-WUfBFixtureSet $run 'Devices')
        $devices[0].LatestInstalledQualityKB | Should Be 'KB5132043'
        $devices[0].ReportedQualityStatus | Should Be 'NotLatest'
        @(Get-WUfBFixtureSet $run 'Pending restarts')[0].RestartWaitingDays | Should Be 2
        @(Get-WUfBFixtureSet $run 'Service states')[0].ServiceSubstate | Should Be 'OfferReady'
        @(Get-WUfBFixtureSet $run 'Alerts')[0].Recommendation | Should Be 'Check installation access'
        @(Get-WUfBFixtureSet $run 'Error summary')[0].AffectedDevices | Should Be 1
    }
    It 'does not treat resolved errors or historical restart timestamps as current failures/restarts' {
        $resolved = & $fixture -Scenario ResolvedError
        if ($resolved.Error) { throw $resolved.Error }
        @(Get-WUfBFixtureSet $resolved 'Failed updates').Count | Should Be 0
        @(Get-WUfBFixtureSet $resolved 'Alerts')[0].AlertStatus | Should Be 'Resolved'
        $installed = & $fixture -Scenario InstalledAfterFailure
        if ($installed.Error) { throw $installed.Error }
        @(Get-WUfBFixtureSet $installed 'Failed updates').Count | Should Be 0
        $restart = & $fixture -Scenario RestartTimestampOnly
        if ($restart.Error) { throw $restart.Error }
        @(Get-WUfBFixtureSet $restart 'Pending restarts').Count | Should Be 0
    }
    It 'keeps uninstall, stale evidence and conflicting deployments out of confirmed installation counts' {
        $uninstall = & $fixture -Scenario Uninstalled
        if ($uninstall.Error) { throw $uninstall.Error }
        @(Get-WUfBFixtureSet $uninstall 'KB investigation')[0].KBStatus | Should Be 'Not installed'
        $stale = & $fixture -Scenario StaleKB
        if ($stale.Error) { throw $stale.Error }
        @(Get-WUfBFixtureSet $stale 'KB investigation')[2].KBStatus | Should Be 'Unknown'
        $conflict = & $fixture -Scenario Conflict
        if ($conflict.Error) { throw $conflict.Error }
        @(Get-WUfBFixtureSet $conflict 'KB investigation')[3].KBStatus | Should Be 'Unknown'
        $stalled = & $fixture -Scenario Stalled
        if ($stalled.Error) { throw $stalled.Error }
        @(Get-WUfBFixtureSet $stalled 'Stalled candidates')[0].StateAgeDays | Should Be 20
        @(Get-WUfBFixtureSet $stalled 'KB investigation')[2].KBStatus | Should Be 'Unknown'
    }
    It 'retains duplicate names, supports exact-name scope and refuses unmatched names' {
        $run = & $fixture -DeviceNames 'fixture-pc'
        if ($run.Error) { throw $run.Error }
        @(Get-WUfBFixtureSet $run 'Devices').Count | Should Be 2
        $run.Queries.Count | Should Be 10
        @(Get-WUfBFixtureSet $run 'Compliance trend').Count | Should Be 0
        $missing = & $fixture -DeviceNames 'Absent-Fixture'
        $missing.Error.Exception.Message | Should Match 'absent from the latest'
        @($missing.Events | Where-Object Type -eq 'Rows').Count | Should Be 0
    }
    It 'uses global IDs explicitly but refuses ambiguous or unidentified device records' {
        $global = & $fixture -Scenario GlobalIdentity
        if ($global.Error) { throw $global.Error }
        @((Get-WUfBFixtureSet $global 'Devices') | Where-Object IdentitySource -eq 'GlobalDeviceId').Count | Should Be 1
        foreach ($scenario in @('DuplicateIdentity','MissingIdentity')) {
            $run = & $fixture -Scenario $scenario
            $run.Error | Should Not BeNullOrEmpty
            @($run.Events | Where-Object Type -eq 'Rows').Count | Should Be 0
        }
    }
    It 'shows null rather than a success percentage when no devices can be evaluated' {
        $run = & $fixture -Scenario NoEvaluatedDevices
        if ($run.Error) { throw $run.Error }
        $overview = @(Get-WUfBFixtureSet $run 'Fleet overview')[0]
        $overview.EvaluatedDevices | Should Be 0
        $overview.SecurityCompliancePercent | Should BeNullOrEmpty
        $stale = & $fixture -Scenario SnapshotStale
        if ($stale.Error) { throw $stale.Error }
        @(Get-WUfBFixtureSet $stale 'Fleet overview')[0].EvaluatedDevices | Should Be 0
    }
    It 'rejects missing required schemas, partial responses and authentication errors without publishing rows' {
        foreach ($scenario in @('RequiredMissing','Empty','Partial','Malformed','InvalidJson','MissingModule','AuthCancelled','AccessDenied','PlainToken')) {
            $run = & $fixture -Scenario $scenario
            $run.Error | Should Not BeNullOrEmpty
            @($run.Events | Where-Object Type -eq 'Rows').Count | Should Be 0
            @($run.Events | Where-Object Type -eq 'ReportVisual').Count | Should Be 0
        }
        $optional = & $fixture -Scenario OptionalMissing
        if ($optional.Error) { throw $optional.Error }
        ($optional.Warnings -join '|') | Should Match 'unavailable optional fields'
    }
    It 'does not publish cancelled results and keeps standalone output as device rows' {
        $cancelled = & $fixture -Cancel
        if ($cancelled.Error) { throw $cancelled.Error }
        @($cancelled.Events | Where-Object Type -eq 'Rows').Count | Should Be 0
        $direct = & $fixture -Direct -UseDeviceAuthentication
        if ($direct.Error) { throw $direct.Error }
        $direct.Output.Count | Should Be 8
        ($direct.Output[0].PSObject.Properties.Name -contains 'SecurityCompliance') | Should Be $true
        $direct.Logins[0].DeviceCode | Should Be $true
    }
    It 'normalizes KB input and reports unobserved KBs as unknown rather than missing' {
        $run = & $fixture -TargetKB '5132043'
        if ($run.Error) { throw $run.Error }
        @(Get-WUfBFixtureSet $run 'KB investigation')[0].TargetKB | Should Be 'KB5132043'
        $unobserved = & $fixture -TargetKB 'KB9999999'
        if ($unobserved.Error) { throw $unobserved.Error }
        @((Get-WUfBFixtureSet $unobserved 'KB investigation') | Where-Object KBStatus -ne 'Unknown').Count | Should Be 0
        ($unobserved.Warnings -join '|') | Should Match 'was not observed'
    }
}

Describe 'WUfB workflow integration' {
    It 'uses only parameters supported by the installed HTTP command, including aliases' {
        $path = Join-Path (Split-Path $desktop -Parent) 'Intune\Devices\Get-WUfBReport.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$null)
        $requests = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Invoke-WebRequest','Invoke-RestMethod')
        },$true))
        $requests.Count | Should Be 1
        foreach ($request in $requests) {
            $command = Get-Command ("Microsoft.PowerShell.Utility\" + $request.GetCommandName())
            foreach ($parameter in $request.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] }) {
                $matches = @($command.Parameters.Values | Where-Object {
                    $_.Name.StartsWith($parameter.ParameterName,[StringComparison]::OrdinalIgnoreCase) -or
                    $_.Aliases -contains $parameter.ParameterName
                })
                $matches.Count | Should Be 1
            }
        }
    }
    It 'persists workspace defaults and drills down by device ID in the native WPF UI' {
        $native = Join-Path $PSScriptRoot 'Fixtures\UsabilityFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $native -WUfBOnly 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native WUfB fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native WUfB settings, input validation, supported layouts and ID-based device drill-down passed'
    }
    It 'binds validated Azure-only inputs without a Graph policy or implicit output files' {
        $workflow = Get-EndpointCatalog | Where-Object Id -eq 'wufb-report'
        $workflow.Kind | Should Be 'Azure'
        $arguments = Get-EndpointArguments $workflow @{WorkspaceId='00000000-0000-0000-0000-000000000002';TargetKB='KB5132043';DeviceNames="Fixture-PC`nFixture-PC-3";LookbackDays='28';StaleDays='7'}
        $arguments.DeviceNames.Count | Should Be 2
        $arguments.LookbackDays | Should Be 28
        ($workflow.Fields.Name -contains 'OutputPath') | Should Be $false
        foreach ($values in @(
            @{}, @{WorkspaceId='invalid'}, @{WorkspaceId=[guid]::Empty}, @{WorkspaceId='00000000-0000-0000-0000-000000000002';TargetKB="KB5132043' | take 1"},
            @{WorkspaceId='00000000-0000-0000-0000-000000000002';LookbackDays='91'},
            @{WorkspaceId='00000000-0000-0000-0000-000000000002';StaleDays='29'}
        )) {
            $rejected = $false
            try { $null = Get-EndpointArguments $workflow $values } catch { $rejected = $true }
            $rejected | Should Be $true
        }
        . (Join-Path $desktop 'GraphSession.ps1')
        $rejected = $false
        try { $null = Get-EndpointGraphPolicy 'wufb-report' } catch { $rejected = $true }
        $rejected | Should Be $true
    }
    It 'rejects truncated and structurally invalid query results' {
        $path = Join-Path (Split-Path $desktop -Parent) 'Intune\Devices\Get-WUfBReport.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$null)
        $function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertFrom-WUfBQueryResponse'},$true)
        . ([scriptblock]::Create($function.Extent.Text))
        $response = @{tables=@(@{columns=@(@{name='Value';type='string'});rows=@(@('one'),@('two'))})}
        $rejected = $false
        try { $null = ConvertFrom-WUfBQueryResponse $response 'Fixture' 1 } catch { $rejected = $true }
        $rejected | Should Be $true
        $response.tables[0].rows = @(,@('one','extra'))
        $rejected = $false
        try { $null = ConvertFrom-WUfBQueryResponse $response 'Fixture' } catch { $rejected = $true }
        $rejected | Should Be $true
    }
}
