function ConvertTo-EndpointSettingsDocument {
    param([Collections.IDictionary]$Document, [switch]$AllowLegacy)
    if (-not $Document) { throw 'Settings must be a JSON object.' }
    if ($AllowLegacy -and $Document['SchemaVersion'] -ne 2) {
        $legacy = $Document
        if ($legacy.Contains('SchemaVersion') -and $legacy.SchemaVersion -ne 1) { throw 'Unsupported settings SchemaVersion. Expected 2 or legacy version 1.' }
        $Document = @{ SchemaVersion = 2 }
        $allowed = @('SchemaVersion')
        if ($legacy.Contains('Theme')) {
            $allowed += @('Theme','TenantId','ReportFolder')
            $Document.Appearance = @{ Theme = $legacy.Theme }
            if ($legacy.Contains('TenantId')) { $Document.Graph = @{ TenantId = $legacy.TenantId } }
            if ($legacy.Contains('ReportFolder')) { $Document.Reports = @{ Folder = $legacy.ReportFolder } }
        }
        elseif ($legacy.Contains('DnsSuffix')) {
            $allowed += 'DnsSuffix'
            $Document.Remote = @{ DnsSuffix = $legacy.DnsSuffix }
        }
        elseif ($legacy.Contains('GroupNames')) {
            $allowed += 'GroupNames'
            $Document.CloudUpdate = @{ GroupNames = $legacy.GroupNames }
        }
        elseif ($legacy.Contains('WorkspaceId') -and $legacy.Contains('AzureTenantId')) {
            $allowed += @('WorkspaceId','AzureTenantId')
            $Document.WUfB = @{ WorkspaceId = $legacy.WorkspaceId; AzureTenantId = $legacy.AzureTenantId }
        }
        else { throw 'Unrecognized legacy settings format; existing files have not been changed.' }
        foreach ($key in $legacy.Keys) {
            if ($key -notin $allowed) { throw "Unknown legacy setting '$key'; existing files have not been changed." }
        }
    }
    if ($Document['SchemaVersion'] -isnot [long] -and $Document['SchemaVersion'] -isnot [int]) {
        throw 'Settings SchemaVersion must be the number 2.'
    }
    if ($Document['SchemaVersion'] -ne 2) { throw 'Unsupported settings SchemaVersion. Expected 2.' }
    $schema = @{
        Appearance = @('Theme'); Graph = @('TenantId'); Remote = @('DnsSuffix')
        CloudUpdate = @('GroupNames'); WUfB = @('WorkspaceId','AzureTenantId'); Reports = @('Folder')
    }
    $result = @{ SchemaVersion = 2 }
    foreach ($section in $Document.Keys) {
        if ($section -eq 'SchemaVersion') { continue }
        if (-not $schema.ContainsKey($section)) { throw "Unknown settings section '$section'." }
        if ($Document[$section] -isnot [Collections.IDictionary]) { throw "Settings section '$section' must be a JSON object." }
        $result[$section] = @{}
        foreach ($key in $Document[$section].Keys) {
            if ($key -notin $schema[$section]) { throw "Unknown setting '$section.$key'." }
            $value = $Document[$section][$key]
            if ($key -eq 'GroupNames') {
                if ($value -isnot [array]) { throw 'CloudUpdate.GroupNames must be an array of strings.' }
                $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                $value = [string[]]@(foreach ($name in $value) {
                    if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or $name -match '[\r\n]') {
                        throw 'CloudUpdate.GroupNames contains an invalid group name.'
                    }
                    $name = $name.Trim()
                    if ($seen.Add($name)) { $name }
                })
            }
            else {
                if ($value -isnot [string]) { throw "Setting '$section.$key' must be a string, not null or another type." }
                $value = $value.Trim()
                switch ("$section.$key") {
                    'Appearance.Theme' {
                        if ($value -notin @('Light','Dark','CatppuccinMocha','GruvboxDark')) { throw 'Theme must be Light, Dark, CatppuccinMocha or GruvboxDark.' }
                        $value = @('Light','Dark','CatppuccinMocha','GruvboxDark') | Where-Object { $_ -eq $value } | Select-Object -First 1
                    }
                    'Graph.TenantId' { $value = ConvertTo-EndpointTenantId $value }
                    'Remote.DnsSuffix' { $value = ConvertTo-EndpointDnsSuffix $value }
                    'Reports.Folder' { $null = ConvertTo-EndpointReportFolder $value }
                    { $_ -in @('WUfB.WorkspaceId','WUfB.AzureTenantId') } {
                        $id = [guid]::Empty
                        if ($value -and (-not [guid]::TryParse($value, [ref]$id) -or $id -eq [guid]::Empty)) { throw "$section.$key must be blank or a nonempty GUID." }
                        if ($value) { $value = $id.ToString() }
                    }
                }
            }
            $result[$section][$key] = $value
        }
    }
    return $result
}

function Read-EndpointSettingsDocument {
    param([string]$Path, [switch]$AllowLegacy)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @{ SchemaVersion = 2 } }
    try {
        $document = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($document -isnot [Collections.IDictionary]) { throw 'Expected a JSON object.' }
        ConvertTo-EndpointSettingsDocument $document -AllowLegacy:$AllowLegacy
    }
    catch { throw "Settings file '$Path' could not be loaded. $($_.Exception.Message)" }
}

function Merge-EndpointSettingsDocument {
    param([hashtable]$Base, [hashtable]$Override)
    foreach ($section in $Override.Keys) {
        if ($section -eq 'SchemaVersion') { continue }
        if (-not $Base.ContainsKey($section)) { $Base[$section] = @{} }
        foreach ($key in $Override[$section].Keys) { $Base[$section][$key] = $Override[$section][$key] }
    }
    return $Base
}

function Get-EndpointSettings {
    param(
        [AllowNull()][string]$Path,
        [AllowNull()][string]$DefaultsPath = (Join-Path $PSScriptRoot 'EndpointToolbox.defaults.json')
    )
    $settings = @{
        SchemaVersion = 2; Appearance = @{ Theme = 'Light' }; Graph = @{ TenantId = '' }
        Remote = @{ DnsSuffix = '' }; CloudUpdate = @{ GroupNames = [string[]]@() }
        WUfB = @{ WorkspaceId = ''; AzureTenantId = '' }; Reports = @{ Folder = '' }
    }
    $settings = Merge-EndpointSettingsDocument $settings (Read-EndpointSettingsDocument $DefaultsPath)
    $settings = Merge-EndpointSettingsDocument $settings (Read-EndpointSettingsDocument $Path -AllowLegacy)
    return $settings
}

function Write-EndpointSettingsDocument {
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Document)
    $document = ConvertTo-EndpointSettingsDocument $Document
    $null = New-Item -Path (Split-Path $Path -Parent) -ItemType Directory -Force -ErrorAction Stop
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $document | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction Stop } }
}

function Save-EndpointSettingsSection {
    param([Parameter(Mandatory)][string]$Path, [string]$Section, [hashtable]$Values)
    $patch = ConvertTo-EndpointSettingsDocument @{ SchemaVersion = 2; $Section = $Values }
    $null = Get-EndpointSettings $Path
    $saved = Read-EndpointSettingsDocument $Path -AllowLegacy
    $saved = Merge-EndpointSettingsDocument $saved $patch
    Write-EndpointSettingsDocument $Path $saved
}

function Initialize-EndpointSettings {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$DefaultsPath = (Join-Path $PSScriptRoot 'EndpointToolbox.defaults.json')
    )
    $null = Read-EndpointSettingsDocument $DefaultsPath
    $saved = Read-EndpointSettingsDocument $Path -AllowLegacy
    if (Test-Path -LiteralPath $Path) {
        $original = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($original['SchemaVersion'] -eq 2) { return }
    }
    $foundLegacy = Test-Path -LiteralPath $Path
    foreach ($name in @('remote-settings.json','cloud-update-settings.json','wufb-settings.json')) {
        $legacyPath = Join-Path (Split-Path $Path -Parent) $name
        if (-not (Test-Path -LiteralPath $legacyPath)) { continue }
        $legacy = Read-EndpointSettingsDocument $legacyPath -AllowLegacy
        $saved = Merge-EndpointSettingsDocument $saved $legacy
        $foundLegacy = $true
    }
    if ($foundLegacy) {
        if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath "$Path.legacy.bak")) {
            Copy-Item -LiteralPath $Path -Destination "$Path.legacy.bak" -ErrorAction Stop
        }
        Write-EndpointSettingsDocument $Path $saved
        Write-Information 'Legacy settings consolidated into settings.json. Original sidecar files are retained but no longer used.' -InformationAction Continue
    }
}
