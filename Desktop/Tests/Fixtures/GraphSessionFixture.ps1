# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

[CmdletBinding()]
param([ValidateSet('Bootstrap','Observe','Expire','Activate','Business','Forbidden','LimitConsent','DeniedBusiness')][string]$Mode = 'Business')
switch ($Mode) {
    'Bootstrap' {
        $manifest=Import-PowerShellDataFile (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'WorkflowCatalog.psd1')
        $granted=@('User.Read','RoleManagement.Read.Directory','DeviceManagementManagedDevices.ReadWrite.All')
        foreach ($entry in $manifest.Workflows) { $granted+= @($entry['GraphScopes']) }
        $global:GraphFixture = @{ Context=$null; Connects=0; Runs=0; Role='3a2c62db-5318-420d-8d74-23affee5d9d5'; Forbidden=$false; Response=$null; GrantedScopes=@($granted | Sort-Object -Unique); RequestedScopes=@() }
        function global:Get-MgContext {
            [CmdletBinding()]param()
            $global:GraphFixture.Context
        }
        function global:Connect-MgGraph {
            [CmdletBinding()]param($Scopes,$ContextScope,$TenantId,[switch]$NoWelcome)
            if ($ContextScope -ne 'Process') { throw 'Fixture requires process-scoped authentication.' }
            if (@($Scopes).Count -ne 1 -or $Scopes[0] -ne 'https://graph.microsoft.com/.default') { throw 'Home must request existing consent only, not a bundle of new scopes.' }
            $global:GraphFixture.Connects++
            $global:GraphFixture.RequestedScopes=@($Scopes)
            $global:GraphFixture.Context=[pscustomobject]@{ Account='fixture@example.invalid'; TenantId=$(if ($TenantId) { $TenantId } else { 'fixture-tenant' }); Scopes=@($global:GraphFixture.GrantedScopes); AuthType='Delegated'; Environment='Global' }
        }
        function global:Disconnect-MgGraph {
            [CmdletBinding()]param()
            $global:GraphFixture.Context=$null
        }
        function global:Invoke-MgGraphRequest {
            [CmdletBinding()]param($Method,$Uri,$OutputType)
            if ($Method -ne 'GET') { throw 'Unexpected write during connection verification.' }
            if ($global:GraphFixture.Forbidden) { throw 'Synthetic forbidden role lookup.' }
            if ($global:GraphFixture.Response) { return & $global:GraphFixture.Response $Method $Uri $OutputType }
            switch -Wildcard ($Uri) {
                '*me[?]*' { return @{id='fixture-user';userPrincipalName='fixture@example.invalid'} }
                '*transitiveMemberOf*' { return @{value=@()} }
                '*roleAssignments*' {
                    $assignments=@()
                    if ($global:GraphFixture.Role) {
                        $assignments=@(@{principalId='fixture-user';directoryScopeId='/';appScopeId=$null;roleDefinition=@{templateId=$global:GraphFixture.Role}})
                    }
                    return @{value=$assignments}
                }
                default { throw "Unexpected Graph fixture URL: $Uri" }
            }
        }
    }
    'Observe' { "Connects=$($global:GraphFixture.Connects);Runs=$($global:GraphFixture.Runs)" }
    'Expire' { $global:GraphFixture.Role='' }
    'Activate' { $global:GraphFixture.Role='3a2c62db-5318-420d-8d74-23affee5d9d5' }
    'Forbidden' { $global:GraphFixture.Forbidden=$true }
    'LimitConsent' {
        $global:GraphFixture.GrantedScopes=@('User.Read','RoleManagement.Read.Directory')
    }
    'Business' {
        if (-not (Get-MgContext)) { throw 'The business fixture did not inherit the Home connection.' }
        $global:GraphFixture.Runs++
        'Business fixture ran using the Home connection.'
    }
    'DeniedBusiness' { throw 'Synthetic target-group authorization denied.' }
}
