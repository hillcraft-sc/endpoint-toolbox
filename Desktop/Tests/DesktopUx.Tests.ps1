# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

$desktop = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force

Describe 'Task-oriented desktop UX' {
    It 'switches and persists dark mode across forms, grids, dropdowns and settings without losing data' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\ThemeFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native theme fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native dark/light themes, generated forms, dropdowns, settings, persistence and errors passed'
    }
    It 'opens dedicated settings history and logs without changing report state' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\DesktopUiFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture -SettingsOnly 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native settings fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native dedicated settings history, logs and preserved report state passed'
    }
    It 'uses compact consistent inputs, usable output panes and smaller secure dialogs at both window sizes' {
        $fixture=Join-Path $PSScriptRoot 'Fixtures\LayoutFixture.ps1'
        foreach ($theme in @('Light','Dark')) {
            $output=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture -Theme $theme 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Native $theme layout fixture failed: $($output -join "`n")" }
            ($output -join "`n") | Should Match 'Compact forms, usable output panes and credential dialogs passed at both window sizes'
        }
    }
    It 'does not reenter event processing while a modal script prompt is open' {
        & (Get-Module EndpointToolboxUI) {
            $previous = Get-Variable -Name Ui -Scope Script -ValueOnly -ErrorAction Ignore
            try {
                $script:Ui = @{Active=[pscustomobject]@{}; ReceivingEvents=$true; ActivityBuffer=[Text.StringBuilder]::new('Pending output')}
                Receive-EndpointEvents
                $script:Ui.ActivityBuffer.ToString() | Should Be 'Pending output'
                $script:Ui.ReceivingEvents | Should Be $true
            }
            finally { $script:Ui=$previous }
        }
    }
    It 'renders the grouped task pages and exercises native single/multiple/skip/cancel app dialogs' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\DesktopUiFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native desktop UX fixture failed: $($output -join "`n")" }
        foreach ($mode in @('Single','Multiple','Skip','Cancel','Script')) {
            ($output -join "`n") | Should Match "Native $mode selection dialog passed"
        }
        ($output -join "`n") | Should Match 'Long-running dispatcher and Cancel passed'
        ($output -join "`n") | Should Match 'Cancellation backlog and next run passed'
        ($output -join "`n") | Should Match 'Large report passed: 100000 rows, 20 columns'
        ($output -join "`n") | Should Match 'Native activity logging, bounded diagnostics and app summary passed'
        ($output -join "`n") | Should Match 'Native saved remote command selection and editable text passed'
        ($output -join "`n") | Should Match 'Native Home navigation and preserved task inputs passed'
        ($output -join "`n") | Should Match 'Native pre-run script loading, filtering, selection and type reset passed'
        ($output -join "`n") | Should Match 'Native pre-run expedited policy picker passed'
        ($output -join "`n") | Should Match 'Native Home connection events and preserved report state passed'
        ($output -join "`n") | Should Match 'Native dedicated settings history, logs and preserved report state passed'
    }
    It 'translates app selections into original indices without changing selection semantics' {
        & (Get-Module EndpointToolboxUI) {
            $rows = @(
                [pscustomobject]@{ Index=0; Selected=$false }
                [pscustomobject]@{ Index=1; Selected=$true }
                [pscustomobject]@{ Index=2; Selected=$true }
            )
            (Get-EndpointAppChoiceAnswer $rows Multiple) | Should Be '1,2'
            (Get-EndpointAppChoiceAnswer $rows Multiple -Skip) | Should Be ''
            $rejected = $false
            try { $null = Get-EndpointAppChoiceAnswer $rows Single } catch { $rejected = $true }
            $rejected | Should Be $true
            $rows[2].Selected = $false
            (Get-EndpointAppChoiceAnswer $rows Single) | Should Be '1'
            $rows[1].Selected = $false
            $rejected = $false
            try { $null = Get-EndpointAppChoiceAnswer $rows Multiple } catch { $rejected = $true }
            $rejected | Should Be $true
        }
    }
    It 'uses plain-English labels while keeping original parameter names available as metadata' {
        & (Get-Module EndpointToolboxUI) {
            (Get-EndpointFieldPresentation 'AppName').Label | Should Be 'App name or wildcard'
            (Get-EndpointFieldPresentation 'DeviceListPath').Label | Should Be 'Device list file'
            (Get-EndpointFieldPresentation 'Justification').Hint | Should Match 'original script prompt'
        }
    }
    It 'rejects an empty assign-user mode instead of silently running a read-only report' {
        $workflow = Get-EndpointCatalog | Where-Object Id -eq 'primary-users'
        $rejected = $false
        try { $null = Get-EndpointArguments $workflow @{Devices='Fixture-PC'} @('RemovePrimaryUser','GroupName','ManagedDeviceId','DeviceListPath') } catch { $rejected=$true }
        $rejected | Should Be $true
    }
    It 'keeps the last 10 successfully connected remote devices, most recent first and without duplicates' {
        & (Get-Module EndpointToolboxUI) {
            $path = Join-Path $env:TEMP "EndpointToolbox-recent-$([guid]::NewGuid())\recent-devices.json"
            try {
                @(Get-EndpointRecentDevices $path).Count | Should Be 0
                foreach ($number in 1..12) { $null = Add-EndpointRecentDevice $path "Fixture-PC$number" }
                $devices = @(Get-EndpointRecentDevices $path)
                $devices.Count | Should Be 10
                $devices[0] | Should Be 'Fixture-PC12'
                $devices[9] | Should Be 'Fixture-PC3'
                $null = Add-EndpointRecentDevice $path ' fixture-pc5 '
                $devices = @(Get-EndpointRecentDevices $path)
                $devices[0] | Should Be 'fixture-pc5'
                $devices.Count | Should Be 10
                @($devices | Where-Object { $_ -eq 'Fixture-PC5' }).Count | Should Be 1
                $null = Add-EndpointRecentDevice $path 'bad name; Remove-Item'
                (Get-EndpointRecentDevices $path)[0] | Should Be 'fixture-pc5'
                '{"SchemaVersion":1,"Devices":["Fixture-PC1","bad name",42]}' | Set-Content -LiteralPath $path
                @(Get-EndpointRecentDevices $path) -join ',' | Should Be 'Fixture-PC1'
                'not json' | Set-Content -LiteralPath $path
                $rejected = $false
                try { $null = Get-EndpointRecentDevices $path } catch { $rejected = $true }
                $rejected | Should Be $true
                $null = Add-EndpointRecentDevice $path 'Fixture-PC99'
                @(Get-EndpointRecentDevices $path) -join ',' | Should Be 'Fixture-PC99'
            }
            finally { Remove-Item -LiteralPath (Split-Path $path -Parent) -Recurse -Force -ErrorAction Ignore }
        }
    }
    It 'stores an optional validated DNS suffix for administrative shares' {
        & (Get-Module EndpointToolboxUI) {
            $path = Join-Path $env:TEMP "EndpointToolbox-remote-$([guid]::NewGuid())\remote-settings.json"
            try {
                (Get-EndpointRemoteSettings $path).DnsSuffix | Should Be ''
                Save-EndpointRemoteSettings $path ' .corp.example.com. ' | Should Be 'corp.example.com'
                (Get-EndpointRemoteSettings $path).DnsSuffix | Should Be 'corp.example.com'
                Save-EndpointRemoteSettings $path '' | Should Be ''
                (Get-EndpointRemoteSettings $path).DnsSuffix | Should Be ''
                foreach ($bad in @('corp example.com', 'corp.example.com\C$', 'a..b', '-bad.com', 'x;y', ('a' * 254))) {
                    $rejected = $false
                    try { $null = Save-EndpointRemoteSettings $path $bad } catch { $rejected = $true }
                    $rejected | Should Be $true
                }
                (Get-EndpointRemoteSettings $path).DnsSuffix | Should Be ''
                '{"DnsSuffix":"bad\\suffix"}' | Set-Content -LiteralPath $path
                $rejected = $false
                try { $null = Get-EndpointRemoteSettings $path } catch { $rejected = $true }
                $rejected | Should Be $true
                'not json' | Set-Content -LiteralPath $path
                $rejected = $false
                try { $null = Get-EndpointRemoteSettings $path } catch { $rejected = $true }
                $rejected | Should Be $true
            }
            finally { Remove-Item -LiteralPath (Split-Path $path -Parent) -Recurse -Force -ErrorAction Ignore }
        }
    }
    It 'keeps the DNS suffix out of the remote form but accepted by the remote script' {
        $workflow = Get-EndpointCatalog | Where-Object Id -eq 'remote-endpoint'
        @($workflow.Fields.Name) -contains 'DnsSuffix' | Should Be $false
        $ast = [Management.Automation.Language.Parser]::ParseFile($workflow.FullPath, [ref]$null, [ref]$null)
        @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath) -contains 'DnsSuffix' | Should Be $true
    }
}
