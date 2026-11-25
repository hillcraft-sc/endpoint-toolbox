[CmdletBinding()]
param([ValidateSet('Bootstrap','Observe','Expire','Activate','Business','Forbidden','LimitConsent','DeniedBusiness','SignInPages','CloudPcHistory')][string]$Mode = 'Business')
switch ($Mode) {
    'Bootstrap' {
        $manifest=Import-PowerShellDataFile (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'WorkflowCatalog.psd1')
        $granted=@('User.Read','RoleManagement.Read.Directory','DeviceManagementManagedDevices.ReadWrite.All')
        foreach ($entry in $manifest.Workflows) { $granted+= @($entry['GraphScopes']) }
        $global:GraphFixture = @{ Context=$null; Connects=0; Disconnects=0; DisconnectFailure=$false; AuthCalls=[Collections.Generic.List[string]]::new(); Runs=0; Role='3a2c62db-5318-420d-8d74-23affee5d9d5'; Forbidden=$false; Response=$null; GrantedScopes=@($granted | Sort-Object -Unique); RequestedScopes=@() }
        function global:Get-MgContext {
            [CmdletBinding()]param()
            $global:GraphFixture.Context
        }
        function global:Connect-MgGraph {
            [CmdletBinding()]param($Scopes,$ContextScope,$TenantId,[switch]$NoWelcome)
            if ($ContextScope -ne 'Process') { throw 'Fixture requires process-scoped authentication.' }
            if (@($Scopes).Count -ne 1 -or $Scopes[0] -ne 'https://graph.microsoft.com/.default') { throw 'Home must request existing consent only, not a bundle of new scopes.' }
            $global:GraphFixture.AuthCalls.Add('Connect')
            $global:GraphFixture.Connects++
            $global:GraphFixture.RequestedScopes=@($Scopes)
            $global:GraphFixture.Context=[pscustomobject]@{ Account='fixture@example.invalid'; TenantId=$(if ($TenantId) { $TenantId } else { 'fixture-tenant' }); Scopes=@($global:GraphFixture.GrantedScopes); AuthType='Delegated'; Environment='Global' }
        }
        function global:Disconnect-MgGraph {
            [CmdletBinding()]param()
            $global:GraphFixture.AuthCalls.Add('Disconnect')
            if ($global:GraphFixture.DisconnectFailure) { throw 'Synthetic Graph sign-out failure.' }
            $global:GraphFixture.Disconnects++
            $global:GraphFixture.Context=$null
        }
        function global:Invoke-MgGraphRequest {
            [CmdletBinding()]param($Method,$Uri,$OutputType,$Headers,$Body,$ContentType)
            if ($Method -ne 'GET' -and -not ($Method -eq 'POST' -and $global:GraphFixture.Response)) { throw 'Unexpected write during connection verification.' }
            if ($global:GraphFixture.Forbidden) { throw 'Synthetic forbidden role lookup.' }
            if ($global:GraphFixture.Response) { return & $global:GraphFixture.Response $Method $Uri $OutputType $Body }
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
    'SignInPages' {
        $global:GraphFixture.Response = {
            param($Method,$Uri,$OutputType)
            switch -Wildcard ($Uri) {
                '*me[?]*' { return @{id='fixture-user';userPrincipalName='fixture@example.invalid'} }
                '*transitiveMemberOf*' { return @{value=@()} }
                '*roleAssignments*' { return @{value=@(@{principalId='fixture-user';directoryScopeId='/';appScopeId=$null;roleDefinition=@{templateId='f2ef992c-3afb-46b9-b7cf-a126ee74c451'}})} }
                '*v1.0/users[?]*' { return @{value=@(@{id='00000000-0000-0000-0000-000000000005'})} }
                '*signIns[?]*skiptoken*' { return @{value=@(@{id='second';isInteractive=$false;status=@{errorCode=0}})} }
                '*signIns[?]*' { return @{value=@(@{id='first';isInteractive=$true;status=@{errorCode=0}});'@odata.nextLink'='https://graph.microsoft.com/beta/auditLogs/signIns?$skiptoken=fixture'} }
                default { throw "Unexpected sign-in paging fixture URL: $Uri" }
            }
        }
    }
    'CloudPcHistory' {
        $global:GraphFixture.Response = {
            param($Method,$Uri,$OutputType,$Body)
            switch -Wildcard ($Uri) {
                '*me[?]*' { return @{id='fixture-user';userPrincipalName='fixture@example.invalid'} }
                '*transitiveMemberOf*' { return @{value=@()} }
                '*roleAssignments*' { return @{value=@(@{principalId='fixture-user';directoryScopeId='/';appScopeId=$null;roleDefinition=@{templateId='3a2c62db-5318-420d-8d74-23affee5d9d5'}})} }
                '*getRemoteConnectionHistoricalReports' {
                    if ($Method -ne 'POST' -or $OutputType -ne 'HttpResponseMessage') { throw 'Unexpected history request.' }
                    $request = $Body | ConvertFrom-Json
                    if ($request.filter -notmatch '00000000-0000-0000-0000-000000000001') { throw 'Wrong Cloud PC.' }
                    $columns = @('SignInDateTime','SignOutDateTime','UsageInHour','RoundTripTimeInMsP50','AvailableBandwidthInMbpsP50','RemoteSignInTimeInSec')
                    $schema = @($columns | ForEach-Object { @{Column=$_} })
                    $values = @('2026-01-01T00:00:00Z','2026-01-01T01:00:00Z',1,20,3,5)
                    $json = @{TotalRowCount=1;Schema=$schema;Values=,@($values)} | ConvertTo-Json -Depth 6 -Compress
                    $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
                    $response.Content = [Net.Http.StringContent]::new($json)
                    return $response
                }
                default { throw "Unexpected history fixture URL: $Uri" }
            }
        }
    }
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
