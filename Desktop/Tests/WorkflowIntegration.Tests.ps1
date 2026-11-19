# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

$desktop = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
$catalog = @(Get-EndpointCatalog)
$fixtureRoot = Join-Path $env:TEMP "EndpointToolbox-tests-$([guid]::NewGuid())"
$null = New-Item -Path $fixtureRoot -ItemType Directory
$userFile = Join-Path $fixtureRoot 'users.txt'
Set-Content -LiteralPath $userFile -Value 'fixture@example.invalid'

function Invoke-OfflineEndpointWorkflow {
    param([string]$Id, [hashtable]$Arguments, [string]$Scenario = 'Happy')
    & {
        param($Workflow, $Parameters, $OutputRoot, $Scenario)
        $fixtureCalls = [Collections.Generic.List[object]]::new()
        $fixtureEvents = [Collections.Generic.List[object]]::new()
        $groupId = '00000000-0000-0000-0000-000000000001'
        $directoryId = '00000000-0000-0000-0000-000000000002'
        $deviceId = '00000000-0000-0000-0000-000000000003'
        $managedId = '00000000-0000-0000-0000-000000000004'
        $userId = '00000000-0000-0000-0000-000000000005'
        $appId = '00000000-0000-0000-0000-000000000006'
        $fixtureDevice = [pscustomobject]@{
            id=$managedId; deviceName='Fixture-PC'; azureADDeviceId=$deviceId
            userPrincipalName='fixture@example.invalid'; userDisplayName='Fixture User'
            operatingSystem='Windows'; deviceType='cloudPC'; model='Cloud PC Fixture'
            lastSyncDateTime=[datetime]::UtcNow.ToString('o'); managedDeviceOwnerType='company'
            serialNumber='SYNTHETIC'; usersLoggedOn=@([pscustomobject]@{userId=$userId;lastLogOnDateTime=[datetime]::UtcNow.ToString('o')})
        }
        $fixtureDirectory = [pscustomobject]@{
            id=$directoryId; deviceId=$deviceId; displayName='Fixture-PC'; operatingSystem='Windows'
            onPremisesSyncEnabled=$true; approximateLastSignInDateTime=[datetime]::UtcNow.AddDays(-120).ToString('o')
            registrationDateTime=[datetime]::UtcNow.AddDays(-180).ToString('o'); physicalIds=@(); trustType='ServerAd'; accountEnabled=$true
        }
        $fixtureUser = [pscustomobject]@{id=$userId;userPrincipalName='fixture@example.invalid';displayName='Fixture User'}
        $fixtureGroup = [pscustomobject]@{id=$groupId;displayName='Fixture Group';groupTypes=@()}
        $fixtureApp = [pscustomobject]@{
            id=$appId;displayName='Fixture App';displayVersion='1.0';publisher='Fixture'
            createdDateTime=[datetime]::UtcNow.ToString('o');'@odata.type'='#microsoft.graph.win32LobApp'
            assignments=@(
                [pscustomobject]@{intent='required';target=[pscustomobject]@{'@odata.type'='#microsoft.graph.allDevicesAssignmentTarget'}}
                [pscustomobject]@{intent='required';target=[pscustomobject]@{'@odata.type'='#microsoft.graph.groupAssignmentTarget';groupId=$groupId}}
            )
        }
        $fixtureRemediation = [pscustomobject]@{id='00000000-0000-0000-0000-000000000011';displayName='Fixture remediation';createdDateTime='2026-01-01T00:00:00Z'}
        $fixturePlatformScript = [pscustomobject]@{id='00000000-0000-0000-0000-000000000012';displayName='Fixture platform script';createdDateTime='2026-01-02T00:00:00Z'}
        $fixtureApps = @($fixtureApp)
        if ($Scenario -eq 'DeploymentMultiple') {
            $secondApp = $fixtureApp.PSObject.Copy()
            $secondApp.id = '00000000-0000-0000-0000-000000000009'
            $secondApp.displayVersion = '2.0'
            $fixtureApps += $secondApp
        }
        if ($Scenario -like 'DeleteBatch*') {
            $fixtureApps = @(
                foreach ($suffix in @('006','008','009')) {
                    $batchApp = $fixtureApp.PSObject.Copy()
                    $batchApp.id = "00000000-0000-0000-0000-000000000$suffix"
                    $batchApp.displayName = "Retired - Fixture $suffix"
                    $batchApp
                }
            )
        }
        function Get-MgContext { [pscustomobject]@{Account='fixture@example.invalid';TenantId='fixture-tenant';Environment='Global';Scopes=@('DeviceManagementManagedDevices.Read.All','Device.Read.All','GroupMember.ReadWrite.All')} }
        function Connect-MgGraph { throw 'Unexpected real sign-in path in offline fixture.' }
        function Disconnect-MgGraph { throw 'Unexpected disconnect in offline fixture.' }
        function Start-Sleep { param($Seconds) }
        function Get-MgDeviceManagementManagedDevice { param($Filter,$ManagedDeviceId) $fixtureDevice }
        function Sync-MgDeviceManagementManagedDevice { param($ManagedDeviceId,$ErrorAction) $fixtureCalls.Add([pscustomobject]@{Method='SYNC';Uri=$ManagedDeviceId}) }
        function Invoke-RestMethod { throw 'No network call may be made by these offline fixtures.' }
        function Invoke-MgGraphRequest {
            param($Method='GET',$Uri,$Body,$ContentType,$OutputType,$Headers)
            $fixtureCalls.Add([pscustomobject]@{Method=$Method;Uri=$Uri;Body=$Body})
            if ($Scenario -eq 'AddDuplicateDevices') {
                if ($Uri -like '*/groups/*/members?*') { return @{value=@(@{id=$fixtureDirectory.id})} }
                if ($Uri -like '*/devices?*') {
                    return @{value=@($fixtureDirectory, [pscustomobject]@{id='00000000-0000-0000-0000-000000000008';displayName='Fixture-PC'})}
                }
            }
            if ($Scenario -eq 'UserLookup' -and $Uri -like '*/users?*') {
                $decoded = [uri]::UnescapeDataString($Uri)
                if ($decoded -like "*O''Brien*") { throw 'Synthetic lookup failure.' }
                if ($decoded -like "*displayName eq 'Doe, Jane'*") { return @{value=@([pscustomobject]@{id='u1';displayName='Doe, Jane';userPrincipalName='jane@example.invalid'})} }
                if ($decoded -like "*displayName eq 'Sam Lee'*") {
                    return @{value=@([pscustomobject]@{id='u2';displayName='Lee, Sam';userPrincipalName='sam1@example.invalid'},[pscustomobject]@{id='u3';displayName='Lee, Sam';userPrincipalName='sam2@example.invalid'})}
                }
                if ($decoded -like "*startswith(givenName,'M')*") { return @{value=@([pscustomobject]@{id='u4';displayName='Smith, Michael';userPrincipalName='michael@example.invalid'})} }
                return @{value=@()}
            }
            if ($Scenario -eq 'AddDuplicateUsers' -and $Uri -like '*/users?*') {
                return @{value=@($fixtureUser, [pscustomobject]@{id='00000000-0000-0000-0000-000000000008';userPrincipalName=$fixtureUser.userPrincipalName})}
            }
            if ($Scenario -like 'RemoveMembers*') {
                if ($Method -eq 'DELETE') {
                    if ($Uri -notmatch ('^https://graph\.microsoft\.com/v1\.0/groups/{0}/members/[a-f0-9-]+/\$ref$' -f $fixtureGroup.id)) {
                        throw 'Expected a direct membership reference DELETE.'
                    }
                    if ($Scenario -eq 'RemoveMembersPartial' -and $Uri -like "*/$userId/*") { throw 'Synthetic removal failure.' }
                    return
                }
                if ($Uri -like '*/members/microsoft.graph.device*') {
                    if ($Uri -like '*skiptoken*') {
                        return @{value=@(@{id='00000000-0000-0000-0000-000000000008';displayName='Duplicate-PC'})}
                    }
                    return @{
                        value=@(@{id=$directoryId;displayName='Fixture-PC'}, @{id='00000000-0000-0000-0000-000000000009';displayName='Duplicate-PC'})
                        '@odata.nextLink'="https://graph.microsoft.com/v1.0/groups/$($fixtureGroup.id)/members/microsoft.graph.device?`$skiptoken=fixture"
                    }
                }
                if ($Uri -like '*/members/microsoft.graph.user*') {
                    return @{value=@(
                        @{id=$userId;userPrincipalName='fixture@example.invalid'}
                        @{id='00000000-0000-0000-0000-000000000008';userPrincipalName='second@example.invalid'}
                    )}
                }
                if ($Uri -match '/groups(?:/[^/?]+)?\?') {
                    $group = @{id=$fixtureGroup.id;displayName='Fixture Group';mailEnabled=$false;groupTypes=@()}
                    if ($Scenario -eq 'RemoveMembersDynamic') { $group.groupTypes = @('DynamicMembership') }
                    if ($Uri -match '/groups\?') { return @{value=@($group)} }
                    return $group
                }
                throw "Unexpected removal fixture request: $Method $Uri"
            }
            if ($Uri -match '/deviceHealthScripts\?') { return @{value=@($fixtureRemediation)} }
            if ($Uri -match '/deviceManagementScripts\?') { return @{value=@($fixturePlatformScript)} }
            if ($Uri -match '/deviceHealthScripts/[^/?]+\?') { return $fixtureRemediation }
            if ($Uri -match '/deviceManagementScripts/[^/?]+\?') { return $fixturePlatformScript }
            if ($Uri -like '*/deviceHealthScripts/*/deviceRunStates*') {
                return @{value=@([pscustomobject]@{
                    id='fixture-health-state';detectionState='success';remediationState='skipped'
                    lastStateUpdateDateTime='2026-01-03T12:00:00Z';expectedStateUpdateDateTime='2026-01-04T12:00:00Z'
                    lastSyncDateTime='2026-01-03T11:55:00Z';preRemediationDetectionScriptOutput='Synthetic detection output'
                    preRemediationDetectionScriptError='';remediationScriptError=''
                    postRemediationDetectionScriptOutput='Synthetic post-detection output';postRemediationDetectionScriptError=''
                    managedDevice=$fixtureDevice
                })}
            }
            if ($Uri -like '*/deviceManagementScripts/*/deviceRunStates*') {
                return @{value=@([pscustomobject]@{
                    id='fixture-platform-state';runState='success';resultMessage='Synthetic platform result'
                    lastStateUpdateDateTime='2026-01-03T13:00:00Z';errorCode=0;errorDescription=''
                    managedDevice=$fixtureDevice
                })}
            }
            if ($Scenario -like 'Deployment*' -and $Method -eq 'POST' -and $Uri -like '*exportJobs*') {
                $request = $Body | ConvertFrom-Json
                if ($Scenario -eq 'DeploymentUserFailure' -and $request.reportName -eq 'UserInstallStatusAggregateByApp') { throw 'Synthetic user report failure.' }
                return @{id='fixture-job';status='completed';url="https://fixture.invalid/$($request.reportName)"}
            }
            if ($Scenario -eq 'PartialAssignments' -and ($Uri -like '*expand=assignments*' -or $Uri -like '*/assignments')) { throw 'Synthetic assignment lookup failure.' }
            if ($Scenario -eq 'UsageMissing' -and $Uri -like '*managedDevices*Missing*') { return @{value=@()} }
            if ($Scenario -eq 'PendingApproval' -and $Method -eq 'DELETE') { throw 'x-msft-approval-code: 00000000-0000-0000-0000-000000000007' }
            if ($Scenario -eq 'DeleteBatchAssignmentFailure' -and $Uri -like '*/00000000-0000-0000-0000-000000000008/assignments') { throw 'Synthetic assignment lookup failure.' }
            if ($Scenario -like 'DeleteBatch*' -and $Method -eq 'DELETE') {
                if ($Scenario -eq 'DeleteBatchAllFailed' -or ($Scenario -eq 'DeleteBatchDependencyFailure' -and $Uri -like '*/00000000-0000-0000-0000-000000000008')) {
                    throw 'Cannot delete this app as it is the parent of another app: 00000000-0000-0000-0000-000000000010.'
                }
                if ($Scenario -eq 'DeleteBatchApproval' -and $Uri -like '*/00000000-0000-0000-0000-000000000008') { throw 'x-msft-approval-code: 00000000-0000-0000-0000-000000000007' }
            }
            if ($Scenario -eq 'CleanupOrphan' -and $Uri -like '*managedDevices*azureADDeviceId*eq*') { return @{value=@()} }
            if ($Method -in @('DELETE','POST') -and $Uri -notlike '*exportJobs*') { return }
            if ($Uri -like '*exportJobs*') { return @{id='fixture-job';status='completed';url='https://fixture.invalid/report'} }
            if ($Uri -like '*windowsQualityUpdateProfiles*') {
                if ($Uri -like '*skiptoken*') {
                    return @{value=@([pscustomobject]@{id='00000000-0000-0000-0000-000000000022';displayName='Fixture Policy'})}
                }
                $page = @{value=@([pscustomobject]@{id='00000000-0000-0000-0000-000000000021';displayName='Fixture Policy'})}
                if ($Scenario -eq 'DuplicateQualityPolicies') {
                    $page['@odata.nextLink'] = 'https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdateProfiles?$skiptoken=fixture'
                }
                return $page
            }
            if ($Uri -like '*windowsAutopilotDeviceIdentities*') { return @{value=@()} }
            if ($Uri -like '*auditLogs/signIns*') { return @{value=@([pscustomobject]@{createdDateTime=[datetime]::UtcNow.ToString('o');userPrincipalName='fixture@example.invalid';userDisplayName='Fixture User';appDisplayName='Fixture App';deviceDetail=@{operatingSystem='Windows';browser='Fixture'};ipAddress='192.0.2.1'})} }
            if ($Uri -match '/managedDevices/[^/?]+\??') {
                if ($Uri -like '*/users*') { return @{value=@($fixtureUser)} }
                return $fixtureDevice
            }
            if ($Uri -like '*deviceManagement/managedDevices*') { return @{value=@($fixtureDevice)} }
            if ($Uri -like '*mobileApps*') {
                if ($Uri -like '*/assignments*') { return @{value=$fixtureApp.assignments} }
                return @{value=$fixtureApps}
            }
            if ($Uri -like '*transitiveMembers*') { return @{value=@($fixtureDirectory)} }
            if ($Uri -match '/groups/[^/?]+/members') { return @{value=@()} }
            if ($Uri -match '/groups/[^/?]+') { return $fixtureGroup }
            if ($Uri -like '*/groups?*') { return @{value=@($fixtureGroup)} }
            if ($Uri -like '*/users?*') { return @{value=@($fixtureUser)} }
            if ($Uri -match '/users/[^/?]+') { return $fixtureUser }
            if ($Uri -like '*/devices?*') { return @{value=@($fixtureDirectory)} }
            throw "Unhandled offline Graph URI: $Uri"
        }
        function Invoke-WebRequest {
            param($Uri,$OutFile,[switch]$UseBasicParsing)
            if ($Scenario -like 'Deployment*') {
                $csv = Join-Path $OutputRoot 'download-fixture.csv'
                if ($Uri -eq 'https://fixture.invalid/DeviceInstallStatusByApp') {
                    @(
                        [pscustomobject]@{DeviceId=$managedId;DeviceName='Fixture-PC';UserPrincipalName='first@example.invalid';InstallState='1';AppInstallState_loc='Installed';ErrorCode='0';AppVersion='1.9'}
                        [pscustomobject]@{DeviceId=$managedId;DeviceName='Fixture-PC';UserPrincipalName='second@example.invalid';InstallState='2';AppInstallState_loc='Failed';ErrorCode='12345';AppVersion='1.8'}
                        [pscustomobject]@{DeviceId='00000000-0000-0000-0000-000000000008';DeviceName='Fixture-PC-2';UserPrincipalName='third@example.invalid';InstallState='5';AppInstallState_loc='Installation en attente';ErrorCode='0';AppVersion='1.9'}
                        [pscustomobject]@{DeviceId='';DeviceName='Unidentified-1';UserPrincipalName='';InstallState='0';AppInstallState_loc='Unknown';ErrorCode='';AppVersion=''}
                        [pscustomobject]@{DeviceId='';DeviceName='Unidentified-2';UserPrincipalName='';InstallState='0';AppInstallState_loc='Unknown';ErrorCode='';AppVersion=''}
                    ) | Export-Csv -LiteralPath $csv -NoTypeInformation
                }
                elseif ($Uri -eq 'https://fixture.invalid/UserInstallStatusAggregateByApp') {
                    [pscustomobject]@{UserPrincipalName='first@example.invalid';InstalledDeviceCount=1;FailedDeviceCount=1} | Export-Csv -LiteralPath $csv -NoTypeInformation
                }
                else { throw "Unexpected deployment fixture URL: $Uri" }
                Compress-Archive -LiteralPath $csv -DestinationPath $OutFile -Force
                return
            }
            if ($Uri -ne 'https://fixture.invalid/report') { throw 'Unexpected external download.' }
            $csv = Join-Path $OutputRoot 'download-fixture.csv'
            [pscustomobject]@{
                DeviceName='Fixture-PC';DeviceId=$managedId;UserId=$userId;ApplicationName='Fixture App'
                ApplicationShortVersion='1.0';ApplicationVersion='1.0';Platform='Windows';Platform_loc='Windows';OSDescription='Windows'
                AppInstallState_loc='Installed';InstallState='Installed';AppInstallState='Installed';AggregateState_loc='Installed';UserPrincipalName='fixture@example.invalid'
            } | Export-Csv -LiteralPath $csv -NoTypeInformation
            Compress-Archive -LiteralPath $csv -DestinationPath $OutFile -Force
        }
        $capturedErrors = @()
        $capturedWarnings = @(); $capturedInformation = @()
        $runId = [guid]::NewGuid().ToString()
        if ($Workflow.Id -eq 'delete-win32-apps') { $Parameters.OutputPath = $OutputRoot }
        $null = & (Join-Path $desktop 'Invoke-WorkflowPresentation.ps1') -ScriptPath $Workflow.FullPath -WorkflowId $Workflow.Id -ScriptArguments $Parameters -ActivityLogPath $OutputRoot -RunId $runId -UiEventSink { param($event) $fixtureEvents.Add($event) } -ErrorVariable capturedErrors -WarningVariable capturedWarnings -InformationVariable capturedInformation 3>$null 6>$null
        if ($Scenario -eq 'Happy' -and $capturedErrors.Count) { throw "Workflow emitted errors: $($capturedErrors -join '; ')" }
        [pscustomobject]@{ Events=$fixtureEvents.ToArray(); Calls=$fixtureCalls.ToArray(); Warnings=$capturedWarnings; Errors=$capturedErrors; Messages=($capturedInformation -join "`n"); RunId=$runId }
    } ($catalog | Where-Object Id -eq $Id) $Arguments $fixtureRoot $Scenario
}

Describe 'Offline endpoint script integration' {
    It 'finds Entra users by name and reports multiple, possible, missing and failed lookups per name' {
        $result = Invoke-OfflineEndpointWorkflow 'entra-user-lookup' @{Names=@('Jane Doe','Sam Lee','Mike Smith','Nobody Here',"Pat O'Brien",'jane doe')} 'UserLookup'
        $rows = @($result.Events | Where-Object { $_.Type -eq 'Rows' })[0].Data
        ($rows | Where-Object Input -eq 'Jane Doe').Status | Should Be 'Found'
        @($rows | Where-Object Input -eq 'Sam Lee' | Where-Object Status -eq 'Multiple').Count | Should Be 2
        ($rows | Where-Object Input -eq 'Mike Smith').Status | Should Be 'PossibleMatch'
        ($rows | Where-Object Input -eq 'Mike Smith').UserPrincipalName | Should Be 'michael@example.invalid'
        ($rows | Where-Object Input -eq 'Nobody Here').Status | Should Be 'NotFound'
        ($rows | Where-Object Input -eq "Pat O'Brien").Status | Should Be 'Failed'
        @($result.Calls | Where-Object { $_.Method -ne 'GET' }).Count | Should Be 0
        $summary = @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data
        $summary.Targeted | Should Be 5
        $summary.Succeeded | Should Be 1
        $summary.NotFound | Should Be 3
        $summary.Failed | Should Be 1
    }
    It 'exports full deployment details, per-device summaries and user status without losing raw versions or errors' {
        $result = Invoke-OfflineEndpointWorkflow 'intune-assignment-win32-deployment-exports' @{AppId='00000000-0000-0000-0000-000000000006';OutputPath=$fixtureRoot} 'DeploymentDetails'
        $result.Messages | Should Match 'Report started: \d{4}-\d{2}-\d{2}'
        $result.Messages | Should Match 'Report ended:'
        $result.Messages | Should Match 'Report elapsed: \d{2}:\d{2}:\d{2}'
        $artifacts = @($result.Events | Where-Object Type -eq 'Artifact')
        $artifacts.Count | Should Be 3
        $device = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -like '*_DeviceStatus' })[0].Data
        $device.Count | Should Be 5
        @($device | Where-Object ErrorCode -eq '12345').Count | Should Be 1
        @($device | Where-Object AppVersion -eq '1.8').Count | Should Be 1
        @($device | Where-Object InstallStateFriendly -eq 'Installation en attente').Count | Should Be 1
        $summary = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -like '*_DeviceSummary' })[0].Data
        $summary.Count | Should Be 4
        ($summary | Where-Object DeviceName -eq 'Fixture-PC').InstallStateFriendly | Should Be 'Failed'
        ($summary | Where-Object DeviceName -eq 'Fixture-PC').ReportRows | Should Be '2'
        @($summary | Where-Object IdentityStatus -eq 'Missing DeviceId').Count | Should Be 2
        @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -like '*_UserStatus' })[0].Data.Count | Should Be 1
        $requests = @($result.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*exportJobs*' })
        $requests.Count | Should Be 2
        foreach ($request in $requests) { ($request.Body | ConvertFrom-Json).localizationType | Should Be 'LocalizedValuesAsAdditionalColumn' }
    }
    It 'retains device exports and reports partial failure if the user report fails' {
        $result = Invoke-OfflineEndpointWorkflow 'intune-assignment-win32-deployment-exports' @{AppId='00000000-0000-0000-0000-000000000006';OutputPath=$fixtureRoot} 'DeploymentUserFailure'
        @($result.Events | Where-Object Type -eq 'Artifact').Count | Should Be 2
        ($result.Errors -join "`n") | Should Match 'Synthetic user report failure'
        $result.Messages | Should Match 'Report elapsed:'
        @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data.Failed | Should Be 1
    }
    It 'supports explicit device-only reporting without requesting a user export' {
        $result = Invoke-OfflineEndpointWorkflow 'intune-assignment-win32-deployment-exports' @{AppId='00000000-0000-0000-0000-000000000006';OutputPath=$fixtureRoot;IncludeUserStatus=$false} 'DeploymentDetails'
        @($result.Events | Where-Object Type -eq 'Artifact').Count | Should Be 2
        @($result.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*exportJobs*' }).Count | Should Be 1
    }
    It 'deduplicates apps requested repeatedly by ID and name' {
        $appId='00000000-0000-0000-0000-000000000006'
        $result = Invoke-OfflineEndpointWorkflow 'intune-assignment-win32-deployment-exports' @{AppId=@($appId,$appId);AppName='Fixture';OutputPath=$fixtureRoot} 'DeploymentDetails'
        @($result.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*exportJobs*' }).Count | Should Be 2
        @($result.Events | Where-Object Type -eq 'Artifact').Count | Should Be 3
    }
    It 'exports separate complete reports for multiple app objects with the same name and ID prefix' {
        $ids=@('00000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000009')
        $result = Invoke-OfflineEndpointWorkflow 'intune-assignment-win32-deployment-exports' @{AppId=$ids;OutputPath=$fixtureRoot} 'DeploymentMultiple'
        $artifacts=@($result.Events | Where-Object Type -eq 'Artifact')
        $artifacts.Count | Should Be 6
        @($artifacts.Data | Select-Object -Unique).Count | Should Be 6
        @($result.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*exportJobs*' }).Count | Should Be 4
        foreach ($id in $ids) {
            $rows=@($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -like "*${id}*_DeviceStatus" })[0].Data
            $rows.Count | Should Be 5
            @($rows.ApplicationId | Select-Object -Unique)[0] | Should Be $id
        }
    }
    It 'keeps identical rapid report runs separate even when ZIP entries retain the same timestamps' {
        $arguments=@{AppId='00000000-0000-0000-0000-000000000006';OutputPath=$fixtureRoot}
        $first=Invoke-OfflineEndpointWorkflow 'intune-assignment-win32-deployment-exports' $arguments 'DeploymentDetails'
        $second=Invoke-OfflineEndpointWorkflow 'intune-assignment-win32-deployment-exports' $arguments 'DeploymentDetails'
        $firstPaths=@(($first.Events | Where-Object Type -eq 'Artifact').Data)
        $secondPaths=@(($second.Events | Where-Object Type -eq 'Artifact').Data)
        $firstPaths.Count | Should Be 3
        $secondPaths.Count | Should Be 3
        @($secondPaths | Where-Object { $_ -in $firstPaths }).Count | Should Be 0
    }
    It 'publishes detail datasets and real artifact paths for all eleven reports' {
        $cases = @(
            @{Id='mobile-inventory';Args=@{OutputPath=$fixtureRoot}}
            @{Id='cloudpc-last-login';Args=@{OutputPath=$fixtureRoot}}
            @{Id='group-devices';Args=@{EntraGroup='Fixture Group';OutputPath=$fixtureRoot}}
            @{Id='device-usage';Args=@{Devices='Fixture-PC';OutputPath=$fixtureRoot}}
            @{Id='quality-updates';Args=@{PolicyName='Fixture Policy';OutputPath=$fixtureRoot}}
            @{Id='intune-script-device-status';Args=@{ScriptType='Remediation';ScriptName='Fixture remediation';OutputPath=$fixtureRoot}}
            @{Id='stale-synced-devices';Args=@{OutputPath=$fixtureRoot}}
            @{Id='discovered-apps';Args=@{Platform='Windows';OutputPath=$fixtureRoot}}
            @{Id='intune-assignment-win32-deployment-exports';Args=@{AppId='00000000-0000-0000-0000-000000000006';OutputPath=$fixtureRoot;IncludeUserStatus=$true}}
            @{Id='all-device-assignments';Args=@{OutputPath=$fixtureRoot}}
            @{Id='group-app-assignments';Args=@{EntraGroup='Fixture Group';OutputPath=$fixtureRoot}}
        )
        foreach ($case in $cases) {
            $result = Invoke-OfflineEndpointWorkflow $case.Id $case.Args
            if (@($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Data.Count }).Count -lt 1) { throw "No data published by $($case.Id)" }
            if (@($result.Events | Where-Object Type -eq 'Artifact').Count -lt 1) { throw "No artifact published by $($case.Id)" }
            foreach ($artifact in @($result.Events | Where-Object Type -eq 'Artifact')) { (Test-Path -LiteralPath $artifact.Data) | Should Be $true }
            $summary = @($result.Events | Where-Object Type -eq 'OperationSummary')
            $summary.Count | Should Be 1
            $summary[0].Data.Affected | Should Be 0
            $summary[0].Data.Failed | Should Be 0
        }
    }
    It 'lists all expedited policies without exporting and runs only the selected ID when names match' {
        $listing = Invoke-OfflineEndpointWorkflow 'quality-updates' @{ListPolicies=$true} 'DuplicateQualityPolicies'
        $choices = @($listing.Events | Where-Object { $_.Type -eq 'Choice' -and $_.Name -eq 'Quality update policies' })[0].Data
        $choices.Count | Should Be 2
        @($choices.Display | Select-Object -Unique).Count | Should Be 2
        $listing.Calls.Count | Should Be 2
        @($listing.Calls | Where-Object Method -ne 'GET').Count | Should Be 0
        @($listing.Events | Where-Object Type -in @('Rows','Artifact','OperationSummary')).Count | Should Be 0

        $result = Invoke-OfflineEndpointWorkflow 'quality-updates' @{PolicyId=$choices[1].Id;OutputPath=$fixtureRoot} 'DuplicateQualityPolicies'
        $requests = @($result.Calls | Where-Object Method -eq 'POST')
        $requests.Count | Should Be 1
        ($requests[0].Body | ConvertFrom-Json).filter | Should Be "(PolicyId eq '$($choices[1].Id)')"
        @($result.Events | Where-Object Type -eq 'Artifact').Count | Should Be 1
    }
    It 'publishes primary-user and sync outcomes with all Graph commands replaced' {
        $result = Invoke-OfflineEndpointWorkflow 'primary-users' @{Devices='Fixture-PC'}
        @($result.Events | Where-Object Type -eq 'Rows')[0].Data[0].Status | Should Be 'Read'
        $result = Invoke-OfflineEndpointWorkflow 'intune-sync' @{Devices='Fixture-PC'}
        @($result.Calls | Where-Object Method -eq 'SYNC').Count | Should Be 1
        @($result.Events | Where-Object Type -eq 'Rows')[0].Data[0].Confirmed | Should Be $false
        $summary = @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data
        $summary.Targeted | Should Be 1
        $summary.Succeeded | Should Be 1
        $summary.Affected | Should Be 1
    }
    It 'reports remediation device states and exports their status details' {
        $result = Invoke-OfflineEndpointWorkflow 'intune-script-device-status' @{ScriptType='Remediation';ScriptName='Fixture remediation';OutputPath=$fixtureRoot} 'ScriptRemediation'
        $rows = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Device status' })[0].Data
        $rows.Count | Should Be 1
        $rows[0].ScriptType | Should Be 'Remediation'
        $rows[0].DeviceName | Should Be 'Fixture-PC'
        $rows[0].DetectionState | Should Be 'success'
        $rows[0].RemediationState | Should Be 'skipped'
        $rows[0].PreRemediationDetectionScriptOutput | Should Be 'Synthetic detection output'
        @($result.Calls | Where-Object { $_.Uri -like '*/deviceHealthScripts/*/deviceRunStates*' }).Count | Should Be 1
        @($result.Events | Where-Object Type -eq 'Artifact').Count | Should Be 1
    }
    It 'reports platform-script run states without using the remediation endpoint' {
        $result = Invoke-OfflineEndpointWorkflow 'intune-script-device-status' @{ScriptType='Platform script';ScriptName='Fixture platform';OutputPath=$fixtureRoot} 'ScriptPlatform'
        $rows = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Device status' })[0].Data
        $rows.Count | Should Be 1
        $rows[0].ScriptType | Should Be 'Platform script'
        $rows[0].RunState | Should Be 'success'
        $rows[0].ResultMessage | Should Be 'Synthetic platform result'
        @($result.Calls | Where-Object { $_.Uri -like '*/deviceManagementScripts/*/deviceRunStates*' }).Count | Should Be 1
        @($result.Events | Where-Object Type -eq 'Artifact').Count | Should Be 1
    }
    It 'loads script choices without retrieving device states or publishing report rows' {
        $result = Invoke-OfflineEndpointWorkflow 'intune-script-device-status' @{ScriptType='All';ListScripts=$true} 'ScriptDiscovery'
        $choices = @($result.Events | Where-Object Type -eq 'ScriptChoices')
        $choices.Count | Should Be 1
        $choices[0].Data.ScriptType | Should Be 'All'
        @($choices[0].Data.Choices).Count | Should Be 2
        @($choices[0].Data.Choices | Where-Object { $_.Id -eq '00000000-0000-0000-0000-000000000011' -and $_.ScriptType -eq 'Remediation' }).Count | Should Be 1
        @($choices[0].Data.Choices | Where-Object { $_.Id -eq '00000000-0000-0000-0000-000000000012' -and $_.ScriptType -eq 'Platform script' }).Count | Should Be 1
        @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Device status' }).Count | Should Be 0
        @($result.Events | Where-Object Type -eq 'Artifact').Count | Should Be 0
        @($result.Calls | Where-Object { $_.Uri -like '*deviceRunStates*' }).Count | Should Be 0
    }
    It 'reports a previously selected script ID without rediscovering or trusting a display-name input' {
        $result = Invoke-OfflineEndpointWorkflow 'intune-script-device-status' @{
            ScriptType='Platform script';ScriptId='00000000-0000-0000-0000-000000000012';OutputPath=$fixtureRoot
        } 'ScriptPlatform'
        $rows = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Device status' })[0].Data
        $rows.Count | Should Be 1
        $rows[0].ScriptName | Should Be 'Fixture platform script'
        @($result.Calls | Where-Object { $_.Uri -match '/deviceManagementScripts\?' }).Count | Should Be 0
        @($result.Calls | Where-Object { $_.Uri -match '/deviceManagementScripts/00000000-0000-0000-0000-000000000012\?' }).Count | Should Be 1
    }
    It 'publishes user and hostname membership additions through the same workflow' {
        $group = '00000000-0000-0000-0000-000000000001'
        $deviceList = Join-Path $fixtureRoot 'add-devices.txt'
        Set-Content -LiteralPath $deviceList -Value @('Fixture-PC',' fixture-pc ','# ignored')
        $deviceResult = Invoke-OfflineEndpointWorkflow 'add-members-to-group' @{GroupId=$group;DeviceListPath=$deviceList}
        $userResult = Invoke-OfflineEndpointWorkflow 'add-members-to-group' @{GroupName='Fixture Group';Users='fixture@example.invalid'}
        foreach ($case in @(@{Run=$deviceResult;Id='00000000-0000-0000-0000-000000000002'}, @{Run=$userResult;Id='00000000-0000-0000-0000-000000000005'})) {
            $posts = @($case.Run.Calls | Where-Object Method -eq 'POST')
            $posts.Count | Should Be 1
            $posts[0].Uri | Should Be "https://graph.microsoft.com/v1.0/groups/$group/members/`$ref"
            ($posts[0].Body | ConvertFrom-Json).'@odata.id' | Should Be "https://graph.microsoft.com/v1.0/directoryObjects/$($case.Id)"
            ($case.Run.Events | Where-Object Type -eq 'Rows').Data[0].Status | Should Be 'Added'
            ($case.Run.Events | Where-Object Type -eq 'OperationSummary').Data.Affected | Should Be 1
        }
    }
    It 'keeps duplicate hostname and ambiguous UPN behavior distinct when adding' {
        $deviceResult = Invoke-OfflineEndpointWorkflow 'add-members-to-group' @{
            GroupName='Fixture Group'; DeviceNames='Fixture-PC'
        } 'AddDuplicateDevices'
        $deviceRows = ($deviceResult.Events | Where-Object Type -eq 'Rows').Data
        ($deviceRows | Where-Object ObjectId -eq '00000000-0000-0000-0000-000000000002').Status | Should Be 'AlreadyMember'
        ($deviceRows | Where-Object ObjectId -eq '00000000-0000-0000-0000-000000000008').Status | Should Be 'Added'
        @($deviceResult.Calls | Where-Object Method -eq 'POST').Count | Should Be 1
        $userResult = Invoke-OfflineEndpointWorkflow 'add-members-to-group' @{
            GroupName='Fixture Group'; Users='fixture@example.invalid'
        } 'AddDuplicateUsers'
        ($userResult.Events | Where-Object Type -eq 'Rows').Data[0].Status | Should Be 'Failed'
        @($userResult.Calls | Where-Object Method -eq 'POST').Count | Should Be 0
    }
    It 'previews direct user removal without a write' {
        $result = Invoke-OfflineEndpointWorkflow 'remove-members-from-group' @{
            GroupName='Fixture Group'; Users=@('fixture@example.invalid','not-direct@example.invalid'); WhatIf=$true
        } 'RemoveMembers'
        $rows = ($result.Events | Where-Object Type -eq 'Rows').Data
        ($rows | Where-Object Input -eq 'fixture@example.invalid').Status | Should Be 'WhatIf'
        ($rows | Where-Object Input -eq 'not-direct@example.invalid').Status | Should Be 'NotFound'
        @($result.Calls | Where-Object Method -ne 'GET').Count | Should Be 0
    }
    It 'removes only the unique device membership reference and skips duplicates across pages' {
        $group = '00000000-0000-0000-0000-000000000001'
        $result = Invoke-OfflineEndpointWorkflow 'remove-members-from-group' @{
            GroupId=$group; DeviceNames=@('Fixture-PC','fixture-pc','Duplicate-PC'); Confirm=$false
        } 'RemoveMembers'
        $rows = ($result.Events | Where-Object Type -eq 'Rows').Data
        $rows.Count | Should Be 2
        ($rows | Where-Object Input -eq 'Duplicate-PC').Status | Should Be 'Unresolved'
        ($rows | Where-Object Input -eq 'Fixture-PC').Status | Should Be 'Removed'
        ($result.Events | Where-Object Type -eq 'OperationSummary').Data.Affected | Should Be 1
        $deletes = @($result.Calls | Where-Object Method -eq 'DELETE')
        $deletes.Count | Should Be 1
        $deletes[0].Uri | Should Be "https://graph.microsoft.com/v1.0/groups/$group/members/00000000-0000-0000-0000-000000000002/`$ref"
    }
    It 'rejects dynamic groups before any membership changes' {
        $detail = try {
            $null = Invoke-OfflineEndpointWorkflow 'remove-members-from-group' @{
                GroupName='Fixture Group'; Users='fixture@example.invalid'; Confirm=$false
            } 'RemoveMembersDynamic'
        }
        catch { $_.Exception.Message }
        $detail | Should Match '^Dynamic, role-assignable'
    }
    It 'reports a failed user removal without blocking the next user' {
        $result = Invoke-OfflineEndpointWorkflow 'remove-members-from-group' @{
            GroupName='Fixture Group'; Users=@('fixture@example.invalid','second@example.invalid'); Confirm=$false
        } 'RemoveMembersPartial'
        $rows = ($result.Events | Where-Object Type -eq 'Rows').Data
        ($rows | Where-Object Input -eq 'fixture@example.invalid').Status | Should Be 'Failed'
        ($rows | Where-Object Input -eq 'second@example.invalid').Status | Should Be 'Removed'
        @($result.Calls | Where-Object Method -eq 'DELETE').Count | Should Be 2
    }
    It 'previews primary-device additions and app deletion without a Graph mutation' {
        $result = Invoke-OfflineEndpointWorkflow 'add-primary-devices-to-group' @{GroupId='00000000-0000-0000-0000-000000000001';UserListPath=$userFile;OutputFile=(Join-Path $fixtureRoot 'primary.csv');WhatIf=$true}
        @($result.Events | Where-Object Type -eq 'Rows')[0].Data[0].Status | Should Be 'WhatIf'
        @($result.Calls | Where-Object Method -in @('POST','DELETE')).Count | Should Be 0
        $result = Invoke-OfflineEndpointWorkflow 'delete-win32-apps' @{AppId='00000000-0000-0000-0000-000000000006';Justification='Synthetic fixture';WhatIf=$true}
        @($result.Calls | Where-Object Method -eq 'DELETE').Count | Should Be 0
        $result.Messages | Should Not Match 'Deleted Win32 app'
    }
    It 'evaluates cleanup guards in preview without deletion or logging calls' {
        $result = Invoke-OfflineEndpointWorkflow 'entra-cleanup' @{Devices='Fixture-PC';WhatIf=$true;ExportCsv=$true;OutputPath=$fixtureRoot}
        @($result.Events | Where-Object Type -eq 'Rows')[0].Data[0].EntraAction | Should Be 'Skipped'
        @($result.Events | Where-Object Type -eq 'Artifact').Count | Should Be 1
        @($result.Calls | Where-Object Method -eq 'DELETE').Count | Should Be 0
    }
    It 'marks failed assignment lookups as incomplete coverage, not an empty success' {
        $result = Invoke-OfflineEndpointWorkflow 'all-device-assignments' @{OutputPath=$fixtureRoot} 'PartialAssignments'
        ($result.Warnings -join "`n") | Should Match 'Failed to read assignments'
        @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data.Failed | Should Be 1
        $result = Invoke-OfflineEndpointWorkflow 'group-app-assignments' @{EntraGroup='Fixture Group';OutputPath=$fixtureRoot} 'PartialAssignments'
        ($result.Warnings -join "`n") | Should Match 'Failed to read assignments'
        @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data.Succeeded | Should Be 0
    }
    It 'includes unresolved device usage inputs instead of reporting only the successful device' {
        $result = Invoke-OfflineEndpointWorkflow 'device-usage' @{Devices=@('Fixture-PC','Missing');OutputPath=$fixtureRoot} 'UsageMissing'
        $summary = @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data
        $summary.Targeted | Should Be 2
        $summary.Succeeded | Should Be 1
        $summary.NotFound | Should Be 1
        $summary.Affected | Should Be 0
    }
    It 'distinguishes pending Multi-Admin Approval from deletion' {
        $result = Invoke-OfflineEndpointWorkflow 'delete-win32-apps' @{AppId='00000000-0000-0000-0000-000000000006';Justification='Synthetic fixture';Confirm=$false} 'PendingApproval'
        $result.Messages | Should Match 'Deletion requires Multi-Admin Approval'
        $result.Messages | Should Match '00000000-0000-0000-0000-000000000007'
        $result.Messages | Should Not Match 'Deleted Win32 app'
    }
    It 'continues a deletion batch after a dependency-blocked app and preserves its error' {
        $ids=@('00000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000009')
        $result = Invoke-OfflineEndpointWorkflow 'delete-win32-apps' @{AppId=$ids;Justification='Synthetic fixture';Confirm=$false;ErrorAction='Stop'} 'DeleteBatchDependencyFailure'
        $deletions=@($result.Calls | Where-Object Method -eq 'DELETE')
        $deletions.Count | Should Be 3
        $deletions[2].Uri | Should Match "$($ids[2])$"
        ($result.Errors -join "`n") | Should Match "Failed to delete 'Retired - Fixture 008'.*Cannot delete this app as it is the parent"
        $result.Messages | Should Match 'Deleted: Retired - Fixture 006'
        $result.Messages | Should Match 'Deleted: Retired - Fixture 009'
        $result.Messages | Should Not Match 'Deleted: Retired - Fixture 008'
        $reportPath = @($result.Events | Where-Object Type -eq 'Artifact')[0].Data
        $report = @(Import-Csv -LiteralPath $reportPath)
        $report.Count | Should Be 3
        ($report[0].PSObject.Properties.Name -join ',') | Should Be 'AppName,AppVersion,AppId,Status,Reason'
        $report[0].Status | Should Be 'Deleted'
        $report[1].Status | Should Be 'Failed'
        $report[1].Reason | Should Match 'parent of another app'
        $report[2].Status | Should Be 'Deleted'
        $summary = @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data
        $summary.Targeted | Should Be 3
        $summary.Succeeded | Should Be 2
        $summary.Failed | Should Be 1
        $result.Messages | Should Match 'Apps targeted: 3 \| Succeeded: 2 \| Failed: 1'
        $records = @(Get-Content -LiteralPath (Join-Path $fixtureRoot "task-delete-win32-apps-$([datetime]::UtcNow.ToString('yyyy-MM-dd')).jsonl") | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object RunId -eq $result.RunId)
        $records.Count | Should Be 2
        $records[1].Summary.Failed | Should Be 1
        $records[1].State | Should Be 'Failed/partial'
    }
    It 'skips deletion when assignments cannot be checked and continues the batch' {
        $ids=@('00000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000009')
        $result = Invoke-OfflineEndpointWorkflow 'delete-win32-apps' @{AppId=$ids;Justification='Synthetic fixture';Confirm=$false} 'DeleteBatchAssignmentFailure'
        $deletions=@($result.Calls | Where-Object Method -eq 'DELETE')
        $deletions.Count | Should Be 2
        @($deletions | Where-Object Uri -like "*$($ids[1])").Count | Should Be 0
        ($result.Errors -join "`n") | Should Match 'Failed to read assignments.*Synthetic assignment lookup failure'
        $result.Messages | Should Match 'Deleted: Retired - Fixture 009'
        $report = @(Import-Csv -LiteralPath @($result.Events | Where-Object Type -eq 'Artifact')[0].Data)
        $report[1].Status | Should Be 'Failed'
        $report[1].Reason | Should Match 'Assignment lookup failed'
    }
    It 'reports every app failure even when no deletion succeeds' {
        $ids=@('00000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000009')
        $result = Invoke-OfflineEndpointWorkflow 'delete-win32-apps' @{AppId=$ids;Justification='Synthetic fixture';Confirm=$false} 'DeleteBatchAllFailed'
        @($result.Calls | Where-Object Method -eq 'DELETE').Count | Should Be 3
        foreach ($suffix in @('006','008','009')) { ($result.Errors -join "`n") | Should Match "Failed to delete 'Retired - Fixture $suffix'" }
        $result.Messages | Should Not Match 'Deleted:'
        $report = @(Import-Csv -LiteralPath @($result.Events | Where-Object Type -eq 'Artifact')[0].Data)
        @($report | Where-Object Status -eq 'Failed').Count | Should Be 3
        $summary = @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data
        $summary.Succeeded | Should Be 0
        $summary.Affected | Should Be 0
        $summary.Failed | Should Be 3
    }
    It 'continues after a pending approval without claiming that app was deleted' {
        $ids=@('00000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000009')
        $result = Invoke-OfflineEndpointWorkflow 'delete-win32-apps' @{AppId=$ids;Justification='Synthetic fixture';Confirm=$false} 'DeleteBatchApproval'
        @($result.Calls | Where-Object Method -eq 'DELETE').Count | Should Be 3
        ($result.Errors -join "`n") | Should Not Match 'Failed to delete'
        $result.Messages | Should Match 'Deletion requires Multi-Admin Approval'
        $result.Messages | Should Match '00000000-0000-0000-0000-000000000007'
        $result.Messages | Should Not Match 'Deleted: Retired - Fixture 008'
        $result.Messages | Should Match 'Deleted: Retired - Fixture 009'
        $report = @(Import-Csv -LiteralPath @($result.Events | Where-Object Type -eq 'Artifact')[0].Data)
        $report[1].Status | Should Be 'PendingApproval'
        $report[1].Reason | Should Match '00000000-0000-0000-0000-000000000007'
        @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data.PendingApproval | Should Be 1
    }
    It 'previews a deletion batch without submitting any deletion requests' {
        $ids=@('00000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000009')
        $result = Invoke-OfflineEndpointWorkflow 'delete-win32-apps' @{AppId=$ids;Justification='Synthetic fixture';WhatIf=$true} 'DeleteBatchDependencyFailure'
        @($result.Calls | Where-Object Method -eq 'DELETE').Count | Should Be 0
        @($result.Calls | Where-Object Uri -like '*/assignments').Count | Should Be 3
        $result.Errors.Count | Should Be 0
        $result.Messages | Should Not Match 'Deleted:'
        $report = @(Import-Csv -LiteralPath @($result.Events | Where-Object Type -eq 'Artifact')[0].Data)
        @($report | Where-Object Status -eq 'WhatIf').Count | Should Be 3
        $summary = @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data
        $summary.Succeeded | Should Be 0
        $summary.Affected | Should Be 0
        $summary.Skipped | Should Be 3
    }
    It 'previews eligible orphan cleanup without deleting or submitting logs' {
        $result = Invoke-OfflineEndpointWorkflow 'entra-cleanup' @{Devices='Fixture-PC';WhatIf=$true;OutputPath=$fixtureRoot} 'CleanupOrphan'
        @($result.Events | Where-Object Type -eq 'Rows')[0].Data[0].EntraAction | Should Be 'WhatIf'
        @($result.Calls | Where-Object Method -eq 'DELETE').Count | Should Be 0
    }
    It 'requires UserColumn when binding CSV user input' {
        $csvPath = Join-Path $fixtureRoot 'user-input.csv'
        Set-Content -LiteralPath $csvPath -Value "UPN`r`nfixture@example.invalid"
        $workflow = $catalog | Where-Object Id -eq 'add-members-to-group'
        $rejected = $false
        try { $null = Get-EndpointArguments $workflow @{GroupId='00000000-0000-0000-0000-000000000001';UserListPath=$csvPath} @('GroupName','Users') } catch { $rejected = $true }
        $rejected | Should Be $true
        $result = Invoke-OfflineEndpointWorkflow 'add-members-to-group' @{GroupId='00000000-0000-0000-0000-000000000001';UserListPath=$csvPath;UserColumn='UPN'}
        @($result.Calls | Where-Object Method -eq 'POST').Count | Should Be 1
    }
    It 'reads CSV column headers without consuming the whole input file' {
        $csvPath = Join-Path $fixtureRoot 'header-input.csv'
        Set-Content -LiteralPath $csvPath -Value "`"User, UPN`",Department`r`nfixture@example.invalid,IT"
        $headers = @(& (Get-Module EndpointToolboxUI) { param($path) Get-EndpointUserColumns $path } $csvPath)
        $headers.Count | Should Be 2
        $headers[0] | Should Be 'User, UPN'
    }
}

Remove-Item -LiteralPath $userFile -Force
Get-ChildItem -LiteralPath $fixtureRoot -File | Remove-Item -Force
Remove-Item -LiteralPath $fixtureRoot
