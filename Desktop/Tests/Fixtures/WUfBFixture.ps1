[CmdletBinding()]
param(
    [string]$Scenario = 'Happy',
    [string]$TargetKB = 'KB5132043',
    [string[]]$DeviceNames = @(),
    [switch]$Direct,
    [switch]$Cancel,
    [switch]$UseDeviceAuthentication,
    [switch]$Repeat,
    [switch]$ResolveDeviceNames
)
$now = [datetime]::UtcNow
$fixtureTenant = '00000000-0000-0000-0000-000000000001'
$workspace = '00000000-0000-0000-0000-000000000002'
$events = [Collections.Generic.List[object]]::new()
$queries = [Collections.Generic.List[string]]::new()
$loginCalls = [Collections.Generic.List[object]]::new()
$configCalls = [Collections.Generic.List[object]]::new()
$graphRequests = [Collections.Generic.List[string]]::new()
$azureState = @{ Context = $null; TokenCalls = 0; ContextChecks = 0 }
$userContext = @{
    Account = @{ Id = 'fixture@example.invalid'; Type = 'User' }
    Tenant = @{ Id = $fixtureTenant }; Environment = @{ Name = 'AzureCloud' }
}
if ($Scenario -in @('ExistingSession','OtherTenant','OtherCloud','ServicePrincipal','InvalidContext',
        'RenewalRequired','RenewalCancelled','RenewalWrongAccount','RenewalWrongTenant','TokenFailure','TokenTlsFailure','ExistingPlainToken','ExistingAccessDenied')) {
    $azureState.Context = $userContext
    switch ($Scenario) {
        'OtherTenant' { $userContext.Tenant.Id = '00000000-0000-0000-0000-000000000003' }
        'OtherCloud' { $userContext.Environment.Name = 'AzureUSGovernment' }
        'ServicePrincipal' { $userContext.Account.Type = 'ServicePrincipal' }
        'InvalidContext' { $userContext.Tenant.Id = 'invalid' }
    }
}
$fixtureLoginExperience = if ($Scenario -eq 'ExistingLoginConfig') { 'On' } else { $null }
$fields = @{
    UCClient = @('AzureADDeviceID','GlobalDeviceId','DeviceName','TimeGenerated','LastWUScanTime','LastCensusScanTime','OSSecurityUpdateStatus','OSQualityUpdateStatus','OSBuild','OSVersion','OSEdition','OSArchitecture','OSServicingChannel','OSQualityUpdateReleaseTime','OSFeatureUpdateStatus','OSFeatureUpdateEOSTime','WUQualityPauseState','WUQualityDeferralDays','WUQualityDeadlineDays','WUQualityGracePeriodDays','AzureADTenantId')
    UCClientUpdateStatus = @('AzureADDeviceId','GlobalDeviceId','TimeGenerated','TargetKBNumber','TargetBuild','TargetVersion','ClientSubstate','ClientSubstateTime','UpdateCategory','UpdateClassification','UpdateDisplayName','UpdateReleaseTime','UpdateInstalledTime','RestartRequiredTime','DeploymentId','AzureADTenantId')
    UCServiceUpdateStatus = @('AzureADDeviceId','GlobalDeviceId','TimeGenerated','TargetBuild','UpdateCategory','UpdateDisplayName','DeploymentId','ServiceState','ServiceSubstate','ServiceSubstateTime','OfferReadyTime','AzureADTenantId')
    UCUpdateAlert = @('AzureADDeviceId','GlobalDeviceId','TimeGenerated','AlertId','AlertStatus','AlertClassification','AlertType','AlertSubtype','TargetBuild','DeploymentId','ErrorCode','ErrorSymName','Description','Recommendation','StartTime','ResolvedTime','AzureADTenantId')
    UCDeviceAlert = @('AzureADDeviceId','GlobalDeviceId','TimeGenerated','AlertId','AlertStatus','AlertClassification','AlertType','AlertSubtype','TargetBuild','DeploymentId','ErrorCode','ErrorSymName','Description','Recommendation','StartTime','ResolvedTime','AzureADTenantId')
}
$rows = @{}
$rows.UCClient = @(foreach ($index in 1..8) {
    @{
        AzureADDeviceId = '00000000-0000-0000-0000-{0:d12}' -f (100 + $index)
        GlobalDeviceId = "fixture-$index"; DeviceName = if ($index -le 2) { 'Fixture-PC' } else { "Fixture-PC-$index" }
        TimeGenerated = $now.AddHours(-1); LastWUScanTime = if ($index -eq 6) { $now.AddDays(-12) } elseif ($index -eq 7) { $null } else { $now.AddHours(-2) }
        LastCensusScanTime = $now.AddHours(-2)
        OSSecurityUpdateStatus = if ($index -in @(2,3,4)) { 'NotLatest' } else { 'Latest' }
        OSQualityUpdateStatus = 'NotLatest'; OSBuild = if ($index -eq 5) { '10.0.26100.200' } elseif ($index -eq 8) { '10.0.22631.400' } elseif ($index -in @(2,3,4)) { '10.0.26100.50' } else { '10.0.26100.100' }
        OSVersion = if ($index -eq 8) { '23H2' } else { '24H2' }
        OSEdition = 'Enterprise'; OSArchitecture = 'amd64'; OSFeatureUpdateStatus = 'InService'
    }
})
function New-FixtureUpdate {
    param([int]$Index, [string]$State)
    @{
        AzureADDeviceId = '00000000-0000-0000-0000-{0:d12}' -f (100 + $Index)
        GlobalDeviceId = "fixture-$Index"; TimeGenerated = $now.AddHours(-1)
        TargetKBNumber = 'KB5132043'; TargetBuild = '10.0.26100.100'; TargetVersion = '24H2'
        ClientSubstate = $State; ClientSubstateTime = $now.AddHours(-3)
        UpdateCategory = 'WindowsQualityUpdate'; UpdateClassification = 'Security'
        UpdateDisplayName = 'Synthetic cumulative update'; UpdateReleaseTime = $now.AddDays(-25)
        UpdateInstalledTime = $null; RestartRequiredTime = $null; DeploymentId = 'fixture-deployment'
    }
}
$installed = New-FixtureUpdate 1 'Installed'
$installed.UpdateInstalledTime = $now.AddDays(-20)
$installed.ClientSubstateTime = $now.AddDays(-20)
$failed = New-FixtureUpdate 3 'Installing'
$restart = New-FixtureUpdate 4 'RebootPending'
$restart.RestartRequiredTime = $now.AddDays(-2)
$rows.UCClientUpdateStatus = @($installed,$failed,$restart)
$rows.UCServiceUpdateStatus = @(@{
    AzureADDeviceId = $failed.AzureADDeviceId; TimeGenerated = $now.AddHours(-1)
    TargetBuild = '10.0.26100.100'; UpdateCategory = 'WindowsQualityUpdate'; DeploymentId = 'fixture-deployment'
    ServiceState = 'Offering'; ServiceSubstate = 'OfferReady'; ServiceSubstateTime = $now.AddHours(-4)
})
$rows.UCUpdateAlert = @(@{
    AzureADDeviceId = $failed.AzureADDeviceId; TimeGenerated = $now.AddHours(-1)
    AlertId = 'fixture-error'; AlertStatus = 'Active'; AlertClassification = 'Error'
    AlertType = 'ClientUpdateAlert'; AlertSubtype = 'InstallIssue'; TargetBuild = '26100.100'
    DeploymentId = 'fixture-deployment'; ErrorCode = '0x80070005'; ErrorSymName = 'E_ACCESSDENIED'
    Description = 'Synthetic access denied'; Recommendation = 'Check installation access'
    StartTime = $now.AddHours(-3)
})
$rows.UCDeviceAlert = @()
switch ($Scenario) {
    'Empty' { $rows.UCClient = @() }
    'DuplicateIdentity' { $rows.UCClient += $rows.UCClient[0].Clone() }
    'ResolvedError' { $rows.UCUpdateAlert[0].AlertStatus = 'Resolved' }
    'InstalledAfterFailure' { $failed.ClientSubstate = 'Installed'; $failed.UpdateInstalledTime = $now.AddHours(-3) }
    'Uninstalled' { $installed.ClientSubstate = 'Uninstalled'; $installed.ClientSubstateTime = $now.AddHours(-3) }
    'RestartTimestampOnly' { $restart.ClientSubstate = 'Installed'; $restart.UpdateInstalledTime = $now.AddHours(-3) }
    'StaleKB' { $failed.ClientSubstateTime = $now.AddDays(-20) }
    'Stalled' { $failed.ClientSubstateTime = $now.AddDays(-20); $rows.UCUpdateAlert[0].AlertStatus = 'Resolved' }
    'Conflict' { $other = $restart.Clone(); $other.ClientSubstate = 'Installed'; $other.DeploymentId = 'other-deployment'; $rows.UCClientUpdateStatus += $other }
    'GlobalIdentity' { $rows.UCClient[0].AzureADDeviceId = ''; $installed.AzureADDeviceId = '' }
    'MissingIdentity' { $rows.UCClient[0].AzureADDeviceId = ''; $rows.UCClient[0].GlobalDeviceId = '' }
    'NoEvaluatedDevices' { foreach ($client in $rows.UCClient) { $client.LastWUScanTime = $null } }
    'SnapshotStale' { foreach ($client in $rows.UCClient) { $client.TimeGenerated = $now.AddDays(-20) } }
    'OptionalMissing' { $fields.UCClient = @($fields.UCClient | Where-Object { $_ -ne 'WUQualityPauseState' }) }
    'RequiredMissing' { $fields.UCClient = @($fields.UCClient | Where-Object { $_ -ne 'OSSecurityUpdateStatus' }) }
}
function Get-Module {
    param($Name, [switch]$ListAvailable)
    if ($Name -ne 'Az.Accounts' -or -not $ListAvailable) { throw 'Unexpected module lookup.' }
    if ($Scenario -ne 'MissingModule') { [pscustomobject]@{ Name = 'Az.Accounts'; Version = [version]'5.5.1' } }
}
function Import-Module { param($Name,$MinimumVersion) if ($Name -ne 'Az.Accounts') { throw 'Unexpected import.' } }
function Disable-AzContextAutosave { param($Scope) if ($Scope -ne 'Process') { throw 'Azure persistence must be process-scoped.' } }
function Get-AzContext {
    $azureState.ContextChecks++
    $azureState.Context
}
function Get-AzConfig {
    param([switch]$LoginExperienceV2,$Scope,$AppliesTo)
    if (-not $LoginExperienceV2 -or $Scope -ne 'Process' -or $AppliesTo -ne 'Az') { throw 'Only the process Azure login selector may be queried.' }
    if ($fixtureLoginExperience) { [pscustomobject]@{Value=$fixtureLoginExperience} }
}
function Update-AzConfig {
    param($LoginExperienceV2,$Scope,$AppliesTo)
    if ($Scope -ne 'Process' -or $AppliesTo -ne 'Az') { throw 'Azure user configuration must not be changed.' }
    $script:fixtureLoginExperience = [string]$LoginExperienceV2
    $configCalls.Add([pscustomobject]@{Operation='Update';Value=[string]$LoginExperienceV2;Scope=$Scope;AppliesTo=$AppliesTo})
}
function Clear-AzConfig {
    param([switch]$LoginExperienceV2,$Scope,$AppliesTo)
    if (-not $LoginExperienceV2 -or $Scope -ne 'Process' -or $AppliesTo -ne 'Az') { throw 'Only the process login override may be cleared.' }
    $script:fixtureLoginExperience = $null
    $configCalls.Add([pscustomobject]@{Operation='Clear';Value='';Scope=$Scope;AppliesTo=$AppliesTo})
}
function Connect-AzAccount {
    param($Scope,[switch]$SkipContextPopulation,$Tenant,$AccountId,[switch]$UseDeviceAuthentication)
    $loginCalls.Add([pscustomobject]@{Scope=$Scope;SkipContextPopulation=$SkipContextPopulation.IsPresent;Tenant=$Tenant;AccountId=$AccountId;DeviceCode=$UseDeviceAuthentication.IsPresent})
    if ($fixtureLoginExperience -ne 'Off') { throw 'The Azure console subscription selector would call the generic ReadLine prompt.' }
    if ($Scenario -in @('AuthCancelled','RenewalCancelled')) { throw 'Synthetic Azure sign-in cancelled.' }
    $azureState.Context = @{
        Account = @{ Id = $(if ($Scenario -eq 'RenewalWrongAccount') { 'other@example.invalid' } else { 'fixture@example.invalid' }); Type = 'User' }
        Tenant = @{ Id = $(if ($Scenario -eq 'RenewalWrongTenant') { '00000000-0000-0000-0000-000000000003' } else { $fixtureTenant }) }
        Environment = @{ Name = 'AzureCloud' }
    }
    @{ Context = $azureState.Context }
}
function Get-AzAccessToken {
    param($ResourceUrl,$DefaultProfile)
    $azureState.TokenCalls++
    if ($ResourceUrl -ne 'https://api.loganalytics.io' -or $DefaultProfile.Tenant.Id -ne $fixtureTenant) { throw 'Wrong Azure resource/context.' }
    if ($Scenario -like 'Renewal*' -and $loginCalls.Count -eq 0) {
        # Model the SDK exception without requiring Az.Accounts in offline tests.
        if (-not ('Microsoft.Azure.Commands.Common.Authentication.AadAuthenticationCantRenewException' -as [type])) {
            Add-Type 'namespace Microsoft.Azure.Commands.Common.Authentication {
                public class AadAuthenticationCantRenewException : System.Exception {
                    public AadAuthenticationCantRenewException(string message) : base(message) {}
                }
            }'
        }
        throw [Microsoft.Azure.Commands.Common.Authentication.AadAuthenticationCantRenewException]::new('Synthetic Azure session requires interactive renewal.')
    }
    if ($Scenario -eq 'TokenFailure') { throw [Net.Http.HttpRequestException]::new('Synthetic token endpoint unavailable.') }
    if ($Scenario -eq 'TokenTlsFailure') { throw [Security.Authentication.AuthenticationException]::new('Synthetic token TLS handshake failure.') }
    if ($Scenario -in @('PlainToken','ExistingPlainToken')) { return @{Token='offline-token'} }
    @{Token=(ConvertTo-SecureString 'offline-token' -AsPlainText -Force)}
}
if ($Scenario -like 'Graph*') {
    $rows.UCClient[0].DeviceName = ''
    $rows.UCClient[1].DeviceName = '#'
    if ($Scenario -eq 'GraphGlobalIdentity') { $rows.UCClient[0].AzureADDeviceId = ''; $installed.AzureADDeviceId = '' }
    if ($Scenario -eq 'GraphBatching') {
        foreach ($index in 9..20) {
            $client = $rows.UCClient[0].Clone()
            $client.AzureADDeviceId = '00000000-0000-0000-0000-{0:d12}' -f (100 + $index)
            $client.GlobalDeviceId = "fixture-$index"
            $rows.UCClient += $client
        }
        foreach ($client in $rows.UCClient) { $client.DeviceName = '' }
    }
}
function Connect-MgGraph { throw 'WUfB must not change Graph authentication.' }
function Get-MgContext {
    if (-not $ResolveDeviceNames) { throw 'WUfB must not require Graph by default.' }
    if ($Scenario -eq 'GraphDisconnected') { return $null }
    @{
        AuthType = $(if ($Scenario -eq 'GraphAppOnly') { 'AppOnly' } else { 'Delegated' })
        Environment = 'Global'
        TenantId = $(if ($Scenario -eq 'GraphOtherTenant') { '00000000-0000-0000-0000-000000000003' } else { $fixtureTenant })
        Scopes = $(if ($Scenario -eq 'GraphNoConsent') { @('User.Read') } else { @('Device.Read.All') })
    }
}
function Invoke-MgGraphRequest {
    [CmdletBinding()]
    param($Method,$Uri,$OutputType)
    if (-not $ResolveDeviceNames -or $Method -ne 'GET' -or $OutputType -ne 'Hashtable') { throw 'Unexpected Graph request.' }
    $graphRequests.Add($Uri)
    if ($Scenario -eq 'GraphDenied') { throw 'Synthetic Graph HTTP 403.' }
    if ($Scenario -eq 'GraphMalformed') { return @{value='invalid'} }
    if ($Scenario -eq 'GraphNoMatch') { return @{value=@()} }
    $filter = [uri]::UnescapeDataString($Uri)
    if ($filter -notmatch '\$select=deviceId,displayName&\$filter=') { throw 'Graph name queries must select only device IDs and names and filter exact device IDs.' }
    $ids = @([regex]::Matches($filter, "deviceId eq '([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    if ($ids.Count -gt 15) { throw 'Graph device query batch is too large.' }
    $devices = @(foreach ($id in $ids) {
        @{deviceId=$id;displayName=$(if ($Scenario -eq 'GraphSameNames') { 'Shared-Graph-Name' } else { 'Graph-PC-' + ([int]$id.Substring(24) - 100) })}
    })
    if ($Scenario -eq 'GraphDuplicate') { $devices += $devices[0].Clone() }
    if ($Scenario -eq 'GraphUnexpectedId') { $devices[0].deviceId = '00000000-0000-0000-0000-000000000099' }
    if ($Scenario -eq 'GraphBlankName') { $devices[0].displayName = '' }
    if ($Scenario -eq 'GraphPages') {
        if ($Uri -like '*page=2') { return @{value=@($devices[1])} }
        return @{value=@($devices[0]);'@odata.nextLink'="$Uri&page=2"}
    }
    if ($Scenario -eq 'GraphRepeatedPage') { return @{value=$devices;'@odata.nextLink'=$Uri} }
    if ($Scenario -eq 'GraphForeignPage') { return @{value=$devices;'@odata.nextLink'='https://example.invalid/v1.0/devices'} }
    @{value=$devices}
}
function Install-Module { throw 'Modules must never be installed automatically.' }
function Invoke-WebRequest {
    [CmdletBinding()]
    param($Uri,$Method,$Authentication,$Token,$ContentType,$Body,$TimeoutSec)
    if ($Uri -ne "https://api.loganalytics.azure.com/v1/workspaces/$workspace/query" -or $Method -ne 'Post' -or
        $Authentication -ne 'Bearer' -or $Token -isnot [Security.SecureString]) { throw 'Unexpected or insecure query request.' }
    $query = ($Body | ConvertFrom-Json).query
    $queries.Add($query)
    if ($Scenario -in @('AccessDenied','ExistingAccessDenied')) { throw 'Synthetic Azure HTTP 403: query access denied.' }
    if ($Scenario -eq 'Partial') { return @{ Content = '{"error":{"code":"PartialError"},"tables":[]}' } }
    if ($Scenario -eq 'Malformed') { return @{ Content = '{"tables":[{"columns":[],"rows":"invalid"}]}' } }
    if ($Scenario -eq 'InvalidJson') { return @{ Content = 'not-json' } }
    $tableName = @($fields.Keys | Where-Object { $query -match "(^|[ ;])$_ \|" })[0]
    if ($query -like '*getschema') {
        $columns = @(@{name='ColumnName';type='string'},@{name='DataType';type='string'})
        $values = @(foreach ($name in $fields[$tableName]) { ,@($name,'System.String') })
    }
    elseif ($query -like '*SnapshotDay*') {
        $columns = @(@{name='SnapshotDay';type='datetime'},@{name='TotalDevices';type='long'},@{name='EvaluatedDevices';type='long'},@{name='SecurityCompliancePercent';type='real'})
        $values = @(,@($now.AddDays(-1).ToString('o'),8,6,50.0))
    }
    else {
        if ($query -notlike "*AzureADTenantId =~ '$fixtureTenant'*" -or $query -notlike '*take 100001*') { throw 'Query must be tenant-bound and bounded.' }
        if ($tableName -eq 'UCClient' -and $query -notlike '*AzureADDeviceId = AzureADDeviceID*') { throw 'Actual case-sensitive schema column was not projected.' }
        $names = @([regex]::Matches($query, '(\w+) = (?:\w+|'''')') | ForEach-Object { $_.Groups[1].Value })
        $columns = @(foreach ($name in $names) { @{name=$name;type=$(if ($name -match 'Time$') {'datetime'} else {'string'})} })
        $values = @(foreach ($record in $rows[$tableName]) {
            ,@(foreach ($name in $names) {
                $value = $record[$name]
                if ($value -is [datetime]) { $value.ToString('o') } else { $value }
            })
        })
    }
    return @{Content=(@{tables=@(@{columns=$columns;rows=$values})} | ConvertTo-Json -Depth 10 -Compress)}
}
$scriptPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) '..\Intune\Devices\Get-WUfBReport.ps1'
$arguments = @{WorkspaceId=$workspace;DeviceNames=$DeviceNames;UseDeviceAuthentication=$UseDeviceAuthentication.IsPresent;ResolveDeviceNames=$ResolveDeviceNames.IsPresent}
if ($Scenario -eq 'OtherTenant') { $arguments.AzureTenantId = $fixtureTenant }
if ($TargetKB) { $arguments.TargetKB = $TargetKB }
$failure = $null; $output = @(); $warnings = @()
try {
    $runs = if ($Repeat) { 2 } else { 1 }
    for ($iteration = 0; $iteration -lt $runs; $iteration++) {
        if ($Direct) { $output = @(& $scriptPath @arguments -WarningVariable warnings) }
        else {
            $adapter = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Invoke-WorkflowPresentation.ps1'
            $sink = { param($event) $events.Add($event) }
            $check = [Func[bool]]{ $Cancel.IsPresent }.GetNewClosure()
            $output = @(& $adapter -ScriptPath $scriptPath -WorkflowId 'wufb-report' -ScriptArguments $arguments -UiEventSink $sink -CancellationCheck $check -WarningVariable warnings)
        }
    }
}
catch { $failure = $_ }
[pscustomobject]@{ Error = $failure; Output = $output; Events = $events.ToArray(); Queries = $queries.ToArray(); GraphRequests = $graphRequests.ToArray(); Logins = $loginCalls.ToArray(); ConfigCalls = $configCalls.ToArray(); LoginExperience = $fixtureLoginExperience; ContextChecks = $azureState.ContextChecks; Warnings = @($warnings) }
