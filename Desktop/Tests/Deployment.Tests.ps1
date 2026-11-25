$desktop = Split-Path $PSScriptRoot -Parent
Describe 'Desktop shortcut deployment' {
    It 'relaunches validation in a fresh process when an older bridge is already loaded' {
        $launcher = Join-Path $desktop 'Start-EndpointToolboxUI.ps1'
        $script = @'
Add-Type 'namespace EndpointToolbox { public class DesktopEngine { public void RunFile(string path, System.Collections.Hashtable arguments, bool withSink) {} } }'
& '__LAUNCHER__' -ValidateOnly
if ($LASTEXITCODE -ne 0) { exit 1 }
'@
        $script = $script.Replace('__LAUNCHER__', $launcher.Replace("'", "''"))
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -STA -EncodedCommand $encoded
        $LASTEXITCODE | Should Be 0
        ($output -join "`n") | Should Match 'intune-sync'
    }
    It 'creates a per-user launch shortcut without policy bypass or elevation' {
        $path = Join-Path $env:TEMP "EndpointToolbox-shortcut-$([guid]::NewGuid()).lnk"
        $shell = $null
        try {
            $null = & (Join-Path $desktop 'Install-EndpointToolboxShortcut.ps1') -ShortcutPath $path
            (Test-Path -LiteralPath $path) | Should Be $true
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($path)
            $shortcut.TargetPath | Should Match 'pwsh.exe$'
            $shortcut.Arguments | Should Match '\-STA'
            $shortcut.Arguments | Should Not Match '\-WindowStyle\s+Hidden'
            $shortcut.WindowStyle | Should Be 1
            $shortcut.Arguments | Should Not Match 'ExecutionPolicy|RunAs'
            $shortcut.Arguments | Should Match 'Start-EndpointToolboxUI.ps1'
            $shortcut.Description | Should Be 'Endpoint Toolbox - Intune, Entra and remote support'
            ($shortcut.IconLocation -split ',')[0] | Should Be (Join-Path $desktop 'endpoint-toolbox.ico')
        }
        finally {
            if ($shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction Stop }
        }
    }
    It 'sets a distinct Windows taskbar application identity for the running window' {
        Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force
        & (Get-Module EndpointToolboxUI) {
            Set-EndpointTaskbarIdentity
            [EndpointToolbox.DesktopTaskbarIdentity]::Get() | Should Be 'EndpointToolbox'
        }
    }
}
