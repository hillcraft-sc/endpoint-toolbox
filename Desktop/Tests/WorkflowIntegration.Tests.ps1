$desktop = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
$catalog = @(Get-EndpointCatalog)
$fixtureRoot = Join-Path $env:TEMP "EndpointToolbox-tests-$([guid]::NewGuid())"
$null = New-Item -Path $fixtureRoot -ItemType Directory
$userFile = Join-Path $fixtureRoot 'users.txt'
Set-Content -LiteralPath $userFile -Value 'fixture@example.invalid'

function Invoke-OfflineEndpointWorkflow {
    param([string]$Id, [hashtable]$Arguments, [string]$Scenario = 'Happy', [switch]$CaptureFailure, [switch]$Direct, [string]$SignInAction = 'New')
    & {
        param($Workflow, $Parameters, $OutputRoot, $Scenario, $CaptureFailure, $Direct, $SignInAction)
        $fixtureCalls = [Collections.Generic.List[object]]::new()
        $fixtureEvents = [Collections.Generic.List[object]]::new()
        $fixtureProgress = [Collections.Generic.List[object]]::new()
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
        function Get-MgContext {
            $scopes = @('DeviceManagementManagedDevices.Read.All','Device.Read.All','GroupMember.ReadWrite.All')
            if ($Scenario -eq 'ListGroupHiddenAllowed') { $scopes += 'Member.Read.Hidden' }
            [pscustomobject]@{Account=$(if ($Scenario -eq 'SignInHistoryOtherAccount') { 'other@example.invalid' } else { 'fixture@example.invalid' });TenantId=$(if ($Scenario -eq 'SignInHistoryOtherTenant') { 'other-tenant' } else { 'fixture-tenant' });Environment='Global';AuthType='Delegated';Scopes=$scopes}
        }
        if ($Scenario -like 'SignInHistory*') {
            function Write-Progress {
                param([string]$Activity, [string]$Status, [switch]$Completed)
                $fixtureProgress.Add([pscustomobject]@{ Activity=$Activity; Status=$Status; Completed=$Completed.IsPresent; Calls=$fixtureCalls.Count })
            }
        }
        function Connect-MgGraph { throw 'Unexpected real sign-in path in offline fixture.' }
        function Disconnect-MgGraph { throw 'Unexpected disconnect in offline fixture.' }
        function Start-Sleep { param($Seconds) }
        function Get-MgDeviceManagementManagedDevice { param($Filter,$ManagedDeviceId) $fixtureDevice }
        function Sync-MgDeviceManagementManagedDevice { param($ManagedDeviceId,$ErrorAction) $fixtureCalls.Add([pscustomobject]@{Method='SYNC';Uri=$ManagedDeviceId}) }
        function Invoke-RestMethod { throw 'A logging webhook must never be called by these offline fixtures.' }
        function Invoke-MgGraphRequest {
            param($Method='GET',$Uri,$Body,$ContentType,$OutputType,$Headers)
            $fixtureCalls.Add([pscustomobject]@{Method=$Method;Uri=$Uri;Body=$Body;Headers=$Headers})
            if ($Scenario -like 'SignInHistory*') {
                if ($Method -ne 'GET') { throw 'Sign-in history must be read-only.' }
                if ($Uri -like 'https://graph.microsoft.com/v1.0/users?*') {
                    if ($Scenario -eq 'SignInHistoryMissing') { return @{value=@()} }
                    $matchedUser = @{id=$userId;userPrincipalName='fixture@example.invalid';displayName='Fixture User';userType='Member'}
                    if ($Scenario -eq 'SignInHistoryGuest') { $matchedUser.userType = 'Guest' }
                    if ($Scenario -eq 'SignInHistoryAmbiguous') { return @{value=@($matchedUser,$matchedUser)} }
                    return @{value=@($matchedUser)}
                }
                if ($Uri -notlike 'https://graph.microsoft.com/beta/auditLogs/signIns?*') { throw "Unexpected sign-in history URL: $Uri" }
                if ($Scenario -eq 'SignInHistoryEmpty') { return @{value=@()} }
                if ($Scenario -eq 'SignInHistoryMalformed') { return @{value='invalid'} }
                if ($Uri -like '*skiptoken*') {
                    if ($Scenario -eq 'SignInHistoryPageFailure') { throw 'Synthetic sign-in page failure.' }
                    if ($Scenario -eq 'SignInHistoryThreePages' -and $Uri -notlike '*skiptoken=last*') {
                        return @{value=@(@{id='middle';isInteractive=$false;status=@{errorCode=0}});'@odata.nextLink'='https://graph.microsoft.com/beta/auditLogs/signIns?$skiptoken=last'}
                    }
                    if ($Scenario -eq 'SignInHistoryLarge') { return @{value=@(@{id='last';createdDateTime='2026-01-01T00:00:00Z';isInteractive=$false;status=@{errorCode=0}})} }
                    return @{value=@(@{id='unknown';createdDateTime='2026-01-01T00:00:00Z';isInteractive=$false;status=@{}})}
                }
                $next = 'https://graph.microsoft.com/beta/auditLogs/signIns?$skiptoken=fixture'
                if ($Scenario -eq 'SignInHistoryUnsafe') { $next = 'https://example.invalid/beta/auditLogs/signIns?$skiptoken=fixture' }
                if ($Scenario -eq 'SignInHistoryRepeat') { $next = $Uri }
                if ($Scenario -eq 'SignInHistoryLarge') {
                    $pageCount = if ($Uri -match '\$top=100$') { 100 } else { 1000 }
                    return @{value=@(1..$pageCount | ForEach-Object { @{id="fixture-$_";createdDateTime='2026-01-02T00:00:00Z';isInteractive=$true;status=@{errorCode=0}} });'@odata.nextLink'=$next}
                }
                if ($Scenario -eq 'SignInHistorySuccessPage') { return @{value=@(@{id='success';isInteractive=$true;status=@{errorCode=0}});'@odata.nextLink'=$next} }
                return @{value=@(
                    @{id='failed';createdDateTime='2026-01-03T00:00:00Z';userPrincipalName='fixture@example.invalid';isInteractive=$true;status=@{errorCode=50126;failureReason='Synthetic failure';additionalDetails='Check credentials'};appDisplayName='Fixture App';correlationId='fixture-correlation';deviceDetail=@{displayName='Fixture-PC'};location=@{city='Fixture City';countryOrRegion='ZZ'}}
                    @{id='success';createdDateTime='2026-01-02T00:00:00Z';isInteractive=$false;status=@{errorCode=0}}
                );'@odata.nextLink'=$next}
            }
            if ($Scenario -like 'CloudInventory*') {
                if ($Method -ne 'GET' -or $Uri -notlike 'https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/cloudPCs*') {
                    throw "Unexpected Cloud PC fixture request: $Method $Uri"
                }
                if ($Scenario -eq 'CloudInventoryEmpty') { return @{value=@()} }
                if ($Scenario -eq 'CloudInventoryMalformed') { return @{value='not an array'} }
                if ($Scenario -eq 'CloudInventoryMissingId') { return @{value=@(@{displayName='Missing ID'})} }
                if ($Uri -like '*skiptoken*') {
                    if ($Scenario -eq 'CloudInventoryFailure') { throw 'Synthetic Cloud PC page failure.' }
                    return @{value=@(
                        @{id='fixture-cloud-2';status='notProvisioned';userPrincipalName='fixture@example.invalid';servicePlanName='Fixture plan'}
                        @{id='fixture-cloud-3';status='failed';userPrincipalName='other@example.invalid';productType='devBox'}
                    )}
                }
                $next = 'https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/cloudPCs?$skiptoken=fixture'
                if ($Scenario -eq 'CloudInventoryUnsafe') { $next = 'https://example.invalid/beta/deviceManagement/virtualEndpoint/cloudPCs?$skiptoken=fixture' }
                if ($Scenario -eq 'CloudInventoryRepeat') { $next = $Uri }
                return @{value=@(@{
                    id='fixture-cloud-1';displayName='Fixture Cloud PC';managedDeviceName='Fixture-PC'
                    provisioningPolicyName='Fixture policy';imageDisplayName='Fixture image';servicePlanName='Fixture plan'
                    productType='enterprise';status='provisioned';userPrincipalName='fixture@example.invalid'
                    lastModifiedDateTime='2026-01-03T00:00:00Z';onPremisesConnectionName='Fixture network'
                    diskEncryptionState='encryptedUsingPlatformManagedKey';managedDeviceId=$managedId;aadDeviceId=$deviceId
                    partnerAgentInstallResults=@(
                        @{isThirdPartyPartner=$true;partnerAgentName='citrix';installStatus='installed'}
                        @{isThirdPartyPartner=$false;partnerAgentName='microsoft';installStatus='installed'}
                    )
                });'@odata.nextLink'=$next}
            }
            if ($Scenario -like 'AppInvest*') {
                $managed = @{id=$managedId;deviceName='Fixture-PC';serialNumber='SYNTHETIC';userPrincipalName='fixture@example.invalid';lastSyncDateTime='2026-01-03T00:00:00Z';operatingSystem='Windows';osVersion='11'}
                $app = @{id=$appId;displayName='Fixture App';displayVersion='1.0';'@odata.type'='#microsoft.graph.win32LobApp';installExperience=@{runAsAccount='system'};minimumSupportedWindowsRelease='Windows11_23H2'}
                if ($Scenario -eq 'AppInvestSnapshot') {
                    $managed.osVersion = '10.0.22621'
                    $managed.azureADDeviceId = $deviceId
                    $app.lastModifiedDateTime = '2026-01-04T00:00:00Z'
                    $app.allowedArchitectures = 'x64'
                    $app.rules = @(
                        @{'@odata.type'='#microsoft.graph.win32LobAppFileSystemRule';ruleType='detection';path='C:\Fixture';fileOrFolderName='fixture.exe'}
                        @{'@odata.type'='#microsoft.graph.win32LobAppPowerShellScriptRule';ruleType='detection';scriptContent='synthetic-script-not-for-report';runAs32Bit=$false}
                    )
                    $app.returnCodes = @(@{returnCode=1603;type='failed'}, @{returnCode=3010;type='softReboot'})
                }
                if ($Scenario -eq 'AppInvestNoRows') { $app.Remove('installExperience') }
                if ($Scenario -eq 'AppInvestApostrophe') { $managed.deviceName="Fixture O'Brien"; $app.displayName="App O'Brien" }
                if ($Uri -match '/managedDevices(?:/[^/?]+)?\?') {
                    if ($Uri -like '*processorArchitecture*') { return @{id=$managedId;processorArchitecture='arm64'} }
                    if ($Scenario -eq 'AppInvestMissingDevice') { return @{value=@()} }
                    if ($Uri -match '/managedDevices/') { return $managed }
                    if ($Scenario -eq 'AppInvestDuplicateDevice') { return @{value=@($managed,$managed)} }
                    return @{value=@($managed)}
                }
                if ($Uri -match '/mobileApps\?') {
                    if ([uri]::UnescapeDataString($Uri) -like "*isof('microsoft.graph.win32LobApp')*") { return @{value=@($app)} }
                    if ($Scenario -eq 'AppInvestMissingApp') { return @{value=@()} }
                    if ($Scenario -eq 'AppInvestDuplicateApp' -and $Uri -like '*skiptoken*') { return @{value=@($app)} }
                    if ($Scenario -eq 'AppInvestDuplicateApp') { return @{value=@($app);'@odata.nextLink'="$($Uri.Split('?')[0])?`$skiptoken=fixture"} }
                    if ($Scenario -eq 'AppInvestUnsafe') { return @{value=@($app);'@odata.nextLink'='https://example.invalid/beta/deviceAppManagement/mobileApps?$skiptoken=fixture'} }
                    if ($Scenario -eq 'AppInvestMalformed') { return @{value='not an array'} }
                    return @{value=@($app)}
                }
                if ($Uri -match '/mobileApps/[^/?]+$') {
                    if ($Scenario -eq 'AppInvestWrongType') { $app['@odata.type']='#microsoft.graph.iosStoreApp' }
                    return $app
                }
                if ($Uri -like '*/assignments*') {
                    if ($Scenario -eq 'AppInvestAssignmentFailure') { throw 'Synthetic app assignment failure.' }
                    if ($Scenario -eq 'AppInvestNoRows') { return @{value=@()} }
                    if ($Uri -like '*skiptoken*') {
                        return @{value=@(@{intent='uninstall';target=@{'@odata.type'='#microsoft.graph.exclusionGroupAssignmentTarget';groupId=$groupId}})}
                    }
                    return @{value=@(
                        @{intent='required';target=@{'@odata.type'='#microsoft.graph.allDevicesAssignmentTarget'}}
                        @{intent='available';target=@{'@odata.type'='#microsoft.graph.groupAssignmentTarget';groupId=$groupId;deviceAndAppManagementAssignmentFilterId=$directoryId;deviceAndAppManagementAssignmentFilterType='include'}}
                    );'@odata.nextLink'="$Uri`?`$skiptoken=fixture"}
                }
                if ($Uri -like '*/groups/*') { return @{id=$groupId;displayName='Fixture Group'} }
                if ($Uri -like '*/devices(*') { return @{id=$directoryId;deviceId=$deviceId} }
                if ($Uri -like '*/transitiveMemberOf') { return @{value=@(@{id=$groupId})} }
                if ($Uri -like '*/relationships') {
                    return @{value=@(if ($Scenario -eq 'AppInvestSnapshot') {
                        @{'@odata.type'='#microsoft.graph.mobileAppDependency';targetType='child';targetId='00000000-0000-0000-0000-000000000008';targetDisplayName='Fixture dependency';dependencyType='autoInstall'}
                    })}
                }
                if ($Uri -like '*/assignmentFilters/*') {
                    if ($Scenario -eq 'AppInvestFilterFailure') { throw 'Synthetic assignment filter failure.' }
                    return @{id=$directoryId;displayName='Fixture filter';rule='(device.model -eq "Synthetic")'}
                }
                if ($Method -eq 'POST' -and $Uri -like '*exportJobs') {
                    if ($Scenario -eq 'AppInvestReportFailure') { throw 'Synthetic deployment export failure.' }
                    return @{id='fixture-job';status='completed';url='https://fixture.invalid/DeviceInstallStatusByApp'}
                }
                throw "Unexpected app investigation fixture request: $Method $Uri"
            }
            if ($Scenario -like 'Investigation*') {
                $managed = @{
                    id=$managedId;deviceName='Fixture-PC';serialNumber='SYNTHETIC';azureADDeviceId=$deviceId
                    userPrincipalName='fixture@example.invalid';operatingSystem='Windows';osVersion='11'
                    complianceState='compliant';lastSyncDateTime='2026-01-03T00:00:00Z'
                }
                if ($Scenario -eq 'InvestigationApostrophe') { $managed.deviceName = "Fixture O'Brien" }
                if ($Scenario -eq 'InvestigationMissingId') { $managed.azureADDeviceId = '' }
                if ($Uri -match '/deviceManagement/managedDevices\?') {
                    if ($Scenario -in @('InvestigationEmpty','InvestigationAutopilotOnly')) { return @{value=@()} }
                    if ($Scenario -in @('InvestigationDuplicate','InvestigationSameName')) {
                        $other = $managed.Clone()
                        $other.id = '00000000-0000-0000-0000-000000000010'
                        if ($Scenario -eq 'InvestigationSameName') { $other.azureADDeviceId = '00000000-0000-0000-0000-000000000011' }
                        return @{value=@($managed,$other)}
                    }
                    return @{value=@($managed)}
                }
                if ($Uri -match '/deviceManagement/managedDevices/[^/?]+/users\?') {
                    if ($Scenario -eq 'InvestigationUserFailure') { throw 'Synthetic primary user failure.' }
                    if ($Scenario -eq 'InvestigationLimitedUser') { return @{value=@(@{id=$userId})} }
                    return @{value=@(@{id=$userId;displayName='Fixture User';userPrincipalName='primary@example.invalid'})}
                }
                if ($Uri -match '/deviceManagement/windowsAutopilotDeviceIdentities(?:\?|$)') {
                    if ([uri]::UnescapeDataString($Uri) -match '[?&]\$select=') {
                        throw 'Synthetic Autopilot HTTP 500: $select is not supported.'
                    }
                    if ($Scenario -in @('InvestigationEmpty','InvestigationSameName')) { return @{value=@()} }
                    if ($Uri -like '*skiptoken*') {
                        if ($Scenario -eq 'InvestigationFailure') { throw 'Synthetic Autopilot page failure.' }
                        return @{value=@(@{id='00000000-0000-0000-0000-000000000008';serialNumber='SYNTHETIC';displayName='Other fixture';managedDeviceId='';azureActiveDirectoryDeviceId=''})}
                    }
                    $autopilot = @{id=$appId;serialNumber='SYNTHETIC';displayName='Fixture-PC';managedDeviceId=$managedId;azureActiveDirectoryDeviceId=$deviceId;groupTag='Fixture';enrollmentState='enrolled';lastContactedDateTime='2026-01-02T00:00:00Z';productKey='SYNTHETIC-NOT-A-PRODUCT-KEY'}
                    if ($Scenario -eq 'InvestigationConflict') { $autopilot.azureActiveDirectoryDeviceId = '00000000-0000-0000-0000-000000000009' }
                    if ($Scenario -eq 'InvestigationInvalidId') { $autopilot.azureActiveDirectoryDeviceId = 'invalid' }
                    if ($Scenario -eq 'InvestigationDuplicate') { $autopilot.managedDeviceId = '' }
                    if ($Scenario -eq 'InvestigationAutopilotOnly') { $autopilot.managedDeviceId = ''; $autopilot.azureActiveDirectoryDeviceId = '' }
                    if ($Scenario -eq 'InvestigationClean') { return @{value=@($autopilot)} }
                    $next = 'https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?$skiptoken=fixture'
                    if ($Scenario -eq 'InvestigationUnsafe') { $next = 'https://example.invalid/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?$skiptoken=fixture' }
                    return @{value=@($autopilot);'@odata.nextLink'=$next}
                }
                if ($Uri -like '*/v1.0/devices?*') {
                    if ($Scenario -eq 'InvestigationEmpty') { return @{value=@()} }
                    $decoded = [uri]::UnescapeDataString($Uri)
                    if ($decoded -like "*displayName eq 'Fixture-PC'*" -or $decoded -like "*deviceId eq '$deviceId'*") {
                        return @{value=@(@{id=$directoryId;deviceId=$deviceId;displayName='Fixture-PC';accountEnabled=$true;trustType='AzureAd';operatingSystem='Windows';approximateLastSignInDateTime='2026-01-01T00:00:00Z'})}
                    }
                    if ($Scenario -eq 'InvestigationApostrophe' -and $decoded -like "*displayName eq 'Fixture O''Brien'*") {
                        return @{value=@(@{id=$directoryId;deviceId=$deviceId;displayName="Fixture O'Brien";accountEnabled=$true})}
                    }
                    return @{value=@()}
                }
                throw "Unexpected investigation fixture request: $Method $Uri"
            }
            if ($Scenario -like 'ListGroup*') {
                $fixtureGroupId = $fixtureGroup.id
                if ($Uri -like "*/v1.0/groups/$fixtureGroupId`?*") {
                    return @{id=$(if ($Scenario -eq 'ListGroupWrongId') { $directoryId } else { $fixtureGroupId });displayName='Fixture Group';visibility='Private'}
                }
                if ($Uri -like '*/v1.0/groups?*') {
                    if ($Scenario -eq 'ListGroupMissing') { return @{value=@()} }
                    $name = if ($Scenario -eq 'ListGroupApostrophe') { "Fixture O'Brien" } else { 'Fixture Group' }
                    $group = @{id=$fixtureGroupId;displayName=$name;visibility='Private'}
                    if ($Scenario -in @('ListGroupHidden','ListGroupHiddenAllowed')) { $group.visibility = 'HiddenMembership' }
                    if ($Scenario -eq 'ListGroupDuplicate') {
                        if ($Uri -like '*skiptoken*') { return @{value=@(@{id=$directoryId;displayName=$name;visibility='Private'})} }
                        return @{value=@($group);'@odata.nextLink'='https://graph.microsoft.com/v1.0/groups?$skiptoken=fixture'}
                    }
                    return @{value=@($group)}
                }
                if ($Uri -like "*/beta/groups/$fixtureGroupId/members?*" -or $Uri -like "*/beta/groups/$fixtureGroupId/transitiveMembers?*") {
                    $relationship = if ($Uri -like '*/transitiveMembers?*') { 'transitiveMembers' } else { 'members' }
                    if ($Scenario -in @('ListGroupEmpty','ListGroupHiddenAllowed')) { return @{value=@()} }
                    if ($Uri -like '*skiptoken*') {
                        if ($Scenario -eq 'ListGroupFailure') { throw 'Synthetic member page failure.' }
                        if ($Scenario -eq 'ListGroupRepeat') {
                            return @{value=@();'@odata.nextLink'=$Uri}
                        }
                        $pageMembers = @(
                            @{id=$directoryId;'@odata.type'='#microsoft.graph.device';displayName='Fixture-PC'}
                            @{id=$appId;'@odata.type'='#microsoft.graph.servicePrincipal';displayName='Fixture application'}
                            @{id=$managedId;'@odata.type'='#microsoft.graph.group';displayName='Nested group'}
                            @{id='00000000-0000-0000-0000-000000000008';'@odata.type'='#microsoft.graph.orgContact'}
                        )
                        if ($relationship -eq 'transitiveMembers') {
                            $pageMembers += @(
                                @{id='00000000-0000-0000-0000-000000000009';'@odata.type'='#microsoft.graph.user';displayName='Indirect user'}
                                @{id=$directoryId;'@odata.type'='#microsoft.graph.device';displayName='Fixture-PC'}
                            )
                        }
                        return @{value=$pageMembers}
                    }
                    $next = "https://graph.microsoft.com/beta/groups/$fixtureGroupId/$relationship`?`$skiptoken=fixture"
                    if ($Scenario -eq 'ListGroupUnsafe') { $next = "https://example.invalid/beta/groups/$fixtureGroupId/members?`$skiptoken=fixture" }
                    if ($Scenario -eq 'ListGroupWrongPath') { $next = "https://graph.microsoft.com/beta/groups/$fixtureGroupId/members?`$skiptoken=fixture" }
                    if ($Scenario -eq 'ListGroupMalformed') { return @{value='not a collection'} }
                    if ($Scenario -eq 'ListGroupInvalidMember') { return @{value=@(@{id=$userId;displayName='Fixture User'})} }
                    return @{value=@(@{id=$userId;'@odata.type'='#microsoft.graph.user';displayName='Fixture User';userPrincipalName='fixture@example.invalid'});'@odata.nextLink'=$next}
                }
                throw "Unexpected group member fixture request: $Method $Uri"
            }
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
            if ($Scenario -like 'DeploymentTriage*' -and $Method -eq 'GET' -and $Uri -like '*/managedDevices/*?*') {
                if ($Uri -notlike "*/$managedId`?*") { return @{id=$managedId;osVersion='Do not use'} }
                if ($Scenario -eq 'DeploymentTriageLookupFailure') { throw 'Synthetic device lookup failure.' }
                return @{id=$managedId;osVersion='10.0.26100';lastSyncDateTime=[datetimeoffset]::UtcNow.AddDays(-3).ToString('o')}
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
            if ($Uri -like '*auditLogs/signIns*') {
                if ($Scenario -eq 'UsageAuditFailed') { throw 'Synthetic audit lookup failure.' }
                if ($Scenario -eq 'UsageEmpty') { return @{value=@()} }
                $signIn = [pscustomobject]@{createdDateTime=[datetime]::UtcNow.ToString('o');userPrincipalName='fixture@example.invalid';userDisplayName='Fixture User';appDisplayName='Fixture App';deviceDetail=@{operatingSystem='Windows';browser='Fixture'};ipAddress='192.0.2.1'}
                if ($Scenario -in @('UsageMismatch','UsageTie')) {
                    $other = $signIn.PSObject.Copy()
                    $other.userPrincipalName = 'observed@example.invalid'
                    return @{value=@($signIn, $signIn, $signIn, $other; if ($Scenario -eq 'UsageMismatch') {
                        $earlier = $other.PSObject.Copy()
                        $earlier.createdDateTime = [datetime]::UtcNow.AddDays(-1).ToString('o')
                        $earlier
                    })}
                }
                return @{value=@($signIn)}
            }
            if ($Uri -match '/managedDevices/[^/?]+\??') {
                if ($Uri -like '*/users*') {
                    if ($Scenario -eq 'UsagePrimaryFailed') { throw 'Synthetic assigned user lookup failure.' }
                    if ($Scenario -eq 'UsageUnassigned') { return @{value=@()} }
                    return @{value=@($fixtureUser)}
                }
                return $fixtureDevice
            }
            if ($Scenario -like 'Discovered*' -and $Uri -like '*managedDevices?*') {
                if ($Scenario -eq 'DiscoveredMissing') { return @{value=@()} }
                if ($Uri -like '*skiptoken*') {
                    return @{value=@([pscustomobject]@{id='00000000-0000-0000-0000-000000000033';deviceName="Fixture O'Brien"})}
                }
                $page = @{value=@([pscustomobject]@{id=$managedId;deviceName="Fixture O'Brien"})}
                if ($Scenario -eq 'DiscoveredDuplicate') {
                    $page['@odata.nextLink'] = 'https://graph.microsoft.com/beta/deviceManagement/managedDevices?$skiptoken=fixture'
                }
                return $page
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
            if ($Scenario -like 'Deployment*' -or $Scenario -like 'AppInvest*') {
                $csv = Join-Path $OutputRoot 'download-fixture.csv'
                if ($Uri -eq 'https://fixture.invalid/DeviceInstallStatusByApp') {
                    $reportRows = @(
                        [pscustomobject]@{DeviceId=$managedId;DeviceName='Fixture-PC';UserPrincipalName='first@example.invalid';InstallState='1';AppInstallState_loc='Installed';ErrorCode='0';AppVersion='1.9'}
                        [pscustomobject]@{DeviceId=$managedId;DeviceName='Fixture-PC';UserPrincipalName='second@example.invalid';InstallState='2';AppInstallState_loc='Failed';ErrorCode='12345';AppVersion='1.8'}
                        [pscustomobject]@{DeviceId='00000000-0000-0000-0000-000000000008';DeviceName='Fixture-PC-2';UserPrincipalName='third@example.invalid';InstallState='5';AppInstallState_loc='Installation en attente';ErrorCode='0';AppVersion='1.9'}
                        [pscustomobject]@{DeviceId='';DeviceName='Unidentified-1';UserPrincipalName='';InstallState='0';AppInstallState_loc='Unknown';ErrorCode='';AppVersion=''}
                        [pscustomobject]@{DeviceId='';DeviceName='Unidentified-2';UserPrincipalName='';InstallState='0';AppInstallState_loc='Unknown';ErrorCode='';AppVersion=''}
                    )
                    if ($Scenario -like 'DeploymentTriage*') {
                        $reportRows[1].AppInstallState_loc = 'Échec'
                        $duplicate = $reportRows[1].PSObject.Copy()
                        $duplicate.ErrorCode = '0x3039'
                        $reportRows += $duplicate
                        $reportRows[2].InstallState = '-1'
                        $reportRows[2].ErrorCode = '0'
                        $reportRows[3].InstallState = '2'
                        $reportRows[3].ErrorCode = '0x3039'
                        $reportRows[4].InstallState = '2'
                        $reportRows[4].ErrorCode = '0x3039'
                    }
                    if ($Scenario -eq 'AppInvestNoRows') { $reportRows = @($reportRows | Where-Object DeviceId -ne $managedId) }
                    if ($Scenario -eq 'AppInvestInstalled') { $reportRows = @($reportRows | Where-Object { $_.DeviceId -eq $managedId -and $_.InstallState -eq '1' }) }
                    if ($Scenario -eq 'AppInvestMalformedReport') {
                        $reportRows = @([pscustomobject]@{DeviceName='Fixture-PC';InstallState='1'})
                    }
                    $reportRows | Export-Csv -LiteralPath $csv -NoTypeInformation
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
            $reportRows = @([pscustomobject]@{
                DeviceName='Fixture-PC';DeviceId=$managedId;UserId=$userId;ApplicationName='Fixture App'
                ApplicationShortVersion='1.0';ApplicationVersion='1.0';Platform='Windows';Platform_loc='Windows';OSDescription='Windows'
                AppInstallState_loc='Installed';InstallState='Installed';AppInstallState='Installed';AggregateState_loc='Installed';UserPrincipalName='fixture@example.invalid'
                CurrentDeviceUpdateSubstatus='FixtureSubstatus';CurrentDeviceUpdateSubstatus_loc='Fixture update substatus'
            })
            if ($Scenario -like 'Discovered*') {
                $otherRow = $reportRows[0].PSObject.Copy()
                $otherRow.DeviceId = '00000000-0000-0000-0000-000000000033'
                $otherRow.ApplicationShortVersion = '9.0'
                $reportRows += $otherRow
            }
            $reportRows | Export-Csv -LiteralPath $csv -NoTypeInformation
            Compress-Archive -LiteralPath $csv -DestinationPath $OutFile -Force
        }
        $capturedErrors = @()
        $capturedWarnings = @(); $capturedInformation = @()
        $runId = [guid]::NewGuid().ToString()
        if ($Workflow.Id -eq 'delete-win32-apps') { $Parameters.OutputPath = $OutputRoot }
        $output = [Collections.Generic.List[object]]::new()
        $failure = $null
        try {
            if ($Direct) {
                & $Workflow.FullPath @Parameters -ErrorVariable capturedErrors -WarningVariable capturedWarnings -InformationVariable capturedInformation 3>$null 6>$null | ForEach-Object { $output.Add($_) }
            }
            else {
                & (Join-Path $desktop 'Invoke-WorkflowPresentation.ps1') -ScriptPath $Workflow.FullPath -WorkflowId $Workflow.Id -ScriptArguments $Parameters -SignInAction $SignInAction -ActivityLogPath $OutputRoot -RunId $runId -CancellationCheck { $Scenario -eq 'SignInHistoryCancelled' } -UiEventSink {
                    param($event)
                    if ($Scenario -eq 'SignInHistoryPresentationFailure' -and $event.Type -eq 'Rows') { throw 'Synthetic report preparation failure.' }
                    $fixtureEvents.Add($event)
                } -ErrorVariable capturedErrors -WarningVariable capturedWarnings -InformationVariable capturedInformation 3>$null 6>$null | ForEach-Object { $output.Add($_) }
            }
        }
        catch {
            if (-not $CaptureFailure) { throw }
            $failure = $_.Exception.Message
        }
        if ($Scenario -eq 'Happy' -and $capturedErrors.Count) { throw "Workflow emitted errors: $($capturedErrors -join '; ')" }
        [pscustomobject]@{ Events=$fixtureEvents.ToArray(); Calls=$fixtureCalls.ToArray(); Progress=$fixtureProgress.ToArray(); Warnings=$capturedWarnings; Errors=$capturedErrors; Messages=($capturedInformation -join "`n"); Output=$output.ToArray(); Failure=$failure; RunId=$runId }
    } ($catalog | Where-Object Id -eq $Id) $Arguments $fixtureRoot $Scenario $CaptureFailure $Direct $SignInAction
}

Describe 'Offline endpoint script integration' {
    It 'reports paged interactive and non-interactive sign-ins with failure details' {
        $result = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' @{UserIdentity='fixture@example.invalid';LookbackDays=1} 'SignInHistoryHappy'
        $rows = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Sign-in events' })[0].Data
        $rows.Count | Should Be 3
        $rows[0].Outcome | Should Be 'Failure'
        $rows[0].ErrorCode | Should Be 50126
        $rows[0].FailureReason | Should Be 'Synthetic failure'
        $rows[0].CorrelationId | Should Be 'fixture-correlation'
        $rows[1].SignInType | Should Be 'Non-interactive'
        $rows[1].Outcome | Should Be 'Success'
        $rows[2].Outcome | Should Be 'Unknown'
        $query = [uri]::UnescapeDataString([string]$result.Calls[1].Uri)
        $query | Should Match "userId eq '00000000-0000-0000-0000-000000000005'"
        $query | Should Match "interactiveUser.*nonInteractiveUser"
        $query | Should Match 'createdDateTime ge .*createdDateTime le '
        $dates = [regex]::Matches($query, '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z')
        $dates.Count | Should Be 2
        ([datetime]::Parse($dates[1].Value).ToUniversalTime() - [datetime]::Parse($dates[0].Value).ToUniversalTime()).TotalHours | Should Be 24
        $result.Calls[0].Headers.ConsistencyLevel | Should Be 'eventual'
        $result.Calls[0].Uri | Should Match '\$count=true'
        $result.Calls.Count | Should Be 3
    }
    It 'reports each request before it starts and records page and processing timings' {
        $run = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' @{UserIdentity='fixture@example.invalid'} 'SignInHistoryHappy'
        $run.Progress[0].Status | Should Match 'user lookup page 1'
        $run.Progress[0].Calls | Should Be 0
        $run.Progress[1].Status | Should Match 'sign-in page 1'
        $run.Progress[1].Calls | Should Be 1
        $run.Progress[2].Status | Should Match 'sign-in page 2'
        $run.Progress[2].Calls | Should Be 2
        $run.Progress[3].Status | Should Match 'Preparing 3 sign-in records'
        $run.Progress[4].Completed | Should Be $true
        $run.Messages | Should Match 'Received user lookup page 1: 1 records in'
        $run.Messages | Should Match 'Received sign-in page 2: 1 records in'
        $run.Messages | Should Match 'Prepared sign-in records in'
    }
    It 'returns one date-filtered page and continues without rerunning the user lookup' {
        $arguments = @{UserIdentity='fixture@example.invalid';LookbackDays=1;ReportMode='Paged events'}
        $run = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryHappy'
        $rows = @($run.Events | Where-Object Type -eq 'Rows')[0].Data
        $rows.Count | Should Be 2
        $run.Calls.Count | Should Be 2
        $run.Calls[1].Uri | Should Match '\$top=100'
        @($run.Events | Where-Object Name -eq 'Sign-in paging')[0].Data.HasMore | Should Be $true
        @($run.Events | Where-Object Type -eq 'OperationSummary')[0].Data.CountsComplete | Should Be $false
        $query = [uri]::UnescapeDataString([string]$run.Calls[1].Uri)
        $query | Should Match 'interactiveUser.*nonInteractiveUser'
        $dates = [regex]::Matches($query, '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z')
        ([datetime]::Parse($dates[1].Value).ToUniversalTime() - [datetime]::Parse($dates[0].Value).ToUniversalTime()).TotalHours | Should Be 24
        $more = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryHappy' -SignInAction More
        $more.Calls.Count | Should Be 1
        $more.Calls[0].Uri | Should Match 'skiptoken'
        @($more.Events | Where-Object Type -eq 'Rows')[0].Data.Count | Should Be 3
        @($more.Events | Where-Object Name -eq 'Sign-in paging')[0].Data.HasMore | Should Be $false
        @($more.Events | Where-Object Type -eq 'OperationSummary')[0].Data.CountsComplete | Should Be $true
    }
    It 'retains a retryable continuation on failure and retrieves all remaining pages' {
        $arguments = @{UserIdentity='fixture@example.invalid';ReportMode='Paged events'}
        $null = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryHappy'
        foreach ($scenario in @('SignInHistoryPageFailure','SignInHistoryOtherAccount','SignInHistoryOtherTenant')) {
            $failed = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments $scenario -CaptureFailure -SignInAction More
            [bool]$failed.Failure | Should Be $true
            @($failed.Events | Where-Object { $_.Type -eq 'Rows' }).Count | Should Be 0
        }
        $changed = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' @{UserIdentity='other@example.invalid';ReportMode='Paged events'} 'SignInHistoryHappy' -CaptureFailure -SignInAction More
        [bool]$changed.Failure | Should Be $true
        $changed.Calls.Count | Should Be 0
        $all = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryHappy' -SignInAction All
        @($all.Events | Where-Object Type -eq 'Rows')[0].Data.Count | Should Be 3
        @($all.Events | Where-Object Name -eq 'Sign-in paging')[0].Data.HasMore | Should Be $false
    }
    It 'limits the first request to 100 records and fetches all remaining pages without truncation' {
        $arguments = @{UserIdentity='fixture@example.invalid';ReportMode='Paged events'}
        $first = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryLarge'
        @($first.Events | Where-Object Type -eq 'Rows')[0].Data.Count | Should Be 100
        $first.Calls.Count | Should Be 2
        $all = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryThreePages' -SignInAction All
        $all.Calls.Count | Should Be 2
        @($all.Events | Where-Object Type -eq 'Rows')[0].Data.Count | Should Be 102
        @($all.Events | Where-Object Type -eq 'OperationSummary')[0].Data.CountsComplete | Should Be $true
    }
    It 'does not consume unseen rows when continuation is cancelled or report preparation fails' {
        $arguments = @{UserIdentity='fixture@example.invalid';ReportMode='Paged events'}
        $null = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryHappy'
        $cancelled = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryCancelled' -SignInAction More
        @($cancelled.Events | Where-Object { $_.Type -eq 'Rows' -or $_.Name -eq 'Sign-in paging' }).Count | Should Be 0
        @($cancelled.Events | Where-Object Type -eq 'OperationSummary')[0].Data.CountsComplete | Should Be $false
        $failed = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryPresentationFailure' -CaptureFailure -SignInAction More
        $failed.Failure | Should Match 'Synthetic report preparation failure'
        @($failed.Events | Where-Object Name -eq 'Sign-in paging').Count | Should Be 0
        $retry = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryHappy' -SignInAction More
        @($retry.Events | Where-Object Type -eq 'Rows')[0].Data.Count | Should Be 3
        @($retry.Events | Where-Object Name -eq 'Sign-in paging')[0].Data.Received | Should Be 3
    }
    It 'keeps an empty failures-only first page explicitly incomplete and pageable' {
        $run = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' @{UserIdentity='fixture@example.invalid';ReportMode='Paged events';FailuresOnly=$true} 'SignInHistorySuccessPage'
        @($run.Events | Where-Object Type -eq 'Rows')[0].Data.Count | Should Be 0
        @($run.Events | Where-Object Name -eq 'Sign-in paging')[0].Data.HasMore | Should Be $true
        @($run.Events | Where-Object Type -eq 'OperationSummary')[0].Data.CountsComplete | Should Be $false
    }
    It 'retrieves every page without a 1000-event result cap' {
        $run = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' @{UserIdentity='fixture@example.invalid'} 'SignInHistoryLarge'
        $rows = @($run.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Sign-in events' })[0].Data
        $rows.Count | Should Be 1001
        $rows[1000].SignInId | Should Be 'last'
        $query = [uri]::UnescapeDataString([string]$run.Calls[1].Uri)
        $dates = [regex]::Matches($query, '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z')
        ([datetime]::Parse($dates[1].Value).ToUniversalTime() - [datetime]::Parse($dates[0].Value).ToUniversalTime()).TotalDays | Should Be 30
    }
    It 'filters failures without hiding unclassifiable events silently' {
        $run = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' @{UserIdentity='fixture@example.invalid';FailuresOnly=$true} 'SignInHistoryHappy' -Direct
        $run.Output.Count | Should Be 1
        $run.Output[0].SignInId | Should Be 'failed'
        ($run.Warnings -join ' ') | Should Match 'excluded from failures-only results'
    }
    It 'returns an empty report and rejects ambiguous or unsafe incomplete sign-in lookups' {
        $empty = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' @{UserIdentity='fixture@example.invalid'} 'SignInHistoryEmpty'
        @($empty.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Sign-in events' })[0].Data.Count | Should Be 0
        foreach ($scenario in @('SignInHistoryMissing','SignInHistoryAmbiguous','SignInHistoryMalformed','SignInHistoryUnsafe','SignInHistoryRepeat','SignInHistoryPageFailure')) {
            $run = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' @{UserIdentity="fixture.o'brien@example.invalid"} $scenario -CaptureFailure
            [bool]$run.Failure | Should Be $true
            @($run.Events | Where-Object { $_.Type -eq 'Rows' }).Count | Should Be 0
            if ($scenario -eq 'SignInHistoryAmbiguous') { $run.Calls.Count | Should Be 1 }
            [uri]::UnescapeDataString([string]$run.Calls[0].Uri) | Should Match "fixture.o''brien@example.invalid"
        }
    }
    It 'uses the retained rollout to correlate diagnostics without exporting the app again' {
        $app = '00000000-0000-0000-0000-000000000006'
        $dependency = '00000000-0000-0000-0000-000000000008'
        $device = '00000000-0000-0000-0000-000000000004'
        $tables = @{}
        foreach ($id in @($app,$dependency)) {
            $table = [Data.DataTable]::new()
            foreach ($name in @('ApplicationId','DeviceId','InstallState','InstallStateFriendly','ErrorCode','UserPrincipalName','LastModifiedDateTime','HexErrorCode')) { $null = $table.Columns.Add($name) }
            $null = $table.Rows.Add($id,$device,'2','Failed','12345','fixture@example.invalid','2026-01-01T00:00:00Z')
            $tables[$id] = $table
        }
        $null = $tables[$app].Rows.Add($app,$device,'1','Installed','0','second@example.invalid','2026-01-02T00:00:00Z')
        $second = '00000000-0000-0000-0000-000000000014'
        $installed = '00000000-0000-0000-0000-000000000024'
        $null = $tables[$app].Rows.Add($app,$device,'2','Localized failure','-2016345060')
        $null = $tables[$app].Rows.Add($app,$device,'-1','Localized failure','2278622236')
        $null = $tables[$app].Rows.Add($app,$second,'2','Failed','0','','','87d1041c')
        $null = $tables[$app].Rows.Add($app,$installed,'1','Failed','2278622236')
        $null = $tables[$app].Rows.Add($dependency,$installed,'2','Failed','2278622236')
        $null = $tables[$app].Rows.Add($app,'','2','Failed','2278622236')
        $null = $tables[$app].Rows.Add($app,$device,'2','Failed','1603','','','0x80070643')
        $null = $tables[$app].Rows.Add($app,$device,'2','Failed','3010')
        $null = $tables[$app].Rows.Add($app,$device,'2','Failed','0')
        $args = @{DeviceSearchBy='Intune device ID';DeviceSearchValue=$device;AppSearchBy='App ID';AppSearchValue=$app;DeploymentSnapshot=$tables;SnapshotTenantId='fixture-tenant'}
        $result = Invoke-OfflineEndpointWorkflow 'app-install-investigation' $args 'AppInvestSnapshot'
        @($result.Calls | Where-Object Method -ne 'GET').Count | Should Be 0
        $codes = ($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Error code details' }).Data
        @($codes).Count | Should Be 5
        $detection = $codes | Where-Object Code -eq '0x87D1041C'
        $detection.DeviceFailureRows | Should Be 2
        $detection.RolloutImpact | Should Be '2 of 3 identified devices'
        $detection.SignedDecimal | Should Be -2016345060
        $detection.UnsignedDecimal | Should Be 2278622236
        $detection.DetectionSettings | Should Match 'File or folder.*fixture\.exe.*PowerShell script'
        $detection.DetectionSettings | Should Not Match 'synthetic-script-not-for-report'
        $wrapped = $codes | Where-Object Code -eq '0x80070643'
        $wrapped.Meaning | Should Match 'wraps Windows error 1603'
        $wrapped.ReportedErrorCode | Should Be '1603'
        $wrapped.ReturnCodeConfiguration | Should BeNullOrEmpty
        ($codes | Where-Object Code -eq '0x00000BC2').ReturnCodeConfiguration | Should Match '3010 -> softReboot.*not verified'
        ($codes | Where-Object Code -eq '0x00003039').Meaning | Should Match 'No documented explanation'
        ($codes | Where-Object Code -eq 'No error code reported').HexCode | Should BeNullOrEmpty
        $findings = ($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Diagnostic findings' }).Data
        foreach ($outcome in @('Current requirement mismatch','Architecture not listed','Failure predates app edit','Mixed reported outcomes','Excluded group membership found','Dependency also reports failure')) {
            @($findings | Where-Object Outcome -eq $outcome).Count | Should BeGreaterThan 0
        }
        $args.SnapshotTenantId = 'other-tenant'
        $blocked = Invoke-OfflineEndpointWorkflow 'app-install-investigation' $args 'AppInvestSnapshot' -CaptureFailure
        $blocked.Failure | Should Match 'different or unverified tenant'
        @($blocked.Calls).Count | Should Be 0
    }
    It 'compares Win32 snapshots offline by device identity and publishes drill-through charts' {
        $before = Join-Path $TestDrive 'before.csv'
        $after = Join-Path $TestDrive 'after.csv'
        $app = '00000000-0000-0000-0000-000000000006'
        $header = 'ApplicationId,AppDisplayVersion,DeviceId,DeviceName,InstallStateFriendly,IdentityStatus,ReportRows'
        @($header, "$app,1,a,Old name,Failed,Identified,2", "$app,1,b,Device B,Installed,Identified,1",
            "$app,1,c,Device C,Pending install,Identified,1", "$app,1,e,Device E,Unknown,Identified,1",
            "$app,1,f,Device F,Installed,Identified,1", "$app,1,,Unidentified,Failed,Missing DeviceId,1") | Set-Content -LiteralPath $before
        @($header, "$app,2,a,New name,Installed,Identified,1", "$app,2,b,Device B,Failed,Identified,1",
            "$app,2,d,Device D,Installed,Identified,1", "$app,2,e,Device E,Failed,Identified,1",
            "$app,2,f,Device F,Installed,Identified,1") | Set-Content -LiteralPath $after
        $result = Invoke-OfflineEndpointWorkflow 'compare-win32-runs' @{BeforeCsv=$before;AfterCsv=$after}
        @($result.Calls).Count | Should Be 0
        $rows = ($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Device changes' }).Data
        $rows.Count | Should Be 6
        ($rows | Where-Object DeviceId -eq a).DeviceName | Should Be 'New name'
        $expected = @{ a='Improved'; b='Regressed'; c='No longer reported'; d='Newly reported'; e='Other status change'; f='Unchanged' }
        foreach ($row in $rows) { $row.Change | Should Be $expected[$row.DeviceId] }
        $charts = ($result.Events | Where-Object Type -eq 'ReportVisual').Data
        $charts[0].Basis | Should Match '1 before, 0 after'
        $bar = $charts[1].Bars | Where-Object Label -eq 'Failed -> Installed'
        $bar.Count | Should Be 1
        $bar.Dataset | Should Be 'Device changes'
        $bar.Column | Should Be 'Transition'
    }

    It 'rejects invalid, mismatched, and duplicate-device Win32 summaries' {
        $before = Join-Path $TestDrive 'before.csv'
        $after = Join-Path $TestDrive 'after.csv'
        $app = '00000000-0000-0000-0000-000000000006'
        $otherApp = '00000000-0000-0000-0000-000000000007'
        $header = 'ApplicationId,AppDisplayVersion,DeviceId,DeviceName,InstallStateFriendly,IdentityStatus,ReportRows'
        $row = "$app,1,a,Device A,Failed,Identified,1"
        @($header, $row) | Set-Content -LiteralPath $before
        $script = ($catalog | Where-Object Id -eq 'compare-win32-runs').FullPath
        foreach ($case in @(
            @{ Content=@('DeviceName,Status','Device A,Failed'); Error='not a Win32 DeviceSummary CSV' }
            @{ Content=@($header, "$otherApp,1,a,Device A,Failed,Identified,1"); Error='same application ID' }
            @{ Content=@($header, $row, $row); Error='duplicate device IDs' }
        )) {
            $case.Content | Set-Content -LiteralPath $after
            { & $script -BeforeCsv $before -AfterCsv $after } | Should Throw $case.Error
        }
    }

    It 'scopes discovered apps and exports to one Intune managed device ID, not its report name or user' {
        foreach ($target in @("Fixture O'Brien", '00000000-0000-0000-0000-000000000004')) {
            $result = Invoke-OfflineEndpointWorkflow 'discovered-apps' @{Platform='Windows';Device=$target;AppName='Fixture*';OutputPath=$fixtureRoot} 'DiscoveredSingle'
            $rows = ($result.Events | Where-Object Type -eq 'Rows').Data
            @($rows).Count | Should Be 1
            $rows[0].DeviceId | Should Be '00000000-0000-0000-0000-000000000004'
            $csv = Import-Csv -LiteralPath ($result.Events | Where-Object Type -eq 'Artifact').Data
            $csv.DeviceId | Should Be $rows[0].DeviceId
            ($result.Events | Where-Object Type -eq 'ReportVisual').Data[0].Bars[0].Label | Should Be '1.0'
            $requests = @($result.Calls | Where-Object Uri -like '*managedDevices*')
            if ($target -like 'Fixture*') {
                $requests.Count | Should Be 1
                [uri]::UnescapeDataString($requests[0].Uri) | Should Match "deviceName eq 'Fixture O''Brien'"
            }
            else { $requests.Count | Should Be 0 }
        }
    }
    It 'does not export discovered apps for missing or ambiguous names or conflicting scopes' {
        foreach ($case in @(
            @{Scenario='DiscoveredMissing';Message='Intune device not found'}
            @{Scenario='DiscoveredDuplicate';Message='Multiple Intune devices'}
            @{Scenario='DiscoveredConflict';Message='not both';Group='Fixture Group'}
        )) {
            $args = @{Platform='Windows';Device="Fixture O'Brien";OutputPath=$fixtureRoot}
            if ($case.Group) { $args.EntraGroup = $case.Group }
            $result = Invoke-OfflineEndpointWorkflow 'discovered-apps' $args $case.Scenario -CaptureFailure
            $result.Failure | Should Match $case.Message
            @($result.Calls | Where-Object Method -eq POST).Count | Should Be 0
            @($result.Events | Where-Object Type -in @('Rows','Artifact','ReportVisual')).Count | Should Be 0
        }
    }
    It 'keeps Entra group scope available for discovered apps' {
        $result = Invoke-OfflineEndpointWorkflow 'discovered-apps' @{Platform='Windows';EntraGroup='Fixture Group';OutputPath=$fixtureRoot}
        @($result.Calls | Where-Object Uri -like '*transitiveMembers*').Count | Should Be 1
        ($result.Events | Where-Object Type -eq 'Rows').Data[0].DeviceName | Should Be 'Fixture-PC'
    }
    It 'lists every Cloud PC page including unprovisioned and failed records without changing them' {
        $result = Invoke-OfflineEndpointWorkflow 'cloudpc-inventory' @{} 'CloudInventoryHappy'
        $result.Failure | Should Be $null
        $result.Output.Count | Should Be 3
        $rows = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'All Cloud PCs' })[0].Data
        $rows.Count | Should Be 3
        $rows[0].DeviceName | Should Be 'Fixture-PC'
        $charts = ($result.Events | Where-Object Type -eq 'ReportVisual').Data
        $charts.Count | Should Be 2
        $charts[0].Total | Should Be 3
        ($charts[0].Bars | Where-Object Label -eq 'Not provisioned').Count | Should Be 1
        ($charts[0].Bars | Where-Object Label -eq 'Failed').Count | Should Be 1
        ($charts[1].Bars | Where-Object Label -eq 'Enterprise').Count | Should Be 1
        $rows[0].ProvisioningPolicy | Should Be 'Fixture policy'
        $rows[0].Image | Should Be 'Fixture image'
        $rows[0].CloudPCSize | Should Be 'Fixture plan'
        $rows[0].DeviceType | Should Be 'enterprise'
        $rows[0].Status | Should Be 'Provisioned'
        $rows[0].EncryptionStatus | Should Be 'encryptedUsingPlatformManagedKey'
        $rows[0].ThirdPartyConnectors | Should Be 'citrix: installed'
        $rows[1].Status | Should Be 'Not provisioned'
        $rows[1].DeviceName | Should Be ''
        $rows[1].UserPrincipalName | Should Be $rows[0].UserPrincipalName
        $rows[2].Status | Should Be 'Failed'
        $summary = @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data
        $summary.Succeeded | Should Be 3
        $summary.Failed | Should Be 0
        $summary.Affected | Should Be 0
        $result.Calls.Count | Should Be 2
        @($result.Calls | Where-Object Method -ne 'GET').Count | Should Be 0
        $result.Calls[0].Uri | Should Match '\$select=.*productType,status'
        $result.Calls[0].Uri | Should Not Match '\$filter='
        $result.Calls[0].Headers.Prefer | Should Be 'include-unknown-enum-members'
        @($result.Events | Where-Object Type -eq 'Artifact').Count | Should Be 0
        $cli = Invoke-OfflineEndpointWorkflow 'cloudpc-inventory' @{} 'CloudInventoryHappy' -Direct
        ($cli.Output | ConvertTo-Json -Depth 5) | Should Be ($result.Output | ConvertTo-Json -Depth 5)
    }
    It 'reports an empty Cloud PC collection and rejects failed or unsafe pages without partial results' {
        $empty = Invoke-OfflineEndpointWorkflow 'cloudpc-inventory' @{} 'CloudInventoryEmpty'
        $empty.Output.Count | Should Be 0
        @($empty.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'All Cloud PCs' })[0].Data.Count | Should Be 0
        foreach ($case in @(
            @{Scenario='CloudInventoryFailure';Message='Synthetic Cloud PC page failure'}
            @{Scenario='CloudInventoryUnsafe';Message='unexpected or repeated'}
            @{Scenario='CloudInventoryRepeat';Message='unexpected or repeated'}
            @{Scenario='CloudInventoryMalformed';Message='valid Cloud PC collection'}
            @{Scenario='CloudInventoryMissingId';Message='without an ID'}
        )) {
            $result = Invoke-OfflineEndpointWorkflow 'cloudpc-inventory' @{} $case.Scenario -CaptureFailure
            $result.Failure | Should Match $case.Message
            $result.Output.Count | Should Be 0
            @($result.Events | Where-Object Type -in @('Rows','ReportVisual')).Count | Should Be 0
            @($result.Calls | Where-Object Uri -like 'https://example.invalid/*').Count | Should Be 0
        }
    }
    It 'investigates one app and device while preserving all matching user-context rows' {
        $args = @{DeviceSearchBy='Device name';DeviceSearchValue='Fixture-PC';AppSearchBy='App name';AppSearchValue='Fixture App'}
        $result = Invoke-OfflineEndpointWorkflow 'app-install-investigation' $args 'AppInvestHappy'
        $result.Output.Count | Should Be 1
        $result.Output[0].ReportRows | Should Be 2
        $result.Output[0].ReportedStates | Should Be 'Failed; Installed'
        $result.Output[0].ErrorCodes | Should Be '0; 12345'
        $result.Output[0].LastIntuneSync | Should Be '2026-01-03T00:00:00Z'
        $result.Output[0].InstallContext | Should Be 'system'
        $rows = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Device deployment rows' })[0].Data
        $rows.Count | Should Be 2
        @($rows.UserPrincipalName | Select-Object -Unique).Count | Should Be 2
        @($rows | Where-Object DeviceId -ne '00000000-0000-0000-0000-000000000004').Count | Should Be 0
        ($result.Events | ConvertTo-Json -Depth 7) | Should Not Match 'third@example.invalid|Unidentified-1'
        $assignments = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'App assignments' })[0].Data
        $assignments.Count | Should Be 3
        ($assignments | Where-Object Intent -eq 'available').FilterRule | Should Be '(device.model -eq "Synthetic")'
        ($assignments | Where-Object Intent -eq 'uninstall').TargetType | Should Be 'exclusionGroupAssignmentTarget'
        @($result.Calls | Where-Object Uri -like '*/groups/*').Count | Should Be 1
        $summary = @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data
        $summary.Succeeded | Should Be 1
        $summary.Failed | Should Be 0
        $summary.Affected | Should Be 0
        @($result.Calls | Where-Object { $_.Method -ne 'GET' -and ($_.Method -ne 'POST' -or $_.Uri -notlike '*/reports/exportJobs') }).Count | Should Be 0
        @($result.Events | Where-Object Type -eq 'Artifact').Count | Should Be 0
        $reportRequest = @($result.Calls | Where-Object Method -eq 'POST')
        $reportRequest.Count | Should Be 1
        ($reportRequest[0].Body | ConvertFrom-Json).filter | Should Be "(ApplicationId eq '00000000-0000-0000-0000-000000000006')"
        $cli = Invoke-OfflineEndpointWorkflow 'app-install-investigation' $args 'AppInvestHappy' -Direct
        ($cli.Output | Select-Object * -ExcludeProperty CollectedUtc | ConvertTo-Json) | Should Be ($result.Output | Select-Object * -ExcludeProperty CollectedUtc | ConvertTo-Json)
        $scratchPaths = @([regex]::Matches($result.Messages + $cli.Messages, '[A-Za-z]:\\[^\r\n]*?EndpointToolbox-AppInvestigation-[a-f0-9]{32}') | ForEach-Object Value | Select-Object -Unique)
        $scratchPaths.Count | Should Be 2
        foreach ($path in $scratchPaths) { (Test-Path -LiteralPath $path) | Should Be $false }
    }
    It 'keeps no-report outcomes unknown and does not count reported installation failure as retrieval failure' {
        $args = @{DeviceSearchBy='Device name';DeviceSearchValue='Fixture-PC';AppSearchBy='App name';AppSearchValue='Fixture App'}
        $empty = Invoke-OfflineEndpointWorkflow 'app-install-investigation' $args 'AppInvestNoRows'
        $empty.Output[0].ReportStatus | Should Match 'outcome unknown'
        $empty.Output[0].AssignmentCount | Should Be 0
        $empty.Output[0].InstallContext | Should Be ''
        @($empty.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Device deployment rows' })[0].Data.Count | Should Be 0
        @($empty.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'App assignments' })[0].Data.Count | Should Be 0
        $checks = @($empty.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Suggested checks' })[0].Data
        ($checks.Evidence -join ' ') | Should Match 'not installation success'
        $installed = Invoke-OfflineEndpointWorkflow 'app-install-investigation' $args 'AppInvestInstalled'
        $installed.Output[0].ReportedStates | Should Be 'Installed'
        $installed.Output[0].Targeting | Should Be 'Not evaluated'
    }
    It 'supports explicit Intune object IDs and escapes apostrophes in both exact name filters' {
        $args = @{DeviceSearchBy='Intune device ID';DeviceSearchValue='00000000-0000-0000-0000-000000000004';AppSearchBy='App ID';AppSearchValue='00000000-0000-0000-0000-000000000006'}
        $result = Invoke-OfflineEndpointWorkflow 'app-install-investigation' $args 'AppInvestHappy'
        $result.Output[0].ReportRows | Should Be 2
        $result.Calls[0].Uri | Should Match '/managedDevices/00000000-0000-0000-0000-000000000004\?'
        $result.Calls[1].Uri | Should Match '/mobileApps/00000000-0000-0000-0000-000000000006$'
        $names = Invoke-OfflineEndpointWorkflow 'app-install-investigation' @{DeviceSearchBy='Device name';DeviceSearchValue="Fixture O'Brien";AppSearchBy='App name';AppSearchValue="App O'Brien"} 'AppInvestApostrophe'
        [uri]::UnescapeDataString($names.Calls[0].Uri) | Should Match "deviceName eq 'Fixture O''Brien'"
        [uri]::UnescapeDataString($names.Calls[1].Uri) | Should Match "displayName eq 'App O''Brien'"
        $args.DeviceSearchValue = 'not-a-guid'
        $invalid = Invoke-OfflineEndpointWorkflow 'app-install-investigation' $args 'AppInvestHappy' -CaptureFailure
        $invalid.Failure | Should Match 'GUID'
        $invalid.Calls.Count | Should Be 0
        $args.DeviceSearchValue = '00000000-0000-0000-0000-000000000004'
        $wrongType = Invoke-OfflineEndpointWorkflow 'app-install-investigation' $args 'AppInvestWrongType' -CaptureFailure
        $wrongType.Failure | Should Match 'matching Win32 app'
    }
    It 'rejects missing and ambiguous exact names without starting a report' {
        foreach ($scenario in @('AppInvestMissingDevice','AppInvestDuplicateDevice','AppInvestMissingApp','AppInvestDuplicateApp')) {
            $args = @{DeviceSearchBy='Device name';DeviceSearchValue='Fixture-PC';AppSearchBy='App name';AppSearchValue='Fixture App'}
            $result = Invoke-OfflineEndpointWorkflow 'app-install-investigation' $args $scenario -CaptureFailure
            $result.Failure | Should Match 'exactly one'
            @($result.Calls | Where-Object Method -eq 'POST').Count | Should Be 0
            @($result.Events | Where-Object Type -eq 'Rows').Count | Should Be 0
        }
    }
    It 'fails explicitly without partial investigation datasets on lookup, paging or report errors' {
        foreach ($case in @(
            @{Scenario='AppInvestUnsafe';Message='unexpected or repeated'}
            @{Scenario='AppInvestMalformed';Message='invalid collection'}
            @{Scenario='AppInvestAssignmentFailure';Message='Synthetic app assignment failure'}
            @{Scenario='AppInvestFilterFailure';Message='Synthetic assignment filter failure'}
            @{Scenario='AppInvestReportFailure';Message='deployment report failed'}
            @{Scenario='AppInvestMalformedReport';Message='did not include DeviceId'}
        )) {
            $args = @{DeviceSearchBy='Device name';DeviceSearchValue='Fixture-PC';AppSearchBy='App name';AppSearchValue='Fixture App'}
            $result = Invoke-OfflineEndpointWorkflow 'app-install-investigation' $args $case.Scenario -CaptureFailure
            $result.Failure | Should Match $case.Message
            $result.Output.Count | Should Be 0
            @($result.Events | Where-Object Type -eq 'Rows').Count | Should Be 0
            @($result.Calls | Where-Object Uri -like 'https://example.invalid/*').Count | Should Be 0
            foreach ($match in [regex]::Matches($result.Messages, '[A-Za-z]:\\[^\r\n]*?EndpointToolbox-AppInvestigation-[a-f0-9]{32}')) {
                (Test-Path -LiteralPath $match.Value) | Should Be $false
            }
        }
    }
    It 'investigates serials using the plain Autopilot list endpoint and projects only report fields' {
        $result = Invoke-OfflineEndpointWorkflow 'device-investigation' @{SearchBy='Serial number';SearchValue='SYNTHETIC'} 'InvestigationHappy'
        $autopilotCalls = @($result.Calls | Where-Object { $_.Uri -match '/windowsAutopilotDeviceIdentities(?:\?|$)' })
        $autopilotCalls.Count | Should Be 2
        $autopilotCalls[0].Uri | Should Be 'https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities'
        $autopilotCalls[1].Uri | Should Match '\$skiptoken=fixture'
        $rows = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Autopilot records' })[0].Data
        $rows.Count | Should Be 2
        ($rows | Where-Object AutopilotId -eq '00000000-0000-0000-0000-000000000006').GroupTag | Should Be 'Fixture'
        ($result.Output | ConvertTo-Json -Depth 4) | Should Not Match 'SYNTHETIC-NOT-A-PRODUCT-KEY|productKey'
        ($result.Events | ConvertTo-Json -Depth 6) | Should Not Match 'SYNTHETIC-NOT-A-PRODUCT-KEY|productKey'
    }
    It 'investigates linked records and preserves separate serial-only candidates' {
        $args = @{SearchBy='Device name';SearchValue='Fixture-PC'}
        $result = Invoke-OfflineEndpointWorkflow 'device-investigation' $args 'InvestigationHappy'
        $overview = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Device overview' })[0].Data
        $device = $overview | Where-Object RecordSource -eq 'Intune'
        $device.PrimaryUsers | Should Be 'primary@example.invalid'
        $device.AssociatedUser | Should Be 'fixture@example.invalid'
        $device.Compliance | Should Be 'compliant'
        $device.EntraStatus | Should Be 'One ID match'
        $device.AutopilotStatus | Should Be 'One ID match'
        $device.AutopilotIds | Should Be '00000000-0000-0000-0000-000000000006'
        @($overview | Where-Object RecordSource -eq 'Autopilot candidate').Count | Should Be 1
        @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Entra records' })[0].Data.Count | Should Be 1
        @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Autopilot records' })[0].Data.Count | Should Be 2
        @($result.Calls | Where-Object Method -ne 'GET').Count | Should Be 0
        $cli = Invoke-OfflineEndpointWorkflow 'device-investigation' $args 'InvestigationHappy' -Direct
        ($cli.Output | ConvertTo-Json -Depth 3) | Should Be ($overview | ConvertTo-Json -Depth 3)
    }
    It 'searches exact serials and associated UPNs and handles autopilot-only results' {
        foreach ($args in @(
            @{SearchBy='Serial number';SearchValue='SYNTHETIC'}
            @{SearchBy='User UPN';SearchValue='fixture@example.invalid'}
        )) {
            $result = Invoke-OfflineEndpointWorkflow 'device-investigation' $args 'InvestigationHappy'
            @($result.Output | Where-Object RecordSource -eq 'Intune').Count | Should Be 1
        }
        $result = Invoke-OfflineEndpointWorkflow 'device-investigation' @{SearchBy='Serial number';SearchValue='SYNTHETIC'} 'InvestigationAutopilotOnly'
        @($result.Output | Where-Object RecordSource -eq 'Autopilot candidate').Count | Should Be 2
        $invalid = Invoke-OfflineEndpointWorkflow 'device-investigation' @{SearchBy='Device name';SearchValue='Fixture-PC'} 'InvestigationInvalidId'
        ($invalid.Output | Where-Object RecordSource -eq 'Intune').AutopilotStatus | Should Match 'conflicting'
        ($invalid.Output | Where-Object RecordSource -eq 'Intune').AutopilotIds | Should Be ''
        @($result.Output | Where-Object RecordSource -eq 'Intune').Count | Should Be 0
    }
    It 'exposes conflicting identifiers and escapes exact search values' {
        $result = Invoke-OfflineEndpointWorkflow 'device-investigation' @{SearchBy='Device name';SearchValue='Fixture-PC'} 'InvestigationConflict'
        ($result.Output | Where-Object RecordSource -eq 'Intune').AutopilotStatus | Should Match 'conflicting'
        @($result.Output | Where-Object RecordSource -eq 'Autopilot candidate').Count | Should Be 2
        $result = Invoke-OfflineEndpointWorkflow 'device-investigation' @{SearchBy='Device name';SearchValue="Fixture O'Brien"} 'InvestigationApostrophe'
        [uri]::UnescapeDataString($result.Calls[0].Uri) | Should Match "deviceName eq 'Fixture O''Brien'"
    }
    It 'drills from reconciliation counts into separate same-name records with their recorded IDs' {
        $result = Invoke-OfflineEndpointWorkflow 'device-investigation' @{SearchBy='Device name';SearchValue='Fixture-PC'} 'InvestigationSameName'
        $rows = ($result.Events | Where-Object Name -eq 'Reconciliation queue' | Where-Object Type -eq 'Rows').Data
        $duplicates = @($rows | Where-Object Finding -eq 'Same name, separate records')
        $duplicates.Count | Should Be 2
        @($duplicates.RecordedManagedDeviceId | Sort-Object -Unique).Count | Should Be 2
        @($duplicates.RecordedEntraDeviceId | Sort-Object -Unique).Count | Should Be 2
        $unmatched = $rows | Where-Object { $_.Finding -eq 'No confirmed match' -and $_.RecordedEntraDeviceId -like '*0011' }
        $unmatched.Reason | Should Match 'No Entra match'
        $unmatched.EntraApproximateLastSignIn | Should Be ''
        $chart = ($result.Events | Where-Object Type -eq 'ReportVisual').Data[0]
        $chart.Total | Should Be $rows.Count
        $bar = $chart.Bars | Where-Object Label -eq 'Same name, separate records'
        $bar.Count | Should Be 2
        $bar.Dataset | Should Be 'Reconciliation queue'
        $bar.Column | Should Be 'Finding'
    }
    It 'keeps conflicting Autopilot identifiers and timestamps visible without confirming the link' {
        $result = Invoke-OfflineEndpointWorkflow 'device-investigation' @{SearchBy='Device name';SearchValue='Fixture-PC'} 'InvestigationConflict'
        $queue = ($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Reconciliation queue' }).Data
        $row = $queue | Where-Object Finding -eq 'Conflicting or shared IDs'
        $row.RecordedEntraDeviceId | Should Be '00000000-0000-0000-0000-000000000003'
        $row.AutopilotEvidence | Should Match 'Entra: 00000000-0000-0000-0000-000000000009'
        $row.ConfirmedAutopilotIds | Should Be ''
        $row.LastIntuneSync | Should Be '2026-01-03T00:00:00Z'
        $row.EntraApproximateLastSignIn | Should Match '^2026-01-01'
        $row.AutopilotLastContact | Should Match '^2026-01-02'
        @($result.Calls | Where-Object Method -ne 'GET').Count | Should Be 0
    }
    It 'distinguishes a missing Entra identifier from a clean reconciliation' {
        $args = @{SearchBy='Device name';SearchValue='Fixture-PC'}
        $missing = Invoke-OfflineEndpointWorkflow 'device-investigation' $args 'InvestigationMissingId'
        $queue = ($missing.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Reconciliation queue' }).Data
        $row = $queue | Where-Object Finding -eq 'Missing or invalid ID'
        $row.RecordSource | Should Be 'Intune'
        $row.RecordedEntraDeviceId | Should Be ''
        $clean = Invoke-OfflineEndpointWorkflow 'device-investigation' $args 'InvestigationClean'
        ($clean.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Reconciliation queue' }).Data.Count | Should Be 0
        ($clean.Events | Where-Object Type -eq 'ReportVisual').Data[0].Total | Should Be 0
    }
    It 'keeps duplicate device identities and limited primary user details visible' {
        $args = @{SearchBy='Device name';SearchValue='Fixture-PC'}
        $result = Invoke-OfflineEndpointWorkflow 'device-investigation' $args 'InvestigationDuplicate'
        $devices = @($result.Output | Where-Object RecordSource -eq 'Intune')
        $devices.Count | Should Be 2
        foreach ($device in $devices) {
            $device.EntraStatus | Should Match 'shared'
            $device.AutopilotStatus | Should Match 'Shared or conflicting'
            $device.AutopilotIds | Should Be ''
        }
        @($result.Output | Where-Object RecordSource -eq 'Autopilot candidate').Count | Should Be 2
        $limited = Invoke-OfflineEndpointWorkflow 'device-investigation' $args 'InvestigationLimitedUser'
        ($limited.Output | Where-Object RecordSource -eq 'Intune').PrimaryUserStatus | Should Be 'Some UPNs unavailable'
        ($limited.Output | Where-Object RecordSource -eq 'Intune').PrimaryUserIds | Should Be '00000000-0000-0000-0000-000000000005'
    }
    It 'reports an empty search and stops without publishing incomplete investigations' {
        $args = @{SearchBy='Device name';SearchValue='Missing'}
        $empty = Invoke-OfflineEndpointWorkflow 'device-investigation' $args 'InvestigationEmpty'
        $empty.Messages | Should Match 'Found 0 Intune, 0 Entra and 0'
        @($empty.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Device overview' })[0].Data.Count | Should Be 0
        ($empty.Events | Where-Object Type -eq 'ReportVisual').Data[0].Total | Should Be 0
        foreach ($case in @(
            @{Scenario='InvestigationFailure';Message='Synthetic Autopilot page failure'}
            @{Scenario='InvestigationUserFailure';Message='Synthetic primary user failure'}
            @{Scenario='InvestigationUnsafe';Message='unexpected or repeated'}
        )) {
            $result = Invoke-OfflineEndpointWorkflow 'device-investigation' @{SearchBy='Device name';SearchValue='Fixture-PC'} $case.Scenario -CaptureFailure
            $result.Failure | Should Match $case.Message
            $result.Output.Count | Should Be 0
            @($result.Events | Where-Object Type -eq 'Rows').Count | Should Be 0
            @($result.Events | Where-Object Type -eq 'ReportVisual').Count | Should Be 0
        }
    }
    It 'reports paginated direct members of all types and preserves pipeline output' {
        $result = Invoke-OfflineEndpointWorkflow 'get-entra-group-members' @{GroupName='Fixture Group'} 'ListGroupMixed'
        $rows = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Members' })[0].Data
        $rows.Count | Should Be 5
        $result.Output.Count | Should Be 5
        ($rows | Where-Object MemberType -eq 'user').UserPrincipalName | Should Be 'fixture@example.invalid'
        ($rows | Where-Object MemberType -eq 'device').DisplayName | Should Be 'Fixture-PC'
        ($rows | Where-Object MemberType -eq 'servicePrincipal').DisplayName | Should Be 'Fixture application'
        ($rows | Where-Object MemberType -eq 'group').DisplayName | Should Be 'Nested group'
        ($rows | Where-Object MemberType -eq 'orgContact').ObjectId | Should Be '00000000-0000-0000-0000-000000000008'
        $chart = ($result.Events | Where-Object Type -eq 'ReportVisual').Data[0]
        $chart.Total | Should Be 5
        ($chart.Bars | Where-Object Label -eq 'Groups').Count | Should Be 1
        ($chart.Bars | Where-Object Label -eq 'Service principals').Count | Should Be 1
        ($result.Warnings -join ' ') | Should Match 'limited information'
        $result.Messages | Should Match 'Nested groups are not expanded'
        @($result.Calls | Where-Object Uri -like '*/transitiveMembers*').Count | Should Be 0
        ($rows[0].PSObject.Properties.Name -join ',') | Should Be 'DisplayName,MemberType,UserPrincipalName,Mail,ObjectId'
        @($result.Calls | Where-Object Method -ne 'GET').Count | Should Be 0
        $summary = @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data
        $summary.Succeeded | Should Be 5
        $summary.CountsComplete | Should Be $true
        $cli = Invoke-OfflineEndpointWorkflow 'get-entra-group-members' @{GroupName='Fixture Group'} 'ListGroupMixed' -Direct
        ($cli.Output | ConvertTo-Json -Depth 3) | Should Be ($rows | ConvertTo-Json -Depth 3)
    }
    It 'returns an empty report and zero count for a group without direct members' {
        $result = Invoke-OfflineEndpointWorkflow 'get-entra-group-members' @{GroupName='Fixture Group'} 'ListGroupEmpty'
        $rowsEvent = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Members' })
        $rowsEvent.Count | Should Be 1
        $rowsEvent[0].Data.Count | Should Be 0
        @($result.Events | Where-Object Type -eq 'ReportVisual').Count | Should Be 0
        $result.Messages | Should Match 'Found 0 direct member'
        @($result.Events | Where-Object Type -eq 'OperationSummary')[0].Data.Succeeded | Should Be 0
        $hidden = Invoke-OfflineEndpointWorkflow 'get-entra-group-members' @{GroupName='Fixture Group'} 'ListGroupHiddenAllowed'
        $hidden.Messages | Should Match 'Found 0 direct member'
    }
    It 'expands nested membership into a paginated unique all-types list without changing the CLI shape' {
        $arguments = @{GroupName='Fixture Group';ExpandNestedGroups=$true}
        $result = Invoke-OfflineEndpointWorkflow 'get-entra-group-members' $arguments 'ListGroupMixed'
        $rows = @($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Members' })[0].Data
        $rows.Count | Should Be 6
        @($rows.ObjectId | Select-Object -Unique).Count | Should Be 6
        ($rows | Where-Object DisplayName -eq 'Indirect user').MemberType | Should Be 'user'
        @($rows | Where-Object MemberType -eq 'device').Count | Should Be 1
        @($rows | Where-Object MemberType -eq 'group').Count | Should Be 1
        @($rows | Where-Object MemberType -eq 'servicePrincipal').Count | Should Be 1
        @($rows | Where-Object MemberType -eq 'orgContact').Count | Should Be 1
        @($result.Calls | Where-Object Uri -like '*/transitiveMembers?*').Count | Should Be 2
        @($result.Calls | Where-Object Method -ne 'GET').Count | Should Be 0
        @($result.Events | Where-Object Type -eq Artifact).Count | Should Be 0
        ($result.Events | Where-Object Type -eq OperationSummary).Data.Succeeded | Should Be 6
        $result.Messages | Should Match 'Nested groups are expanded into a flat list'
        ($result.Events | Where-Object Type -eq ReportVisual).Data[0].Total | Should Be 6
        $cli = Invoke-OfflineEndpointWorkflow 'get-entra-group-members' $arguments 'ListGroupMixed' -Direct
        ($cli.Output | ConvertTo-Json -Depth 3) | Should Be ($rows | ConvertTo-Json -Depth 3)
        $empty = Invoke-OfflineEndpointWorkflow 'get-entra-group-members' $arguments 'ListGroupEmpty'
        @($empty.Events | Where-Object Type -eq Rows)[0].Data.Count | Should Be 0
    }
    It 'resolves a group by ID without name lookup and rejects a different returned group' {
        $arguments = @{GroupId='00000000-0000-0000-0000-000000000001';ExpandNestedGroups=$true}
        $result = Invoke-OfflineEndpointWorkflow 'get-entra-group-members' $arguments 'ListGroupMixed'
        $result.Output.Count | Should Be 6
        $result.Calls[0].Uri | Should Match '/v1.0/groups/00000000-0000-0000-0000-000000000001\?'
        @($result.Calls | Where-Object Uri -match '/v1.0/groups\?').Count | Should Be 0
        $failed = Invoke-OfflineEndpointWorkflow 'get-entra-group-members' $arguments 'ListGroupWrongId' -CaptureFailure
        $failed.Failure | Should Match 'valid exact group match'
        @($failed.Events | Where-Object Type -eq Rows).Count | Should Be 0
    }
    It 'does not publish partial expanded membership when Graph pages fail or change scope' {
        foreach ($scenario in @('ListGroupUnsafe','ListGroupRepeat','ListGroupMalformed','ListGroupInvalidMember','ListGroupFailure','ListGroupWrongPath','ListGroupHidden')) {
            $failed = Invoke-OfflineEndpointWorkflow 'get-entra-group-members' @{GroupName='Fixture Group';ExpandNestedGroups=$true} $scenario -CaptureFailure
            [bool]$failed.Failure | Should Be $true
            $failed.Output.Count | Should Be 0
            @($failed.Events | Where-Object Type -eq Rows).Count | Should Be 0
            @($failed.Events | Where-Object Type -eq ReportVisual).Count | Should Be 0
            @($failed.Events | Where-Object Type -eq OperationSummary).Count | Should Be 0
        }
    }
    It 'escapes apostrophes in exact group name queries' {
        $result = Invoke-OfflineEndpointWorkflow 'get-entra-group-members' @{GroupName="Fixture O'Brien"} 'ListGroupApostrophe'
        [uri]::UnescapeDataString($result.Calls[0].Uri) | Should Match "displayName eq 'Fixture O''Brien'"
    }
    It 'rejects missing, duplicate and hidden groups without the required consent' {
        foreach ($case in @(
            @{Scenario='ListGroupMissing';Message='No group matched'}
            @{Scenario='ListGroupDuplicate';Message='Multiple groups matched'}
            @{Scenario='ListGroupHidden';Message='Member.Read.Hidden'}
        )) {
            $errorMessage = ''
            try { Invoke-OfflineEndpointWorkflow 'get-entra-group-members' @{GroupName='Fixture Group'} $case.Scenario | Out-Null }
            catch { $errorMessage = $_.Exception.Message }
            $errorMessage | Should Match $case.Message
        }
    }
    It 'fails rather than publishing an incomplete report on bad or failed pages' {
        foreach ($case in @(
            @{Scenario='ListGroupUnsafe';Message='unexpected or repeated'}
            @{Scenario='ListGroupRepeat';Message='unexpected or repeated'}
            @{Scenario='ListGroupMalformed';Message='valid collection'}
            @{Scenario='ListGroupInvalidMember';Message='valid object ID or type'}
            @{Scenario='ListGroupFailure';Message='Synthetic member page failure'}
        )) {
            $result = Invoke-OfflineEndpointWorkflow 'get-entra-group-members' @{GroupName='Fixture Group'} $case.Scenario -CaptureFailure
            $result.Failure | Should Match $case.Message
            $result.Output.Count | Should Be 0
            @($result.Events | Where-Object Type -eq 'Rows').Count | Should Be 0
            @($result.Events | Where-Object Type -eq 'OperationSummary').Count | Should Be 0
        }
    }
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
    It 'groups localized Win32 failures by code and only charts verified device context' {
        $args = @{AppId='00000000-0000-0000-0000-000000000006';OutputPath=$fixtureRoot;IncludeUserStatus=$false}
        foreach ($includeContext in @($false,$true)) {
            $args.IncludeDeviceContext = $includeContext
            $result = Invoke-OfflineEndpointWorkflow 'intune-assignment-win32-deployment-exports' $args 'DeploymentTriage'
            $queue = $result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -like 'Failure triage -*' }
            $queue.Data.Count | Should Be 4
            $identified = $queue.Data | Where-Object { $_.ManagedDeviceId -and $_.ErrorCode -eq '0x00003039' }
            $identified.FailureRows | Should Be 2
            @($queue.Data | Where-Object { -not $_.ManagedDeviceId -and $_.ContextStatus -eq 'No usable managed device ID' }).Count | Should Be 2
            $charts = ($result.Events | Where-Object Type -eq 'ReportVisual').Data
            $bar = ($charts | Where-Object Title -eq 'Win32 failures by error code').Bars | Where-Object Label -eq '0x00003039'
            $bar.Count | Should Be 3
            $bar.Column | Should Be 'ErrorCode'
            $bar.Dataset | Should Be $queue.Name
            $calls = @($result.Calls | Where-Object Uri -like '*/deviceManagement/managedDevices/*')
            if ($includeContext) {
                $calls.Count | Should Be 2
                $identified.OSVersion | Should Be '10.0.26100'
                $identified.SyncAge | Should Be '1 to under 7 days'
                $unverified = $queue.Data | Where-Object ErrorCode -eq 'No error code reported'
                $unverified.ContextStatus | Should Be 'Device ID not verified'
                $unverified.OSVersion | Should Be ''
                ($charts | Where-Object Title -eq 'Error code by reported OS version').Total | Should Be 1
                ($charts | Where-Object Title -eq 'Error code by last Intune sync age').Total | Should Be 1
            } else {
                $calls.Count | Should Be 0
                $identified.ContextStatus | Should Be 'Not requested'
                @($charts | Where-Object Title -like 'Error code by *').Count | Should Be 0
            }
        }
    }
    It 'retains deployment failures when an optional device lookup fails' {
        $args = @{AppId='00000000-0000-0000-0000-000000000006';OutputPath=$fixtureRoot;IncludeUserStatus=$false;IncludeDeviceContext=$true}
        $result = Invoke-OfflineEndpointWorkflow 'intune-assignment-win32-deployment-exports' $args 'DeploymentTriageLookupFailure'
        $queue = $result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -like 'Failure triage -*' }
        $row = $queue.Data | Where-Object ContextStatus -eq 'Lookup failed'
        $row.FailureRows | Should Be 2
        $row.OSVersion | Should Be ''
        ($result.Warnings -join ' ') | Should Match 'Device context unavailable'
        $chart = ($result.Events | Where-Object Type -eq 'ReportVisual').Data | Where-Object Title -eq 'Error code by reported OS version'
        $chart.Total | Should Be 0
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
        $charts = ($result.Events | Where-Object Type -eq 'ReportVisual').Data
        $charts.Count | Should Be 3
        $charts[0].Total | Should Be 2
        $charts[0].Basis | Should Match '2 rows without a device ID excluded'
        ($charts[0].Bars | Where-Object Label -eq 'Failed').Count | Should Be 1
        ($charts[0].Bars | Where-Object Label -like 'Other or unknown*').Count | Should Be 1
        $charts[1].Total | Should Be 2
        @($charts[1].Bars | Where-Object Label -eq 'Not installed').Count | Should Be 0
        $requests = @($result.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -like '*exportJobs*' })
        $requests.Count | Should Be 2
        foreach ($request in $requests) { ($request.Body | ConvertFrom-Json).localizationType | Should Be 'LocalizedValuesAsAdditionalColumn' }
    }
    It 'retains device exports and reports partial failure if the user report fails' {
        $result = Invoke-OfflineEndpointWorkflow 'intune-assignment-win32-deployment-exports' @{AppId='00000000-0000-0000-0000-000000000006';OutputPath=$fixtureRoot} 'DeploymentUserFailure'
        @($result.Events | Where-Object Type -eq 'Artifact').Count | Should Be 2
        ($result.Errors -join "`n") | Should Match 'Synthetic user report failure'
        $partialCharts = ($result.Events | Where-Object Type -eq 'ReportVisual').Data
        @($partialCharts | Where-Object Title -eq 'Win32 failures by error code').Count | Should Be 1
        @($partialCharts | Where-Object Title -eq 'Device outcomes in the user report').Count | Should Be 0
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
        $visuals = @($result.Events | Where-Object Type -eq 'ReportVisual')
        $visuals.Count | Should Be 2
        @($visuals.Name | Select-Object -Unique).Count | Should Be 2
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
    It 'publishes detail datasets and real artifact paths for all ten file-producing reports' {
        $cases = @(
            @{Id='mobile-inventory';Args=@{OutputPath=$fixtureRoot}}
            @{Id='cloudpc-last-login';Args=@{OutputPath=$fixtureRoot}}
            @{Id='device-usage';Args=@{Devices='Fixture-PC';OutputPath=$fixtureRoot}}
            @{Id='quality-updates';Args=@{PolicyName='Fixture Policy';OutputPath=$fixtureRoot}}
            @{Id='intune-script-device-status';Args=@{ScriptType='Remediation';ScriptName='Fixture remediation';OutputPath=$fixtureRoot}}
            @{Id='stale-synced-devices';Args=@{OutputPath=$fixtureRoot}}
            @{Id='discovered-apps';Args=@{Platform='Windows';AppName='Fixture App';OutputPath=$fixtureRoot}}
            @{Id='intune-assignment-win32-deployment-exports';Args=@{AppId='00000000-0000-0000-0000-000000000006';OutputPath=$fixtureRoot;IncludeUserStatus=$true}}
            @{Id='all-device-assignments';Args=@{OutputPath=$fixtureRoot}}
            @{Id='group-app-assignments';Args=@{EntraGroup='Fixture Group';OutputPath=$fixtureRoot}}
        )
        foreach ($case in $cases) {
            $result = Invoke-OfflineEndpointWorkflow $case.Id $case.Args
            if (@($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Data.Count }).Count -lt 1) { throw "No data published by $($case.Id)" }
            if (@($result.Events | Where-Object Type -eq 'Artifact').Count -lt 1) { throw "No artifact published by $($case.Id)" }
            if ($case.Id -eq 'mobile-inventory') {
                $charts = ($result.Events | Where-Object Type -eq 'ReportVisual').Data
                $charts.Count | Should Be 4
                ($charts[1].Bars | Where-Object Label -eq 'Company').Count | Should Be 1
                ($charts[2].Bars | Where-Object Label -eq 'Other or unknown').Count | Should Be 1
            }
            if ($case.Id -eq 'stale-synced-devices') {
                $chart = ($result.Events | Where-Object Type -eq 'ReportVisual').Data[0]
                $chart.Total | Should Be 1
                ($chart.Bars | Where-Object Label -eq '90-179 days').Count | Should Be 1
            }
            if ($case.Id -in @('cloudpc-last-login','device-usage','discovered-apps')) {
                $visual = @($result.Events | Where-Object Type -eq 'ReportVisual')
                $visual.Count | Should Be 1
                $visual[0].Data[0].Total | Should Be 1
                $label = if ($case.Id -eq 'discovered-apps') { '1.0' } else { '0-6 days' }
                $chart = if ($case.Id -eq 'device-usage') {
                    $visual[0].Data | Where-Object Title -eq 'Days since latest successful Entra sign-in'
                } else { $visual[0].Data[0] }
                ($chart.Bars | Where-Object Label -eq $label).Count | Should Be 1
                if ($case.Id -eq 'discovered-apps') { $visual[0].Name | Should Be 'Fixture App' }
            }
            foreach ($artifact in @($result.Events | Where-Object Type -eq 'Artifact')) { (Test-Path -LiteralPath $artifact.Data) | Should Be $true }
            $summary = @($result.Events | Where-Object Type -eq 'OperationSummary')
            $summary.Count | Should Be 1
            $summary[0].Data.Affected | Should Be 0
            $summary[0].Data.Failed | Should Be 0
        }
    }
    It 'counts distinct devices per app version and retains grouped and missing version counts' {
        . (Join-Path $desktop 'ReportVisuals.ps1')
        $rows = @(1..9 | ForEach-Object { [pscustomobject]@{ ReportedVersion = "1.$_"; DeviceId = 'device-a' } })
        $rows += [pscustomobject]@{ ReportedVersion = '1.1'; DeviceId = 'DEVICE-A' }
        $rows += [pscustomobject]@{ ReportedVersion = '1.1'; DeviceId = 'device-b' }
        $rows += [pscustomobject]@{ ReportedVersion = ''; DeviceId = 'device-b' }
        $chart = Get-EndpointDiscoveredVersionChart $rows
        $chart.Total | Should Be 11
        $chart.Bars[0].Label | Should Be '1.1'
        $chart.Bars[0].Count | Should Be 2
        ($chart.Bars | Where-Object Label -eq 'Other reported versions').Count | Should Be 1
        ($chart.Bars | Where-Object Label -eq 'No version reported').Count | Should Be 1
    }
    It 'classifies offset logons and Entra sign-ins without treating missing or future dates as old activity' {
        . (Join-Path $desktop 'ReportVisuals.ps1')
        $now = [datetimeoffset]'2026-02-01T12:00:00Z'
        $cloudRows = @(
            [pscustomobject]@{ LoginStatus='Reported'; LastLoginEastern='2026-01-25 07:00:00 -05:00' }
            [pscustomobject]@{ LoginStatus='Reported'; LastLoginEastern='2026-01-25 07:00:01 -05:00' }
            [pscustomobject]@{ LoginStatus='Not reported' }
            [pscustomobject]@{ LoginStatus='Lookup failed' }
            [pscustomobject]@{ LoginStatus='Reported'; LastLoginEastern='invalid' }
        )
        $cloud = Get-EndpointActivityRecencyChart 'cloudpc-last-login' $cloudRows $now
        (($cloud.Bars | ForEach-Object { $_.Count }) -join ',') | Should Be '1,1,0,0,1,1,1'
        $signInRows = @(
            [pscustomobject]@{ LastSignIn=$now.AddDays(-30).ToString('o') }
            [pscustomobject]@{ LastSignIn=$now.AddDays(-90) }
            [pscustomobject]@{ Note='No sign-ins in window' }
            [pscustomobject]@{ Note='No azureADDeviceId' }
            [pscustomobject]@{ LastSignIn=$now.AddMinutes(1).UtcDateTime }
        )
        $signIns = Get-EndpointActivityRecencyChart 'device-usage' $signInRows $now
        (($signIns.Bars | ForEach-Object { $_.Count }) -join ',') | Should Be '0,0,1,1,1,1,1'
    }
    It 'lists all expedited policies without exporting and runs only the selected ID when names match' {
        $listing = Invoke-OfflineEndpointWorkflow 'quality-updates' @{ListPolicies=$true} 'DuplicateQualityPolicies'
        $choices = @($listing.Events | Where-Object { $_.Type -eq 'Choice' -and $_.Name -eq 'Quality update policies' })[0].Data
        $choices.Count | Should Be 2
        @($choices.Display | Select-Object -Unique).Count | Should Be 2
        $listing.Calls.Count | Should Be 2
        @($listing.Calls | Where-Object Method -ne 'GET').Count | Should Be 0
        @($listing.Events | Where-Object Type -in @('Rows','Artifact','OperationSummary','ReportVisual')).Count | Should Be 0

        $result = Invoke-OfflineEndpointWorkflow 'quality-updates' @{PolicyId=$choices[1].Id;OutputPath=$fixtureRoot} 'DuplicateQualityPolicies'
        $requests = @($result.Calls | Where-Object Method -eq 'POST')
        $requests.Count | Should Be 1
        ($requests[0].Body | ConvertFrom-Json).filter | Should Be "(PolicyId eq '$($choices[1].Id)')"
        @($result.Events | Where-Object Type -eq 'Artifact').Count | Should Be 1
        $charts = ($result.Events | Where-Object Type -eq 'ReportVisual').Data
        $charts.Count | Should Be 2
        $charts[0].Bars[0].Label | Should Be 'Installed'
        $charts[1].Bars[0].Label | Should Be 'Fixture update substatus'
        $charts[1].Total | Should Be 1
    }
    It 'keeps every update record in the chart total when labels are missing or grouped' {
        . (Join-Path $desktop 'ReportVisuals.ps1')
        $rows = @(1..10 | ForEach-Object { [pscustomobject]@{ AggregateState = "Fixture status $_" } })
        $rows += [pscustomobject]@{}
        $chart = @(Get-EndpointInventoryCharts 'quality-updates' $rows)[0]
        $chart.Total | Should Be 11
        $chart.Bars.Count | Should Be 10
        $chart.Bars[0].Label | Should Match '^Fixture status '
        ($chart.Bars | Where-Object Label -eq 'Other reported values').Count | Should Be 2
        ($chart.Bars | Where-Object Label -eq 'No value in report').Count | Should Be 1
    }
    It 'distinguishes reported update statuses without giving grouped or missing data an accent' {
        . (Join-Path $desktop 'ReportVisuals.ps1')
        $rows = @(1..10 | ForEach-Object {
            [pscustomobject]@{ AggregateState_loc = "Overall $_"; CurrentDeviceUpdateSubstatus = "Detail $_" }
        })
        $rows += [pscustomobject]@{}
        foreach ($chart in (Get-EndpointInventoryCharts 'quality-updates' $rows)) {
            $reported = @($chart.Bars | Where-Object Label -match '^(Overall|Detail) ')
            @($reported | Where-Object Color -ne 'Neutral' | Select-Object -ExpandProperty Color -Unique).Count | Should Be 8
            @($chart.Bars | Where-Object { $_.Label -in @('Other reported values', 'No value in report') -and $_.Color -eq 'Neutral' }).Count | Should Be 2
        }
    }
    It 'bins stale sign-ins without treating missing dates as recent or confirmed stale' {
        . (Join-Path $desktop 'ReportVisuals.ps1')
        $rows = @(89, 90, 179, 180, 364, 365, $null | ForEach-Object {
            [pscustomobject]@{ ActivityStatus = 'Stale'; DaysSinceLastSignIn = $_ }
        })
        $rows += [pscustomobject]@{ ActivityStatus = 'Unknown'; DaysSinceLastSignIn = 365 }
        $chart = Get-EndpointInventoryCharts 'stale-synced-devices' $rows
        $chart.Total | Should Be 8
        (($chart.Bars | ForEach-Object { $_.Count }) -join ',') | Should Be '1,2,2,1,2'
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
        $charts = ($result.Events | Where-Object Type -eq 'ReportVisual').Data
        $charts.Count | Should Be 2
        ($charts[0].Bars | Where-Object Label -eq 'Without issues').Count | Should Be 1
        ($charts[1].Bars | Where-Object Label -eq 'Skipped').Count | Should Be 1
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
        $chart = ($result.Events | Where-Object Type -eq 'ReportVisual').Data[0]
        $chart.Total | Should Be 1
        ($chart.Bars | Where-Object Label -eq 'Succeeded').Count | Should Be 1
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
    It 'compares the assigned Intune user with the unique leader by active days, not event count' {
        $result = Invoke-OfflineEndpointWorkflow 'device-usage' @{Devices='Fixture-PC';OutputPath=$fixtureRoot} 'UsageMismatch'
        $row = ($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Devices' }).Data[0]
        $row.IntunePrimaryUser | Should Be 'fixture@example.invalid'
        $row.ObservedTopUser | Should Be 'observed@example.invalid'
        $row.PrimaryUserActiveDays | Should Be 1
        $row.TopUserActiveDays | Should Be 2
        $row.PrimaryUserComparison | Should Be 'Mismatch'
        $row.ActiveDayGap | Should Be 1
        @($row.ObservedSignInDaysUtc -split ';').Count | Should Be 2
        $bar = ($result.Events | Where-Object Type -eq 'ReportVisual').Data[0].Bars | Where-Object Label -eq 'Mismatch'
        $bar.Count | Should Be 1
        $bar.Column | Should Be 'ReviewCategory'
        $row.SignIns | Should Be 5
        @($result.Calls | Where-Object Method -ne GET).Count | Should Be 0
    }
    It 'distinguishes matches, ties, no assignment, no sign-ins, and failed lookups' {
        foreach ($case in @(
            @{Scenario='Happy'; Comparison='Match'; Failed=0}
            @{Scenario='UsageTie'; Comparison='Inconclusive - tied active days'; Failed=0}
            @{Scenario='UsageUnassigned'; Comparison='No Intune primary user assigned'; Failed=0}
            @{Scenario='UsageEmpty'; Comparison='Inconclusive - no sign-ins in window'; Failed=0}
            @{Scenario='UsagePrimaryFailed'; Comparison='Inconclusive - Lookup failed'; Failed=1}
            @{Scenario='UsageAuditFailed'; Comparison='Inconclusive - sign-in lookup failed'; Failed=1}
        )) {
            $result = Invoke-OfflineEndpointWorkflow 'device-usage' @{Devices='Fixture-PC';OutputPath=$fixtureRoot} $case.Scenario
            $row = ($result.Events | Where-Object { $_.Type -eq 'Rows' -and $_.Name -eq 'Devices' }).Data[0]
            $row.PrimaryUserComparison | Should Be $case.Comparison
            ($result.Events | Where-Object Type -eq 'OperationSummary').Data.Failed | Should Be $case.Failed
            if ($case.Scenario -in @('UsageTie','UsageEmpty','UsageAuditFailed')) {
                [string]$row.ObservedTopUser | Should Be ''
            }
        }
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
    It 'treats cleanup remote logging as optional and uses the Toolbox variable name' {
        $scriptText = Get-Content -LiteralPath (Join-Path (Split-Path $desktop -Parent) 'Intune\Devices\Remove-EntraDevice.ps1') -Raw
        $scriptText | Should Match 'ENDPOINT_TOOLBOX_LOGGING_WEBHOOK'
        $scriptText | Should Not Match 'ENDPOINT_MANAGEMENT_LOGGING_WEBHOOK'
        $scriptText | Should Not Match 'IsNullOrWhiteSpace\(\$WebhookUrl\)\) \{\s*throw'
        $scriptText | Should Match '\$remoteLoggingEnabled'
        $scriptText | Should Match 'elseif \(-not \$remoteLoggingEnabled\)'
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

Describe 'Chart paging and inventory integration' {
    It 'updates loaded-only charts after paging without extra requests and preserves retry on failure' {
        $arguments = @{UserIdentity='fixture@example.invalid';LookbackDays=1;ReportMode='Paged events'}
        $first = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryHappy'
        $first.Calls.Count | Should Be 2
        $charts = @($first.Events | Where-Object Type -eq 'ReportVisual')[0].Data
        $charts.Count | Should Be 6
        $charts[0].Basis | Should Match '2 shown event\(s\) from 2 received'
        $charts[0].Basis | Should Match 'Incomplete'
        $failed = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryPageFailure' -CaptureFailure -SignInAction More
        [bool]$failed.Failure | Should Be $true
        @($failed.Events | Where-Object Type -eq 'ReportVisual').Count | Should Be 0
        $more = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' $arguments 'SignInHistoryHappy' -SignInAction More
        $more.Calls.Count | Should Be 1
        $charts = @($more.Events | Where-Object Type -eq 'ReportVisual')[0].Data
        $charts[0].Basis | Should Match '3 shown event\(s\) from 3 received'
        $charts[0].Basis | Should Match 'No more pages returned'
    }

    It 'publishes explicitly incomplete visuals for an empty failures-only page' {
        $run = Invoke-OfflineEndpointWorkflow 'user-sign-in-history' @{UserIdentity='fixture@example.invalid';ReportMode='Paged events';FailuresOnly=$true} 'SignInHistorySuccessPage'
        $charts = @($run.Events | Where-Object Type -eq 'ReportVisual')[0].Data
        $charts[0].Total | Should Be 0
        $charts[0].Basis | Should Match '0 shown event\(s\) from 1 received'
        $charts[0].Basis | Should Match 'Incomplete'
        $charts[0].Basis | Should Match 'Failures-only'
    }

    It 'publishes the mobile OS version chart alongside existing inventory charts' {
        $result = Invoke-OfflineEndpointWorkflow 'mobile-inventory' @{OutputPath=$fixtureRoot}
        $charts = @($result.Events | Where-Object Type -eq 'ReportVisual')[0].Data
        $charts.Count | Should Be 4
        $charts[3].Title | Should Be 'Mobile OS versions'
        $charts[3].Total | Should Be @($result.Events | Where-Object Type -eq 'Rows')[0].Data.Count
    }
}

Remove-Variable -Name EndpointSignInHistoryState -Scope Global -ErrorAction Ignore
Remove-Item -LiteralPath $userFile -Force
Get-ChildItem -LiteralPath $fixtureRoot -File | Remove-Item -Force
Remove-Item -LiteralPath $fixtureRoot
