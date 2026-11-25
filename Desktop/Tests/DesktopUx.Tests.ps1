$desktop = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force

Describe 'Visual summary PNG export' {
    It 'exports the complete themed summary safely in the background without new Graph requests' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\ReportVisualExportFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native chart export fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native full-summary PNG, theme, labels, save defaults, cancellation, failure safety and background export passed'
    }
}

Describe 'Report folder settings' {
    It 'persists report settings and deletes only confirmed CSV reports safely' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\UsabilityFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture -ReportSettingsOnly 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native report folder settings fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native report folder persistence, validation, defaults, overrides and export dialogs passed'
        ($output -join "`n") | Should Match 'Native report deletion confirmation, cancellation, scope, active-run blocking and partial errors passed'
    }
}

Describe 'Expander header focus' {
    It 'removes persistent borders while preserving keyboard focus cues and toggling' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\UsabilityFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture -ExpanderFocusOnly 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native expander focus fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native expander toggling without persistent borders and preserved keyboard focus cues passed'
    }
}

Describe 'Workflow menu navigation' {
    It 'offers one all-types group membership task with optional nested expansion' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\UsabilityFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture -GroupMembersOnly 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native membership form fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native unified group membership, optional expansion, accessible inputs and supported layouts passed'
    }
    It 'starts with collapsed menus and places user and group tasks correctly' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\UsabilityFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture -NavigationOnly 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native workflow menu fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native collapsed startup menus passed'
        ($output -join "`n") | Should Match 'Native workflow menu placement, expansion, heading and search passed'
    }
}

Describe 'Task-oriented desktop UX' {
    It 'closes cleanly before filtering and cancels an active report filter' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\ShutdownFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native shutdown fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native shutdown without a report and with an active filter passed'
    }
    It 'renders and binds accessible device and app investigation search controls' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\DeviceInvestigationFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Device investigation form fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Device investigation form and accessible search passed'
        ($output -join "`n") | Should Match 'App investigation form and accessible searches passed'
        ($output -join "`n") | Should Match 'Win32 triage investigation shortcut passed'
    }
    It 'preserves drafts, shows inline validation and protects edited remote commands' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\UsabilityFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native usability fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Task drafts, inline validation and remote command confirmation passed'
        ($output -join "`n") | Should Match 'Native report cell selection and copy passed'
    }
    It 'opens the exact category rows and displays the selected device sign-in dates' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\ReportReviewFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native report review fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native chart drill-through and sign-in calendar passed'
    }
    It 'filters large reports without blocking the dispatcher or applying stale searches' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\ReportFilterFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native report filter fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Large report filtering remained responsive'
    }
    It 'switches and persists themes across forms, grids, dropdowns and settings without losing data' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\ThemeFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native theme fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native themes, generated forms, dropdowns, settings, persistence and errors passed'
        ($output -join "`n") | Should Match 'Themed report bars, counts, proportions and reset passed'
        ($output -join "`n") | Should Match 'Settings appearance and keyboard shortcuts passed'
    }
    It 'opens dedicated settings history and logs without changing report state' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\DesktopUiFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture -SettingsOnly 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Native settings fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Native dedicated settings history, logs and preserved report state passed'
    }
    It 'uses saved Cloud Update group names only for optional membership reporting' {
        $fixture = Join-Path $PSScriptRoot 'Fixtures\CloudUpdateFormFixture.ps1'
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -File $fixture 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Cloud Update form fixture failed: $($output -join "`n")" }
        ($output -join "`n") | Should Match 'Cloud Update saved group settings and optional switch behavior passed'
    }
    It 'uses compact consistent inputs, usable output panes and smaller secure dialogs at both window sizes' {
        $fixture=Join-Path $PSScriptRoot 'Fixtures\LayoutFixture.ps1'
        foreach ($theme in @('Light','Dark','CatppuccinMocha','GruvboxDark')) {
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
        ($output -join "`n") | Should Match 'Native Cloud Update group list form passed'
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
    It 'stores and validates an optional remote DNS suffix per user' {
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
    It 'uses the optional DNS suffix for UNC only when the device name is not already qualified' {
        $scriptPath = Join-Path (Split-Path $desktop -Parent) 'PSRemote-Endpoint.ps1'
        $global:EndpointTestUncRoots = [Collections.Generic.List[string]]::new()
        $global:EndpointTestCredentialMessages = [Collections.Generic.List[string]]::new()
        function Test-Connection { param($ComputerName, $Count, [switch]$Quiet) $true }
        function Test-WSMan { [CmdletBinding()] param($ComputerName) }
        function Get-Credential {
            param($Message, $Title)
            $global:EndpointTestCredentialMessages.Add($Message)
            [pscredential]::new('fixture', (ConvertTo-SecureString 'fixture' -AsPlainText -Force))
        }
        function New-PSDrive {
            param($Name, $PSProvider, $Root, $Credential)
            $global:EndpointTestUncRoots.Add($Root)
            [pscustomobject]@{ Root = $Root }
        }
        function Start-Process { param($FilePath, $ArgumentList) }
        function New-PSSession { param($ComputerName, [switch]$EnableNetworkAccess, $Authentication, $Credential) [pscustomobject]@{} }
        function Enter-PSSession { param($Session) }
        try {
            & $scriptPath -Device 'Fixture-PC' -UNC
            & $scriptPath -Device 'Fixture-PC' -UNC -DnsSuffix 'corp.example.com'
            & $scriptPath -Device 'Fixture-PC.existing.example.com' -UNC -DnsSuffix 'other.example.com'
            ($global:EndpointTestUncRoots -join '|') | Should Be '\\Fixture-PC\C$|\\Fixture-PC.corp.example.com\C$|\\Fixture-PC.existing.example.com\C$'
            ($global:EndpointTestCredentialMessages -join '|') | Should Be (('Enter device administrator credentials', 'Enter device administrator credentials', 'Enter device administrator credentials') -join '|')
            $rejected = $false
            try { & $scriptPath -Device 'Fixture-PC' -DnsSuffix 'corp.example.com\C$' } catch { $rejected = $true }
            $rejected | Should Be $true
        }
        finally {
            $global:EndpointTestUncRoots = $null
            $global:EndpointTestCredentialMessages = $null
            foreach ($name in @('Test-Connection','Test-WSMan','Get-Credential','New-PSDrive','Start-Process','New-PSSession','Enter-PSSession')) {
                Remove-Item "Function:\$name" -ErrorAction Ignore
            }
        }
    }
}
