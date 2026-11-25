[CmdletBinding()]
param([string]$OutputPath, [string]$Mode = 'Success', [Func[bool]]$CancellationCheck, [scriptblock]$UiEventSink)
$fixtureApps = @(
    foreach ($number in 1..3) {
        @{id="00000000-0000-0000-0000-00000000000$number";displayName="Retired - Fixture $number";displayVersion='1.0';'@odata.type'='#microsoft.graph.win32LobApp'}
    }
)
function Get-MgContext { @{Account='fixture@example.invalid'} }
function Invoke-MgGraphRequest {
    param($Method,$Uri,$Headers)
    if ($Method -eq 'GET') {
        if ($Uri -like '*/assignments') { return @{value=@()} }
        return @{value=$fixtureApps}
    }
    if ($Method -eq 'DELETE') {
        if ($Mode -eq 'Cancel' -and $Uri -like '*/00000000-0000-0000-0000-000000000002') {
            & $UiEventSink ([pscustomobject]@{Type='Stage';Name='In-flight deletion';Data='Synthetic request waiting for cancellation.'}) | Out-Null
            Start-Sleep -Seconds 30
        }
        return
    }
    throw "Unexpected synthetic Graph request: $Method $Uri"
}
$desktop = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
& (Join-Path $desktop 'Invoke-WorkflowPresentation.ps1') -ScriptPath (Join-Path (Split-Path $desktop -Parent) 'Intune\Apps\Remove-Win32App.ps1') -WorkflowId 'delete-win32-apps' -ScriptArguments @{
    AppId=@($fixtureApps.id); Justification='Synthetic fixture'; Confirm=($Mode -eq 'Decline'); OutputPath=$OutputPath
} -UiEventSink $UiEventSink -ActivityLogPath $OutputPath -RunId 'fixture-removal' -CancellationCheck $CancellationCheck
