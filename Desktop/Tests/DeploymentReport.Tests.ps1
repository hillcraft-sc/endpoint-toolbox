# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

$desktop = Split-Path $PSScriptRoot -Parent
$report = Join-Path (Split-Path $desktop -Parent) 'Intune\Assignments\Get-Win32AppDeploymentStatus.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($report,[ref]$tokens,[ref]$errors)
foreach ($name in @('Get-DeploymentState','Get-DeploymentDeviceSummary')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if (-not $definition) { throw "Missing report function $name." }
    . ([scriptblock]::Create($definition.Extent.Text))
}

Describe 'Merged deployment report state summaries' {
    It 'preserves localized labels and maps original numeric install-state values' {
        (Get-DeploymentState ([pscustomobject]@{InstallState='2';AppInstallState_loc='Echec'})) | Should Be 'Echec'
        (Get-DeploymentState ([pscustomobject]@{InstallState='2'})) | Should Be 'Failed'
        (Get-DeploymentState ([pscustomobject]@{InstallState='123'})) | Should Be 'Unknown (123)'
        (Get-DeploymentState ([pscustomobject]@{InstallState='PendingInstall'})) | Should Be 'PendingInstall'
    }
    It 'ranks raw codes despite localization and does not count multiple users as devices' {
        $rows=@(
            [pscustomobject]@{DeviceId='fixture';DeviceName='Fixture-PC';InstallState='1';InstallStateFriendly='Installe'}
            [pscustomobject]@{DeviceId='fixture';DeviceName='Fixture-PC';InstallState='2';InstallStateFriendly='Echec'}
            [pscustomobject]@{DeviceId='fixture-2';DeviceName='Fixture-PC-2';InstallState='5';InstallStateFriendly='En attente'}
        )
        $summary=@(Get-DeploymentDeviceSummary $rows 'Fixture App' 'fixture-app' '1.0')
        $summary.Count | Should Be 2
        ($summary | Where-Object DeviceId -eq 'fixture').InstallStateFriendly | Should Be 'Echec'
        ($summary | Where-Object DeviceId -eq 'fixture').ReportRows | Should Be 2
        ($summary | Where-Object DeviceId -eq 'fixture').ApplicationId | Should Be 'fixture-app'
    }
    It 'never treats an unclassified state as a known successful installation' {
        $rows=@(
            [pscustomobject]@{DeviceId='fixture';DeviceName='Fixture-PC';InstallState='1';InstallStateFriendly='Installed'}
            [pscustomobject]@{DeviceId='fixture';DeviceName='Fixture-PC';InstallState='777';InstallStateFriendly='Unknown (777)'}
        )
        $summary=@(Get-DeploymentDeviceSummary $rows 'Fixture App' 'fixture-app' '1.0')
        $summary[0].InstallStateFriendly | Should Be 'Unknown (777)'
    }
}
