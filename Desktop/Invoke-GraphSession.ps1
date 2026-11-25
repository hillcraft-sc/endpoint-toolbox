[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Connect','Check','Disconnect','Run','CloudPcHistory')][string]$Action,
    [string]$TenantId = '',
    [string]$RequiredTenant = '',
    [string]$ScriptPath,
    [string]$WorkflowId,
    [hashtable]$ScriptArguments = @{},
    [string]$ActivityLogPath = '',
    [string]$RunId = '',
    [guid]$CloudPcId,
    [string]$CloudPcName = '',
    [string]$InventoryTenant = '',
    [Func[bool]]$CancellationCheck,
    [scriptblock]$UiEventSink,
    [ValidateSet('New','More','All')][string]$SignInAction = 'New',
    [string]$SignInContinuationId = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GraphSession.ps1')
$session = $null
try {
    if ($Action -eq 'Disconnect') {
        if (Get-MgContext -ErrorAction Stop) { Disconnect-MgGraph -ErrorAction Stop | Out-Null }
        $session = [pscustomobject]@{ State='Disconnected'; Account=''; TenantId=''; CheckedUtc=''; Roles=@(); Scopes=@(); Message='Disconnected from the application Graph session.' }
    }
    else {
        if ($Action -eq 'Connect') {
            $connect = @{ Scopes = @('https://graph.microsoft.com/.default'); ContextScope = 'Process'; NoWelcome = $true; ErrorAction = 'Stop' }
            if ($TenantId) { $connect.TenantId = $TenantId }
            if (Get-MgContext -ErrorAction Stop) { Disconnect-MgGraph -ErrorAction Stop | Out-Null }
            Connect-MgGraph @connect | Out-Null
        }
        $session = Get-EndpointGraphSession
    }
    if ($UiEventSink) { & $UiEventSink ([pscustomobject]@{Type='GraphSession';Name='Graph session';Data=$session}) | Out-Null }
    if ($Action -in @('Run','CloudPcHistory')) {
        if ($ScriptArguments['ForceInteractive']) { throw 'Use Home to reconnect before running instead of ForceInteractive, so the account and roles can be checked before the script starts.' }
        $policyId = if ($Action -eq 'CloudPcHistory') { 'cloudpc-inventory' } else { $WorkflowId }
        Assert-EndpointGraphAccess $session (Get-EndpointGraphPolicy $policyId $ScriptArguments) $RequiredTenant
        if ($Action -eq 'CloudPcHistory' -and (-not $InventoryTenant -or $session.TenantId -ne $InventoryTenant)) {
            throw 'The Graph tenant no longer matches the Cloud PC inventory. Run All Cloud PCs again.'
        }
        if ($UiEventSink) { & $UiEventSink ([pscustomobject]@{Type='Stage';Name='Graph access checked';Data='Live connection, scopes and active role checks passed. Starting the original script; service authorization still applies.'}) | Out-Null }
    }
}
catch {
    if ($UiEventSink) {
        & $UiEventSink ([pscustomobject]@{Type='GraphSession';Name='Graph session';Data=[pscustomobject]@{
            State='Unverified'; Account=$(if ($session) { $session.Account } else { '' })
            TenantId=$(if ($session) { $session.TenantId } else { '' }); CheckedUtc=$(if ($session) { $session.CheckedUtc } else { '' })
            Roles=@(); Scopes=$(if ($session) { $session.Scopes } else { @() })
            Message="Access check failed; no task was started. $($_.Exception.Message)"
        }}) | Out-Null
    }
    throw
}
if ($Action -eq 'Run') {
    if ($CancellationCheck -and $CancellationCheck.Invoke()) { throw 'Cancelled before the business script started.' }
    & (Join-Path $PSScriptRoot 'Invoke-WorkflowPresentation.ps1') -ScriptPath $ScriptPath -WorkflowId $WorkflowId -ScriptArguments $ScriptArguments -ActivityLogPath $ActivityLogPath -RunId $RunId -CancellationCheck $CancellationCheck -UiEventSink $UiEventSink -SignInAction $SignInAction -SignInContinuationId $SignInContinuationId
}
elseif ($Action -eq 'CloudPcHistory') {
    if ($CancellationCheck -and $CancellationCheck.Invoke()) { throw 'Cancelled before Cloud PC history was requested.' }
    & (Join-Path $PSScriptRoot 'Get-CloudPcConnectionHistory.ps1') -CloudPcId $CloudPcId -CloudPcName $CloudPcName -CancellationCheck $CancellationCheck -UiEventSink $UiEventSink
}
