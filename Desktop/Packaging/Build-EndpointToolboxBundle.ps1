<#
.SYNOPSIS
Builds a distributable Endpoint Toolbox ZIP.

.DESCRIPTION
Run this script from a complete repository on Windows with PowerShell 7.6 or
newer and the Windows .NET Framework C# compiler (csc.exe). The script stages
the app and catalog workflows, validates the deployment settings and launcher,
and creates EndpointToolbox-<Version>.zip.

The ZIP does not include PowerShell or workflow modules. Client computers must
extract the entire ZIP and have PowerShell 7.6 or newer installed at
Program Files\PowerShell\7\pwsh.exe, along with modules needed by their workflows.
The ZIP is not an installer. Script signing and application-control policies
still apply.

.PARAMETER OutputDirectory
Directory for the ZIP. It is created if necessary. The build fails if a ZIP
with the same version already exists there.

.PARAMETER Version
Version used in the ZIP name and launcher file version. Defaults to 0.1.0.

.PARAMETER ConfigurationPath
Optional path to an administrator-prepopulated deployment defaults JSON file.
It is validated and included as Desktop\EndpointToolbox.defaults.json. If
omitted, the repository template is used.

.PARAMETER SigningCertificate
Optional code-signing certificate object used to sign the staged PowerShell
scripts, modules, data files, and launcher executable. The build verifies each
signature. If omitted, no signatures are added. Signatures are not timestamped.

.EXAMPLE
.\Desktop\Packaging\Build-EndpointToolboxBundle.ps1 -OutputDirectory C:\Builds -Version 1.0.0

Builds C:\Builds\EndpointToolbox-1.0.0.zip using the repository defaults.
Run this and the following examples from the repository root.

.EXAMPLE
.\Desktop\Packaging\Build-EndpointToolboxBundle.ps1 -OutputDirectory C:\Builds -Version 1.0.0 -ConfigurationPath C:\Deployment\EndpointToolbox.defaults.json

Builds a ZIP with administrator-prepopulated deployment defaults.

.EXAMPLE
$certificate = Get-Item Cert:\CurrentUser\My\<certificate-thumbprint>
.\Desktop\Packaging\Build-EndpointToolboxBundle.ps1 -OutputDirectory C:\Builds -Version 1.0.0 -SigningCertificate $certificate

Builds a ZIP with signed PowerShell files and launcher. Replace the placeholder with the
thumbprint of an approved code-signing certificate with an accessible private key.

.NOTES
For full help, run:
Get-Help .\Desktop\Packaging\Build-EndpointToolboxBundle.ps1 -Full
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OutputDirectory,

    [version]$Version = '0.1.0',

    [string]$ConfigurationPath,

    [System.Security.Cryptography.X509Certificates.X509Certificate2]$SigningCertificate
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.6') {
    throw 'Build the bundle on Windows with PowerShell 7.6 or newer.'
}

$desktop = Split-Path $PSScriptRoot -Parent
$repo = Split-Path $desktop -Parent
$compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw 'The Windows .NET Framework C# compiler (csc.exe) is required on the build machine.'
}

function Set-BundleSignature {
    param([string]$Path)

    $null = Set-AuthenticodeSignature -LiteralPath $Path -Certificate $SigningCertificate -ErrorAction Stop
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $SigningCertificate.Thumbprint) {
        throw "Signature verification failed for ${Path}: $($signature.StatusMessage)"
    }
}

$output = (New-Item -ItemType Directory -Path $OutputDirectory -Force).FullName
$archive = Join-Path $output "EndpointToolbox-$Version.zip"
if (Test-Path -LiteralPath $archive) { throw "Bundle already exists: $archive" }
$stage = Join-Path ([IO.Path]::GetTempPath()) "EndpointToolbox-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $stage -ItemType Directory
try {
    $catalog = Import-PowerShellDataFile (Join-Path $desktop 'WorkflowCatalog.psd1')
    $files = @(
        'Desktop\ActivityLogging.ps1', 'Desktop\EndpointToolboxUI.psm1', 'Desktop\GraphSession.ps1', 'Desktop\Get-CloudPcConnectionHistory.ps1',
        'Desktop\Hosting\DesktopPowerShellHost.cs', 'Desktop\Invoke-GraphSession.ps1', 'Desktop\Export-ReportVisual.ps1',
        'Desktop\Invoke-WorkflowPresentation.ps1', 'Desktop\MainWindow.xaml', 'Desktop\RemoteCommands.json',
        'Desktop\ReportVisuals.ps1', 'Desktop\Start-EndpointToolboxUI.ps1', 'Desktop\WorkflowCatalog.psd1',
        'Desktop\endpoint-toolbox-nobkg.png', 'Desktop\endpoint-toolbox.ico',
        'Desktop\Settings.ps1', 'Desktop\EndpointToolbox.defaults.json',
        'Intune\Assignments\Win32ErrorCodes.psm1'
    ) + @($catalog.Workflows.Path)

    foreach ($path in ($files | Sort-Object -Unique)) {
        $source = Join-Path $repo $path
        $target = Join-Path $stage $path
        $null = New-Item -Path (Split-Path $target -Parent) -ItemType Directory -Force
        Copy-Item -LiteralPath $source -Destination $target
    }

    if ($ConfigurationPath) {
        Copy-Item -LiteralPath $ConfigurationPath -Destination (Join-Path $stage 'Desktop\EndpointToolbox.defaults.json')
    }
    if ($SigningCertificate) {
        foreach ($file in (Get-ChildItem -LiteralPath $stage -Recurse -File |
                Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })) {
            Set-BundleSignature -Path $file.FullName
        }
    }
    $configurationScript = @'
$ErrorActionPreference = 'Stop'
Import-Module '__MODULE__'
& (Get-Module EndpointToolboxUI) { param($Path) $null = Read-EndpointSettingsDocument $Path } '__DEFAULTS__'
'@
    $configurationScript = $configurationScript.Replace('__MODULE__', (Join-Path $stage 'Desktop\EndpointToolboxUI.psm1').Replace("'", "''")).
        Replace('__DEFAULTS__', (Join-Path $stage 'Desktop\EndpointToolbox.defaults.json').Replace("'", "''"))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($configurationScript))
    $configurationCheck = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -EncodedCommand $encoded 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Deployment settings validation failed: $($configurationCheck -join "`n")" }

    $exe = Join-Path $stage 'EndpointToolbox.exe'
    $versionSource = Join-Path $stage 'BundleVersion.cs'
    $numericVersion = '{0}.{1}.{2}.{3}' -f $Version.Major, $Version.Minor, [Math]::Max(0, $Version.Build), [Math]::Max(0, $Version.Revision)
    '[assembly: System.Reflection.AssemblyFileVersion("{0}")]' -f $numericVersion |
        Set-Content -LiteralPath $versionSource -Encoding ascii
    $icon = Join-Path $desktop 'endpoint-toolbox.ico'
    $launcher = Join-Path $PSScriptRoot 'EndpointToolboxLauncher.cs'
    & $compiler /nologo /target:winexe /platform:anycpu /optimize+ /reference:System.Windows.Forms.dll "/out:$exe" "/win32icon:$icon" $launcher $versionSource
    if ($LASTEXITCODE -ne 0) { throw "Launcher compilation failed (exit $LASTEXITCODE)." }
    Remove-Item -LiteralPath $versionSource

    if ($SigningCertificate) {
        Set-BundleSignature -Path $exe
    }

    $validation = Start-Process -FilePath $exe -ArgumentList '-ValidateOnly' -Wait -PassThru
    if ($validation.ExitCode -ne 0) { throw "Staged executable validation failed (exit $($validation.ExitCode))." }

    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $archive)
    Get-Item -LiteralPath $archive
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
