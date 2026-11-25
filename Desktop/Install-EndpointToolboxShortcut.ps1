[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ShortcutPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Endpoint Toolbox.lnk')
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The desktop shortcut requires Windows.' }
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$launcher = Join-Path $PSScriptRoot 'Start-EndpointToolboxUI.ps1'
$icon = Join-Path $PSScriptRoot 'endpoint-toolbox.ico'
if (-not (Test-Path -LiteralPath $icon -PathType Leaf)) { throw "The application shortcut icon is missing: $icon" }
if ($PSCmdlet.ShouldProcess($ShortcutPath, 'Create Endpoint Toolbox desktop shortcut')) {
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = $pwsh
        $shortcut.Arguments = "-NoProfile -STA -File `"$launcher`""
        $shortcut.WorkingDirectory = $PSScriptRoot
        $shortcut.Description = 'Endpoint Toolbox - Intune, Entra and remote support'
        $shortcut.IconLocation = "$icon,0"
        $shortcut.Save()
    }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    Get-Item -LiteralPath $ShortcutPath
}
