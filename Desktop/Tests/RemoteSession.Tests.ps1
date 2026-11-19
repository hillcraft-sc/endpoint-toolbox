# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

$desktop = Split-Path $PSScriptRoot -Parent
if (-not ('EndpointToolbox.DesktopEngine' -as [type])) { Add-Type -Path (Join-Path $desktop 'Hosting\DesktopPowerShellHost.cs') }
$fixture = Join-Path $PSScriptRoot 'Fixtures\HostFixture.ps1'

function Receive-RemoteFixture {
    param($Engine, [scriptblock]$Answer)
    $events = [Collections.Generic.List[object]]::new()
    $deadline = [datetime]::Now.AddSeconds(15)
    do {
        $null = $Engine.Poll(); $event = $null
        while ($Engine.Host.Events.TryDequeue([ref]$event)) {
            $events.Add($event)
            if ($event.Kind -eq 'Prompt') { & $Answer $event.Data }
        }
        if ([datetime]::Now -gt $deadline) { $Engine.Cancel(); throw 'Remote fixture timed out.' }
        Start-Sleep -Milliseconds 10
    } while ($Engine.Busy -or -not $Engine.Host.Events.IsEmpty)
    $events.ToArray()
}

Describe 'Secure prompts and remote runspace isolation' {
    It 'shows terminal-style remote output and a temporary animated running indicator through success, failure and cancellation' {
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File (Join-Path $PSScriptRoot 'Fixtures\RemoteOutputFixture.ps1') 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Remote output fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native terminal-style remote output and running indicator passed'
    }
    It 'transfers a credential securely without emitting its password' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($fixture, @{Mode='Credential'}, $true)
            $events = @(Receive-RemoteFixture $engine {
                param($request)
                $secret = ConvertTo-SecureString 'synthetic-only' -AsPlainText -Force
                $request.Complete([pscredential]::new('fixture', $secret))
            })
            @($events | Where-Object { $_.Kind -eq 'Output' -and [string]$_.Data -eq 'CredentialLength: 14' }).Count | Should Be 1
            @($events | Where-Object { [string]$_.Data -match 'synthetic-only' }).Count | Should Be 0
        }
        finally { $engine.Dispose() }
    }
    It 'supports secure-string input and cancellation without ordinary text secrets' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        try {
            $engine.RunFile($fixture, @{Mode='Secure'}, $true)
            $events = @(Receive-RemoteFixture $engine { param($request) $request.Complete((ConvertTo-SecureString 'fixture' -AsPlainText -Force)) })
            @($events | Where-Object { $_.Kind -eq 'Output' -and [string]$_.Data -eq 'SecureLength: 7' }).Count | Should Be 1
            $engine.RunFile($fixture, @{Mode='Credential'}, $true)
            $null = Receive-RemoteFixture $engine { param($request) $request.Cancel() }
            $engine.LastState | Should Be 'Cancelled'
        }
        finally { $engine.Dispose() }
    }
    It 'routes commands only to the pushed session runspace' {
        $engine = [EndpointToolbox.DesktopEngine]::new()
        $syntheticRemote = [runspacefactory]::CreateRunspace()
        $syntheticRemote.Open()
        try {
            $syntheticRemote.SessionStateProxy.SetVariable('EndpointFixtureMarker', 'synthetic-remote')
            $engine.Host.PushRunspace($syntheticRemote)
            $engine.Connected | Should Be $true
            $engine.RunCommand('$EndpointFixtureMarker')
            $events = @(Receive-RemoteFixture $engine)
            @($events | Where-Object { $_.Kind -eq 'Output' -and [string]$_.Data -eq 'synthetic-remote' }).Count | Should Be 1
            $engine.Host.PopRunspace()
            $engine.Connected | Should Be $false
            $rejected = $false
            try { $engine.RunCommand("'not local'") } catch { $rejected = $true }
            $rejected | Should Be $true
        }
        finally { $engine.Dispose(); $syntheticRemote.Dispose() }
    }
    It 'does not reopen cancelled prompt requests' {
        $request = [EndpointToolbox.InputRequest]::new('Text','Fixture','Fixture',$null)
        try {
            $request.Cancel()
            $request.IsCompleted | Should Be $true
            $request.Complete('must not become approval')
            $request.Cancelled | Should Be $true
        }
        finally { $request.Dispose() }
    }
}
