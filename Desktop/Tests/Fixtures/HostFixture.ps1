[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Output', 'Prompt', 'Secure', 'Credential', 'Confirm', 'Wait', 'Exit', 'Rows', 'Choices', 'DefineCommand', 'ResponsiveWorkload', 'ReportOutput')]
    [string]$Mode = 'Output',
    [int]$Count = 3,
    [string]$Literal,
    [scriptblock]$UiEventSink
)
switch ($Mode) {
    'ReportOutput' {
        Write-Host 'Generating report fixture'
        Write-Warning 'Report fixture warning'
        $results = @(for ($i=0; $i -lt $Count; $i++) {
            [pscustomobject]@{
                DeviceName="Report-device-$i"; Status='Read'; RawVersion='123.456'; ErrorCode='0'
                DeviceId="fixture-$i"; UserPrincipalName='fixture@example.invalid'; ApplicationId='fixture-app'
                AppDisplayName='Fixture Report'; AppDisplayVersion='123.456'; InstallState='1'
                InstallStateFriendly='Installed'; LastModifiedDateTime='2026-11-04T00:00:00Z'; Platform='Windows'
                OSVersion='10.0'; UserName='Fixture User'; Publisher='Fixture'; AppVersion='123.456'
                Architecture='x64'; ErrorDescription=''; ManagementAgent='Intune'
            }
        })
        $results
        if ($Count -le 10000) { $results | Format-Table }
        'Report generation finished'
    }
    'ResponsiveWorkload' {
        for ($i = 0; $i -lt 2000; $i++) { Write-Host "Long-running fixture output $i" }
        Add-Type -TypeDefinition @'
public sealed class EndpointSlowFormattingFixture
{
    public string Name => "Slow formatting fixture";
    public string Detail
    {
        get { System.Threading.Thread.Sleep(2000); return "Formatting completed"; }
    }
}
'@
        [EndpointSlowFormattingFixture]::new()
        for ($i = 0; $i -lt 10; $i++) {
            [pscustomobject]@{ Name = "Following row $i"; Detail = 'Formatting completed' }
            Start-Sleep -Milliseconds 100
        }
        Start-Sleep -Seconds 60
    }
    'DefineCommand' { function global:Test-EndpointWorkerCommand { throw 'Discovery must not execute this command.' } }
    'Choices' {
        & $UiEventSink ([pscustomobject]@{
            Type = 'ScriptChoices'; Name = 'Intune scripts'
            Data = [pscustomobject]@{ ScriptType = 'All'; Choices = @([pscustomobject]@{Id='00000000-0000-0000-0000-000000000001';DisplayName='Fixture remediation'}) }
        })
    }
    'Output' {
        Write-Host 'host message'
        Write-Warning 'fixture warning'
        Write-Output ([pscustomobject]@{ Name = 'fixture'; Literal = $Literal })
        if ($UiEventSink) { & $UiEventSink ([pscustomobject]@{ Type = 'Rows'; Name = 'Fixture'; Data = @([pscustomobject]@{ Name = 'structured'; Status = 'Read' }) }) }
    }
    'Prompt' { $answer = Read-Host 'Fixture input'; "Answer: $answer" }
    'Secure' { $answer = Read-Host 'Fixture secret' -AsSecureString; "SecureLength: $($answer.Length)" }
    'Credential' { $credential = Get-Credential -Message 'Synthetic credentials only' -Title 'Fixture'; "CredentialLength: $($credential.Password.Length)" }
    'Confirm' { if ($PSCmdlet.ShouldContinue('Fixture approval?', 'Fixture confirmation')) { 'Approved' } else { 'Declined' } }
    'Wait' { Start-Sleep -Seconds 30 }
    'Exit' { exit 1 }
    'Rows' {
        $rows = @(for ($i = 0; $i -lt $Count; $i++) { [pscustomobject]@{ DeviceName = "Fixture-$i"; Index = $i; Status = 'Read' } })
        & $UiEventSink ([pscustomobject]@{ Type = 'Rows'; Name = 'Large fixture'; Data = $rows })
    }
}
