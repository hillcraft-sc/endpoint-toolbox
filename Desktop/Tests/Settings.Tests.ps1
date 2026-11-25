$desktop = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $desktop 'EndpointToolboxUI.psm1') -Force

Describe 'Layered universal settings' {
    BeforeEach {
        $root = Join-Path $env:TEMP "EndpointToolbox-config-$([guid]::NewGuid())"
        $null = New-Item -Path $root -ItemType Directory
        $path = Join-Path $root 'settings.json'
        $defaults = Join-Path $root 'defaults.json'
    }
    AfterEach {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
    It 'layers built-ins, deployment defaults and explicit empty user overrides by individual key' {
        '{"SchemaVersion":2,"Appearance":{"Theme":"dark"},"Graph":{"TenantId":"example.invalid"},"Remote":{"DnsSuffix":"corp.example.invalid"},"CloudUpdate":{"GroupNames":["Fixture.One"]},"WUfB":{"WorkspaceId":"00000000-0000-0000-0000-000000000002","AzureTenantId":"00000000-0000-0000-0000-000000000003"}}' |
            Set-Content -LiteralPath $defaults
        '{"SchemaVersion":2,"Graph":{"TenantId":""},"CloudUpdate":{"GroupNames":[]},"WUfB":{"WorkspaceId":""}}' | Set-Content -LiteralPath $path
        & (Get-Module EndpointToolboxUI) {
            param($path,$defaults)
            $settings = Get-EndpointSettings $path $defaults
            $settings.Appearance.Theme | Should Be 'Dark'
            $settings.Graph.TenantId | Should Be ''
            $settings.CloudUpdate.GroupNames.Count | Should Be 0
            $settings.WUfB.WorkspaceId | Should Be ''
            $settings.WUfB.AzureTenantId | Should Be '00000000-0000-0000-0000-000000000003'
            $settings.Remote.DnsSuffix | Should Be 'corp.example.invalid'
            $settings.Reports.Folder | Should Be ''
        } $path $defaults
    }
    It 'saves all settings to one file without copying deployment defaults or changing their file' {
        '{"SchemaVersion":2,"Graph":{"TenantId":"example.invalid"},"Remote":{"DnsSuffix":"corp.example.invalid"}}' | Set-Content -LiteralPath $defaults
        $original = Get-Content -LiteralPath $defaults -Raw
        & (Get-Module EndpointToolboxUI) {
            param($path,$defaults,$root)
            Save-EndpointThemePreference $path Dark
            $saved = Read-EndpointSettingsDocument $path
            $saved.ContainsKey('Graph') | Should Be $false
            $saved.ContainsKey('Remote') | Should Be $false
            (Get-EndpointSettings $path $defaults).Graph.TenantId | Should Be 'example.invalid'
            $null = Save-EndpointTenantPreference $path 'user.example.invalid'
            $null = Save-EndpointRemoteSettings $path ' .user.example.invalid. '
            $null = @(Save-EndpointCloudUpdateGroups $path "Fixture.One`r`nfixture.one`r`nFixture.Two")
            $null = Save-EndpointWUfBSettings $path '00000000-0000-0000-0000-000000000002' ''
            $null = Save-EndpointReportFolderPreference $path (Join-Path $root 'reports')
            $settings = Get-EndpointSettings $path $defaults
            $settings.Appearance.Theme | Should Be 'Dark'
            $settings.Graph.TenantId | Should Be 'user.example.invalid'
            $settings.Remote.DnsSuffix | Should Be 'user.example.invalid'
            ($settings.CloudUpdate.GroupNames -join '|') | Should Be 'Fixture.One|Fixture.Two'
            $settings.WUfB.WorkspaceId | Should Be '00000000-0000-0000-0000-000000000002'
            (Get-EndpointReportFolderPreference $path) | Should Be (Join-Path $root 'reports')
            $settings.SchemaVersion | Should Be 2
        } $path $defaults $root
        (Get-Content -LiteralPath $defaults -Raw) | Should Be $original
        @(Get-ChildItem -LiteralPath $root -Filter '*settings.json').Count | Should Be 1
        @(Get-ChildItem -LiteralPath $root -Filter '*.tmp').Count | Should Be 0
    }
    It 'applies updated admin defaults only where the user has not overridden a value' {
        '{"SchemaVersion":2,"Graph":{"TenantId":"first.example.invalid"},"Remote":{"DnsSuffix":"first.example.invalid"}}' | Set-Content -LiteralPath $defaults
        & (Get-Module EndpointToolboxUI) { param($path) $null = Save-EndpointTenantPreference $path '' } $path
        '{"SchemaVersion":2,"Graph":{"TenantId":"second.example.invalid"},"Remote":{"DnsSuffix":"second.example.invalid"}}' | Set-Content -LiteralPath $defaults
        & (Get-Module EndpointToolboxUI) {
            param($path,$defaults)
            $settings = Get-EndpointSettings $path $defaults
            $settings.Graph.TenantId | Should Be ''
            $settings.Remote.DnsSuffix | Should Be 'second.example.invalid'
        } $path $defaults
    }
    It 'migrates legacy preferences and sidecars atomically and does not read them again' {
        '{"Theme":"dark","TenantId":"example.invalid","ReportFolder":"%TEMP%"}' | Set-Content -LiteralPath $path
        '{"SchemaVersion":1,"DnsSuffix":"corp.example.invalid"}' | Set-Content -LiteralPath (Join-Path $root 'remote-settings.json')
        '{"SchemaVersion":1,"GroupNames":["Fixture.One"]}' | Set-Content -LiteralPath (Join-Path $root 'cloud-update-settings.json')
        '{"SchemaVersion":1,"WorkspaceId":"00000000-0000-0000-0000-000000000002","AzureTenantId":""}' | Set-Content -LiteralPath (Join-Path $root 'wufb-settings.json')
        $original = Get-Content -LiteralPath $path -Raw
        & (Get-Module EndpointToolboxUI) {
            param($path)
            Initialize-EndpointSettings $path ''
            $saved = Read-EndpointSettingsDocument $path
            $saved.Appearance.Theme | Should Be 'Dark'
            $saved.Graph.TenantId | Should Be 'example.invalid'
            $saved.Reports.Folder | Should Be '%TEMP%'
            $saved.Remote.DnsSuffix | Should Be 'corp.example.invalid'
            $saved.CloudUpdate.GroupNames[0] | Should Be 'Fixture.One'
            $saved.WUfB.WorkspaceId | Should Be '00000000-0000-0000-0000-000000000002'
        } $path
        (Get-Content -LiteralPath "$path.legacy.bak" -Raw) | Should Be $original
        (Test-Path -LiteralPath (Join-Path $root 'wufb-settings.json')) | Should Be $true
        'invalid retained legacy file' | Set-Content -LiteralPath (Join-Path $root 'remote-settings.json')
        & (Get-Module EndpointToolboxUI) { param($path) Initialize-EndpointSettings $path ''; (Get-EndpointRemoteSettings $path).DnsSuffix | Should Be 'corp.example.invalid' } $path
    }
    It 'migrates existing sidecars when there are no appearance preferences and does not create overrides for new users' {
        & (Get-Module EndpointToolboxUI) { param($path) Initialize-EndpointSettings $path '' } $path
        (Test-Path -LiteralPath $path) | Should Be $false
        '{"SchemaVersion":1,"DnsSuffix":""}' | Set-Content -LiteralPath (Join-Path $root 'remote-settings.json')
        & (Get-Module EndpointToolboxUI) {
            param($path)
            Initialize-EndpointSettings $path ''
            (Read-EndpointSettingsDocument $path).Remote.DnsSuffix | Should Be ''
        } $path
    }
    It 'refuses invalid migration or shared-file saves without overwriting valid preferences' {
        '{"Theme":"Light","TenantId":"example.invalid"}' | Set-Content -LiteralPath $path
        'broken' | Set-Content -LiteralPath (Join-Path $root 'wufb-settings.json')
        $original = Get-Content -LiteralPath $path -Raw
        & (Get-Module EndpointToolboxUI) {
            param($path)
            $rejected = $false
            try { Initialize-EndpointSettings $path '' } catch { $rejected = $true }
            $rejected | Should Be $true
        } $path
        (Get-Content -LiteralPath $path -Raw) | Should Be $original
        (Test-Path -LiteralPath "$path.legacy.bak") | Should Be $false
        'broken' | Set-Content -LiteralPath $path
        & (Get-Module EndpointToolboxUI) {
            param($path)
            foreach ($section in @('Appearance','Remote')) {
                $rejected = $false
                try { Save-EndpointSettingsSection $path $section $(if ($section -eq 'Appearance') { @{Theme='Dark'} } else { @{DnsSuffix='corp.example.invalid'} }) } catch { $rejected = $true }
                $rejected | Should Be $true
            }
        } $path
        (Get-Content -LiteralPath $path -Raw).Trim() | Should Be 'broken'
    }
    It 'rejects malformed deployment schemas and invalid values rather than silently ignoring them' {
        foreach ($json in @(
            '[]', 'null', '{}', '{"SchemaVersion":3}', '{"SchemaVersion":"2"}',
            '{"SchemaVersion":2,"Unknown":{}}', '{"SchemaVersion":2,"Graph":{"TenantId":null}}',
            '{"SchemaVersion":2,"Graph":{"Tenant":"example.invalid"}}', '{"SchemaVersion":2,"WUfB":{"WorkspaceId":"not-a-guid"}}',
            '{"SchemaVersion":2,"CloudUpdate":{"GroupNames":"One"}}', '{"SchemaVersion":2,"CloudUpdate":{"GroupNames":[42]}}',
            '{"SchemaVersion":2,"Reports":{"Folder":"relative"}}', '{"SchemaVersion":2,"Appearance":{"Theme":"invalid"}}'
        )) {
            $json | Set-Content -LiteralPath $defaults
            & (Get-Module EndpointToolboxUI) {
                param($path,$defaults)
                $rejected = $false
                try { $null = Get-EndpointSettings $path $defaults } catch { $rejected = $true }
                $rejected | Should Be $true
            } $path $defaults
            (Test-Path -LiteralPath $path) | Should Be $false
        }
    }
}

Describe 'Deployable settings payload' {
    It 'signs every staged PowerShell file and the launcher when a certificate is supplied' {
        $root = Join-Path $env:TEMP "EndpointToolbox-signing-$([guid]::NewGuid())"
        $null = New-Item -Path $root -ItemType Directory
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new()
        Mock Set-AuthenticodeSignature { }
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $certificate }
        }
        try {
            $builder = Join-Path $desktop 'Packaging\Build-EndpointToolboxBundle.ps1'
            $null = & $builder -OutputDirectory $root -SigningCertificate $certificate
            $extract = Join-Path $root 'extracted'
            [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $root 'EndpointToolbox-0.1.0.zip'), $extract)
            $powershellFiles = @(Get-ChildItem -LiteralPath $extract -Recurse -File |
                Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })
            Assert-MockCalled Set-AuthenticodeSignature -Times ($powershellFiles.Count + 1) -Exactly
            Assert-MockCalled Get-AuthenticodeSignature -Times ($powershellFiles.Count + 1) -Exactly
            foreach ($extension in '.ps1', '.psm1', '.psd1', '.exe') {
                Assert-MockCalled Set-AuthenticodeSignature -ParameterFilter {
                    [IO.Path]::GetExtension($LiteralPath) -eq $extension
                }
            }
        }
        finally {
            $certificate.Dispose()
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
    It 'does not create an archive when a staged signature cannot be verified' {
        $root = Join-Path $env:TEMP "EndpointToolbox-signing-failure-$([guid]::NewGuid())"
        $null = New-Item -Path $root -ItemType Directory
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new()
        Mock Set-AuthenticodeSignature { }
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'NotTrusted'; StatusMessage = 'Untrusted test signature' }
        }
        try {
            $builder = Join-Path $desktop 'Packaging\Build-EndpointToolboxBundle.ps1'
            { & $builder -OutputDirectory $root -SigningCertificate $certificate } | Should Throw 'Signature verification failed'
            @(Get-ChildItem -LiteralPath $root -Filter '*.zip').Count | Should Be 0
        }
        finally {
            $certificate.Dispose()
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        }
    }
    It 'rejects invalid deployment defaults before launching native validation or creating an archive' {
        $root = Join-Path $env:TEMP "EndpointToolbox-invalid-config-$([guid]::NewGuid())"
        $null = New-Item -Path $root -ItemType Directory
        $defaults = Join-Path $root 'admin.json'
        try {
            '{"SchemaVersion":2,"WUfB":{"WorkspaceId":"invalid"}}' | Set-Content -LiteralPath $defaults
            $builder = Join-Path $desktop 'Packaging\Build-EndpointToolboxBundle.ps1'
            $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $builder -OutputDirectory $root -ConfigurationPath $defaults 2>&1
            ($LASTEXITCODE -ne 0) | Should Be $true
            ($output -join "`n") | Should Match 'Deployment settings validation failed'
            @(Get-ChildItem -LiteralPath $root -Filter '*.zip').Count | Should Be 0
        }
        finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
    It 'includes and discovers the selected admin defaults in the staged bundle without user overrides' {
        $root = Join-Path $env:TEMP "EndpointToolbox-bundle-config-$([guid]::NewGuid())"
        $null = New-Item -Path $root -ItemType Directory
        $defaults = Join-Path $root 'admin.json'
        try {
            '{"SchemaVersion":2,"Graph":{"TenantId":"fixture.example.invalid"},"WUfB":{"WorkspaceId":"00000000-0000-0000-0000-000000000002","AzureTenantId":"00000000-0000-0000-0000-000000000003"}}' | Set-Content -LiteralPath $defaults
            $builder = Join-Path $desktop 'Packaging\Build-EndpointToolboxBundle.ps1'
            $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $builder -OutputDirectory $root -ConfigurationPath $defaults 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Bundle build failed: $($output -join "`n")" }
            $archive = Join-Path $root 'EndpointToolbox-0.1.0.zip'
            $extract = Join-Path $root 'extracted'
            [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extract)
            $stagedModule = Join-Path $extract 'Desktop\EndpointToolboxUI.psm1'
            $script = @'
param($module,$userPath)
Import-Module $module
& (Get-Module EndpointToolboxUI) {
    param($userPath)
    $settings = Get-EndpointSettings ''
    if ($settings.Graph.TenantId -ne 'fixture.example.invalid' -or $settings.WUfB.WorkspaceId -ne '00000000-0000-0000-0000-000000000002') { throw 'Deployment defaults not discovered.' }
    $null = Save-EndpointWUfBSettings $userPath '' $settings.WUfB.AzureTenantId
    $saved = Read-EndpointSettingsDocument $userPath
    if ($saved.WUfB.WorkspaceId -ne '' -or $saved.WUfB.ContainsKey('AzureTenantId')) { throw 'Clearing the workspace did not preserve tenant inheritance.' }
    if ((Get-EndpointWUfBSettings $userPath).AzureTenantId -ne $settings.WUfB.AzureTenantId) { throw 'Inherited Azure tenant changed.' }
} $userPath
'@
            $verify = Join-Path $root 'verify.ps1'
            $script | Set-Content -LiteralPath $verify
            $output = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $verify $stagedModule (Join-Path $root 'user-settings.json') 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Staged settings verification failed: $($output -join "`n")" }
            (Test-Path -LiteralPath (Join-Path $extract 'Desktop\Settings.ps1')) | Should Be $true
            @(Get-ChildItem -LiteralPath $extract -Recurse -Filter 'settings.json').Count | Should Be 0
        }
        finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force } }
    }
}
