# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

[CmdletBinding()]
param([switch]$ValidateOnly, [switch]$SmokeTest)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path $PSScriptRoot 'ActivityLogging.ps1')
    $engineType = 'EndpointToolbox.DesktopEngine' -as [type]
    $bridgeVersion = if ($engineType) { $engineType.GetField('PresentationVersion') } else { $null }
    if ($engineType -and (-not $bridgeVersion -or $bridgeVersion.GetRawConstantValue() -ne 10)) {
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
        $launchArguments = @('-NoProfile', '-STA', '-File', $PSCommandPath)
        if ($ValidateOnly) { $launchArguments += '-ValidateOnly' }
        if ($SmokeTest) { $launchArguments += '-SmokeTest' }
        & $pwsh @launchArguments
        if ($LASTEXITCODE -ne 0) { throw "Fresh Endpoint Toolbox process exited with code $LASTEXITCODE." }
        return
    }
    Import-Module (Join-Path $PSScriptRoot 'EndpointToolboxUI.psm1') -Force
    Start-EndpointToolboxUI -ValidateOnly:$ValidateOnly -SmokeTest:$SmokeTest
}
catch {
    if (-not $ValidateOnly -and -not $SmokeTest -and (Get-Command Write-EndpointActivityRecord -ErrorAction Ignore)) {
        try {
            Write-EndpointActivityRecord -LogRoot (Join-Path $env:LOCALAPPDATA 'EndpointToolbox\Logs') -Event 'AppLaunchFailed' -State 'Failed' -Message $_.Exception.Message
        }
        catch { Write-Error "Could not record the application error in the activity log: $($_.Exception.Message)" -ErrorAction Continue }
    }
    Write-Error -Message $_ -ErrorAction Continue
    if (-not $ValidateOnly -and -not $SmokeTest -and $IsWindows) {
        Add-Type -AssemblyName PresentationFramework
        [void][Windows.MessageBox]::Show($_.Exception.Message, 'Endpoint Toolbox could not start', 'OK', 'Error')
    }
    exit 1
}
