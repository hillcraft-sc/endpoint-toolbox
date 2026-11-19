# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ActivityLogging.ps1')
. (Join-Path $PSScriptRoot 'GraphSession.ps1')

function Write-EndpointUiRecord {
    param([string]$Event, [string]$State = '', [string]$Message = '', [object]$Summary, [switch]$Required, [switch]$PrivateRemote)
    $ui = $script:Ui
    if (-not $ui.ContainsKey('LogRoot') -or -not $ui.LogRoot) { return }
    $workflowId = ''; $runId = ''; $device = ''
    if ($ui.Active) {
        $workflowId = $ui.Active.WorkflowId
        $runId = $ui.Active.RunId
        if ($ui.Active.IsRemote) { $device = $ui.RemoteTarget; $Message = '' }
    }
    elseif ($ui.Workflow -and $Event -notin @('AppStarted','AppClosed')) { $workflowId = $ui.Workflow.Id }
    if ($PrivateRemote) { $Message = ''; $workflowId = 'remote-endpoint'; $device = $ui.RemoteTarget }
    try {
        Write-EndpointActivityRecord -LogRoot $ui.LogRoot -Event $Event -WorkflowId $workflowId -RunId $runId -State $State -Device $device -Message $Message -Summary $Summary
    }
    catch {
        Add-EndpointActivity 'Logging error' "Activity logging failed: $($_.Exception.Message)"
        if ($Required) { throw }
        Set-EndpointLiveText $ui.Controls.Status 'Activity logging failed. See Script output; do not assume an audit record was saved.'
    }
}

function Protect-EndpointText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $text = $text -replace '(?i)([?&](?:token|sig|signature|access_token|code)=)[^&\s"<>]+', '$1[redacted]'
    $text = $text -replace '(?i)(Bearer\s+)[A-Za-z0-9._~+/-]+=*', '$1[redacted]'
    return $text
}

function Set-EndpointLiveText {
    param([Windows.Controls.TextBlock]$Element, [AllowEmptyString()][string]$Text)
    if ($Element.Text -ceq $Text) { return }
    $Element.Text = $Text
    if ([Windows.Automation.Peers.AutomationPeer]::ListenerExists([Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged)) {
        $peer = [Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($Element)
        if ($peer) { $peer.RaiseAutomationEvent([Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged) }
    }
}

function Get-EndpointRemoteCommands {
    param([string]$Path = (Join-Path $PSScriptRoot 'RemoteCommands.json'))
    $catalog = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($catalog -isnot [hashtable] -or $catalog.SchemaVersion -ne 1 -or $catalog.Commands -isnot [array] -or -not $catalog.Commands.Count) {
        throw 'Invalid remote command catalog: expected SchemaVersion 1 and a nonempty Commands array.'
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $catalog.Commands) {
        if ($entry -isnot [hashtable]) { throw 'Invalid remote command catalog entry.' }
        foreach ($field in @('Name','Description','Command')) {
            if ($entry[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($entry[$field])) { throw "Remote command is missing a nonempty $field string." }
        }
        if (-not $names.Add($entry.Name)) { throw "Duplicate remote command name: $($entry.Name)" }
        $tokens = $null; $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($entry.Command, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "Remote command '$($entry.Name)' has invalid PowerShell syntax: $($errors.Message -join '; ')" }
        [pscustomobject]@{ Name = $entry.Name; Description = $entry.Description; Command = $entry.Command }
    }
}

function Get-EndpointCatalog {
    param([string]$CatalogPath = (Join-Path $PSScriptRoot 'WorkflowCatalog.psd1'))
    $manifest = Import-PowerShellDataFile -LiteralPath $CatalogPath
    if ($manifest.SchemaVersion -ne 1) { throw 'Unsupported workflow catalog schema.' }
    $root = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $manifest.Workflows) {
        foreach ($key in @('Id', 'Title', 'Category', 'Path', 'Risk', 'Description')) {
            if (-not $entry[$key]) { throw "Catalog entry is missing $key." }
        }
        if (-not $ids.Add($entry.Id)) { throw "Duplicate workflow ID: $($entry.Id)" }
        $fullPath = [IO.Path]::GetFullPath((Join-Path $root $entry.Path))
        if (-not $fullPath.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith("$PSScriptRoot\", [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetExtension($fullPath) -ne '.ps1') { throw "Unapproved workflow path: $($entry.Path)" }
        if (-not $paths.Add($fullPath)) { throw "Duplicate workflow path: $($entry.Path)" }
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "Invalid script $($entry.Path): $($parseErrors.Message -join '; ')" }
        $help = $ast.GetHelpContent()
        $configuredTenant = ''
        foreach ($assignment in $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.UserPath -eq 'TenantId'
        }, $true)) {
            if ($assignment.Right -is [Management.Automation.Language.PipelineAst]) {
                $expression = $assignment.Right.GetPureExpression()
                if ($expression -is [Management.Automation.Language.StringConstantExpressionAst]) { $configuredTenant = $expression.Value }
            }
        }
        $parameterNames = @($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
        $hiddenParameters = if ($entry.ContainsKey('HiddenParameters')) { @($entry.HiddenParameters) } else { @() }
        foreach ($hiddenParameter in $hiddenParameters) {
            if ($hiddenParameter -notin $parameterNames) { throw "Unknown hidden parameter $hiddenParameter in $($entry.Id)." }
        }
        $fields = [Collections.Generic.List[object]]::new()
        foreach ($parameter in $ast.ParamBlock.Parameters) {
            $name = $parameter.Name.VariablePath.UserPath
            if ($name -eq 'UiEventSink' -or $name -in $hiddenParameters) { continue }
            $type = $parameter.StaticType
            $choices = @()
            $required = $false
            foreach ($attribute in $parameter.Attributes) {
                if ($attribute -isnot [Management.Automation.Language.AttributeAst]) { continue }
                if ($attribute.TypeName.Name -eq 'ValidateSet') {
                    $choices = @($attribute.PositionalArguments | ForEach-Object { $_.SafeGetValue() })
                }
                if ($attribute.TypeName.Name -eq 'Parameter') {
                    foreach ($argument in $attribute.NamedArguments) {
                        if ($argument.ArgumentName -eq 'Mandatory') {
                            $required = $argument.ExpressionOmitted -or [bool]$argument.Argument.SafeGetValue()
                        }
                    }
                }
            }
            $default = ''
            if ($entry.ContainsKey('Defaults') -and $entry.Defaults.ContainsKey($name)) {
                $default = $entry.Defaults[$name]
                if ($default -is [string] -and $default -eq 'TEMP') { $default = $env:TEMP }
            }
            $detail = if ($help -and $help.Parameters.ContainsKey($name.ToUpperInvariant())) { $help.Parameters[$name.ToUpperInvariant()] } else { $name }
            $fields.Add([pscustomobject]@{
                Name = $name; Type = $type; Choices = $choices; Required = $required; Default = $default
                Help = $detail; Advanced = $name -in @('ForceInteractive', 'AutoDeleteAutopilot', 'DeleteFromAutopilot', 'VerifyTimeoutMinutes', 'VerifyIntervalSeconds', 'TimeoutSeconds')
            })
        }
        if ($entry.ContainsKey('ShouldProcess') -and $entry.ShouldProcess) {
            $fields.Add([pscustomobject]@{ Name = 'WhatIf'; Type = [switch]; Choices = @(); Required = $false; Default = $false; Help = 'Preview remote changes. Existing script CSV output may still be written.'; Advanced = $false })
            $fields.Add([pscustomobject]@{ Name = 'Confirm'; Type = [string]; Choices = @('Script default', 'Prompt', 'Suppress ShouldProcess prompts'); Required = $false; Default = 'Script default'; Help = 'Suppressing ShouldProcess does not suppress mandatory primary-user Yes/No approval. Autopilot approval is independent.'; Advanced = $true })
        }
        $selectors = if ($entry.ContainsKey('Selectors')) { @($entry.Selectors) } else { @() }
        $kind = if ($entry.ContainsKey('Kind')) { $entry.Kind } else { 'Graph' }
        if ($kind -notin @('Graph', 'Remote', 'Office')) { throw "Invalid execution kind for $($entry.Id)." }
        foreach ($selector in $selectors) {
            foreach ($option in $selector.Options) {
                foreach ($name in $option.Parameters) {
                    if ($name -notin $parameterNames) { throw "Unknown selector parameter $name in $($entry.Id)." }
                }
            }
        }
        [pscustomobject]@{
            Id = $entry.Id; Title = $entry.Title; Category = $entry.Category; Path = $entry.Path; FullPath = $fullPath
            Risk = $entry.Risk; Description = $entry.Description; Fields = $fields.ToArray(); Selectors = $selectors
            Kind = $kind; Notes = if ($help) { $help.Notes } else { '' }
            ConfiguredTenant = $configuredTenant
            Display = "$($entry.Category) | $($entry.Title)"
        }
    }
}

function Test-EndpointCatalogCoverage {
    param([object[]]$Catalog)
    $root = Split-Path $PSScriptRoot -Parent
    $actual = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File |
        Where-Object { -not $_.FullName.StartsWith("$PSScriptRoot\", [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object FullName)
    $difference = @(Compare-Object -ReferenceObject $actual -DifferenceObject @($Catalog.FullPath))
    if ($difference.Count) { throw "Unintegrated or missing business scripts: $($difference.InputObject -join ', ')" }
}

function Get-EndpointArguments {
    param([object]$Workflow, [hashtable]$Values, [string[]]$Inactive = @())
    $arguments = @{}
    foreach ($field in $Workflow.Fields) {
        if ($field.Name -in $Inactive) { continue }
        $value = $Values[$field.Name]
        if ($field.Name -eq 'Confirm') {
            if ($value -eq 'Prompt') { $arguments.Confirm = $true }
            elseif ($value -eq 'Suppress ShouldProcess prompts') { $arguments.Confirm = $false }
            continue
        }
        if ($field.Type -eq [switch]) {
            if ($value -eq $true) { $arguments[$field.Name] = $true }
            elseif ($field.Default -eq $true -and $Values.ContainsKey($field.Name)) { $arguments[$field.Name] = $false }
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            if ($field.Required) { throw "$($field.Name) is required." }
            continue
        }
        $value = ([string]$value).Trim()
        if ($field.Choices.Count -and $value -notin $field.Choices) { throw "Invalid $($field.Name) selection." }
        if ($field.Type -eq [int]) {
            $number = 0
            if (-not [int]::TryParse($value, [ref]$number) -or $number -lt 1) { throw "$($field.Name) must be a positive whole number." }
            if ($field.Name -in @('Days', 'LookbackDays') -and $Workflow.Id -in @('stale-synced-devices', 'add-primary-devices-to-group') -and $number -gt 3650) { throw "$($field.Name) cannot exceed 3650." }
            if ($Workflow.Id -eq 'm365-cloud-update' -and $field.Name -eq 'PageSize' -and $number -gt 200) { throw 'PageSize cannot exceed 200.' }
            $value = $number
        }
        elseif ($field.Type.IsArray) {
            $value = [string[]]@($value -split '\r?\n' | ForEach-Object Trim | Where-Object { $_ })
            if ($field.Type -eq [guid[]]) { $value = [guid[]]$value }
        }
        if ($field.Name -in @('GroupId', 'AppId')) {
            foreach ($id in @($value)) {
                $parsed = [guid]::Empty
                if (-not [guid]::TryParse($id, [ref]$parsed)) { throw "$($field.Name) must contain valid GUIDs." }
            }
        }
        if ($field.Name -in @('DeviceListPath', 'UserListPath') -and -not (Test-Path -LiteralPath $value -PathType Leaf)) { throw "Input file does not exist: $value" }
        $arguments[$field.Name] = $value
    }
    if ($arguments['NewPrimaryUser'] -and $arguments['RemovePrimaryUser']) { throw 'Assign and remove primary user are mutually exclusive.' }
    if ($Workflow.Id -eq 'primary-users' -and 'RemovePrimaryUser' -in $Inactive -and 'NewPrimaryUser' -notin $Inactive -and -not $arguments['NewPrimaryUser']) { throw 'Enter the new primary user UPN, or choose Read primary users.' }
    if ($arguments['AutoDeleteAutopilot'] -and -not $arguments['DeleteFromAutopilot']) { throw 'AutoDeleteAutopilot requires DeleteFromAutopilot.' }
    if ($Workflow.Id -eq 'entra-cleanup' -and $arguments['OpenReport'] -and -not $arguments['ExportCsv']) { throw 'OpenReport requires ExportCsv.' }
    if ($Workflow.Id -eq 'm365-cloud-update') {
        if ($arguments['IncludeWaveGroups'] -and -not $arguments['WaveGroupNames']) { throw 'Enter at least one rollout group name, or clear Include rollout group membership.' }
        if (-not $arguments['IncludeWaveGroups']) { $arguments.Remove('WaveGroupNames') }
    }
    if ($Workflow.Id -in @('delete-win32-apps', 'intune-assignment-win32-deployment-exports') -and -not $arguments['AppName'] -and -not $arguments['AppId']) { throw 'Supply an app name/pattern or app ID.' }
    if ($Workflow.Id -in @('add-members-to-group','remove-members-from-group')) {
        $sources = @('Users','UserListPath','DeviceNames','DeviceListPath' | Where-Object { $arguments[$_] })
        if ($sources.Count -ne 1) { throw 'Supply user UPNs, device names, or one list file.' }
        $extension = if ($arguments['UserListPath']) { [IO.Path]::GetExtension($arguments['UserListPath']) } else { '' }
        if ($extension -in @('.csv', '.xlsx')) {
            if (-not $arguments['UserColumn']) { throw 'UserColumn is required for CSV/XLSX input.' }
            if ($extension -eq '.xlsx' -and -not (Get-Module -ListAvailable ImportExcel)) { throw 'XLSX input requires ImportExcel. Install-Module ImportExcel -Scope CurrentUser' }
        }
        elseif ($arguments['UserColumn']) { throw 'UserColumn is only supported with CSV/XLSX input.' }
    }
    return $arguments
}

function Add-EndpointActivity {
    param([string]$Name, [object]$Message, [switch]$Remote)
    $text = Protect-EndpointText $Message
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $Name`: $text`r`n"
    $remoteLine = ''
    if ($Remote -and $Name -ne 'Run timing') {
        $remoteLine = switch ($Name) {
            'Remote command submitted' { "PS [$($script:Ui.RemoteTarget)]> $text`r`n" }
            'Output' { "$text`r`n" }
            'Pipeline' { "$text`r`n" }
            'Remote session' { '' }
            default { "$Name`: $text`r`n" }
        }
    }
    if ($null -ne $script:Ui.ActivityBuffer) {
        $null = $script:Ui.ActivityBuffer.Append($line)
        if ($remoteLine) { $null = $script:Ui.RemoteBuffer.Append($remoteLine) }
        return
    }
    $script:Ui.Controls.Activity.AppendText($line)
    $script:Ui.Controls.Activity.ScrollToEnd()
    if ($remoteLine) {
        $script:Ui.Controls.RemoteOutput.AppendText($remoteLine)
        $script:Ui.Controls.RemoteOutput.ScrollToEnd()
    }
}

function Update-EndpointRemoteIndicator {
    $ui = $script:Ui
    $running = $ui.Active -and $ui.Active.IsRemote -and $ui.Active.Engine.Busy
    $ui.Controls.RemoteBusyIndicator.Visibility = if ($running) { 'Visible' } else { 'Collapsed' }
    if ($running) {
        $frame = @('|','/','-','\')[[int]([math]::Floor([datetime]::UtcNow.TimeOfDay.TotalMilliseconds / 250) % 4)]
        $label = if ($ui.Active.Engine.Host.IsStopping) { 'Stopping' } else { 'Running' }
        $ui.Controls.RemoteBusyIndicator.Text = "$frame $label..."
    }
    else { $ui.Controls.RemoteBusyIndicator.Text = '' }
}

function Get-EndpointUserColumns {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Select an existing CSV or XLSX user file first.' }
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.csv' {
            Add-Type -AssemblyName Microsoft.VisualBasic.Core
            $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($Path)
            try {
                $parser.SetDelimiters([string[]]@(','))
                $parser.HasFieldsEnclosedInQuotes = $true
                return $parser.ReadFields()
            }
            finally { $parser.Dispose() }
        }
        '.xlsx' {
            if (-not (Get-Module -ListAvailable ImportExcel)) { throw 'XLSX header selection requires ImportExcel. Install-Module ImportExcel -Scope CurrentUser' }
            $row = Import-Excel -Path $Path -StartRow 1 -EndRow 2 -ErrorAction Stop | Select-Object -First 1
            if (-not $row) { throw 'The first worksheet contains no user data.' }
            return $row.PSObject.Properties.Name
        }
        default { throw 'Column selection is only available for CSV or XLSX files.' }
    }
}

function Update-EndpointFields {
    $inactive = [Collections.Generic.List[string]]::new()
    foreach ($selector in $script:Ui.Selectors) {
        $chosen = $selector.Definition.Options[$selector.Control.SelectedIndex]
        foreach ($option in $selector.Definition.Options) {
            foreach ($parameter in $option.Parameters) {
                if ($parameter -notin $chosen.Parameters) { $inactive.Add($parameter) }
            }
        }
    }
    $script:Ui.Inactive = $inactive.ToArray()
    foreach ($name in $script:Ui.FieldRows.Keys) {
        $script:Ui.FieldRows[$name].Visibility = if ($name -in $script:Ui.Inactive -or $name -eq 'RemovePrimaryUser') { 'Collapsed' } else { 'Visible' }
    }
    if ($script:Ui.Workflow.Id -eq 'primary-users') {
        $script:Ui.FieldControls.RemovePrimaryUser.IsChecked = 'RemovePrimaryUser' -notin $script:Ui.Inactive
        $readOnly = 'NewPrimaryUser' -in $script:Ui.Inactive -and 'RemovePrimaryUser' -in $script:Ui.Inactive
        $script:Ui.FieldRows.WhatIf.Parent.Parent.Visibility = if ($readOnly) { 'Collapsed' } else { 'Visible' }
        Set-EndpointLiveText $script:Ui.Controls.RiskLabel $(if ($readOnly) { 'Read only' } else { 'Change' })
        $script:Ui.Controls.RiskBadge.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, $(if ($readOnly) { 'Brush.Success' } else { 'Brush.Warning' }))
    }
    Update-EndpointRunLabel
}

function Get-EndpointFieldPresentation {
    param([string]$Name)
    $labels = @{
        AppName = 'App name or wildcard'; AppId = 'App object ID'; Justification = 'Business justification'
        Devices = 'Device names'; DeviceNames = 'Device names'; Device = 'Computer name'
        DeviceListPath = 'Device list file'; EntraGroup = 'Entra group name or ID'; GroupName = 'Group display name'; GroupId = 'Group object ID'
        ManagedDeviceId = 'Intune managed device IDs'; NewPrimaryUser = 'New primary user (UPN)'; RemovePrimaryUser = 'Remove primary user'
        ScriptType = 'Script type'
        UserListPath = 'User list file'; Users = 'User principal names (UPNs)'; UserColumn = 'Column containing user UPNs'; Names = 'Person names'
        OutputPath = 'Report folder or CSV path'; OutputFile = 'Report CSV file'; CsvPath = 'Optional CSV export'
        ExportFolder = 'Report folder'; NoExport = 'Do not save CSV reports'; TenantId = 'Office sign-in tenant ID or domain'; PageSize = 'Devices per API page'
        IncludeWaveGroups = 'Include rollout group membership (Graph)'; WaveGroupNames = 'Rollout group names'
        LookbackDays = 'Look back (days)'; Days = 'Inactive for at least (days)'; PolicyName = 'Update policy name'
        IncludeUserStatus = 'Include user deployment status (recommended)'; AppType = 'Application type'; Platform = 'Device platform'
        OpenReport = 'Open the CSV after completion'; ExportCsv = 'Export cleanup results to CSV'
        VerifySync = 'Wait and check for a newer device sync'; VerifyTimeoutMinutes = 'Sync check timeout (minutes)'
        VerifyIntervalSeconds = 'Sync check interval (seconds)'; TimeoutSeconds = 'Report timeout (seconds)'
        ForceInteractive = 'Force a new interactive Graph sign-in'; DeleteFromAutopilot = 'Also delete matching Autopilot records'
        AutoDeleteAutopilot = 'Skip the separate Autopilot confirmation'; UNC = 'Also open the administrative share in Windows Explorer'
        Confirm = 'Script confirmation prompts'; WhatIf = 'Preview only (WhatIf) - do not make remote changes'
    }
    $hints = @{
        AppName = 'Exact names or PowerShell wildcards, for example Google Chrome* or *Adobe*.'
        AppId = 'Optional. Intune mobileApps object IDs, not application/client IDs.'
        Justification = 'Used by Intune for deletion or Multi-Admin Approval. Leave blank to use the original script prompt.'
        Devices = 'Enter one device name per line.'; DeviceNames = 'Enter one hostname per line.'
        Users = 'Enter one UPN per line, for example user@example.com.'
        Names = 'Enter one name per line, as First Last or Last, First.'
        EntraGroup = 'Enter the group display name or its object ID.'
        NewPrimaryUser = 'The user to assign, for example user@example.com. The script still asks for per-device approval.'
        WhatIf = 'Unchecked runs the original action with its normal confirmations. Preview may still create CSV reports.'
        Confirm = 'Script default preserves the original confirmations. Suppressing these does not bypass mandatory primary-user approval.'
        AutoDeleteAutopilot = 'Warning: suppresses Autopilot approval only. Entra deletion is a separate decision.'
        DeviceListPath = 'Choose a text file containing one device name per line.'
        IncludeUserStatus = 'Enabled by default for full reporting. Uncheck only if you want device reports without the separate user-status export.'
        OutputPath = 'TEMP is prefilled. The selected script controls export naming and whether a CSV filename is accepted.'
        ExportFolder = 'TEMP is prefilled, outside the repository. Saves device, full inventory and rollout summary CSVs.'
        NoExport = 'Show report data and statistics without saving the three CSV files.'
        TenantId = 'organizations allows a work or school account. This sign-in is separate from Home Graph.'
        WaveGroupNames = 'Enter one exact Entra group display name per line. Required when rollout group membership is included; ignored otherwise.'
        IncludeWaveGroups = 'Optional. Uses only the groups listed under Rollout group names. Connect on Home first in the same tenant as Office; existing Group.Read.All and Device.Read.All consent is required. Multiple matches are separated by semicolons.'
        UserColumn = 'For CSV or XLSX, choose the exact column holding the user UPNs.'
        VerifySync = 'A request being accepted does not mean the device has checked in.'
    }
    [pscustomobject]@{
        Label = if ($labels.ContainsKey($Name)) { $labels[$Name] } else { ($Name -creplace '([a-z])([A-Z])', '$1 $2') }
        Hint = if ($hints.ContainsKey($Name)) { $hints[$Name] } else { '' }
    }
}

function Set-EndpointNavigation {
    param([string]$Query = '')
    $ui = $script:Ui
    $selectedId = if ($ui.Workflow) { $ui.Workflow.Id } else { '' }
    $items = @($ui.Catalog | Where-Object { "$($_.Display) $($_.Path)".IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Sort-Object Category,Title)
    $view = [Windows.Data.ListCollectionView]::new([Collections.IList]$items)
    $view.GroupDescriptions.Add([Windows.Data.PropertyGroupDescription]::new('Category'))
    $ui.Controls.WorkflowList.ItemsSource = $view
    $selected = $items | Where-Object Id -eq $selectedId | Select-Object -First 1
    if ($selected) { $ui.Controls.WorkflowList.SelectedItem = $selected }
    else { $ui.Controls.WorkflowList.SelectedIndex = if ($items.Count) { 0 } else { -1 } }
    if (-not $items.Count) {
        $ui.Workflow = $null
        $ui.Controls.WorkflowTitle.Text = 'No matching tasks'
        $ui.Controls.Description.Text = 'Try a different search or clear the search box.'
        $ui.Controls.Form.Children.Clear()
    }
    $ui.Controls.RunButton.IsEnabled = $items.Count -gt 0 -and -not $ui.Faulted
}

function Update-EndpointRunLabel {
    $ui = $script:Ui
    if (-not $ui.Workflow) { return }
    $preview = $ui.FieldControls.ContainsKey('WhatIf') -and $ui.FieldControls.WhatIf.IsChecked -and
        -not ($ui.Workflow.Id -eq 'primary-users' -and 'NewPrimaryUser' -in $ui.Inactive -and 'RemovePrimaryUser' -in $ui.Inactive)
    $ui.Controls.RunButton.Content = if ($preview) { '_Run preview' } elseif ($ui.Workflow.Kind -eq 'Remote') { '_Connect to endpoint' } elseif ($ui.Workflow.Id -eq 'delete-win32-apps') { '_Find apps & continue' } elseif ($ui.Workflow.Risk -eq 'Read only') { '_Run report' } else { '_Run task' }
    $readOnly = $ui.Workflow.Risk -eq 'Read only' -or ($ui.Workflow.Id -eq 'primary-users' -and 'NewPrimaryUser' -in $ui.Inactive -and 'RemovePrimaryUser' -in $ui.Inactive)
    if ($readOnly) { $ui.Controls.RunButton.Content = '_Run report' }
    $officeGroups = $ui.Workflow.Id -eq 'm365-cloud-update' -and $ui.FieldControls.ContainsKey('IncludeWaveGroups') -and $ui.FieldControls.IncludeWaveGroups.IsChecked
    $hint = if ($preview) { 'PREVIEW - no remote changes. Script CSV exports may still be written.' } elseif ($officeGroups) { 'Read-only Office report with Graph group lookup. Connect on Home first; Graph access is checked before the separate Office sign-in. Both sign-ins must use the same tenant.' } elseif ($ui.Workflow.Kind -eq 'Office') { 'Read-only Office report. A separate Microsoft sign-in opens when run; Home Graph is not required. MSAL.PS must already be installed.' } elseif ($readOnly) { 'Read-only report. Connect on Home first; live access is checked before the script starts.' } elseif ($ui.Workflow.Kind -eq 'Remote') { 'Endpoint credentials are separate from Graph sign-in. Commands never run locally.' } else { 'Connect on Home first. Live access is checked before starting; original confirmations still apply.' }
    Set-EndpointLiveText $ui.Controls.ExecutionHint $hint
    if ($ui.Workflow.Id -in @('intune-script-device-status', 'quality-updates')) {
        $ui.Controls.RunButton.IsEnabled = [bool](-not $ui.Active -and -not $ui.Faulted -and $ui.ScriptPicker -and $ui.ScriptPicker.Selected)
    }
    elseif (-not $ui.Active) {
        $ui.Controls.RunButton.IsEnabled = -not $ui.Faulted
    }
}

function New-EndpointSection {
    param([string]$Title, [string]$Description, [switch]$Collapsed)
    $window = $script:Ui.Window
    $panel = [Windows.Controls.StackPanel]::new()
    if ($Description) {
        $hint = [Windows.Controls.TextBlock]::new(); $hint.Text = $Description; $hint.TextWrapping = 'Wrap'
        $hint.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Muted'); $hint.Margin = $window.FindResource('Spacing.Section.Description.Margin'); $null = $panel.Children.Add($hint)
    }
    if ($Collapsed) {
        $container = [Windows.Controls.Expander]::new(); $container.Header = $Title; $container.Content = $panel
        $panel.Margin = [Windows.Thickness]::new(8,8,4,0)
    }
    else {
        $container = [Windows.Controls.Border]::new()
        $container.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'Brush.Background.Elevated')
        $container.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'Brush.Border.Subtle')
        $container.BorderThickness = $window.FindResource('BorderThickness.Default'); $container.CornerRadius = $window.FindResource('CornerRadius.Large')
        $container.Padding = $window.FindResource('Padding.Section'); $container.Margin = $window.FindResource('Spacing.Panel.Margin')
        $heading = [Windows.Controls.TextBlock]::new(); $heading.Text = $Title; $heading.FontSize = $window.FindResource('Font.Size.Subheading')
        $heading.FontWeight = 'SemiBold'; $heading.Margin = $window.FindResource('Spacing.Section.Header.Margin')
        $panel.Children.Insert(0, $heading); $container.Child = $panel
    }
    $null = $script:Ui.Controls.Form.Children.Add($container)
    return $panel
}

function New-EndpointForm {
    $ui = $script:Ui
    $workflow = $ui.Controls.WorkflowList.SelectedItem
    if (-not $workflow) { return }
    $ui.Controls.HomePanel.Visibility = 'Collapsed'
    $ui.Controls.TaskPanel.Visibility = 'Visible'
    $ui.Workflow = $workflow
    $ui.Controls.WorkflowTitle.Text = $workflow.Title
    $ui.Controls.CategoryLabel.Text = $workflow.Category.ToUpperInvariant()
    Set-EndpointLiveText $ui.Controls.RiskLabel $workflow.Risk
    $ui.Controls.RiskBadge.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, $(if ($workflow.Risk -eq 'Read only') { 'Brush.Success' } elseif ($workflow.Risk -eq 'Destructive') { 'Brush.Error' } else { 'Brush.Warning' }))
    $ui.Controls.Description.Text = $workflow.Description
    if ($workflow.ConfiguredTenant -and $ui.GraphContext -and $ui.GraphContext.TenantId -ne $workflow.ConfiguredTenant) {
        $ui.Controls.Description.Text += "`r`nWARNING: the current Graph tenant differs from this script's configured tenant. Existing-context branches may reuse the current connection without switching tenants."
    }
    $ui.Controls.ScriptPath.Text = $workflow.Path
    $ui.Controls.ConfigureTab.IsSelected = $true
    $ui.Controls.FormScroll.ScrollToTop()
    $ui.Controls.RemoteTab.Visibility = if ($workflow.Kind -eq 'Remote' -or $ui.Remote.Connected) { 'Visible' } else { 'Collapsed' }
    $ui.Controls.WorkflowGuide.Text = switch ($workflow.Id) {
        'delete-win32-apps' { 'Enter app names or patterns, or use app IDs. Select specific versions when prompted, review assignment warnings, then confirm each deletion. Choose Preview to inspect the targets without deleting.' }
        'intune-assignment-win32-deployment-exports' { 'Enter part of an app name (for example Chrome) or a wildcard such as *Adobe*. Select one or more matching apps when prompted. Each selected app gets full device details, a one-row-per-device summary, and user deployment status. This is read-only reporting.' }
        'intune-script-device-status' { 'Choose remediation, platform script or both, then select Load scripts. Filter the list, choose exactly one script, and run the report. This reads Intune-reported device status and never runs the selected script.' }
        'quality-updates' { 'Connect on Home, then select Load policies. Filter the list, choose one expedited update policy, and run the read-only device status report.' }
        'add-members-to-group' { 'Choose a group and enter user UPNs or device names, or select a list file. Already-present direct members are skipped. If multiple Entra devices share a hostname, all matching devices are processed.' }
        'entra-user-lookup' { 'Enter names or choose a text file with one name per line. Exact matches show as Found. Multiple means several users share the name. PossibleMatch (same surname and first initial, for example Mike / Michael) must be reviewed before use.' }
        'remove-members-from-group' { 'Choose a group and supply user UPNs or device names. Use Preview to check matches without removing anyone. Only direct memberships can be removed; the user and device objects are not deleted.' }
        'primary-users' { 'Choose whether to read, assign or remove primary users, then select your devices. Each change still requires the original per-device approval.' }
        'remote-endpoint' { 'Enter a computer name and connect. Credentials are requested securely in the app. After connection, use the Remote workspace under Run & results.' }
        'm365-cloud-update' { 'Run and complete the separate Office sign-in. Report data opens with portal-style device rows; choose Rollout summary, Progress by wave or Release in the dataset selector for statistics. CSV reports default to TEMP, not the repository.' }
        default { 'Choose your inputs, review the options, then run. Live output and any reports appear under Run & results. Only inputs for the selected source are shown.' }
    }
    $ui.Controls.Form.Children.Clear()
    $ui.FieldControls = @{}; $ui.FieldRows = @{}; $ui.Selectors = @(); $ui.ScriptPicker = $null
    $targetPanel = if ($workflow.Id -eq 'quality-updates') { New-EndpointScriptPicker } else { New-EndpointSection 'Target & input' }
    foreach ($definition in $workflow.Selectors) {
        $label = [Windows.Controls.TextBlock]::new(); $label.Text = $definition.Label; $label.FontWeight = 'SemiBold'; $label.Margin = $ui.Window.FindResource('Spacing.Label.Margin')
        $combo = [Windows.Controls.ComboBox]::new()
        $combo.Margin = $ui.Window.FindResource('Spacing.Field.Margin')
        [Windows.Automation.AutomationProperties]::SetName($combo, $definition.Label)
        [Windows.Automation.AutomationProperties]::SetLabeledBy($combo, $label)
        [Windows.Automation.AutomationProperties]::SetHelpText($combo, "Choose a $($definition.Label.ToLowerInvariant()) source.")
        foreach ($option in $definition.Options) { $null = $combo.Items.Add($option.Name) }
        $combo.SelectedIndex = 0
        $null = $targetPanel.Children.Add($label); $null = $targetPanel.Children.Add($combo)
        $ui.Selectors += [pscustomobject]@{ Definition = $definition; Control = $combo }
        $combo.Add_SelectionChanged({ Update-EndpointFields })
    }
    $optionsPanel = $null; $reportPanel = $null; $idPanel = $null; $advancedPanel = $null; $modePanel = $null
    foreach ($field in $workflow.Fields) {
        $presentation = Get-EndpointFieldPresentation $field.Name
        if ($workflow.Id -eq 'intune-assignment-win32-deployment-exports' -and $field.Name -eq 'AppName') {
            $presentation.Label = 'App name, keyword or wildcard'
            $presentation.Hint = 'Enter part of the name, for example Chrome, or a pattern such as *Adobe*. Enter one search per line.'
        }
        if ($workflow.Id -eq 'intune-assignment-win32-deployment-exports' -and $field.Name -eq 'OutputPath') {
            $presentation.Label = 'Report folder'
            $presentation.Hint = 'A folder for each selected app''s device details, device summary and user-status CSVs. Defaults to TEMP.'
        }
        $row = [Windows.Controls.StackPanel]::new()
        $row.Margin = $ui.Window.FindResource('Spacing.Field.Margin')
        $label = [Windows.Controls.TextBlock]::new()
        $label.Text = $presentation.Label + $(if ($field.Required) { ' *' } else { '' })
        $label.FontWeight = 'SemiBold'; $label.Margin = $ui.Window.FindResource('Spacing.Label.Margin')
        $label.ToolTip = $field.Help
        if ($field.Type -ne [switch]) { $null = $row.Children.Add($label) }
        if ($field.Type -eq [switch]) {
            $control = [Windows.Controls.CheckBox]::new(); $control.IsChecked = [bool]$field.Default
            $control.Content = $presentation.Label
            if ($field.Name -in @('WhatIf','IncludeWaveGroups')) { $control.Add_Checked({ Update-EndpointRunLabel }); $control.Add_Unchecked({ Update-EndpointRunLabel }) }
        }
        elseif ($field.Name -eq 'UserColumn') {
            $control = [Windows.Controls.ComboBox]::new(); $control.IsEditable = $true
        }
        elseif ($workflow.Kind -eq 'Remote' -and $field.Name -eq 'Device') {
            $control = [Windows.Controls.ComboBox]::new(); $control.IsEditable = $true
            $presentation.Hint = 'Type a computer name, or choose one of the last 10 you connected to.'
            if ($ui.ContainsKey('RecentDevicesPath') -and $ui.RecentDevicesPath) {
                try { foreach ($device in Get-EndpointRecentDevices $ui.RecentDevicesPath) { $null = $control.Items.Add($device) } }
                catch { $presentation.Hint = "Recent devices could not be loaded; type the computer name. $($_.Exception.Message)" }
            }
        }
        elseif ($field.Choices.Count) {
            $control = [Windows.Controls.ComboBox]::new()
            if (-not $field.Required) { $null = $control.Items.Add('') }
            foreach ($choice in $field.Choices) { $null = $control.Items.Add($choice) }
            $control.SelectedItem = [string]$field.Default
        }
        else {
            $control = [Windows.Controls.TextBox]::new(); $control.Text = [string]$field.Default
            if ($field.Type.IsArray) { $control.Style = $ui.Window.FindResource('MultilineInput') }
        }
        [Windows.Automation.AutomationProperties]::SetName($control, $label.Text)
        if ($field.Type -ne [switch]) {
            [Windows.Automation.AutomationProperties]::SetLabeledBy($control, $label)
        }
        if ($field.Help) { [Windows.Automation.AutomationProperties]::SetHelpText($control, $field.Help) }
        $control.ToolTip = "-$($field.Name)`r`n$($field.Help)"
        $null = $row.Children.Add($control)
        if ($presentation.Hint -or $field.Type.IsArray) {
            $hint = [Windows.Controls.TextBlock]::new()
            $hint.Text = $presentation.Hint + $(if ($field.Type.IsArray -and $presentation.Hint -notmatch 'per line') { ' Enter one value per line.' } else { '' })
            $hint.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Muted'); $hint.FontSize = $ui.Window.FindResource('Font.Size.Secondary')
            $hint.TextWrapping = 'Wrap'; $hint.Margin = $ui.Window.FindResource('Spacing.Hint.Margin')
            $helpText = if ($field.Help) { "$($field.Help)`r`n$($hint.Text)" } else { $hint.Text }
            [Windows.Automation.AutomationProperties]::SetHelpText($control, $helpText)
            $null = $row.Children.Add($hint)
        }
        if ($field.Name -eq 'UserColumn') {
            $loadHeaders = [Windows.Controls.Button]::new(); $loadHeaders.Content = 'Read columns from file'; $loadHeaders.HorizontalAlignment = 'Left'
            $loadHeaders.Margin = $ui.Window.FindResource('Spacing.Browse.Margin')
            $loadHeaders.Add_Click({
                try {
                    $ui = $script:Ui
                    $columns = @(Get-EndpointUserColumns $ui.FieldControls.UserListPath.Text)
                    $ui.FieldControls.UserColumn.Items.Clear()
                    foreach ($column in $columns) { $null = $ui.FieldControls.UserColumn.Items.Add($column) }
                    $ui.FieldControls.UserColumn.SelectedIndex = 0
                }
                catch { Show-EndpointError $_ }
            })
            $null = $row.Children.Add($loadHeaders)
        }
        if ($field.Name -in @('OutputPath', 'ExportFolder', 'OutputFile', 'CsvPath', 'DeviceListPath', 'UserListPath')) {
            $browse = [Windows.Controls.Button]::new(); $browse.Content = 'Browse...'
            $browse.HorizontalAlignment = 'Left'
            $browse.Margin = $ui.Window.FindResource('Spacing.Browse.Margin')
            $browse.Tag = [pscustomobject]@{ Control = $control; Name = $field.Name }
            $browse.Add_Click({
                param($sender)
                try {
                    if ($sender.Tag.Name -in @('OutputPath', 'ExportFolder')) {
                        $picker = [Microsoft.Win32.OpenFolderDialog]::new()
                        if ($picker.ShowDialog($script:Ui.Window)) { $sender.Tag.Control.Text = $picker.FolderName }
                    }
                    elseif ($sender.Tag.Name -in @('OutputFile', 'CsvPath')) {
                        $picker = [Microsoft.Win32.SaveFileDialog]::new(); $picker.Filter = 'CSV report (*.csv)|*.csv'
                        if ($picker.ShowDialog($script:Ui.Window)) { $sender.Tag.Control.Text = $picker.FileName }
                    }
                    else {
                        $picker = [Microsoft.Win32.OpenFileDialog]::new()
                        $picker.Filter = if ($sender.Tag.Name -eq 'UserListPath' -and $script:Ui.Workflow.Id -in @('add-members-to-group','remove-members-from-group')) { 'User lists|*.txt;*.csv;*.xlsx|All files|*.*' } else { 'Text files|*.txt|All files|*.*' }
                        if ($picker.ShowDialog($script:Ui.Window)) { $sender.Tag.Control.Text = $picker.FileName }
                    }
                }
                catch { Show-EndpointError $_ }
            })
            $null = $row.Children.Add($browse)
        }
        $ui.FieldControls[$field.Name] = $control; $ui.FieldRows[$field.Name] = $row
        if ($field.Advanced -or $field.Name -eq 'Confirm') {
            if (-not $advancedPanel) { $advancedPanel = New-EndpointSection 'Advanced script controls' 'These options affect authentication, polling or confirmations. Leave defaults unless needed.' -Collapsed }
            $null = $advancedPanel.Children.Add($row)
        }
        elseif ($field.Name -eq 'AppId') {
            if (-not $idPanel) {
                $idPanel = [Windows.Controls.StackPanel]::new(); $idPanel.Margin = $ui.Window.FindResource('Spacing.Advanced.Margin')
                $idExpander = [Windows.Controls.Expander]::new(); $idExpander.Header = 'Use app object IDs (optional)'
                $idExpander.Content = $idPanel; $null = $targetPanel.Children.Add($idExpander)
            }
            $null = $idPanel.Children.Add($row)
        }
        elseif ($field.Name -eq 'WhatIf') {
            if (-not $modePanel) {
                $modePanel = New-EndpointSection 'Execution mode'
                $modePanel.Parent.Padding = $ui.Window.FindResource('Padding.ExecutionMode')
                $modePanel.Children[0].FontSize = $ui.Window.FindResource('Font.Size.Body')
                $modePanel.Children[0].Margin = $ui.Window.FindResource('Spacing.ExecutionMode.Header.Margin')
            }
            $row.Margin = [Windows.Thickness]::new(0); $control.Margin = $ui.Window.FindResource('Spacing.ExecutionMode.Control.Margin')
            $null = $modePanel.Children.Add($row)
        }
        elseif ($field.Name -in @('OutputPath','ExportFolder','NoExport','OutputFile','CsvPath','OpenReport','ExportCsv')) {
            if (-not $reportPanel) { $reportPanel = New-EndpointSection 'Report & export settings' 'Your script retains its original export behavior. These settings are optional unless marked required.' -Collapsed }
            $null = $reportPanel.Children.Add($row)
        }
        elseif ($field.Name -eq 'RemovePrimaryUser') { $null = $targetPanel.Children.Add($row) }
        elseif ($field.Type -eq [switch]) {
            if (-not $optionsPanel) { $optionsPanel = New-EndpointSection 'Options' }
            $null = $optionsPanel.Children.Add($row)
        }
        else { $null = $targetPanel.Children.Add($row) }
        if ($workflow.Id -eq 'intune-script-device-status' -and $field.Name -eq 'ScriptType') {
            New-EndpointScriptPicker -TypeControl $control
        }
    }
    if (-not $advancedPanel) { $advancedPanel = New-EndpointSection 'Script permissions & details' '' -Collapsed }
    $notes = [Windows.Controls.TextBlock]::new()
    $access = if ($workflow.Kind -eq 'Graph') {
        $policy = Get-EndpointGraphPolicy $workflow.Id
        $primaryNote = if ($workflow.Id -eq 'primary-users') { ' Changes require Intune Administrator.' } else { '' }
        "Home sign-in required. Active role check: $(($policy.RoleGroups | ForEach-Object { $_.AnyOf -join ' or ' }) -join '; ').${primaryNote} Where supported, preview uses the reader role check.`r`n"
    } else { '' }
    $notes.Text = "${access}Script permissions / limitations:`r`n$($workflow.Notes)"
    $notes.TextWrapping = 'Wrap'; $notes.Margin = $ui.Window.FindResource('Spacing.Notes.Margin')
    $null = $advancedPanel.Children.Add($notes)
    if ($modePanel) {
        $container = $modePanel.Parent
        $ui.Controls.Form.Children.Remove($container)
        $ui.Controls.Form.Children.Insert(0, $container)
    }
    $container = $advancedPanel.Parent
    $ui.Controls.Form.Children.Remove($container)
    $null = $ui.Controls.Form.Children.Add($container)
    Update-EndpointFields
    Write-EndpointUiRecord -Event 'TaskSelected'
    if (-not $ui.Active) { Set-EndpointLiveText $ui.Controls.Status "Selected - $($workflow.Title). Sign-in and permissions not verified." }
}

function Show-EndpointError {
    param([object]$ErrorRecord, [switch]$PrivateRemote, [switch]$NoActivityLog)
    $message = Protect-EndpointText $ErrorRecord
    if (-not $NoActivityLog) { Write-EndpointUiRecord -Event 'AppError' -State 'Error' -Message $message -PrivateRemote:$PrivateRemote }
    if ($script:Ui.TestMode) { throw $message }
    Add-EndpointActivity 'Error' $message
    $summary = ($message -split '\r?\n', 2)[0]
    $summary = if ($summary.Length -gt 180) { $summary.Substring(0, 180) + '... See Script output for details.' } else { $summary }
    Set-EndpointLiveText $script:Ui.Controls.Status $summary
    $null = [Windows.MessageBox]::Show($script:Ui.Window, $message, 'Endpoint Toolbox', 'OK', 'Error')
}

function Set-EndpointTheme {
    param([Parameter(Mandatory)][Windows.Window]$Window, [ValidateSet('Light','Dark')][string]$Theme)
    if (-not $Window.Resources.Contains('Theme.LightPalette')) {
        $light = @{}
        foreach ($key in @($Window.Resources.Keys)) {
            if ($key -is [string] -and $key.StartsWith('Color.')) { $light[$key] = $Window.Resources[$key] }
        }
        $Window.Resources['Theme.LightPalette'] = $light
    }
    $palette = if ($Theme -eq 'Dark') { $Window.Resources['Theme.DarkPalette'] } else { $Window.Resources['Theme.LightPalette'] }
    foreach ($key in $palette.Keys) {
        $Window.Resources[$key] = $palette[$key]
        $Window.Resources[$key.Replace('Color.', 'Brush.')] = [Windows.Media.SolidColorBrush]::new($palette[$key])
    }
    $Window.Resources['Theme.Current'] = $Theme
}

function Get-EndpointThemePreference {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'Light' }
    $preference = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $preference -or -not $preference.PSObject.Properties['Theme'] -or $preference.Theme -notin @('Light','Dark')) {
        throw 'The saved appearance preference is invalid. Expected Theme to be Light or Dark.'
    }
    return $preference.Theme
}

function Save-EndpointThemePreference {
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('Light','Dark')][string]$Theme)
    $null = New-Item -Path (Split-Path $Path -Parent) -ItemType Directory -Force -ErrorAction Stop
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [pscustomobject]@{ Theme = $Theme } | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction Stop } }
}

function ConvertTo-EndpointDnsSuffix {
    # Returns the normalized suffix (empty is allowed) or throws if it is not a plain DNS name.
    param([AllowNull()][string]$Value)
    $suffix = if ($Value) { $Value.Trim().TrimStart('.').TrimEnd('.') } else { '' }
    if ($suffix -and ($suffix.Length -gt 253 -or $suffix -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$')) {
        throw 'The DNS suffix must contain only letters, digits, hyphens and dots, for example corp.example.com.'
    }
    return $suffix
}

function Get-EndpointRemoteSettings {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ DnsSuffix = '' } }
    $saved = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $saved -or -not $saved.PSObject.Properties['DnsSuffix']) { throw 'The saved remote settings are invalid. Expected a DnsSuffix value.' }
    return [pscustomobject]@{ DnsSuffix = ConvertTo-EndpointDnsSuffix ([string]$saved.DnsSuffix) }
}

function Save-EndpointRemoteSettings {
    param([Parameter(Mandatory)][string]$Path, [AllowNull()][string]$DnsSuffix)
    $suffix = ConvertTo-EndpointDnsSuffix $DnsSuffix
    $null = New-Item -Path (Split-Path $Path -Parent) -ItemType Directory -Force -ErrorAction Stop
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [pscustomobject]@{ SchemaVersion = 1; DnsSuffix = $suffix } | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction Stop } }
    return $suffix
}

function Test-EndpointRecentDeviceName {
    param([AllowNull()][object]$Name)
    return $Name -is [string] -and $Name.Length -le 255 -and $Name -match '^[A-Za-z0-9][A-Za-z0-9._:-]*$'
}

function Get-EndpointRecentDevices {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [string[]]@() }
    $saved = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $saved -or -not $saved.PSObject.Properties['Devices']) { throw 'The saved recent device list is invalid. Expected a Devices list.' }
    return [string[]]@(@($saved.Devices) | Where-Object { Test-EndpointRecentDeviceName $_ } | Select-Object -First 10)
}

function Add-EndpointRecentDevice {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Device)
    $Device = $Device.Trim()
    if (-not (Test-EndpointRecentDeviceName $Device)) { return }
    $existing = try { Get-EndpointRecentDevices $Path } catch { [string[]]@() }
    $devices = [string[]]@(@($Device) + @($existing | Where-Object { $_ -ne $Device }) | Select-Object -First 10)
    $null = New-Item -Path (Split-Path $Path -Parent) -ItemType Directory -Force -ErrorAction Stop
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [pscustomobject]@{ SchemaVersion = 1; Devices = $devices } | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction Stop } }
    return $devices
}

function Initialize-EndpointTheme {
    $ui = $script:Ui
    Set-EndpointTheme $ui.Window Light
    try {
        if ($ui.ThemePath) { Set-EndpointTheme $ui.Window (Get-EndpointThemePreference $ui.ThemePath) }
    }
    catch { Show-EndpointError $_ }
    $ui.Controls.DarkModeToggle.IsChecked = $ui.Window.Resources['Theme.Current'] -eq 'Dark'
    $ui.ChangingTheme = $false
    $themeChanged = {
        $ui = $script:Ui
        if ($ui.ChangingTheme) { return }
        $ui.ChangingTheme = $true
        $previous = $ui.Window.Resources['Theme.Current']
        try {
            $theme = if ($ui.Controls.DarkModeToggle.IsChecked) { 'Dark' } else { 'Light' }
            if ($ui.ThemePath) { Save-EndpointThemePreference $ui.ThemePath $theme }
            Set-EndpointTheme $ui.Window $theme
        }
        catch {
            $ui.Controls.DarkModeToggle.IsChecked = $previous -eq 'Dark'
            Show-EndpointError $_
        }
        finally { $ui.ChangingTheme = $false }
    }
    $ui.Controls.DarkModeToggle.Add_Checked($themeChanged)
    $ui.Controls.DarkModeToggle.Add_Unchecked($themeChanged)
}

function Update-EndpointHistory {
    $ui = $script:Ui
    $table = [Data.DataTable]::new('Run history')
    foreach ($key in @('RunId','WorkflowId','StartUtc','EndUtc','State','Rows')) { $null = $table.Columns.Add($key) }
    if (Test-Path -LiteralPath $ui.HistoryPath) {
        $history = @(Get-Content -LiteralPath $ui.HistoryPath -ErrorAction Stop | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
        foreach ($record in $history) {
            $row = $table.NewRow()
            foreach ($column in $table.Columns) { $row[$column.ColumnName] = [string]$record.($column.ColumnName) }
            $table.Rows.Add($row)
        }
    }
    $ui.Settings.Controls.HistoryGrid.ItemsSource = $table.DefaultView
    Set-EndpointLiveText $ui.Settings.Controls.HistoryStatus $(if ($table.Rows.Count) { "$($table.Rows.Count) saved runs. Times are UTC." } else { 'No saved run metadata yet.' })
}

function New-EndpointSettingsWindow {
    param([Parameter(Mandatory)][Windows.Window]$Owner)
    $dialog = [Windows.Window]::new()
    $dialog.Title = 'Settings - Endpoint Toolbox'
    if ($Owner.IsLoaded) { $dialog.Owner = $Owner }
    $dialog.Width = [Math]::Min(1000, [Windows.SystemParameters]::WorkArea.Width)
    $dialog.Height = [Math]::Min(700, [Windows.SystemParameters]::WorkArea.Height)
    $dialog.MinWidth = [Math]::Min(600, $dialog.Width); $dialog.MinHeight = [Math]::Min(400, $dialog.Height)
    $dialog.WindowStartupLocation = 'CenterOwner'; $dialog.UseLayoutRounding = $true
    $dialog.SetResourceReference([Windows.Window]::BackgroundProperty, 'Brush.Background.Primary')
    $dialog.SetResourceReference([Windows.Window]::ForegroundProperty, 'Brush.Text.Primary')
    $dialog.FontFamily = $Owner.FindResource('Font.Family.UI')
    $dialog.FontSize = $Owner.FindResource('Font.Size.Body')
    $dialog.Resources.MergedDictionaries.Add($Owner.Resources)
    Set-EndpointWindowIcon $dialog
    $dialog.Content = [Windows.Markup.XamlReader]::Parse(@'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      Margin="{DynamicResource Spacing.Dialog.Margin}">
  <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TabControl Name="SettingsTabs" AutomationProperties.Name="Settings tabs">
    <TabItem Name="HistoryTab" Header="_History" AutomationProperties.Name="History">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <TextBlock Text="Local run history contains metadata only, not report data or full console output."
                   TextWrapping="Wrap" Foreground="{DynamicResource Brush.Text.Secondary}" Margin="{DynamicResource Spacing.Panel.Margin}"/>
        <WrapPanel Grid.Row="1" Margin="{DynamicResource Spacing.Panel.Margin}">
          <Button Name="HistoryButton" Content="_Refresh history" AutomationProperties.Name="Refresh history"/>
          <Button Name="ClearHistoryButton" Content="_Clear history" AutomationProperties.Name="Clear history"/>
        </WrapPanel>
        <DataGrid Name="HistoryGrid" Grid.Row="2" AutomationProperties.Name="Run history" AutoGenerateColumns="False">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Run ID" Binding="{Binding RunId}"/>
            <DataGridTextColumn Header="Workflow" Binding="{Binding WorkflowId}"/>
            <DataGridTextColumn Header="Started (UTC)" Binding="{Binding StartUtc}"/>
            <DataGridTextColumn Header="Ended (UTC)" Binding="{Binding EndUtc}"/>
            <DataGridTextColumn Header="State" Binding="{Binding State}"/>
            <DataGridTextColumn Header="Rows" Binding="{Binding Rows}"/>
          </DataGrid.Columns>
        </DataGrid>
        <TextBlock Name="HistoryStatus" Grid.Row="3" TextWrapping="Wrap" Margin="{DynamicResource Spacing.Hint.Margin}"
                   AutomationProperties.Name="History status" AutomationProperties.LiveSetting="Polite"/>
      </Grid>
    </TabItem>
    <TabItem Name="LogsTab" Header="_Logs" AutomationProperties.Name="Logs">
      <StackPanel>
        <TextBlock Text="Activity logs contain compact run events and diagnostics. Full script and remote output is saved only through the workspace save actions."
                   TextWrapping="Wrap" Foreground="{DynamicResource Brush.Text.Secondary}" Margin="{DynamicResource Spacing.Panel.Margin}"/>
        <Button Name="OpenActivityLogsButton" Content="Open activity _logs" HorizontalAlignment="Left" AutomationProperties.Name="Open activity logs"/>
        <TextBlock Text="Clearing run history does not delete activity logs or reports." TextWrapping="Wrap"
                   Foreground="{DynamicResource Brush.Text.Secondary}" Margin="{DynamicResource Spacing.Hint.Margin}"/>
      </StackPanel>
    </TabItem>
    <TabItem Name="RemoteTab" Header="_Remote" AutomationProperties.Name="Remote">
      <StackPanel>
        <TextBlock Text="Optional DNS suffix for the administrative share (UNC) opened by the Remote endpoint session, for example corp.example.com. When set, the share path is \\computer.suffix\C$. Leave empty to use the computer name as typed. A name that already contains a dot is used as is."
                   TextWrapping="Wrap" Foreground="{DynamicResource Brush.Text.Secondary}" Margin="{DynamicResource Spacing.Panel.Margin}"/>
        <Label Content="DNS _suffix (optional)" Target="{Binding ElementName=DnsSuffixBox}"/>
        <TextBox Name="DnsSuffixBox" MaxLength="253" HorizontalAlignment="Left" Width="360"
                 AutomationProperties.Name="DNS suffix" ToolTip="For example corp.example.com"/>
        <Button Name="SaveRemoteSettingsButton" Content="_Save" HorizontalAlignment="Left" Margin="{DynamicResource Spacing.Panel.Margin}"
                AutomationProperties.Name="Save remote settings"/>
        <TextBlock Name="RemoteSettingsStatus" TextWrapping="Wrap" Margin="{DynamicResource Spacing.Hint.Margin}"
                   AutomationProperties.Name="Remote settings status" AutomationProperties.LiveSetting="Polite"/>
      </StackPanel>
    </TabItem>
  </TabControl>
  <Button Name="CloseSettingsButton" Grid.Row="1" Content="C_lose" HorizontalAlignment="Right" Margin="{DynamicResource Spacing.Dialog.Buttons.Margin}"
          AutomationProperties.Name="Close settings"/>
</Grid>
'@)
    $controls = @{}
    foreach ($name in @('SettingsTabs','HistoryTab','LogsTab','HistoryButton','ClearHistoryButton','HistoryGrid','HistoryStatus','OpenActivityLogsButton','RemoteTab','DnsSuffixBox','SaveRemoteSettingsButton','RemoteSettingsStatus','CloseSettingsButton')) {
        $controls[$name] = $dialog.Content.FindName($name)
        if (-not $controls[$name]) { throw "Required settings control is missing: $name" }
    }
    $controls.HistoryButton.Add_Click({
        try { Update-EndpointHistory; Write-EndpointUiRecord -Event 'HistoryViewed' }
        catch { Show-EndpointError $_ }
    })
    $controls.ClearHistoryButton.Add_Click({
        try {
            if ($script:Ui.Active) { throw 'Wait for the running operation before clearing metadata.' }
            if (Test-Path -LiteralPath $script:Ui.HistoryPath) { Remove-Item -LiteralPath $script:Ui.HistoryPath -ErrorAction Stop }
            Update-EndpointHistory
            Set-EndpointLiveText $script:Ui.Settings.Controls.HistoryStatus 'Run metadata cleared. Activity logs and reports are unchanged.'
            Write-EndpointUiRecord -Event 'HistoryCleared'
        }
        catch { Show-EndpointError $_ }
    })
    $controls.OpenActivityLogsButton.Add_Click({
        try {
            if (-not $script:Ui.LogRoot) { throw 'Persistent logging is disabled in offline smoke tests.' }
            Invoke-Item -LiteralPath $script:Ui.LogRoot -ErrorAction Stop
        }
        catch { Show-EndpointError $_ }
    })
    $controls.SaveRemoteSettingsButton.Add_Click({
        try {
            if (-not $script:Ui.RemoteSettingsPath) { throw 'Persistent settings are disabled in offline smoke tests.' }
            $saved = Save-EndpointRemoteSettings $script:Ui.RemoteSettingsPath $script:Ui.Settings.Controls.DnsSuffixBox.Text
            $script:Ui.Settings.Controls.DnsSuffixBox.Text = $saved
            $message = if ($saved) { "Saved. UNC shares will use the suffix $saved." } else { 'Saved. UNC shares will use the computer name as typed.' }
            Set-EndpointLiveText $script:Ui.Settings.Controls.RemoteSettingsStatus $message
        }
        catch { Show-EndpointError $_ }
    })
    $controls.CloseSettingsButton.Add_Click({ $script:Ui.Settings.Window.Close() })
    $dialog.Add_KeyDown({ param($sender,$eventArgs) if ($eventArgs.Key -eq 'Escape') { $eventArgs.Handled = $true; $sender.Close() } })
    return @{ Window = $dialog; Controls = $controls }
}

function Show-EndpointSettings {
    try {
        if (-not $script:Ui.Settings) {
            $script:Ui.Settings = New-EndpointSettingsWindow $script:Ui.Window
            $script:Ui.Settings.Window.Add_Closed({ $script:Ui.Settings = $null })
        }
        $script:Ui.Settings.Window.Show()
        $null = $script:Ui.Settings.Window.Activate()
        $script:Ui.Settings.Controls.HistoryTab.IsSelected = $true
        if ($script:Ui.RemoteSettingsPath) {
            try { $script:Ui.Settings.Controls.DnsSuffixBox.Text = (Get-EndpointRemoteSettings $script:Ui.RemoteSettingsPath).DnsSuffix }
            catch { Set-EndpointLiveText $script:Ui.Settings.Controls.RemoteSettingsStatus "Saved remote settings could not be loaded. $($_.Exception.Message)" }
        }
        Update-EndpointHistory
        Write-EndpointUiRecord -Event 'HistoryViewed'
    }
    catch { Show-EndpointError $_ }
}

function Get-EndpointAppChoiceAnswer {
    param([object[]]$Candidates, [ValidateSet('Single','Multiple')][string]$Mode, [switch]$Skip)
    if ($Skip) {
        if ($Mode -eq 'Single') { throw 'This script requires one app; cancel the run instead of skipping.' }
        return ''
    }
    $selected = @($Candidates | Where-Object Selected)
    if (-not $selected.Count) { throw 'Select at least one app to continue.' }
    if ($Mode -eq 'Single' -and $selected.Count -ne 1) { throw 'Select exactly one app for this report.' }
    return ($selected.Index -join ',')
}

function Update-EndpointScriptChoiceList {
    $picker = $script:Ui.ScriptPicker
    if (-not $picker) { return }
    $filter = $picker.Search.Text.Trim()
    $visible = @($picker.Choices | Where-Object {
        -not $filter -or
        $_.DisplayName.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $_.ScriptType.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    $picker.Updating = $true
    try {
        $picker.List.ItemsSource = $null
        $picker.List.ItemsSource = $visible
        $selectedIndex = -1
        if ($picker.Selected) {
            for ($index = 0; $index -lt $visible.Count; $index++) {
                if ($visible[$index].Id -eq $picker.Selected.Id -and $visible[$index].ScriptType -eq $picker.Selected.ScriptType) {
                    $selectedIndex = $index
                    break
                }
            }
            if ($selectedIndex -lt 0) { $picker.Selected = $null }
        }
        $picker.List.SelectedIndex = $selectedIndex
    }
    finally { $picker.Updating = $false }
    if ($picker.Selected) {
        Set-EndpointLiveText $picker.Status "Selected: $($picker.Selected.Display). Run the report to retrieve its device status."
    }
    elseif ($picker.LoadedType) {
        $message = if (-not $picker.Choices.Count) { "Intune returned no $($picker.Plural)." }
            else { "$($visible.Count) $($picker.Plural) match. Select one $($picker.Singular) to enable the report." }
        Set-EndpointLiveText $picker.Status $message
    }
    else {
        Set-EndpointLiveText $picker.Status "Load $($picker.Plural) from Intune before selecting a report target."
    }
    Update-EndpointRunLabel
}

function Update-EndpointScriptSelection {
    $picker = $script:Ui.ScriptPicker
    if (-not $picker -or $picker.Updating) { return }
    $picker.Selected = $picker.List.SelectedItem
    if ($picker.Selected) {
        Set-EndpointLiveText $picker.Status "Selected: $($picker.Selected.Display). Run the report to retrieve its device status."
    }
    else {
        Set-EndpointLiveText $picker.Status "$($picker.List.Items.Count) $($picker.Plural) match. Select one $($picker.Singular) to enable the report."
    }
    Update-EndpointRunLabel
}

function Reset-EndpointScriptChoices {
    $picker = $script:Ui.ScriptPicker
    if (-not $picker) { return }
    $picker.LoadedType = ''
    $picker.Choices = @()
    $picker.Selected = $null
    $picker.Search.Clear()
    $picker.List.ItemsSource = $null
    $picker.List.IsEnabled = $false
    $picker.Search.IsEnabled = $false
    Set-EndpointLiveText $picker.Status "Load $($picker.Plural) from Intune before selecting a report target."
    Update-EndpointRunLabel
}

function Set-EndpointScriptChoices {
    param([Parameter(Mandatory)]$Data)
    $picker = $script:Ui.ScriptPicker
    if (-not $picker) { throw 'The Intune script picker is not available for the active workflow.' }
    $expectedType = if ($picker.TypeControl) { [string]$picker.TypeControl.SelectedItem } else { 'Policies' }
    if ($Data.ScriptType -ne $expectedType) { throw 'The loaded Intune list does not match the current picker.' }
    $choices = @($Data.Choices)
    foreach ($choice in $choices) {
        $id = [guid]::Empty
        if (-not [guid]::TryParse([string]$choice.Id, [ref]$id) -or
            [string]::IsNullOrWhiteSpace([string]$choice.DisplayName) -or
            ($picker.TypeControl -and $choice.ScriptType -notin @('Remediation', 'Platform script'))) {
            throw "Intune returned a $($picker.Singular) with invalid selection data."
        }
    }
    $picker.LoadedType = $expectedType
    $picker.Choices = $choices
    $picker.Selected = $null
    $picker.Search.IsEnabled = $true
    $picker.List.IsEnabled = $true
    Update-EndpointScriptChoiceList
}

function New-EndpointScriptPicker {
    param([Windows.Controls.ComboBox]$TypeControl)
    $ui = $script:Ui
    $singular = if ($TypeControl) { 'script' } else { 'policy' }
    $plural = if ($TypeControl) { 'scripts' } else { 'policies' }
    $panel = New-EndpointSection "Select an Intune $singular" "Load the available $plural, filter the list, and select one before running the read-only device status report."
    $load = [Windows.Controls.Button]::new()
    $load.Content = "Load $plural"
    $load.HorizontalAlignment = 'Left'
    $load.Margin = $ui.Window.FindResource('Spacing.Browse.Margin')
    [Windows.Automation.AutomationProperties]::SetName($load, "Load $plural")
    $load.Add_Click({ Invoke-EndpointScriptDiscovery })
    $null = $panel.Children.Add($load)

    $label = [Windows.Controls.TextBlock]::new()
    $label.Text = "Filter available $plural"
    $label.FontWeight = 'SemiBold'
    $label.Margin = $ui.Window.FindResource('Spacing.Label.Margin')
    $search = [Windows.Controls.TextBox]::new()
    $search.IsEnabled = $false
    $search.Margin = $ui.Window.FindResource('Spacing.Field.Margin')
    [Windows.Automation.AutomationProperties]::SetName($search, $label.Text)
    [Windows.Automation.AutomationProperties]::SetLabeledBy($search, $label)
    $search.Add_TextChanged({ Update-EndpointScriptChoiceList })
    $null = $panel.Children.Add($label)
    $null = $panel.Children.Add($search)

    $list = [Windows.Controls.ListBox]::new()
    $list.DisplayMemberPath = 'Display'
    $list.MaxHeight = $ui.Window.FindResource('Control.Height.SelectionGrid')
    $list.IsEnabled = $false
    $list.SetResourceReference([Windows.Controls.Control]::PaddingProperty, 'Padding.Control')
    [Windows.Controls.VirtualizingPanel]::SetIsVirtualizing($list, $true)
    [Windows.Controls.VirtualizingPanel]::SetVirtualizationMode($list, [Windows.Controls.VirtualizationMode]::Recycling)
    [Windows.Automation.AutomationProperties]::SetName($list, "Available Intune $plural")
    [Windows.Automation.AutomationProperties]::SetHelpText($list, "Select one $singular to enable the device status report.")
    $list.Add_SelectionChanged({ Update-EndpointScriptSelection })
    $null = $panel.Children.Add($list)

    $status = [Windows.Controls.TextBlock]::new()
    $status.TextWrapping = 'Wrap'
    $status.Margin = $ui.Window.FindResource('Spacing.Hint.Margin')
    $status.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Secondary')
    [Windows.Automation.AutomationProperties]::SetLiveSetting($status, [Windows.Automation.AutomationLiveSetting]::Polite)
    $null = $panel.Children.Add($status)
    $ui.ScriptPicker = [pscustomobject]@{
        TypeControl = $TypeControl; Load = $load; Search = $search; List = $list; Status = $status
        Singular = $singular; Plural = $plural
        Choices = @(); LoadedType = ''; Selected = $null; Updating = $false
    }
    if ($TypeControl) { $TypeControl.Add_SelectionChanged({ Reset-EndpointScriptChoices }) }
    Set-EndpointLiveText $status "Load $plural from Intune before selecting a report target."
    if (-not $TypeControl) { return $panel }
}

function Show-EndpointInput {
    param([object]$Request)
    $ui = $script:Ui
    $dialog = [Windows.Window]::new()
    $dialog.Title = $Request.Caption; $dialog.Owner = $ui.Window
    $appChoice = $Request.Kind -eq 'Text' -and $ui.Choice
    $width = if ($appChoice) { 1000 } elseif ($Request.Kind -in @('Credential','Secure')) { 440 } else { 580 }
    $dialog.Width = [Math]::Min($width, [Windows.SystemParameters]::WorkArea.Width - 40)
    $dialog.MaxWidth = [Windows.SystemParameters]::WorkArea.Width - 40
    $dialog.SizeToContent = 'Height'; $dialog.MaxHeight = [Windows.SystemParameters]::WorkArea.Height - 60
    $dialog.SetResourceReference([Windows.Window]::BackgroundProperty, 'Brush.Background.Primary')
    $dialog.SetResourceReference([Windows.Window]::ForegroundProperty, 'Brush.Text.Primary')
    $dialog.FontFamily = $ui.Window.FindResource('Font.Family.UI')
    $dialog.FontSize = $ui.Window.FindResource('Font.Size.Body')
    $dialog.Resources.MergedDictionaries.Add($ui.Window.Resources)
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Tag = [pscustomobject]@{ Accepted = $false }
    $panel = [Windows.Controls.StackPanel]::new(); $panel.Margin = $ui.Window.FindResource('Spacing.Dialog.Margin')
    $heading = [Windows.Controls.TextBlock]::new()
    $heading.Text = if ($Request.Kind -eq 'Credential') { 'Enter credentials' } else { 'Your script needs input' }
    $heading.FontSize = $ui.Window.FindResource('Font.Size.Heading'); $heading.FontWeight = 'SemiBold'
    $heading.Margin = $ui.Window.FindResource('Spacing.Dialog.Heading.Margin'); $heading.TextWrapping = 'Wrap'
    $null = $panel.Children.Add($heading)
    $message = [Windows.Controls.TextBlock]::new(); $message.Text = Protect-EndpointText $Request.Message
    $message.TextWrapping = 'Wrap'; $null = $panel.Children.Add($message)
    $candidateGrid = $null; $candidates = @(); $choiceMode = ''
    if ($Request.Kind -eq 'Text' -and $ui.Choice) {
        $choiceMode = $ui.Choice.Name
        $heading.Text = if ($ui.Active.WorkflowId -eq 'delete-win32-apps') { 'Choose apps to delete' } elseif ($choiceMode -eq 'Script') { 'Choose an Intune script' } elseif ($choiceMode -eq 'Single') { 'Choose an app to report on' } else { 'Choose apps to report on' }
        $message.Text = if ($choiceMode -eq 'Script') { 'Search the available remediations and platform scripts, select one row, then choose Use this script.' } elseif ($choiceMode -eq 'Single') { 'Select one row, then choose Use this app. This report runs for one app only.' } else { 'Check the apps you want to use, then choose Use selected apps. Nothing is selected automatically. Skip pattern continues without these matches.' }
        $candidateGrid = [Windows.Controls.DataGrid]::new(); $candidateGrid.AutoGenerateColumns = $false
        $candidateGrid.IsReadOnly = $choiceMode -in @('Single', 'Script'); $candidateGrid.Height = $ui.Window.FindResource('Control.Height.SelectionGrid')
        $candidateGrid.Margin = $ui.Window.FindResource('Spacing.Dialog.Grid.Margin')
        $candidateGrid.SelectionMode = 'Single'
        if ($choiceMode -eq 'Script') {
            $searchLabel = [Windows.Controls.TextBlock]::new(); $searchLabel.Text = 'Search scripts'; $searchLabel.FontWeight = 'SemiBold'
            $searchLabel.Margin = $ui.Window.FindResource('Spacing.Label.Margin')
            [Windows.Automation.AutomationProperties]::SetName($searchLabel, 'Search scripts')
            $searchBox = [Windows.Controls.TextBox]::new(); $searchBox.Margin = $ui.Window.FindResource('Spacing.Dialog.Text.Margin')
            [Windows.Automation.AutomationProperties]::SetName($searchBox, 'Search available Intune scripts')
            [Windows.Automation.AutomationProperties]::SetLabeledBy($searchBox, $searchLabel)
            [Windows.Automation.AutomationProperties]::SetHelpText($searchBox, 'Filter the list by script type, name or ID.')
            $null = $panel.Children.Add($searchLabel); $null = $panel.Children.Add($searchBox)
        }
        if ($choiceMode -eq 'Multiple') {
            $selectColumn = [Windows.Controls.DataGridTemplateColumn]::new(); $selectColumn.Header = 'Use'
            $selectColumn.CellTemplate = [Windows.Markup.XamlReader]::Parse('<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><CheckBox IsChecked="{Binding Selected,Mode=TwoWay,UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" AutomationProperties.Name="Select app" AutomationProperties.HelpText="Select this matching app"/></DataTemplate>')
            $candidateGrid.Columns.Add($selectColumn)
        }
        $columnNames = if ($choiceMode -eq 'Script') { @('Type','Name','Created','Id') } else { @('Name','Version','Created','Id') }
        foreach ($columnName in $columnNames) {
            $column = [Windows.Controls.DataGridTextColumn]::new(); $column.Header = $columnName
            $column.Binding = [Windows.Data.Binding]::new($columnName); $column.IsReadOnly = $true
            $candidateGrid.Columns.Add($column)
        }
        $index = 0
        $candidates = @($ui.Choice.Data | ForEach-Object {
            if ($choiceMode -eq 'Script') {
                [pscustomobject]@{ Selected = $false; Index = $index++; Type = $_.ScriptType; Name = $_.DisplayName; Version = ''; Created = $_.CreatedDateTime; Id = $_.Id }
            }
            else {
                [pscustomobject]@{ Selected = $false; Index = $index++; Type = ''; Name = $_.displayName; Version = $_.displayVersion; Created = $_.createdDateTime; Id = $_.id }
            }
        })
        if ($choiceMode -eq 'Script') {
            $candidateView = [Windows.Data.CollectionViewSource]::GetDefaultView($candidates)
            $candidateView.Filter = {
                param($candidate)
                $query = [string]$searchBox.Text
                if ([string]::IsNullOrWhiteSpace($query)) { return $true }
                $candidateText = "$($candidate.Type) $($candidate.Name) $($candidate.Id)"
                return $candidateText.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0
            }.GetNewClosure()
            $searchBox.Tag = [pscustomobject]@{ View = $candidateView; Grid = $candidateGrid }
            $searchBox.Add_TextChanged({ param($sender) $sender.Tag.View.Refresh(); $sender.Tag.Grid.SelectedIndex = -1 })
            $candidateGrid.ItemsSource = $candidateView
        }
        else { $candidateGrid.ItemsSource = $candidates }
        $candidateGrid.SelectedIndex = -1
        [Windows.Automation.AutomationProperties]::SetName($candidateGrid, $(if ($choiceMode -eq 'Script') { 'Available Intune scripts' } else { 'Matching apps' }))
        $null = $panel.Children.Add($candidateGrid)
        if ($choiceMode -eq 'Multiple') {
            $selectionButtons = [Windows.Controls.WrapPanel]::new()
            foreach ($selection in @('Select all','Clear selection')) {
                $button = [Windows.Controls.Button]::new(); $button.Content = $selection
                [Windows.Automation.AutomationProperties]::SetName($button, $selection)
                $button.Tag = [pscustomobject]@{ Rows = $candidates; Grid = $candidateGrid; Select = $selection -eq 'Select all' }
                $button.Add_Click({ param($sender) foreach ($row in $sender.Tag.Rows) { $row.Selected = $sender.Tag.Select }; $sender.Tag.Grid.Items.Refresh() })
                $null = $selectionButtons.Children.Add($button)
            }
            $null = $panel.Children.Add($selectionButtons)
        }
        $ui.Choice = $null
    }
    $text = $null; $password = $null; $usernameLabel = $null
    if ($Request.Kind -in @('Text', 'Credential') -and -not $candidateGrid) {
        if ($Request.Kind -eq 'Credential') {
            $usernameLabel = [Windows.Controls.TextBlock]::new(); $usernameLabel.Text = 'Username'; $usernameLabel.Margin = $ui.Window.FindResource('Spacing.Dialog.Username.Margin')
            $null = $panel.Children.Add($usernameLabel)
        }
        $text = [Windows.Controls.TextBox]::new()
        $text.Margin = if ($Request.Kind -eq 'Credential') { [Windows.Thickness]::new(0) } else { $ui.Window.FindResource('Spacing.Dialog.Text.Margin') }
        $text.ToolTip = if ($Request.Kind -eq 'Credential') { 'Privileged account username' } else { 'Response to the original script prompt.' }
        [Windows.Automation.AutomationProperties]::SetName($text, $(if ($Request.Kind -eq 'Credential') { 'Username' } else { 'Script response' }))
        if ($usernameLabel) { [Windows.Automation.AutomationProperties]::SetLabeledBy($text, $usernameLabel) }
        $null = $panel.Children.Add($text)
    }
    if ($Request.Kind -in @('Credential', 'Secure')) {
        $passwordLabel = [Windows.Controls.TextBlock]::new(); $passwordLabel.Text = 'Password'; $passwordLabel.Margin = $ui.Window.FindResource('Spacing.Dialog.Password.Margin')
        $null = $panel.Children.Add($passwordLabel)
        $password = [Windows.Controls.PasswordBox]::new()
        [Windows.Automation.AutomationProperties]::SetName($password, 'Password')
        [Windows.Automation.AutomationProperties]::SetLabeledBy($password, $passwordLabel)
        $null = $panel.Children.Add($password)
    }
    $buttons = [Windows.Controls.WrapPanel]::new()
    $buttons.Margin = $ui.Window.FindResource('Spacing.Dialog.Buttons.Margin')
    $validation = [Windows.Controls.TextBlock]::new(); $validation.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Error'); $validation.TextWrapping = 'Wrap'
    [Windows.Automation.AutomationProperties]::SetName($validation, 'Validation message')
    [Windows.Automation.AutomationProperties]::SetLiveSetting($validation, [Windows.Automation.AutomationLiveSetting]::Polite)
    $null = $panel.Children.Add($validation)
    if ($Request.Kind -eq 'Choice') {
        for ($i = 0; $i -lt $Request.Choices.Length; $i++) {
            $button = [Windows.Controls.Button]::new(); $button.Content = $Request.Choices[$i]
            $button.Tag = [pscustomobject]@{ Dialog = $dialog; Request = $Request; Answer = $i }
            $button.Add_Click({ param($sender) $sender.Tag.Request.Complete([int]$sender.Tag.Answer); $sender.Tag.Dialog.Tag.Accepted = $true; $sender.Tag.Dialog.Close() })
            $null = $buttons.Children.Add($button)
        }
    }
    else {
        $ok = [Windows.Controls.Button]::new()
        $ok.Content = if ($choiceMode -eq 'Script') { 'Use this script' } elseif ($choiceMode -eq 'Single') { 'Use this app' } elseif ($candidateGrid) { 'Use selected apps' } else { 'Continue' }
        $ok.Style = $ui.Window.FindResource('PrimaryButton')
        $ok.Tag = [pscustomobject]@{ Dialog = $dialog; Request = $Request; Text = $text; Password = $password; Grid = $candidateGrid; Validation = $validation; Rows = $candidates; Mode = $choiceMode }
        $ok.Add_Click({
            param($sender)
            $tag = $sender.Tag
            if ($tag.Request.Kind -eq 'Credential') {
                if ([string]::IsNullOrWhiteSpace($tag.Text.Text) -or $tag.Password.SecurePassword.Length -eq 0) { Set-EndpointLiveText $tag.Validation 'Enter a username and password, or cancel the run.'; return }
                $answer = [pscredential]::new($tag.Text.Text, $tag.Password.SecurePassword.Copy())
            }
            elseif ($tag.Request.Kind -eq 'Secure') { $answer = $tag.Password.SecurePassword.Copy() }
            elseif ($tag.Grid) {
                if ($tag.Mode -eq 'Script') {
                    if (-not $tag.Grid.SelectedItem) { Set-EndpointLiveText $tag.Validation 'Select one script to continue.'; return }
                    $answer = [string]$tag.Grid.SelectedItem.Index
                }
                elseif ($tag.Mode -eq 'Single') {
                    foreach ($row in $tag.Rows) { $row.Selected = $row -eq $tag.Grid.SelectedItem }
                    try { $answer = Get-EndpointAppChoiceAnswer $tag.Rows $tag.Mode }
                    catch { Set-EndpointLiveText $tag.Validation $_.Exception.Message; return }
                }
                else {
                    try { $answer = Get-EndpointAppChoiceAnswer $tag.Rows $tag.Mode }
                    catch { Set-EndpointLiveText $tag.Validation $_.Exception.Message; return }
                }
            }
            else {
                $answer = $tag.Text.Text
            }
            $tag.Request.Complete($answer); $tag.Dialog.Tag.Accepted = $true; $tag.Dialog.Close()
        })
        $null = $buttons.Children.Add($ok)
        if ($choiceMode -eq 'Multiple') {
            $skip = [Windows.Controls.Button]::new(); $skip.Content = 'Skip pattern'
            $skip.Tag = [pscustomobject]@{ Dialog = $dialog; Request = $Request }
            $skip.Add_Click({ param($sender) $sender.Tag.Request.Complete(''); $sender.Tag.Dialog.Tag.Accepted = $true; $sender.Tag.Dialog.Close() })
            $null = $buttons.Children.Add($skip)
        }
    }
    $cancel = [Windows.Controls.Button]::new(); $cancel.Content = 'Cancel run'; $cancel.IsCancel = $true
    [Windows.Automation.AutomationProperties]::SetName($cancel, 'Cancel run')
    $cancel.Tag = $dialog; $cancel.Add_Click({ param($sender) $sender.Tag.Close() })
    $null = $buttons.Children.Add($cancel); $null = $panel.Children.Add($buttons)
    $dialog.Tag | Add-Member -NotePropertyName RefusalButton -NotePropertyValue $cancel
    foreach ($button in $buttons.Children) {
        if ([string]$button.Content -match '^No($|\s)') { $dialog.Tag.RefusalButton = $button; break }
    }
    $dialog.Add_Loaded({ param($sender) $null = $sender.Tag.RefusalButton.Focus() })
    if (-not $candidateGrid -and $ui.Controls.Activity.Text) {
        $context = [Windows.Controls.Expander]::new(); $context.Header = 'Review recent script output and assignment warnings'
        $recent = [Windows.Controls.TextBox]::new(); $recent.IsReadOnly = $true
        $recent.MinHeight = $ui.Window.FindResource('Control.Height.RecentOutput.Minimum')
        $recent.MaxHeight = $ui.Window.FindResource('Control.Height.RecentOutput.Maximum')
        $recent.VerticalScrollBarVisibility = 'Auto'; $recent.TextWrapping = 'Wrap'
        $recent.Text = $ui.Controls.Activity.Text.Substring([Math]::Max(0, $ui.Controls.Activity.Text.Length - 8000))
        $context.Content = $recent; $panel.Children.Insert(2, $context)
    }
    $scroll = [Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.Content = $panel
    $dialog.Content = $scroll
    $null = $dialog.ShowDialog()
    if (-not $dialog.Tag.Accepted) { $Request.Cancel(); $ui.Active.Engine.Cancel() }
}

function Update-EndpointResults {
    $ui = $script:Ui
    $name = $ui.Controls.DatasetSelector.SelectedItem
    if (-not $name -or -not $ui.Datasets.ContainsKey([string]$name)) { $ui.Controls.ResultsGrid.ItemsSource = $null; return }
    $table = $ui.Datasets[[string]$name]
    $filter = $ui.Controls.ResultFilter.Text.Replace("'", "''").Replace('[', '[[]').Replace('%', '[%]').Replace('*', '[*]')
    $expressions = @($table.Columns | ForEach-Object { "CONVERT([$($_.ColumnName.Replace(']', '\]'))], 'System.String') LIKE '%$filter%'" })
    $table.DefaultView.RowFilter = if ($filter -and $expressions.Count) { $expressions -join ' OR ' } else { '' }
    if ($table.ExtendedProperties['PreparedForDesktop']) {
        $ui.Controls.ResultsGrid.ItemsSource = [EndpointToolbox.ReportRows]::new($table.DefaultView)
    } else { $ui.Controls.ResultsGrid.ItemsSource = $table.DefaultView }
}

function Invoke-EndpointRun {
    $ui = $script:Ui
    if ($ui.Active -or $ui.PendingBatches.Count) { return }
    $workflow = $ui.Workflow
    try {
        if ($ui.Faulted) { throw 'The desktop host is faulted. Restart the application before another operation.' }
        $workflow = $ui.Workflow
        if (-not $workflow) { throw 'Select a workflow.' }
        $values = @{}
        foreach ($field in $workflow.Fields) {
            $control = $ui.FieldControls[$field.Name]
            $values[$field.Name] = if ($field.Type -eq [switch]) { [bool]$control.IsChecked } elseif ($control -is [Windows.Controls.ComboBox] -and -not $control.IsEditable) { [string]$control.SelectedItem } else { $control.Text }
        }
        $arguments = Get-EndpointArguments $workflow $values $ui.Inactive
        if ($workflow.Id -eq 'intune-script-device-status') {
            $picker = $ui.ScriptPicker
            if (-not $picker -or -not $picker.Selected -or $picker.LoadedType -ne $arguments.ScriptType) {
                throw 'Load scripts from Intune, then select one script before running the report.'
            }
            $arguments.ScriptId = [string]$picker.Selected.Id
            $arguments.ScriptName = [string]$picker.Selected.DisplayName
            $arguments.ScriptType = [string]$picker.Selected.ScriptType
        }
        elseif ($workflow.Id -eq 'quality-updates') {
            if (-not $ui.ScriptPicker -or -not $ui.ScriptPicker.Selected) {
                throw 'Load policies from Intune, then select one policy before running the report.'
            }
            $arguments.PolicyId = [guid]$ui.ScriptPicker.Selected.Id
        }
        $requiresGraph = $workflow.Kind -eq 'Graph' -or ($workflow.Id -eq 'm365-cloud-update' -and $arguments['IncludeWaveGroups'])
        if ($requiresGraph -and -not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { throw 'Microsoft.Graph.Authentication is missing. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser' }
        if ($workflow.Kind -eq 'Remote') {
            if ($ui.Remote.Host.OwnedSession) { throw 'Disconnect the existing application-owned remote session first.' }
            if (-not (Get-Command Test-WSMan -ErrorAction Ignore)) { throw 'Test-WSMan is unavailable in this PowerShell installation.' }
            if ($arguments['UNC'] -and $ui.ContainsKey('RemoteSettingsPath') -and $ui.RemoteSettingsPath) {
                try { $dnsSuffix = (Get-EndpointRemoteSettings $ui.RemoteSettingsPath).DnsSuffix }
                catch { throw "Fix the DNS suffix under Settings > Remote, or clear it. $($_.Exception.Message)" }
                if ($dnsSuffix) { $arguments['DnsSuffix'] = $dnsSuffix }
            }
        }
        $originalWillConfirm = $workflow.Id -in @('delete-win32-apps', 'primary-users') -and $arguments['Confirm'] -ne $false
        if ($workflow.Risk -ne 'Read only' -and -not $arguments['WhatIf'] -and -not $originalWillConfirm -and
            -not ($workflow.Id -eq 'primary-users' -and -not $arguments['NewPrimaryUser'] -and -not $arguments['RemovePrimaryUser'])) {
            $review = foreach ($key in @($arguments.Keys | Sort-Object)) {
                if ($key -in @('Justification','Confirm','WhatIf')) { continue }
                $value = $arguments[$key]
                if ($value -is [array]) { "$key`: $($value.Count) item(s); first: $($value[0])" } else { "$key`: $value" }
            }
            $reviewText = $review -join "`r`n"
            $answer = [Windows.MessageBox]::Show($ui.Window, "This is a REAL operation: $($workflow.Title).`r`n$($workflow.Description)`r`n`r`n$reviewText`r`nContinue?", 'Confirm execution', 'YesNo', 'Warning', 'No')
            if ($answer -ne 'Yes') { return }
        }
        if ($workflow.Id -eq 'add-primary-devices-to-group' -and (Test-Path -LiteralPath $arguments.OutputFile)) {
            if ([Windows.MessageBox]::Show($ui.Window, "Overwrite $($arguments.OutputFile)? This also happens in preview.", 'Existing output file', 'YesNo', 'Warning', 'No') -ne 'Yes') { return }
        }
        $ui.Datasets = @{}; $ui.Controls.DatasetSelector.Items.Clear(); $ui.Controls.ResultsGrid.ItemsSource = $null
        $ui.Controls.ResultsTab.IsEnabled = $false
        $ui.Controls.Artifacts.Items.Clear(); $ui.Controls.Activity.Clear(); $ui.Choice = $null
        $engine = if ($workflow.Kind -eq 'Remote') { $ui.Remote } else { $ui.Graph }
        if ($workflow.Kind -eq 'Remote') { $ui.RemoteTarget = [string]$arguments['Device'] }
        $ui.Active = [pscustomobject]@{ Engine = $engine; WorkflowId = $workflow.Id; Operation = 'Report'; Start = [datetime]::UtcNow; RunId = [guid]::NewGuid().ToString(); Failures = $false; Warnings = $false; PendingApproval = $false; IsRemote = $workflow.Kind -eq 'Remote'; Completed = $false; State = '' }
        $ui.ActivitySummary = $null
        $ui.DiagnosticCount = 0
        Write-EndpointUiRecord -Event 'RunRequested' -State $(if ($arguments['WhatIf']) { 'Preview' } else { 'Running' }) -Required
        $requiredCommands = [string[]]@()
        if ($workflow.Id -eq 'intune-sync') {
            $requiredCommands = [string[]]@('Get-MgDeviceManagementManagedDevice', 'Sync-MgDeviceManagementManagedDevice')
        }
        $invocation = @{
            ScriptPath = $workflow.FullPath; ScriptArguments = $arguments; WorkflowId = $workflow.Id
            ActivityLogPath = $ui.LogRoot; RunId = $ui.Active.RunId
        }
        $runner = 'Invoke-WorkflowPresentation.ps1'
        if ($requiresGraph) {
            $runner = 'Invoke-GraphSession.ps1'
            $invocation.Action = 'Run'; $invocation.RequiredTenant = $workflow.ConfiguredTenant
        }
        $engine.RunFile((Join-Path $PSScriptRoot $runner), $invocation, $true, $requiredCommands)
        $ui.Controls.OutputTab.IsSelected = $true
        $ui.Controls.ActivityTab.IsSelected = $true
        Set-EndpointLiveText $ui.Controls.RunSummary "$($workflow.Title) - running. Script prompts will appear when input is needed."
        $ui.Controls.Progress.IsIndeterminate = $true
        Set-EndpointLiveText $ui.Controls.Status $(if ($requiresGraph) { 'Checking live Graph access and active roles before starting the script...' } else { 'Running. Cancel cannot roll back requests already accepted by remote services.' })
        $ui.Controls.RunButton.IsEnabled = $false; $ui.Controls.CancelButton.IsEnabled = $true
        $ui.Controls.SendCommandButton.IsEnabled = $false
        $ui.Controls.DisconnectButton.IsEnabled = $false
        $ui.Controls.Form.IsEnabled = $false; $ui.Controls.WorkflowList.IsEnabled = $false
        $ui.Controls.Search.IsEnabled = $false
    }
    catch {
        Write-EndpointUiRecord -Event 'RunStartFailed' -State 'Failed' -Message $_
        $ui.Active = $null
        Show-EndpointError $_ -PrivateRemote:($workflow -and $workflow.Kind -eq 'Remote')
    }
}

function Invoke-EndpointScriptDiscovery {
    $ui = $script:Ui
    if ($ui.Active -or $ui.PendingBatches.Count) { return }
    try {
        if ($ui.Faulted) { throw 'The desktop host is faulted. Restart the application before another operation.' }
        if (-not $ui.Workflow -or $ui.Workflow.Id -notin @('intune-script-device-status', 'quality-updates') -or -not $ui.ScriptPicker) {
            throw 'The Intune picker is not available for the selected workflow.'
        }
        if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { throw 'Microsoft.Graph.Authentication is missing. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser' }
        Reset-EndpointScriptChoices
        $picker = $ui.ScriptPicker
        $arguments = if ($picker.TypeControl) {
            @{ ScriptType = [string]$picker.TypeControl.SelectedItem; ListScripts = $true }
        } else { @{ ListPolicies = $true } }
        $ui.Active = [pscustomobject]@{
            Engine = $ui.Graph; WorkflowId = $ui.Workflow.Id; Operation = 'ScriptDiscovery'
            Start = [datetime]::UtcNow; RunId = [guid]::NewGuid().ToString()
            Failures = $false; Warnings = $false; PendingApproval = $false
            IsRemote = $false; Completed = $false; State = ''
        }
        $ui.ActivitySummary = $null
        $ui.DiagnosticCount = 0
        Write-EndpointUiRecord -Event 'DiscoveryRequested' -State 'Loading' -Required
        $ui.Graph.RunFile((Join-Path $PSScriptRoot 'Invoke-GraphSession.ps1'), @{
            Action = 'Run'; RequiredTenant = $ui.Workflow.ConfiguredTenant
            ScriptPath = $ui.Workflow.FullPath; WorkflowId = $ui.Workflow.Id
            ScriptArguments = $arguments
        }, $true)
        $ui.Controls.OutputTab.IsSelected = $true
        $ui.Controls.ActivityTab.IsSelected = $true
        Set-EndpointLiveText $ui.Controls.RunSummary "Loading Intune $($picker.Plural). This does not run a device status report."
        $ui.Controls.Progress.IsIndeterminate = $true
        Set-EndpointLiveText $ui.Controls.Status "Checking live Graph access and active roles before loading $($picker.Plural)..."
        $ui.Controls.RunButton.IsEnabled = $false; $ui.Controls.CancelButton.IsEnabled = $true
        $ui.Controls.SendCommandButton.IsEnabled = $false
        $ui.Controls.DisconnectButton.IsEnabled = $false
        $ui.Controls.Form.IsEnabled = $false; $ui.Controls.WorkflowList.IsEnabled = $false
        $ui.Controls.Search.IsEnabled = $false
    }
    catch {
        $ui.Active = $null
        Update-EndpointRunLabel
        Show-EndpointError $_
    }
}

function Show-EndpointHome {
    $script:Ui.Controls.TaskPanel.Visibility = 'Collapsed'
    $script:Ui.Controls.HomePanel.Visibility = 'Visible'
    Update-EndpointHomeControls
}

function Update-EndpointHomeControls {
    $ui = $script:Ui
    $enabled = -not $ui.Active -and -not $ui.Faulted
    foreach ($name in @('GraphConnectButton','GraphCheckButton','GraphDisconnectButton','GraphTenant')) { $ui.Controls[$name].IsEnabled = $enabled }
    $ui.Controls.GraphStopButton.IsEnabled = [bool]$ui.Active
    $ui.Controls.ReturnToTaskButton.IsEnabled = [bool]$ui.Workflow
}

function Show-EndpointGraphSession {
    param([Parameter(Mandatory)]$Session)
    $ui = $script:Ui
    $ui.GraphSession = $Session
    Set-EndpointLiveText $ui.Controls.GraphSessionStatus (Protect-EndpointText $Session.Message)
    if ($Session.Account) {
        $roles = if ($Session.State -ne 'Checked') { 'Unverified. See the access-check message above.' } elseif ($Session.Roles.Count) { $Session.Roles -join ', ' } else { 'None of the supported tenant-wide built-in roles are active.' }
        $ui.Controls.GraphSessionDetails.Text = "Account: $($Session.Account)`r`nTenant: $($Session.TenantId)`r`nLast live check (UTC): $($Session.CheckedUtc)`r`nActive roles: $roles`r`nDelegated scopes: $($Session.Scopes -join ', ')`r`nThis is a point-in-time result. Every Graph task checks again before starting."
    }
    else {
        $ui.Controls.GraphSessionDetails.Text = 'No current verified access result. Connect or check again from Home. If a PIM role was just activated, allow time for propagation; reconnect if access still fails.'
        if ($Session.State -eq 'Disconnected') {
            $ui.GraphContext=$null
            $ui.Controls.ContextLabel.Text='Disconnected from Graph via Home. Connect on Home before running a Graph task.'
        }
    }
}

function Invoke-EndpointGraphAction {
    param([ValidateSet('Connect','Check','Disconnect')][string]$Action)
    $ui = $script:Ui
    if ($ui.Active -or $ui.PendingBatches.Count) { return }
    try {
        if ($ui.Faulted) { throw 'The desktop host is faulted. Restart the application before another operation.' }
        if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) { throw 'Microsoft.Graph.Authentication is missing. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser' }
        $ui.Active = [pscustomobject]@{ Engine=$ui.Graph; WorkflowId="graph-session-$($Action.ToLowerInvariant())"; Start=[datetime]::UtcNow; RunId=[guid]::NewGuid().ToString(); Failures=$false; Warnings=$false; PendingApproval=$false; IsRemote=$false; Completed=$false; State='' }
        $ui.ActivitySummary=$null; $ui.DiagnosticCount=0
        Show-EndpointGraphSession ([pscustomobject]@{State='Unverified';Account='';Message="$Action in progress. Wait for the worker result; no task is running."})
        Write-EndpointUiRecord -Event 'RunRequested' -State 'CheckingGraph' -Required
        $ui.Graph.RunFile((Join-Path $PSScriptRoot 'Invoke-GraphSession.ps1'), @{
            Action=$Action
            TenantId=$ui.Controls.GraphTenant.Text.Trim()
        }, $true)
        $ui.Controls.RunButton.IsEnabled=$false; $ui.Controls.CancelButton.IsEnabled=$true
        $ui.Controls.Form.IsEnabled=$false; $ui.Controls.WorkflowList.IsEnabled=$false; $ui.Controls.Search.IsEnabled=$false
        $ui.Controls.SendCommandButton.IsEnabled=$false; $ui.Controls.DisconnectButton.IsEnabled=$false
        Update-EndpointHomeControls
    }
    catch {
        $ui.Active=$null
        Show-EndpointGraphSession ([pscustomobject]@{State='Unverified';Account='';Message="Graph action failed: $($_.Exception.Message)"})
        Update-EndpointHomeControls
        Show-EndpointError $_
    }
}

function Add-EndpointRows {
    param([string]$Name, [object]$Rows)
    $ui = $script:Ui
    if ($Rows -is [EndpointToolbox.PreparedReport]) {
        $table = $Rows.Table
        if ($ui.Datasets.ContainsKey($Name)) { throw "A prepared report was published more than once: $Name" }
        $ui.Datasets[$Name] = $table
        if (-not $ui.ContainsKey('ActivitySummary') -or $null -eq $ui.ActivitySummary) {
            $ui.Active.Failures = $ui.Active.Failures -or $Rows.HasFailures
            $ui.Active.Warnings = $ui.Active.Warnings -or $Rows.HasWarnings
            $ui.Active.PendingApproval = $ui.Active.PendingApproval -or $Rows.PendingApproval
        }
        $null = $ui.Controls.DatasetSelector.Items.Add($Name)
        $ui.Controls.ResultsTab.IsEnabled = $true
        return
    }
    if (-not $ui.Datasets.ContainsKey($Name)) {
        $table = [Data.DataTable]::new($Name)
        $ui.Datasets[$Name] = $table
        $null = $ui.Controls.DatasetSelector.Items.Add($Name)
        $ui.Controls.ResultsTab.IsEnabled = $true
    }
    if ($null -eq $Rows) { $Rows = [object[]]@() }
    $ui.PendingBatches.Enqueue([pscustomobject]@{ Name = $Name; Items = $Rows.GetEnumerator() })
}

function Stop-EndpointOperation {
    $ui = $script:Ui
    if (-not $ui.Active) { return }
    Write-EndpointUiRecord -Event 'CancellationRequested' -State 'Cancelling'
    $ui.Active.Engine.Cancel()
    $ui.PendingBatches.Clear()
    $ui.Choice = $null
    $ui.Controls.CancelButton.IsEnabled = $false
    $ui.Controls.Progress.IsIndeterminate = $true
    Set-EndpointLiveText $ui.Controls.Status 'Stopping worker; queued display output discarded. Existing results are partial. Waiting only for the current operation to stop.'
    Add-EndpointActivity 'Cancellation requested' 'Queued log/report rendering was discarded. Displayed data may be incomplete; files already saved remain available. Requests already submitted to remote services cannot be undone.'
}

function Update-EndpointRunTiming {
    param([switch]$Finished)
    $ui = $script:Ui
    $engine = $ui.Active.Engine
    $start = $engine.StartedUtc
    $end = $engine.FinishedUtc
    $startText = $start.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss.fff')
    $elapsed = $engine.Elapsed.ToString('c')
    $text = "Started: $startText | Worker elapsed: $elapsed"
    if ($end) {
        $ready = [datetime]::UtcNow
        $tail = $ready - $end
        $total = $engine.Elapsed + $tail
        $text = "Started: $startText | Worker ended: $($end.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss.fff')) | Worker runtime: $elapsed"
        $text += if ($Finished) { " | Display processing ended: $($ready.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss.fff'))" } else { ' | Preparing display...' }
        $text += " | After-worker display time: $($tail.ToString('c')) | Total: $($total.ToString('c'))"
    }
    $ui.Controls.RunTiming.Text = $text
    if ($Finished) { Add-EndpointActivity 'Run timing' $text -Remote:$ui.Active.IsRemote }
}

function Receive-EndpointEvents {
    $ui = $script:Ui
    if (-not $ui.Active -or $ui.ReceivingEvents) { return }
    Update-EndpointRemoteIndicator
    Update-EndpointHomeControls
    if ($ui.Faulted) {
        $null = $ui.Active.Engine.Poll()
        if (-not $ui.Active.Engine.Busy) {
            $ui.Active = $null
            Update-EndpointRemoteIndicator
            $ui.Controls.CancelButton.IsEnabled = $false
            Set-EndpointLiveText $ui.Controls.Status 'UI processing failed. Partial results may remain. Close and restart the application; do not assume remote operations were rolled back.'
        }
        return
    }
    $ui.ReceivingEvents = $true
    try {
        $ui.ActivityBuffer = [Text.StringBuilder]::new()
        $ui.RemoteBuffer = [Text.StringBuilder]::new()
        $phaseWatch = [Diagnostics.Stopwatch]::StartNew()
        $engine = $ui.Active.Engine
        $null = $engine.Poll()
        $homeOperation = $ui.Active.WorkflowId -like 'graph-session-*'
        if (-not $homeOperation) { Update-EndpointRunTiming }
        if ($engine.Host.IsStopping) {
            $ui.PendingBatches.Clear()
            $engine.Host.DiscardPendingPresentationEvents()
            if (-not $engine.Busy) { $ui.Active.Completed = $true; $ui.Active.State = 'Cancelled' }
        }
        $event = $null; $count = 0
        while ($count++ -lt 100 -and $phaseWatch.ElapsedMilliseconds -lt 10 -and $engine.Host.Events.TryDequeue([ref]$event)) {
            switch ($event.Kind) {
                'OperationSummary' {
                    $ui.ActivitySummary = $event.Data
                    if ($event.Data.Failed -gt 0) { $ui.Active.Failures = $true }
                    if ($event.Data.NotFound -gt 0 -or -not $event.Data.CountsComplete) { $ui.Active.Warnings = $true }
                    if ($event.Data.PendingApproval -gt 0) { $ui.Active.PendingApproval = $true }
                }
                { $_ -in @('Rows', 'Summary') } { Add-EndpointRows $event.Name $event.Data }
                'ScriptChoices' { Set-EndpointScriptChoices $event.Data }
                'Choice' {
                    if ($event.Name -eq 'Quality update policies') {
                        Set-EndpointScriptChoices ([pscustomobject]@{ ScriptType = 'Policies'; Choices = $event.Data })
                    }
                    else { $ui.Choice = $event }
                }
                'Prompt' { if (-not $event.Data.IsCompleted) { Show-EndpointInput $event.Data } }
                'Context' {
                    $ui.GraphContext = $event.Data
                    $ui.Controls.ContextLabel.Text = "Last observed Graph account: $($event.Data.Account) | Tenant: $($event.Data.TenantId) | Use Home for a live check; observed context alone does not verify permissions."
                    if ($ui.Workflow -and $ui.Workflow.ConfiguredTenant -and $event.Data.TenantId -ne $ui.Workflow.ConfiguredTenant) {
                        $ui.Active.Warnings = $true
                        Add-EndpointActivity 'Tenant mismatch' 'The observed Graph context differs from the script-configured tenant. Existing-context branches can reuse it without switching tenants.'
                    }
                }
                'GraphSession' { Show-EndpointGraphSession $event.Data }
                'Stage' {
                    if ($event.Name -eq 'Graph access checked') { Set-EndpointLiveText $ui.Controls.Status 'Access preflight passed. Running; cancellation cannot roll back requests already accepted by remote services.' }
                    Add-EndpointActivity $event.Name $event.Data -Remote:$ui.Active.IsRemote
                }
                'Artifact' {
                    if (Test-Path -LiteralPath ([string]$event.Data) -PathType Leaf) { $null = $ui.Controls.Artifacts.Items.Add([pscustomobject]@{ Display = "$($event.Name): $($event.Data)"; Path = [string]$event.Data }) }
                    else { $ui.Active.Warnings = $true; Add-EndpointActivity 'Missing artifact' "The generated file is no longer available: $($event.Data)" }
                }
                'Progress' {
                    $progress = $event.Data
                    if ($progress.PercentComplete -ge 0) { $ui.Controls.Progress.IsIndeterminate = $false; $ui.Controls.Progress.Value = $progress.PercentComplete }
                    Set-EndpointLiveText $ui.Controls.Status (Protect-EndpointText "$($progress.Activity) $($progress.StatusDescription)")
                }
                'Complete' { $ui.Active.Completed = $true; $ui.Active.State = if ($engine.Host.IsStopping) { 'Cancelled' } else { $event.Name } }
                'Error' {
                    $ui.Active.Failures = $true
                    Add-EndpointActivity $event.Name $event.Data -Remote:$ui.Active.IsRemote
                    if (-not $ui.ContainsKey('DiagnosticCount')) { $ui.DiagnosticCount = 0 }
                    if ($ui.DiagnosticCount++ -lt 20) { Write-EndpointUiRecord -Event 'TaskError' -State 'Error' -Message $event.Data }
                }
                'Warning' {
                    $ui.Active.Warnings = $true
                    Add-EndpointActivity $event.Name $event.Data -Remote:$ui.Active.IsRemote
                    if (-not $ui.ContainsKey('DiagnosticCount')) { $ui.DiagnosticCount = 0 }
                    if ($ui.DiagnosticCount++ -lt 20) { Write-EndpointUiRecord -Event 'TaskWarning' -State 'Warning' -Message $event.Data }
                }
                'Output' {
                    if ($event.Data -is [string]) { Add-EndpointActivity 'Output' $event.Data -Remote:$ui.Active.IsRemote }
                    elseif (-not ($event.Data.PSObject.TypeNames -match 'Microsoft.PowerShell.Commands.Internal.Format')) {
                        Add-EndpointActivity 'Output' $event.Data -Remote:$ui.Active.IsRemote
                    }
                }
                default { Add-EndpointActivity $event.Name $event.Data -Remote:$ui.Active.IsRemote }
            }
        }
        if ($ui.TestMode) { $ui.Timings.Events = [Math]::Max($ui.Timings.Events, $phaseWatch.ElapsedMilliseconds) }
        $watch = [Diagnostics.Stopwatch]::StartNew(); $rowCount = 0
        $interpretRowOutcomes = -not $ui.ContainsKey('ActivitySummary') -or $null -eq $ui.ActivitySummary
        while ($ui.PendingBatches.Count -and $watch.ElapsedMilliseconds -lt 10 -and $rowCount++ -lt 200) {
            $batch = $ui.PendingBatches.Peek()
            if (-not $batch.Items.MoveNext()) { $null = $ui.PendingBatches.Dequeue(); continue }
            $item = $batch.Items.Current
            if ($null -eq $item) { continue }
            $table = $ui.Datasets[$batch.Name]
            $properties = @($item.PSObject.Properties | Where-Object { $_.MemberType -in @('NoteProperty', 'Property', 'AliasProperty') })
            if (-not $properties.Count) { $properties = @([pscustomobject]@{ Name = 'Value'; Value = $item }) }
            foreach ($property in $properties) { if (-not $table.Columns.Contains($property.Name)) { $null = $table.Columns.Add($property.Name, [string]) } }
            $row = $table.NewRow()
            foreach ($property in $properties) {
                $row[$property.Name] = Protect-EndpointText $property.Value
                if ($interpretRowOutcomes) {
                    if ($property.Name -in @('Status', 'LoginStatus', 'EntraAction', 'AutopilotAction') -and $property.Value -in @('Failed', 'Error', 'DirectoryDeviceNotFound', 'Lookup failed')) { $ui.Active.Failures = $true }
                    if ($property.Name -eq 'Status' -and $property.Value -eq 'PendingApproval') { $ui.Active.PendingApproval = $true }
                    if ($property.Name -eq 'Status' -and $property.Value -in @('NotFound','NoEligibleDevice','Unresolved','NotConfirmed')) { $ui.Active.Warnings = $true }
                }
            }
            $table.Rows.Add($row)
        }
        if ($ui.TestMode) { $ui.Timings.Rows = [Math]::Max($ui.Timings.Rows, $watch.ElapsedMilliseconds) }
        $phaseWatch.Restart()
        if ($ui.Controls.DatasetSelector.SelectedIndex -lt 0 -and $ui.Controls.DatasetSelector.Items.Count) {
            $ui.Controls.DatasetSelector.SelectedIndex = 0
            if ($ui.TestMode) { $ui.Timings.Binding = [Math]::Max($ui.Timings.Binding, $phaseWatch.ElapsedMilliseconds) }
            return
        }
        if ($ui.TestMode) { $ui.Timings.Binding = [Math]::Max($ui.Timings.Binding, $phaseWatch.ElapsedMilliseconds) }
        $phaseWatch.Restart()
        if ($ui.Active.Completed -and $ui.PendingBatches.Count -eq 0 -and $engine.Host.Events.IsEmpty) {
            $scriptDiscovery = $ui.Active.PSObject.Properties['Operation'] -and $ui.Active.Operation -eq 'ScriptDiscovery'
            if ($ui.Active.WorkflowId -like 'graph-session-*' -and $ui.Active.State -eq 'Cancelled') {
                Show-EndpointGraphSession ([pscustomobject]@{State='Unverified';Account='';Message='Graph action cancelled. Check the connection again; no access result is current.'})
            }
            if ($scriptDiscovery) {
                $listLabel = "$($ui.ScriptPicker.Plural) list"
                $availableChoices = $ui.ScriptPicker.Choices.Count
                if ($ui.Active.State -eq 'Cancelled' -or $ui.Active.Failures) { Reset-EndpointScriptChoices }
                elseif (-not $ui.ScriptPicker.LoadedType) {
                    $ui.Active.Failures = $true
                    Add-EndpointActivity 'Error' "The worker finished without returning the Intune $listLabel."
                }
            }
            $state = if ($scriptDiscovery -and $ui.Active.State -eq 'Cancelled') { "$listLabel load cancelled" }
                elseif ($scriptDiscovery -and $ui.Active.Failures) { "$listLabel load failed" }
                elseif ($scriptDiscovery) { "$listLabel loaded ($availableChoices available)" }
                elseif ($ui.Active.State -eq 'Cancelled') { 'Cancelled; queued display output discarded, results may be incomplete' }
                elseif ($ui.Active.Failures) { 'Partial failure / failed; review datasets and diagnostics' }
                elseif ($ui.Active.PendingApproval) { 'Completed; one or more actions pending approval' }
                elseif ($ui.Active.Warnings) { 'Finished with warnings - review script output' } else { 'Script finished - review output' }
            $rows = 0
            if (-not $homeOperation -and -not $scriptDiscovery) { foreach ($table in $ui.Datasets.Values) { $rows += $table.Rows.Count } }
            $history = [ordered]@{ RunId = $ui.Active.RunId; WorkflowId = $ui.Active.WorkflowId; StartUtc = $ui.Active.Start.ToString('o'); EndUtc = [datetime]::UtcNow.ToString('o'); State = $state; Rows = $rows }
            $null = New-Item -Path (Split-Path $ui.HistoryPath -Parent) -ItemType Directory -Force
            $history | ConvertTo-Json -Compress | Add-Content -LiteralPath $ui.HistoryPath -Encoding utf8 -ErrorAction Stop
            if ($scriptDiscovery) {
                $status = if ($ui.Active.State -eq 'Cancelled') { "Loading the $listLabel was cancelled. No device status report was run." }
                    elseif ($ui.Active.Failures) { "The $listLabel could not be loaded. Review activity for the error, then try again." }
                    elseif (-not $availableChoices) { "Intune returned no $($ui.ScriptPicker.Plural)." }
                    else { "$availableChoices $($ui.ScriptPicker.Plural) loaded. Filter the list and select one before running the report." }
                if (-not $ui.Active.Failures -and $ui.Active.State -ne 'Cancelled' -and -not $ui.ScriptPicker.TypeControl) {
                    $ui.Controls.ConfigureTab.IsSelected = $true
                }
                Set-EndpointLiveText $ui.Controls.Status $status
            }
            else { Set-EndpointLiveText $ui.Controls.Status "$state | $rows data rows. Review script output for the original action outcomes and warnings." }
            $taskTitle = $ui.Catalog | Where-Object Id -eq $ui.Active.WorkflowId | Select-Object -ExpandProperty Title -First 1
            if (-not $taskTitle) { $taskTitle = $ui.Active.WorkflowId }
            if (-not $homeOperation) {
                $runSummary = if ($scriptDiscovery) { "$taskTitle`: $state. No device status report was run." } else { "$taskTitle`: $state." }
                if (-not $scriptDiscovery -and $ui.Active.WorkflowId -ne 'm365-cloud-update') { $runSummary += " $rows report rows. Script output is authoritative for action outcomes, skipped items and pending approvals." }
                Set-EndpointLiveText $ui.Controls.RunSummary $runSummary
            }
            $summary = if ($ui.ContainsKey('ActivitySummary')) { $ui.ActivitySummary } else { $null }
            if ($ui.Active.State -eq 'Cancelled' -and $summary) { $summary.CountsComplete = $false }
            if ($summary -and -not $homeOperation -and $ui.Active.WorkflowId -ne 'm365-cloud-update') { Set-EndpointLiveText $ui.Controls.RunSummary "$taskTitle`: $state. $(Format-EndpointOutcomeSummary $summary)" }
            $logState = $state
            if ($ui.Active.WorkflowId -eq 'remote-endpoint' -and $ui.Active.State -ne 'Cancelled') {
                $logState = if ($ui.Remote.Connected) { 'Connected' } else { 'ConnectionFailed' }
                if ($ui.Remote.Connected -and $ui.ContainsKey('RecentDevicesPath') -and $ui.RecentDevicesPath) {
                    try {
                        $recent = Add-EndpointRecentDevice $ui.RecentDevicesPath $ui.RemoteTarget
                        $deviceBox = if ($ui.Workflow -and $ui.Workflow.Id -eq 'remote-endpoint') { $ui.FieldControls['Device'] } else { $null }
                        if ($recent -and $deviceBox -is [Windows.Controls.ComboBox]) {
                            $typed = $deviceBox.Text
                            $deviceBox.Items.Clear(); foreach ($device in $recent) { $null = $deviceBox.Items.Add($device) }
                            $deviceBox.Text = $typed
                        }
                    }
                    catch { Add-EndpointActivity 'Warning' "The recent device list could not be saved. $($_.Exception.Message)" }
                }
            }
            if ($ui.Active.WorkflowId -eq 'remote-disconnect') {
                $logState = if ($ui.Remote.Connected) { 'DisconnectFailed' } else { 'Disconnected' }
            }
            Write-EndpointUiRecord -Event $(if ($scriptDiscovery) { 'DiscoveryFinished' } else { 'RunFinished' }) -State $logState -Summary $summary
            if ($rows -and -not $ui.Active.Failures -and $ui.Active.State -ne 'Cancelled') { $ui.Controls.ResultsTab.IsSelected = $true }
            if ($ui.Active.WorkflowId -eq 'remote-endpoint' -and $ui.Remote.Connected) { $ui.Controls.RemoteTab.IsSelected = $true }
            $ui.Controls.Progress.IsIndeterminate = $false; $ui.Controls.Progress.Value = 0
            $ui.Controls.RunButton.IsEnabled = $true; $ui.Controls.CancelButton.IsEnabled = $false
            $ui.Controls.Form.IsEnabled = $true; $ui.Controls.WorkflowList.IsEnabled = $true
            $ui.Controls.Search.IsEnabled = $true
            if (-not $homeOperation) { Update-EndpointRunTiming -Finished }
            $ui.Active = $null
            Update-EndpointRunLabel
            Update-EndpointHomeControls
            $ui.Controls.SendCommandButton.IsEnabled = $ui.Remote.Connected
            $ui.Controls.DisconnectButton.IsEnabled = $null -ne $ui.Remote.Host.OwnedSession
            $remoteStatus = if ($ui.Remote.Connected) { "CONNECTED to $($ui.RemoteTarget) | Supplied credentials: $($ui.Remote.Host.RemoteIdentity). Commands execute remotely, never as the Graph account." } else { 'Disconnected. Commands cannot run locally.' }
            Set-EndpointLiveText $ui.Controls.RemoteStatus $remoteStatus
        }
        if ($ui.TestMode) { $ui.Timings.Completion = [Math]::Max($ui.Timings.Completion, $phaseWatch.ElapsedMilliseconds) }
    }
    catch {
        $ui.Faulted = $true
        $ui.Controls.RunButton.IsEnabled = $false
        $ui.Controls.SendCommandButton.IsEnabled = $false
        $ui.Controls.DisconnectButton.IsEnabled = $false
        if ($ui.Active -and $ui.Active.Engine.Busy) { $ui.Active.Engine.Cancel() }
        Show-EndpointError "UI event processing failed. Restart the application before another operation. $($_.Exception.Message)"
    }
    finally {
        Update-EndpointRemoteIndicator
        $activity = $ui.ActivityBuffer
        $remote = $ui.RemoteBuffer
        $ui.ActivityBuffer = $null; $ui.RemoteBuffer = $null
        $ui.ReceivingEvents = $false
        if ($activity.Length) {
            $ui.Controls.Activity.AppendText($activity.ToString())
            $ui.Controls.Activity.ScrollToEnd()
        }
        if ($remote.Length) {
            $ui.Controls.RemoteOutput.AppendText($remote.ToString())
            $ui.Controls.RemoteOutput.ScrollToEnd()
        }
    }
}

function Start-EndpointToolboxUI {
    [CmdletBinding()]
    param([switch]$ValidateOnly, [switch]$SmokeTest)
    if (-not $IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.6') { throw 'Windows with PowerShell 7.6 or newer is required.' }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Launch with pwsh.exe -NoProfile -STA -File Start-EndpointToolboxUI.ps1' }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    if (-not ('EndpointToolbox.DesktopEngine' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Hosting\DesktopPowerShellHost.cs') }
    $bridgeVersion = [EndpointToolbox.DesktopEngine].GetField('PresentationVersion')
    if (-not $bridgeVersion -or $bridgeVersion.GetRawConstantValue() -ne 10) {
        throw 'An older desktop hosting bridge is loaded. Launch Start-EndpointToolboxUI.ps1 to open the updated application in a fresh PowerShell process.'
    }
    $catalog = @(Get-EndpointCatalog)
    Test-EndpointCatalogCoverage $catalog
    $remoteCommands = @(Get-EndpointRemoteCommands)
    Set-EndpointTaskbarIdentity
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'MainWindow.xaml')))
    Set-EndpointWindowIcon $window
    $workArea = [Windows.SystemParameters]::WorkArea
    $window.MinWidth = [Math]::Min($window.MinWidth, $workArea.Width)
    $window.MinHeight = [Math]::Min($window.MinHeight, $workArea.Height)
    $window.Width = [Math]::Min($window.Width, $workArea.Width)
    $window.Height = [Math]::Min($window.Height, $workArea.Height)
    if ($ValidateOnly -or $SmokeTest) {
        Set-EndpointTheme $window Dark
        Set-EndpointTheme $window Light
        $settings = New-EndpointSettingsWindow $window
        $settings.Window.Close()
    }
    if ($ValidateOnly) { $window.Close(); return $catalog }
    $logRoot = if ($SmokeTest) { '' } else { Join-Path $env:LOCALAPPDATA 'EndpointToolbox\Logs' }
    if ($logRoot) { Write-EndpointActivityRecord -LogRoot $logRoot -Event 'AppStarted' }
    $controls = @{}
    foreach ($name in @('ContextLabel','Status','Progress','Search','SettingsButton','DarkModeToggle','WorkflowList','WorkflowTitle','CategoryLabel','RiskBadge','RiskLabel','Description','ScriptPath','Form','FormScroll','WorkflowGuide','ExecutionHint','WorkspaceTabs','ConfigureTab','OutputTab','RunSummary','RunTiming','ActivityTab','ResultsTab','RunButton','CancelButton','DisconnectButton','SaveResultsButton','SaveLogButton','SaveRemoteLogButton','OpenArtifactButton','Tabs','DatasetSelector','ResultFilter','ResultsGrid','Activity','Artifacts','RemoteTab','RemoteStatus','RemoteCommandPicker','RemoteCommandDescription','RemoteCommand','SendCommandButton','RemoteOutput','RemoteBusyIndicator')) {
        $controls[$name] = $window.FindName($name)
        if (-not $controls[$name]) { throw "Required desktop control is missing: $name" }
    }
    foreach ($name in @('HomeButton','HomePanel','TaskPanel','GraphTenant','GraphConnectButton','GraphCheckButton','GraphDisconnectButton','GraphStopButton','OpenPimButton','GraphSessionStatus','GraphSessionDetails','ReturnToTaskButton')) {
        $controls[$name]=$window.FindName($name)
        if (-not $controls[$name]) { throw "Required Home control is missing: $name" }
    }
    $script:Ui = @{
        Window = $window; Controls = $controls; Settings = $null; Catalog = $catalog; Workflow = $null; FieldControls = @{}; FieldRows = @{}
        Selectors = @(); Inactive = @(); Datasets = @{}; PendingBatches = [Collections.Generic.Queue[object]]::new()
        Graph = [EndpointToolbox.DesktopEngine]::new(); Remote = [EndpointToolbox.DesktopEngine]::new()
        Active = $null; Choice = $null; ScriptPicker = $null; Timer = [Windows.Threading.DispatcherTimer]::new()
        HistoryPath = Join-Path $env:LOCALAPPDATA 'EndpointToolbox\history.jsonl'
        LogRoot = $logRoot
        ThemePath = if ($SmokeTest) { '' } else { Join-Path $env:LOCALAPPDATA 'EndpointToolbox\settings.json' }
        RecentDevicesPath = if ($SmokeTest) { '' } else { Join-Path $env:LOCALAPPDATA 'EndpointToolbox\recent-devices.json' }
        RemoteSettingsPath = if ($SmokeTest) { '' } else { Join-Path $env:LOCALAPPDATA 'EndpointToolbox\remote-settings.json' }
        ActivitySummary = $null; DiagnosticCount = 0
        TestMode = [bool]$SmokeTest
        RemoteTarget = ''
        Timings = @{ Events = 0; Rows = 0; Binding = 0; Completion = 0 }
        Faulted = $false
        ReceivingEvents = $false
        ActivityBuffer = $null; RemoteBuffer = $null
        GraphContext = $null
        GraphSession = $null
    }
    Initialize-EndpointTheme
    $controls.RemoteCommandPicker.ItemsSource = $remoteCommands
    $controls.RemoteCommandPicker.Add_SelectionChanged({
        $ui = $script:Ui
        $command = $ui.Controls.RemoteCommandPicker.SelectedItem
        if (-not $command) { return }
        $ui.Controls.RemoteCommand.Text = $command.Command
        $ui.Controls.RemoteCommandDescription.Text = $command.Description
    })
    $controls.WorkflowList.Add_SelectionChanged({ New-EndpointForm })
    Set-EndpointNavigation
    $controls.HomeButton.Add_Click({ Show-EndpointHome })
    $controls.ReturnToTaskButton.Add_Click({
        $script:Ui.Controls.HomePanel.Visibility='Collapsed'
        $script:Ui.Controls.TaskPanel.Visibility='Visible'
    })
    $controls.GraphConnectButton.Add_Click({ Invoke-EndpointGraphAction Connect })
    $controls.GraphCheckButton.Add_Click({ Invoke-EndpointGraphAction Check })
    $controls.GraphDisconnectButton.Add_Click({ Invoke-EndpointGraphAction Disconnect })
    $controls.GraphStopButton.Add_Click({ Stop-EndpointOperation })
    $controls.OpenPimButton.Add_Click({
        try { Start-Process 'https://entra.microsoft.com/#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/aadroles' -ErrorAction Stop }
        catch { Show-EndpointError $_ }
    })
    $controls.WorkflowList.Add_PreviewMouseLeftButtonUp({
        if ($script:Ui.Workflow) {
            $script:Ui.Controls.HomePanel.Visibility='Collapsed'
            $script:Ui.Controls.TaskPanel.Visibility='Visible'
        }
    })
    $controls.WorkflowList.Add_KeyDown({
        param($sender,$eventArgs)
        if ($eventArgs.Key -eq 'Return' -and $script:Ui.Workflow) {
            $script:Ui.Controls.HomePanel.Visibility='Collapsed'
            $script:Ui.Controls.TaskPanel.Visibility='Visible'
        }
    })
    Show-EndpointHome
    $script:Ui.Graph.CapturePipelineObjects = $true
    $script:Ui.Graph.FormatPipelineOutput = $true
    $script:Ui.Remote.FormatPipelineOutput = $true
    $script:Ui.Graph.Host.PrepareReportTables = $true
    $script:Ui.Remote.Host.PrepareReportTables = $true
    $script:Ui.Graph.SuppressScriptObjectOutput = $true
    $script:Ui.Remote.SuppressScriptObjectOutput = $true
    $controls.Search.Add_TextChanged({
        if ($script:Ui.Active) { return }
        Set-EndpointNavigation $script:Ui.Controls.Search.Text
    })
    $controls.RunButton.Add_Click({ Invoke-EndpointRun })
    $controls.CancelButton.Add_Click({ Stop-EndpointOperation })
    $controls.DatasetSelector.Add_SelectionChanged({ Update-EndpointResults })
    $controls.ResultFilter.Add_TextChanged({ try { Update-EndpointResults } catch { Show-EndpointError $_ } })
    $controls.OpenArtifactButton.Add_Click({
        try {
            $artifact = $script:Ui.Controls.Artifacts.SelectedItem
            if (-not $artifact) { throw 'Select a generated artifact first.' }
            Invoke-Item -LiteralPath $artifact.Path -ErrorAction Stop
            Write-EndpointUiRecord -Event 'ReportOpened'
        }
        catch { Show-EndpointError $_ }
    })
    $controls.SaveResultsButton.Add_Click({
        try {
            $name = $script:Ui.Controls.DatasetSelector.SelectedItem
            if (-not $name) { throw 'Select a dataset first.' }
            $picker = [Microsoft.Win32.SaveFileDialog]::new(); $picker.Filter = 'CSV report|*.csv'
            if ($picker.ShowDialog($script:Ui.Window)) {
                $table = $script:Ui.Datasets[[string]$name]
                $rows = foreach ($row in $table.DefaultView) {
                    $values = [ordered]@{}; foreach ($column in $table.Columns) { $values[$column.ColumnName] = $row[$column.ColumnName] }; [pscustomobject]$values
                }
                $rows | Export-Csv -LiteralPath $picker.FileName -NoTypeInformation -Encoding utf8 -ErrorAction Stop
                Write-EndpointUiRecord -Event 'ReportExported'
            }
        }
        catch { Show-EndpointError $_ }
    })
    $saveLogHandler = {
        try {
            $picker = [Microsoft.Win32.SaveFileDialog]::new(); $picker.Filter = 'Text log|*.txt'
            if ($picker.ShowDialog($script:Ui.Window)) {
                $log = if ($script:Ui.Controls.RemoteTab.IsSelected) { $script:Ui.Controls.RemoteOutput.Text } else { $script:Ui.Controls.Activity.Text }
                Set-Content -LiteralPath $picker.FileName -Value $log -Encoding utf8 -ErrorAction Stop
                Write-EndpointUiRecord -Event 'OutputSaved'
            }
        }
        catch { Show-EndpointError $_ }
    }
    $controls.SaveLogButton.Add_Click($saveLogHandler)
    $controls.SaveRemoteLogButton.Add_Click($saveLogHandler)
    $controls.SettingsButton.Add_Click({ Show-EndpointSettings })
    $controls.SendCommandButton.Add_Click({
        $ui = $script:Ui
        if ($ui.Active) { return }
        try {
            if ([string]::IsNullOrWhiteSpace($ui.Controls.RemoteCommand.Text)) { throw 'Enter a remote PowerShell command.' }
            $ui.Active = [pscustomobject]@{ Engine = $ui.Remote; WorkflowId = 'remote-command'; Start = [datetime]::UtcNow; RunId = [guid]::NewGuid().ToString(); Failures = $false; Warnings = $false; PendingApproval = $false; IsRemote = $true; Completed = $false; State = '' }
            $ui.ActivitySummary = $null; $ui.DiagnosticCount = 0
            $ui.Remote.RunCommand($ui.Controls.RemoteCommand.Text)
            Add-EndpointActivity 'Remote command submitted' $ui.Controls.RemoteCommand.Text -Remote
            $ui.Controls.RunButton.IsEnabled = $false; $ui.Controls.CancelButton.IsEnabled = $true; $ui.Controls.SendCommandButton.IsEnabled = $false
        }
        catch { $ui.Active = $null; Show-EndpointError $_ -NoActivityLog }
    })
    $controls.DisconnectButton.Add_Click({
        $ui = $script:Ui
        if ($ui.Active) { return }
        try {
            $ui.Active = [pscustomobject]@{ Engine = $ui.Remote; WorkflowId = 'remote-disconnect'; Start = [datetime]::UtcNow; RunId = [guid]::NewGuid().ToString(); Failures = $false; Warnings = $false; PendingApproval = $false; IsRemote = $true; Completed = $false; State = '' }
            $ui.ActivitySummary = $null; $ui.DiagnosticCount = 0
            Write-EndpointUiRecord -Event 'DisconnectRequested' -State 'Disconnecting'
            $ui.Remote.Disconnect()
            $ui.Controls.RunButton.IsEnabled = $false; $ui.Controls.CancelButton.IsEnabled = $true
        }
        catch { $ui.Active = $null; Show-EndpointError $_ -PrivateRemote }
    })
    $window.Add_Closing({
        param($sender, $eventArgs)
        if ($script:Ui.Active) {
            $eventArgs.Cancel = $true
            Stop-EndpointOperation
            Set-EndpointLiveText $script:Ui.Controls.Status 'Cancellation requested. Wait for completion, then close. Remote changes and logging may be partial.'
        }
    })
    $script:Ui.Timer.Interval = [timespan]::FromMilliseconds(50)
    $script:Ui.Timer.Add_Tick({ Receive-EndpointEvents })
    if (-not $SmokeTest) { $script:Ui.Timer.Start() }
    try {
        if ($SmokeTest) {
            if ($controls.HomePanel.Visibility -ne 'Visible' -or $controls.TaskPanel.Visibility -ne 'Collapsed' -or $script:Ui.GraphSession) { throw 'Startup must open Home without claiming verified Graph access.' }
            if (-not $script:Ui.Workflow -or -not $controls.WorkflowTitle.Text -or -not $controls.Form.Children.Count) { throw 'The initial task page was not populated at startup.' }
            foreach ($workflow in $catalog) {
                $controls.WorkflowList.SelectedItem = $workflow
                if ($controls.WorkflowTitle.Text -ne $workflow.Title) { throw "Task title was not updated for $($workflow.Id)." }
                if ($script:Ui.FieldControls.ContainsKey('WhatIf') -and $script:Ui.FieldControls.WhatIf.IsChecked) { throw "Preview was silently enabled for $($workflow.Id)." }
                foreach ($selector in $script:Ui.Selectors) {
                    for ($i = 0; $i -lt $selector.Control.Items.Count; $i++) {
                        $selector.Control.SelectedIndex = $i; Update-EndpointFields
                        foreach ($name in $script:Ui.Inactive) {
                            if ($script:Ui.FieldRows[$name].Visibility -ne 'Collapsed') { throw "Inactive input $name is still visible for $($workflow.Id)." }
                        }
                    }
                }
            }
            if ($controls.WorkflowList.Items.Groups.Count -ne @($catalog.Category | Select-Object -Unique).Count) { throw 'Sidebar categories are not grouped.' }
            Set-EndpointNavigation 'no-such-task-offline-fixture'
            if ($controls.RunButton.IsEnabled -or $script:Ui.Workflow) { throw 'An empty search retained an executable task.' }
            Set-EndpointNavigation
            $script:Ui.HistoryPath = Join-Path $env:TEMP "EndpointToolbox-smoke-$([guid]::NewGuid()).jsonl"
            $script:Ui.Active = [pscustomobject]@{ Engine = $script:Ui.Graph; WorkflowId = 'offline-smoke'; Start = [datetime]::UtcNow; RunId = [guid]::NewGuid().ToString(); Failures = $false; Warnings = $false; PendingApproval = $false; IsRemote = $false; Completed = $false; State = '' }
            $script:Ui.Graph.RunFile((Join-Path $PSScriptRoot 'Tests\Fixtures\HostFixture.ps1'), @{ Mode = 'Rows'; Count = 100000 }, $true)
            $maxTick = 0; $total = [Diagnostics.Stopwatch]::StartNew()
            while ($script:Ui.Active) {
                $tick = [Diagnostics.Stopwatch]::StartNew()
                Receive-EndpointEvents
                $maxTick = [Math]::Max($maxTick, $tick.ElapsedMilliseconds)
                if ($total.Elapsed.TotalMinutes -gt 3) { throw 'Offline desktop smoke test timed out.' }
            }
            $table = $script:Ui.Datasets['Large fixture']
            if ($table.Rows.Count -ne 100000) { throw "Expected 100000 rows, received $($table.Rows.Count)." }
            if ($maxTick -gt 250) { throw "UI batching exceeded the 250 ms acceptance target: $maxTick ms. Stages: $($script:Ui.Timings | ConvertTo-Json -Compress)" }
            if ($total.Elapsed.TotalSeconds -gt 10) { throw "Preparing and binding 100000 fixture rows exceeded 10 seconds: $($total.Elapsed.TotalSeconds)." }
            [pscustomobject]@{ WorkflowsRendered = $catalog.Count; Rows = $table.Rows.Count; MaxTickMilliseconds = $maxTick; TotalSeconds = [Math]::Round($total.Elapsed.TotalSeconds, 2); Stages = $script:Ui.Timings }
        }
        else { $null = $window.ShowDialog() }
    }
    finally {
        $script:Ui.Timer.Stop()
        if ($script:Ui.Settings) { $script:Ui.Settings.Window.Close() }
        try { $script:Ui.Remote.Dispose() } finally { $script:Ui.Graph.Dispose(); Write-EndpointUiRecord -Event 'AppClosed' }
        if ($SmokeTest -and (Test-Path -LiteralPath $script:Ui.HistoryPath)) { Remove-Item -LiteralPath $script:Ui.HistoryPath -ErrorAction Stop }
    }
}

function Set-EndpointWindowIcon {
    param([Parameter(Mandatory)] [System.Windows.Window]$Window)
    $iconPath = Join-Path $PSScriptRoot 'endpoint-toolbox-32.png'
    if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
        throw "The application window icon is missing: $iconPath"
    }
    $icon = [Windows.Media.Imaging.BitmapImage]::new()
    $icon.BeginInit()
    $icon.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $icon.UriSource = [Uri]::new($iconPath, [UriKind]::Absolute)
    $icon.EndInit()
    $icon.Freeze()
    $Window.Icon = $icon
}

function Set-EndpointTaskbarIdentity {
    $identityType = 'EndpointToolbox.DesktopTaskbarIdentity' -as [type]
    if (-not $identityType) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace EndpointToolbox {
    public static class DesktopTaskbarIdentity {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int GetCurrentProcessExplicitAppUserModelID(out IntPtr appId);

        public static void Set(string appId) {
            Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(appId));
        }

        public static string Get() {
            IntPtr appId;
            Marshal.ThrowExceptionForHR(GetCurrentProcessExplicitAppUserModelID(out appId));
            try {
                return Marshal.PtrToStringUni(appId);
            }
            finally {
                Marshal.FreeCoTaskMem(appId);
            }
        }
    }
}
'@
        $identityType = 'EndpointToolbox.DesktopTaskbarIdentity' -as [type]
    }
    $identityType::Set('HillCraft.EndpointToolbox')
}

Export-ModuleMember -Function Start-EndpointToolboxUI, Get-EndpointCatalog, Test-EndpointCatalogCoverage, Get-EndpointArguments, Protect-EndpointText
