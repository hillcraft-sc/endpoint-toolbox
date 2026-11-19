# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

@{
    SchemaVersion = 1
    Workflows = @(
        @{
            Id = 'mobile-inventory'; Title = 'Mobile device inventory'; Category = 'Inventory'
            Path = 'Intune\Devices\Export-IntuneMobileDevices.ps1'; Risk = 'Read only'
            GraphRole = 'Reader'; GraphScopes = @('DeviceManagementManagedDevices.Read.All')
            Description = 'iOS/iPadOS and Android inventory, compliance and ownership.'
            Defaults = @{ Platform = 'All'; OutputPath = 'TEMP' }
        }
        @{
            Id = 'cloudpc-last-login'; Title = 'Cloud PC last login'; Category = 'Inventory'
            Path = 'Intune\Devices\Get-CloudPCsLastLogin.ps1'; Risk = 'Read only'
            GraphRole = 'Reader'; GraphScopes = @('DeviceManagementManagedDevices.Read.All')
            Description = 'Intune-reported Windows logons, not Windows 365 connections. Missing is not never used. Dates are Eastern with offset.'
            Defaults = @{ OutputPath = 'TEMP' }
        }
        @{
            Id = 'group-devices'; Title = 'Entra group devices'; Category = 'Inventory'
            Path = 'Intune\Devices\Get-EntraGroupDevices.ps1'; Risk = 'Read only'
            GraphRole = 'Reader'; GraphScopes = @('Group.Read.All','Directory.Read.All','Device.Read.All')
            Description = 'Transitive group device members. Entra object/device IDs are not Intune IDs.'
            Defaults = @{ OutputPath = 'TEMP' }
        }
        @{
            Id = 'entra-user-lookup'; Title = 'Find Entra users by name'; Category = 'Inventory'
            Path = 'entra\Find-EntraUsersByName.ps1'; Risk = 'Read only'
            GraphRole = 'Reader'; GraphScopes = @('User.Read.All')
            Description = 'Matches "First Last" or "Last, First" names to Entra users. Same-surname, same-initial results are possible matches only.'
            Selectors = @(
                @{ Label = 'Names to find'; Options = @(
                    @{ Name = 'Names'; Parameters = @('Names') }
                    @{ Name = 'Name list file'; Parameters = @('UserListPath') }
                ) }
            )
        }
        @{
            Id = 'device-usage'; Title = 'Device user usage'; Category = 'Device reports'
            Path = 'Intune\Devices\Get-DeviceUserUsage.ps1'; Risk = 'Read only'
            GraphRole = 'Reader'; GraphScopes = @('DeviceManagementManagedDevices.Read.All','AuditLog.Read.All','Directory.Read.All','Group.Read.All')
            Description = 'Successful Entra sign-ins; retention depends on the tenant. Duplicate device names report every match.'
            Defaults = @{ OutputPath = 'TEMP'; LookbackDays = 30 }
            Selectors = @(@{ Label = 'Device source'; Options = @(
                @{ Name = 'Device names'; Parameters = @('Devices') }
                @{ Name = 'Text file'; Parameters = @('DeviceListPath') }
                @{ Name = 'Entra group'; Parameters = @('EntraGroup') }
            ) })
        }
        @{
            Id = 'quality-updates'; Title = 'Expedited quality updates'; Category = 'Device reports'
            Path = 'Intune\Devices\Get-QualityUpdates-Report.ps1'; Risk = 'Read only'
            GraphRole = 'Reader'; GraphScopes = @('DeviceManagementConfiguration.Read.All')
            Description = 'Load Intune expedited quality-update policies and report device status for one selected policy.'
            Defaults = @{ OutputPath = 'TEMP' }
            HiddenParameters = @('PolicyName', 'PolicyId', 'ListPolicies')
        }
        @{
            Id = 'intune-script-device-status'; Title = 'Remediation and platform script status'; Category = 'Device reports'
            Path = 'Intune\Devices\Get-IntuneScriptDeviceStatus.ps1'; Risk = 'Read only'
            GraphRole = 'Reader'; GraphScopes = @('DeviceManagementScripts.Read.All')
            Description = 'Search Intune remediations and platform scripts, select one, and export its per-device run status.'
            Defaults = @{ ScriptType = 'All'; OutputPath = 'TEMP' }
            HiddenParameters = @('ScriptName', 'ScriptId', 'ListScripts')
        }
        @{
            Id = 'm365-cloud-update'; Title = 'Microsoft 365 Apps Cloud Update'; Category = 'Device reports'
            Path = 'entra\Get-M365CloudUpdateReport.ps1'; Risk = 'Read only'; Kind = 'Office'
            GraphRole = 'Reader'; GraphScopes = @('Group.Read.All','Device.Read.All')
            Description = 'Monthly Enterprise Channel release, rollout statistics and device details. Uses a separate interactive MSAL sign-in, not Home Graph. Undocumented Office portal APIs may change without notice.'
            Defaults = @{
                TenantId = 'organizations'
                PageSize = 200
                ExportFolder = 'TEMP'
                IncludeWaveGroups = $false
            }
        }
        @{
            Id = 'stale-synced-devices'; Title = 'Stale AD-synced Entra devices'; Category = 'Device reports'
            Path = 'Intune\Devices\Get-StaleSyncedDevices.ps1'; Risk = 'Read only'
            GraphRole = 'Reader'; GraphScopes = @('Device.Read.All')
            Description = 'Approximate Entra activity, not AD last logon. Unknown activity is not confirmed stale.'
            Defaults = @{ OutputPath = 'TEMP'; Days = 90 }
        }
        @{
            Id = 'discovered-apps'; Title = 'Discovered apps'; Category = 'Apps and assignments'
            Path = 'Intune\Devices\Get-DiscoveredApps.ps1'; Risk = 'Read only'
            GraphRole = 'Reader'; GraphScopes = @('DeviceManagementApps.Read.All','DeviceManagementManagedDevices.Read.All','Group.Read.All','Directory.Read.All')
            Description = 'Platform inventory, optional app wildcard and device/user group scope. Large exports may take 30 minutes.'
            Defaults = @{ OutputPath = 'TEMP' }
        }
        @{
            Id = 'intune-assignment-win32-deployment-exports'; Title = 'Win32 app deployment status'; Category = 'Apps and assignments'
            Path = 'Intune\Assignments\Get-Win32AppDeploymentStatus.ps1'; Risk = 'Read only'
            GraphRole = 'Reader'; GraphScopes = @('DeviceManagementApps.Read.All')
            Description = 'Search by partial name or wildcard, then select one or more apps. Exports full device details, a per-device summary and user status for each selected app.'
            Defaults = @{ OutputPath = 'TEMP'; TimeoutSeconds = 300; IncludeUserStatus = $true }
        }
        @{
            Id = 'all-device-assignments'; Title = 'Apps assigned to All Devices / Users'; Category = 'Apps and assignments'
            Path = 'Intune\Assignments\Get-AppsAssignedToAllDevices.ps1'; Risk = 'Read only'
            GraphRole = 'Reader'; GraphScopes = @('DeviceManagementApps.Read.All')
            Description = 'Assignment targets and filters, not guaranteed effective device coverage. Failed lookups mean incomplete results.'
            Defaults = @{ OutputPath = 'TEMP'; AppType = 'Win32' }
        }
        @{
            Id = 'group-app-assignments'; Title = 'Apps assigned to an Entra group'; Category = 'Apps and assignments'
            Path = 'Intune\Assignments\Get-IntuneAppAssignmentsForGroup.ps1'; Risk = 'Read only'
            GraphRole = 'Reader'; GraphScopes = @('DeviceManagementApps.Read.All','Group.Read.All')
            Description = 'Direct include/exclude assignments to this group, not effective assignments for its members.'
            Defaults = @{ OutputPath = 'TEMP'; AppType = 'All' }
        }
        @{
            Id = 'delete-win32-apps'; Title = 'Delete Win32 apps'; Category = 'Apps and assignments'
            Path = 'Intune\Apps\Remove-Win32App.ps1'; Risk = 'Destructive'; ShouldProcess = $true
            GraphRole = 'Intune'; GraphScopes = @('DeviceManagementApps.ReadWrite.All')
            Description = 'Deletes app objects and their assignments, not installed software. Approval may remain pending. Supply business justification.'
            Defaults = @{ WhatIf = $false; OutputPath = 'TEMP' }
        }
        @{
            Id = 'add-members-to-group'; Title = 'Add users or devices to Entra group'; Category = 'Groups'
            Path = 'entra\Add-EntraGroupMembers.ps1'; Risk = 'Change'
            GraphRole = 'Groups'; GraphScopes = @('Group.Read.All','GroupMember.ReadWrite.All')
            Description = 'Adds direct memberships. Duplicate hostnames add all matching Entra device objects. No script-backed preview.'
            Selectors = @(
                @{ Label = 'Target group'; Options = @(
                    @{ Name = 'Group ID'; Parameters = @('GroupId') }
                    @{ Name = 'Group name'; Parameters = @('GroupName') }
                ) }
                @{ Label = 'Members to add'; Options = @(
                    @{ Name = 'User UPNs'; Parameters = @('Users') }
                    @{ Name = 'User list file'; Parameters = @('UserListPath', 'UserColumn') }
                    @{ Name = 'Device names'; Parameters = @('DeviceNames') }
                    @{ Name = 'Device text file'; Parameters = @('DeviceListPath') }
                ) }
            )
        }
        @{
            Id = 'remove-members-from-group'; Title = 'Remove users or devices from Entra group'; Category = 'Groups'
            Path = 'entra\Remove-EntraGroupMembers.ps1'; Risk = 'Destructive'; ShouldProcess = $true
            GraphRole = 'Groups'; GraphScopes = @('Group.Read.All')
            Description = 'Remove direct memberships only. Dynamic and other protected groups are blocked; ambiguous matches are skipped.'
            Defaults = @{ WhatIf = $false }
            Selectors = @(
                @{ Label = 'Target group'; Options = @(
                    @{ Name = 'Group ID'; Parameters = @('GroupId') }
                    @{ Name = 'Group name'; Parameters = @('GroupName') }
                ) }
                @{ Label = 'Members to remove'; Options = @(
                    @{ Name = 'User UPNs'; Parameters = @('Users') }
                    @{ Name = 'User list file'; Parameters = @('UserListPath', 'UserColumn') }
                    @{ Name = 'Device names'; Parameters = @('DeviceNames') }
                    @{ Name = 'Device text file'; Parameters = @('DeviceListPath') }
                ) }
            )
        }
        @{
            Id = 'create-direct-reports-group'; Title = 'Create direct reports group'; Category = 'Groups'
            Path = 'entra\New-EntraDirectReportsGroup.ps1'; Risk = 'Change'; ShouldProcess = $true
            GraphRole = 'Groups'; GraphScopes = @('User.Read.All','Group.ReadWrite.All')
            Description = 'Supply the manager exact full name or UPN. Creates Entra.Users.DirectReports.<FirstLast> from Entra first and last names, not display name. Entra includes the manager and immediate reports. Existing names block creation; membership processing is asynchronous.'
            Defaults = @{ WhatIf = $false }
        }
        @{
            Id = 'add-primary-devices-to-group'; Title = "Add users' most recently synced devices"; Category = 'Groups'
            Path = 'entra\Add-PrimaryUserDevicesToEntraGroup.ps1'; Risk = 'Change'; ShouldProcess = $true
            GraphRole = 'Groups'; GraphScopes = @('DeviceManagementManagedDevices.Read.All','Device.Read.All','GroupMember.ReadWrite.All')
            Description = 'Uses Intune userPrincipalName, not the primary-user relationship. Latest eligible Windows sync wins. OutputFile is overwritten even in preview.'
            Defaults = @{ LookbackDays = 30; OutputFile = 'C:\temp\PrimaryUserDeviceGroupResults.csv'; WhatIf = $false }
            Selectors = @(@{ Label = 'Target group'; Options = @(
                @{ Name = 'Group ID'; Parameters = @('GroupId') }
                @{ Name = 'Group name'; Parameters = @('GroupName') }
            ) })
        }
        @{
            Id = 'primary-users'; Title = 'Read / change Intune primary users'; Category = 'Device actions'
            Path = 'Intune\Devices\Get-IntuneDevicePrimaryUser.ps1'; Risk = 'Read / change'; ShouldProcess = $true
            GraphRole = 'Intune'; GraphScopes = @('DeviceManagementManagedDevices.Read.All','User.Read.All','Group.Read.All')
            Description = 'Read, assign or remove Intune primary users. Changes retain individual Yes/No approval. Requests are not verified changes.'
            Defaults = @{ WhatIf = $false }
            Selectors = @(
            @{ Label = 'What would you like to do?'; Options = @(
                @{ Name = 'Read primary users'; Parameters = @() }
                @{ Name = 'Assign a new primary user'; Parameters = @('NewPrimaryUser') }
                @{ Name = 'Remove the primary user'; Parameters = @('RemovePrimaryUser') }
            ) }
            @{ Label = 'Device source'; Options = @(
                @{ Name = 'Device names'; Parameters = @('Devices') }
                @{ Name = 'Intune managed device IDs'; Parameters = @('ManagedDeviceId') }
                @{ Name = 'Text file'; Parameters = @('DeviceListPath') }
                @{ Name = 'Group display name'; Parameters = @('GroupName') }
            ) })
        }
        @{
            Id = 'intune-sync'; Title = 'Request Intune sync'; Category = 'Device actions'
            Path = 'Intune\Devices\Invoke-IntuneSync.ps1'; Risk = 'Change'
            GraphRole = 'Intune'; GraphScopes = @('DeviceManagementManagedDevices.ReadWrite.All','DeviceManagementManagedDevices.PrivilegedOperations.All','Group.Read.All')
            Description = 'Real sync requests, no WhatIf. Requested is not confirmed. Requires Get-MgDeviceManagementManagedDevice and Sync-MgDeviceManagementManagedDevice; module packaging can vary by Graph version.'
            Defaults = @{ VerifyTimeoutMinutes = 10; VerifyIntervalSeconds = 30 }
            Selectors = @(
                @{
                    Label = 'Device source'
                    Options = @(
                        @{ Name = 'Device names'; Parameters = @('Devices') }
                        @{ Name = 'Text file'; Parameters = @('DeviceListPath') }
                        @{ Name = 'Entra group'; Parameters = @('EntraGroup') }
                    )
                }
            )
        }
        @{
            Id = 'entra-cleanup'; Title = 'Entra / Autopilot cleanup'; Category = 'Device actions'
            Path = 'Intune\Devices\Remove-EntraDevice.ps1'; Risk = 'Destructive'; ShouldProcess = $true
            GraphRole = 'Cleanup'; GraphScopes = @('Device.ReadWrite.All','DeviceManagementManagedDevices.Read.All','DeviceManagementServiceConfig.ReadWrite.All')
            Description = 'Deletes orphaned objects; no age threshold. Declining Autopilot deletion still allows separately approved Entra deletion. Real runs always save a results CSV; preview saves one only when Export CSV is selected.'
            Defaults = @{ OutputPath = 'TEMP'; WhatIf = $false }
            Selectors = @(
                @{
                    Label = 'Device source'
                    Options = @(
                        @{ Name = 'Device names'; Parameters = @('Devices') }
                        @{ Name = 'Text file'; Parameters = @('DeviceListPath') }
                    )
                }
            )
        }
        @{
            Id = 'remote-endpoint'; Title = 'Remote endpoint session'; Category = 'Remote support'
            Path = 'PSRemote-Endpoint.ps1'; Risk = 'Privileged remote session'; Kind = 'Remote'
            HiddenParameters = @('DnsSuffix')
            Description = 'Ping and WinRM checks, privileged credentials, Negotiate / EnableNetworkAccess. Commands run in the embedded workspace. UNC explicitly hands off to Explorer; its credential access is not guaranteed. An optional DNS suffix for the share is set under Settings > Remote.'
        }
    )
}
