Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ActivityLogging.ps1')
. (Join-Path $PSScriptRoot 'GraphSession.ps1')
. (Join-Path $PSScriptRoot 'Settings.ps1')

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

function Update-EndpointSignInPagingControls {
    $ui = $script:Ui
    if (-not $ui.Controls['SignInPagingActions']) { return }
    $paging = $ui['SignInPaging']
    $visible = $ui.Workflow -and $ui.Workflow.Id -eq 'user-sign-in-history' -and $paging
    $ui.Controls.SignInPagingActions.Visibility = if ($visible) { 'Visible' } else { 'Collapsed' }
    $enabled = $visible -and $paging.HasMore -and -not $ui.Active -and -not $ui.Faulted
    $ui.Controls.LoadMoreSignIns.IsEnabled = [bool]$enabled
    $ui.Controls.RetrieveAllSignIns.IsEnabled = [bool]$enabled
    if ($visible) {
        Set-EndpointLiveText $ui.Controls.SignInPagingStatus $(if ($paging.HasMore) { "Incomplete: $($paging.Received) events read; more pages available." } else { "$($paging.Received) events read; no more pages." })
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

function Update-EndpointRemoteCommandSelection {
    $ui = $script:Ui
    if ($ui.RemoteCommandSelectionChanging) { return }
    $command = $ui.Controls.RemoteCommandPicker.SelectedItem
    if (-not $command) { return }
    $original = if ($ui.RemoteCommandSelection) { $ui.RemoteCommandSelection.Command } else { '' }
    if ($ui.Controls.RemoteCommand.Text -cne $original -and
        -not (Confirm-EndpointAction $ui.Window 'Replace the edited command with the selected saved command?' 'Replace remote command')) {
        $ui.RemoteCommandSelectionChanging = $true
        try { $ui.Controls.RemoteCommandPicker.SelectedItem = $ui.RemoteCommandSelection }
        finally { $ui.RemoteCommandSelectionChanging = $false }
        return
    }
    $ui.RemoteCommandSelection = $command
    $ui.Controls.RemoteCommand.Text = $command.Command
    $ui.Controls.RemoteCommandDescription.Text = $command.Description
}

function Get-EndpointCatalog {
    param(
        [string]$CatalogPath = (Join-Path $PSScriptRoot 'WorkflowCatalog.psd1'),
        [string]$ReportFolder = (Join-Path $env:TEMP 'endpoint-toolbox')
    )
    $ReportFolder = ConvertTo-EndpointReportFolder $ReportFolder
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
        $parameterNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
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
                if ($default -and $name -in @('OutputPath','ExportFolder')) { $default = $ReportFolder }
                elseif ($default -and $name -in @('OutputFile','CsvPath')) { $default = Join-Path $ReportFolder ([IO.Path]::GetFileName($default)) }
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
        if ($kind -notin @('Graph', 'Remote', 'Office', 'Azure', 'Local')) { throw "Invalid execution kind for $($entry.Id)." }
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
    # The legacy device-only CLI remains available outside the consolidated membership task.
    $standaloneOnly = Join-Path $root 'Intune\Devices\Get-EntraGroupDevices.ps1'
    $actual = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File |
        Where-Object { -not $_.FullName.StartsWith("$PSScriptRoot\", [StringComparison]::OrdinalIgnoreCase) -and $_.FullName -ne $standaloneOnly } |
        ForEach-Object FullName)
    $difference = @(Compare-Object -ReferenceObject $actual -DifferenceObject @($Catalog.FullPath))
    if ($difference.Count) { throw "Unintegrated or missing business scripts: $($difference.InputObject -join ', ')" }
}

function Throw-EndpointFieldError {
    param([string]$Field, [string]$Message)
    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['EndpointField'] = $Field
    throw $exception
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
            if ($field.Required) { Throw-EndpointFieldError $field.Name "$($field.Name) is required." }
            if ($field.Default -and $field.Name -in @('OutputPath','ExportFolder','OutputFile','CsvPath')) {
                $arguments[$field.Name] = $field.Default
            }
            if ($field.Type.IsArray -and $Values.ContainsKey($field.Name) -and @($field.Default).Count) {
                $arguments[$field.Name] = [string[]]@()
            }
            continue
        }
        $value = ([string]$value).Trim()
        if ($field.Choices.Count -and $value -notin $field.Choices) { Throw-EndpointFieldError $field.Name "Invalid $($field.Name) selection." }
        if ($field.Type -eq [int]) {
            $number = 0
            if (-not [int]::TryParse($value, [ref]$number) -or $number -lt 1) { Throw-EndpointFieldError $field.Name "$($field.Name) must be a positive whole number." }
            if ($field.Name -in @('Days', 'LookbackDays') -and $Workflow.Id -in @('stale-synced-devices', 'add-primary-devices-to-group') -and $number -gt 3650) { Throw-EndpointFieldError $field.Name "$($field.Name) cannot exceed 3650." }
            if ($Workflow.Id -eq 'user-sign-in-history' -and $field.Name -eq 'LookbackDays' -and $number -gt 30) { Throw-EndpointFieldError $field.Name 'Choose a lookback between 1 and 30 days.' }
            if ($Workflow.Id -eq 'm365-cloud-update' -and $field.Name -eq 'PageSize' -and $number -gt 200) { Throw-EndpointFieldError $field.Name 'PageSize cannot exceed 200.' }
            if ($Workflow.Id -eq 'wufb-report' -and $field.Name -eq 'LookbackDays' -and $number -gt 90) { Throw-EndpointFieldError $field.Name 'Choose a lookback between 1 and 90 days.' }
            if ($Workflow.Id -eq 'wufb-report' -and $field.Name -eq 'StaleDays' -and $number -gt 28) { Throw-EndpointFieldError $field.Name 'Choose a stale threshold between 1 and 28 days.' }
            $value = $number
        }
        elseif ($field.Type.IsArray) {
            $value = [string[]]@($value -split '\r?\n' | ForEach-Object Trim | Where-Object { $_ })
            if ($field.Type -eq [guid[]]) {
                foreach ($id in $value) {
                    $parsed = [guid]::Empty
                    if (-not [guid]::TryParse($id, [ref]$parsed)) { Throw-EndpointFieldError $field.Name "$($field.Name) must contain valid GUIDs." }
                }
                $value = [guid[]]$value
            }
        }
        if ($field.Name -in @('GroupId', 'AppId', 'WorkspaceId', 'AzureTenantId')) {
            foreach ($id in @($value)) {
                $parsed = [guid]::Empty
                if (-not [guid]::TryParse($id, [ref]$parsed)) { Throw-EndpointFieldError $field.Name "$($field.Name) must contain valid GUIDs." }
                if ($field.Name -in @('WorkspaceId','AzureTenantId') -and $parsed -eq [guid]::Empty) { Throw-EndpointFieldError $field.Name "$($field.Name) cannot be an empty GUID." }
            }
        }
        if ($Workflow.Id -eq 'wufb-report' -and $field.Name -eq 'TargetKB' -and $value -notmatch '^(?i:KB)?[0-9]{6,8}$') {
            Throw-EndpointFieldError $field.Name 'Enter an exact KB number, for example KB5132043.'
        }
        if ($field.Name -in @('DeviceListPath', 'UserListPath', 'BeforeCsv', 'AfterCsv') -and -not (Test-Path -LiteralPath $value -PathType Leaf)) { Throw-EndpointFieldError $field.Name "Input file does not exist: $value" }
        $arguments[$field.Name] = $value
    }
    if ($arguments['NewPrimaryUser'] -and $arguments['RemovePrimaryUser']) { throw 'Assign and remove primary user are mutually exclusive.' }
    if ($Workflow.Id -eq 'primary-users' -and 'RemovePrimaryUser' -in $Inactive -and 'NewPrimaryUser' -notin $Inactive -and -not $arguments['NewPrimaryUser']) { Throw-EndpointFieldError 'NewPrimaryUser' 'Enter the new primary user UPN, or choose Read primary users.' }
    if ($Workflow.Id -eq 'discovered-apps') {
        if ('EntraGroup' -in $Inactive -and 'Device' -notin $Inactive -and -not $arguments['Device']) {
            Throw-EndpointFieldError 'Device' 'Enter an exact Intune device name or Intune managed device ID.'
        }
        if ('Device' -in $Inactive -and 'EntraGroup' -notin $Inactive -and -not $arguments['EntraGroup']) {
            Throw-EndpointFieldError 'EntraGroup' 'Enter an Entra group name or object ID.'
        }
    }
    if ($arguments['AutoDeleteAutopilot'] -and -not $arguments['DeleteFromAutopilot']) { Throw-EndpointFieldError 'AutoDeleteAutopilot' 'Enable deletion of matching Autopilot records before skipping its confirmation.' }
    if ($Workflow.Id -eq 'entra-cleanup' -and $arguments['OpenReport'] -and -not $arguments['ExportCsv']) { Throw-EndpointFieldError 'OpenReport' 'Enable CSV export before opening the report.' }
    if ($Workflow.Id -in @('delete-win32-apps', 'intune-assignment-win32-deployment-exports') -and -not $arguments['AppName'] -and -not $arguments['AppId']) { Throw-EndpointFieldError 'AppName' 'Supply an app name/pattern or app ID.' }
    if ($Workflow.Id -in @('add-members-to-group','remove-members-from-group')) {
        $sources = @('Users','UserListPath','DeviceNames','DeviceListPath' | Where-Object { $arguments[$_] })
        if ($sources.Count -ne 1) {
            $source = @('Users','UserListPath','DeviceNames','DeviceListPath' | Where-Object { $_ -notin $Inactive } | Select-Object -First 1)
            Throw-EndpointFieldError $(if ($source.Count) { $source[0] } else { 'Users' }) 'Supply user UPNs, device names, or one list file.'
        }
        $extension = if ($arguments['UserListPath']) { [IO.Path]::GetExtension($arguments['UserListPath']) } else { '' }
        if ($extension -in @('.csv', '.xlsx')) {
            if (-not $arguments['UserColumn']) { Throw-EndpointFieldError 'UserColumn' 'Choose the column containing user UPNs for CSV/XLSX input.' }
            if ($extension -eq '.xlsx' -and -not (Get-Module -ListAvailable ImportExcel)) { throw 'XLSX input requires ImportExcel. Install-Module ImportExcel -Scope CurrentUser' }
        }
        elseif ($arguments['UserColumn']) { Throw-EndpointFieldError 'UserColumn' 'A user column is only supported with CSV/XLSX input.' }
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
        UserIdentity = 'User UPN or primary email address'; FailuresOnly = 'Show failed sign-ins only'; ReportMode = 'Report view'
        OutputPath = 'Report folder or CSV path'; OutputFile = 'Report CSV file'; CsvPath = 'Optional CSV export'
        BeforeCsv = 'Older DeviceSummary CSV'; AfterCsv = 'Newer DeviceSummary CSV'
        ExportFolder = 'Report folder'; NoExport = 'Do not save CSV reports'; TenantId = 'Office sign-in tenant ID or domain'; PageSize = 'Devices per API page'
        IncludeWaveGroups = 'Include rollout group membership (Graph)'
        WaveGroupNames = 'Rollout group names'
        WorkspaceId = 'Log Analytics Workspace ID'; AzureTenantId = 'Azure sign-in tenant ID (optional)'
        TargetKB = 'Investigate a KB (optional)'; StaleDays = 'Treat telemetry as stale after (days)'
        UseDeviceAuthentication = 'Use Azure device-code sign-in'
        ResolveDeviceNames = 'Resolve missing computer names using Graph'
        ExpandNestedGroups = 'Expand nested groups'
        LookbackDays = 'Look back (days)'; Days = 'Inactive for at least (days)'; PolicyName = 'Update policy name'
        IncludeUserStatus = 'Include user deployment status (recommended)'; AppType = 'Application type'; Platform = 'Device platform'
        IncludeDeviceContext = 'Look up OS version and last sync for failed devices'
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
        UserIdentity = 'Enter one exact UPN or primary email address. Ambiguous users are not queried.'
        FailuresOnly = 'Exclude successful sign-ins. Events without a valid error code cannot be classified and are excluded with a warning.'
        ReportMode = 'Paged events reads up to 100 events first. Use Load more or Retrieve all in Report data to continue. Detailed events retrieves everything. Both use a rolling UTC window.'
        EntraGroup = 'Enter the group display name or its object ID.'
        NewPrimaryUser = 'The user to assign, for example user@example.com. The script still asks for per-device approval.'
        WhatIf = 'Unchecked runs the original action with its normal confirmations. Preview may still create CSV reports.'
        Confirm = 'Script default preserves the original confirmations. Suppressing these does not bypass mandatory primary-user approval.'
        AutoDeleteAutopilot = 'Warning: suppresses Autopilot approval only. Entra deletion is a separate decision.'
        DeviceListPath = 'Choose a text file containing one device name per line.'
        IncludeUserStatus = 'Enabled by default for full reporting. Uncheck only if you want device reports without the separate user-status export.'
        IncludeDeviceContext = 'Optional. Requires permission to read managed devices and adds one lookup per unique failed device.'
        OutputPath = 'The default folder is set under Settings > Reports. Override it here for this run. The script controls export naming and whether a CSV filename is accepted.'
        ExportFolder = 'The default folder is set under Settings > Reports. Saves device, full inventory and rollout summary CSVs.'
        NoExport = 'Show report data and statistics without saving the three CSV files.'
        TenantId = 'organizations allows a work or school account. This sign-in is separate from Home Graph.'
        WorkspaceId = 'Workspace GUID, not its Azure resource ID. Existing Azure query access is required.'
        AzureTenantId = 'Optional tenant GUID. Azure sign-in is independent of Home Graph.'
        TargetKB = 'For example KB5132043. Leave blank for fleet reporting. No KB record means Unknown, not missing.'
        StaleDays = 'Default 7 days. Stale/unknown devices are shown separately and excluded from the headline percentage.'
        UseDeviceAuthentication = 'Use device-code authentication if browser/broker sign-in is unavailable. Review the Microsoft sign-in instructions in Script output.'
        ResolveDeviceNames = 'Optional; off by default. Connect on Home to the same tenant as Azure with Device.Read.All consent. Fills only missing/suppressed names using Entra device IDs. Reveals directory names in reports and exports; use only if permitted by your organization.'
        ExpandNestedGroups = 'Include members of nested groups at every depth. Returns all member types, including group objects, in one flat list with each object listed once. Off means direct members only.'
        IncludeWaveGroups = 'Optional. Configure exact group names in Settings > Cloud Update first. Connect on Home in the same tenant as Office; existing Group.Read.All and Device.Read.All consent is required.'
        UserColumn = 'For CSV or XLSX, choose the exact column holding the user UPNs.'
        VerifySync = 'A request being accepted does not mean the device has checked in.'
    }
    [pscustomobject]@{
        Label = if ($labels.ContainsKey($Name)) { $labels[$Name] } else { ($Name -creplace '([a-z])([A-Z])', '$1 $2') }
        Hint = if ($hints.ContainsKey($Name)) { $hints[$Name] } else { '' }
    }
}

function Save-EndpointFormDraft {
    $ui = $script:Ui
    if (-not $ui.Workflow -or -not $ui.FieldControls.Count) { return }
    if (-not $ui.ContainsKey('FormDrafts')) { $ui.FormDrafts = @{} }
    $values = @{}
    foreach ($field in $ui.Workflow.Fields) {
        $control = $ui.FieldControls[$field.Name]
        if (-not $control) { continue }
        $values[$field.Name] = if ($field.Type -eq [switch]) { [bool]$control.IsChecked }
            elseif ($control -is [Windows.Controls.ComboBox] -and -not $control.IsEditable) { $control.SelectedItem }
            else { $control.Text }
    }
    $picker = if ($ui.ScriptPicker) {
        @{
            Choices = @($ui.ScriptPicker.Choices); LoadedType = $ui.ScriptPicker.LoadedType
            Selected = $ui.ScriptPicker.Selected; Search = $ui.ScriptPicker.Search.Text
        }
    } else { $null }
    $ui.FormDrafts[$ui.Workflow.Id] = @{
        Values = $values; Selectors = @($ui.Selectors | ForEach-Object { $_.Control.SelectedIndex }); Picker = $picker
    }
}

function Clear-EndpointFieldErrors {
    if (-not $script:Ui.ContainsKey('FieldErrors')) { return }
    foreach ($errorText in $script:Ui.FieldErrors.Values) { $errorText.Text = ''; $errorText.Visibility = 'Collapsed' }
}

function Show-EndpointFieldError {
    param([string]$Field, [string]$Message)
    $ui = $script:Ui
    if (-not $ui.FieldControls.ContainsKey($Field) -or -not $ui.FieldErrors.ContainsKey($Field) -or
        $ui.FieldRows[$Field].Visibility -ne 'Visible') { return $false }
    $label = (Get-EndpointFieldPresentation $Field).Label
    $message = $Message -replace "\b$([regex]::Escape($Field))\b", $label
    $errorText = $ui.FieldErrors[$Field]
    $errorText.Visibility = 'Visible'
    Set-EndpointLiveText $errorText $message
    $ui.Controls.ConfigureTab.IsSelected = $true
    $parent = [Windows.LogicalTreeHelper]::GetParent($ui.FieldRows[$Field])
    while ($parent) {
        if ($parent -is [Windows.Controls.Expander]) { $parent.IsExpanded = $true }
        $parent = [Windows.LogicalTreeHelper]::GetParent($parent)
    }
    $ui.Window.UpdateLayout()
    $ui.FieldRows[$Field].BringIntoView()
    $null = $ui.FieldControls[$Field].Focus()
    Set-EndpointLiveText $ui.Controls.Status $message
    return $true
}

function Restore-EndpointFormDraft {
    $ui = $script:Ui
    if (-not $ui.ContainsKey('FormDrafts') -or -not $ui.FormDrafts.ContainsKey($ui.Workflow.Id)) { return }
    $draft = $ui.FormDrafts[$ui.Workflow.Id]
    foreach ($field in $ui.Workflow.Fields) {
        if (-not $draft.Values.ContainsKey($field.Name)) { continue }
        $control = $ui.FieldControls[$field.Name]
        if ($field.Type -eq [switch]) { $control.IsChecked = $draft.Values[$field.Name] }
        elseif ($control -is [Windows.Controls.ComboBox] -and -not $control.IsEditable) { $control.SelectedItem = $draft.Values[$field.Name] }
        else { $control.Text = [string]$draft.Values[$field.Name] }
    }
    for ($i = 0; $i -lt $ui.Selectors.Count -and $i -lt $draft.Selectors.Count; $i++) {
        $ui.Selectors[$i].Control.SelectedIndex = $draft.Selectors[$i]
    }
    if ($ui.ScriptPicker -and $draft.Picker -and $draft.Picker.LoadedType) {
        $ui.ScriptPicker.LoadedType = $draft.Picker.LoadedType
        $ui.ScriptPicker.Choices = $draft.Picker.Choices
        $ui.ScriptPicker.Selected = $draft.Picker.Selected
        $ui.ScriptPicker.Search.IsEnabled = $true
        $ui.ScriptPicker.List.IsEnabled = $true
        $ui.ScriptPicker.Search.Text = $draft.Picker.Search
        Update-EndpointScriptChoiceList
    }
}

function Update-EndpointNavigationExpansion {
    $ui = $script:Ui
    if (-not $ui.NavigationNeedsExpansion) { return }
    $groups = [Collections.Generic.List[Windows.Controls.Expander]]::new()
    $pending = [Collections.Generic.Stack[Windows.DependencyObject]]::new()
    $pending.Push($ui.Controls.WorkflowList)
    while ($pending.Count) {
        $parent = $pending.Pop()
        for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($parent); $i++) {
            $child = [Windows.Media.VisualTreeHelper]::GetChild($parent, $i)
            if ($child -is [Windows.Controls.Expander] -and $child.Tag -eq 'WorkflowCategory') { $groups.Add($child) }
            $pending.Push($child)
        }
    }
    if ($groups.Count -lt $ui.Controls.WorkflowList.Items.Groups.Count) { return }
    $ui.NavigationNeedsExpansion = $false
    foreach ($group in $groups) {
        $group.IsExpanded = [bool]($ui.NavigationQuery -or ($ui.NavigationExpandSelected -and $ui.Workflow -and $group.Header -eq $ui.Workflow.Category))
    }
}

function Set-EndpointNavigation {
    param([string]$Query = '', [switch]$InitiallyCollapsed)
    $ui = $script:Ui
    if (-not $ui.ContainsKey('NavigationInitialized')) {
        $ui.NavigationInitialized = $true
        $ui.NavigationNeedsExpansion = $false
        $ui.Controls.WorkflowList.Add_LayoutUpdated({ Update-EndpointNavigationExpansion })
        $ui.Controls.WorkflowList.Add_PreviewKeyDown({
            param($sender, $eventArgs)
            if ($eventArgs.Key -notin @([Windows.Input.Key]::Left, [Windows.Input.Key]::Right)) { return }
            $node = $eventArgs.OriginalSource
            $header = $false
            while ($node -and $node -ne $sender) {
                if ($node -is [Windows.Controls.Primitives.ToggleButton]) { $header = $true }
                if ($header -and $node -is [Windows.Controls.Expander] -and $node.Tag -eq 'WorkflowCategory') {
                    $node.IsExpanded = $eventArgs.Key -eq [Windows.Input.Key]::Right
                    $eventArgs.Handled = $true
                    return
                }
                if ($node -isnot [Windows.Media.Visual]) { return }
                $node = [Windows.Media.VisualTreeHelper]::GetParent($node)
            }
        })
    }
    $ui.NavigationQuery = $Query
    $ui.NavigationExpandSelected = -not $InitiallyCollapsed
    $items = @($ui.Catalog | Where-Object { "$($_.Display) $($_.Path)".IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Sort-Object Category,Title)
    $view = [Windows.Data.ListCollectionView]::new([Collections.IList]$items)
    $view.GroupDescriptions.Add([Windows.Data.PropertyGroupDescription]::new('Category'))
    $ui.NavigationUpdating = $true
    try {
        $ui.Controls.WorkflowList.ItemsSource = $view
        if ($ui.Workflow) {
            $selected = $items | Where-Object Id -eq $ui.Workflow.Id | Select-Object -First 1
            if ($selected) { $ui.Controls.WorkflowList.SelectedItem = $selected }
        }
        elseif ($items.Count) { $ui.Controls.WorkflowList.SelectedIndex = 0 }
    }
    finally { $ui.NavigationUpdating = $false }
    $ui.Controls.SearchEmpty.Visibility = if ($items.Count) { 'Collapsed' } else { 'Visible' }
    $ui.NavigationNeedsExpansion = $items.Count -gt 0
    if (-not $ui.Workflow -and $ui.Controls.WorkflowList.SelectedItem) { New-EndpointForm }
}

function Update-EndpointRunLabel {
    $ui = $script:Ui
    Update-EndpointSignInPagingControls
    if (-not $ui.Workflow) { return }
    $preview = $ui.FieldControls.ContainsKey('WhatIf') -and $ui.FieldControls.WhatIf.IsChecked -and
        -not ($ui.Workflow.Id -eq 'primary-users' -and 'NewPrimaryUser' -in $ui.Inactive -and 'RemovePrimaryUser' -in $ui.Inactive)
    $ui.Controls.RunButton.Content = if ($preview) { '_Run preview' } elseif ($ui.Workflow.Kind -eq 'Remote') { '_Connect to endpoint' } elseif ($ui.Workflow.Id -eq 'delete-win32-apps') { '_Find apps & continue' } elseif ($ui.Workflow.Risk -eq 'Read only') { '_Run report' } else { '_Run task' }
    $readOnly = $ui.Workflow.Risk -eq 'Read only' -or ($ui.Workflow.Id -eq 'primary-users' -and 'NewPrimaryUser' -in $ui.Inactive -and 'RemovePrimaryUser' -in $ui.Inactive)
    if ($readOnly) { $ui.Controls.RunButton.Content = '_Run report' }
    $officeGroups = $ui.Workflow.Id -eq 'm365-cloud-update' -and $ui.FieldControls.ContainsKey('IncludeWaveGroups') -and $ui.FieldControls.IncludeWaveGroups.IsChecked
    $wufbNames = $ui.Workflow.Id -eq 'wufb-report' -and $ui.FieldControls.ContainsKey('ResolveDeviceNames') -and $ui.FieldControls.ResolveDeviceNames.IsChecked
    $hint = if ($preview) { 'PREVIEW - no remote changes. Script CSV exports may still be written.' } elseif ($officeGroups) { 'Read-only Office report with Graph group lookup. Connect on Home first; Graph access is checked before the separate Office sign-in. Both sign-ins must use the same tenant.' } elseif ($wufbNames) { 'Read-only WUfB report with Graph name lookup. Connect on Home first with Device.Read.All consent and a supported reader role. Graph and Azure must use the same tenant. Directory names appear in reports and exports.' } elseif ($ui.Workflow.Kind -eq 'Office') { 'Read-only Office report. A separate Microsoft sign-in opens when run; Home Graph is not required. MSAL.PS must already be installed.' } elseif ($ui.Workflow.Kind -eq 'Azure') { 'Read-only Azure report. Separate Azure sign-in and existing workspace query access are required. Home Graph is not used; Az.Accounts 5.0+ must already be installed.' } elseif ($ui.Workflow.Kind -eq 'Local') { 'Read-only comparison of local exports. No sign-in is needed.' } elseif ($readOnly) { 'Read-only report. Connect on Home first; live access is checked before the script starts.' } elseif ($ui.Workflow.Kind -eq 'Remote') { 'Endpoint credentials are separate from Graph sign-in. Commands never run locally.' } else { 'Connect on Home first. Live access is checked before starting; original confirmations still apply.' }
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
        $container.Margin = $window.FindResource('Spacing.Panel.Margin')
        $heading = [Windows.Controls.TextBlock]::new(); $heading.Text = $Title; $heading.FontSize = $window.FindResource('Font.Size.Subheading')
        $heading.FontWeight = 'SemiBold'; $heading.Margin = $window.FindResource('Spacing.Section.Header.Margin')
        $panel.Children.Insert(0, $heading); $container.Child = $panel
    }
    $null = $script:Ui.Controls.Form.Children.Add($container)
    return $panel
}

function New-EndpointForm {
    $ui = $script:Ui
    if ($ui.ContainsKey('NavigationUpdating') -and $ui.NavigationUpdating) { return }
    $workflow = $ui.Controls.WorkflowList.SelectedItem
    if (-not $workflow) { return }
    Save-EndpointFormDraft
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
        'wufb-report' { 'Save defaults under Settings > WUfB, or enter the workspace GUID here. Run to reuse a compatible Azure user session or sign in when needed. Optional exact device names restrict the fleet; an optional KB adds per-device investigation. Resolve missing computer names using Graph is off by default and requires Home sign-in in the same tenant. Report data includes compliance, updates, errors, restarts, KB investigation, observed updates, trends and data health. Graph-enriched runs also include Device name resolution with the original names and lookup sources. Select a device row to open its updates or alerts. No CSV import is required.' }
        'add-members-to-group' { 'Choose a group and enter user UPNs or device names, or select a list file. Already-present direct members are skipped. If multiple Entra devices share a hostname, all matching devices are processed.' }
        'get-entra-group-members' { 'Enter an exact group name or object ID. All member types are returned; no type selection is needed. Leave Expand nested groups unchecked for direct members only, or enable it to include indirect members at every depth. Expanded results are a flat list of unique objects, including the nested groups themselves. Filter, copy or Export view under Report data. Entra object IDs are not Intune managed-device IDs. This is read-only and does not change membership.' }
        'entra-user-lookup' { 'Enter names or choose a text file with one name per line. Exact matches show as Found. Multiple means several users share the name. PossibleMatch (same surname and first initial, for example Mike / Michael) must be reviewed before use.' }
        'user-sign-in-history' { 'Enter one exact UPN or primary email address. Paged events shows the first API page; use Load more or Retrieve all under Report data. An incomplete report or empty failures-only page does not mean no other events exist. Both views use Graph beta and a rolling UTC window.' }
        'remove-members-from-group' { 'Choose a group and supply user UPNs or device names. Use Preview to check matches without removing anyone. Only direct memberships can be removed; the user and device objects are not deleted.' }
        'primary-users' { 'Choose whether to read, assign or remove primary users, then select your devices. Each change still requires the original per-device approval.' }
        'remote-endpoint' { 'Enter a computer name and connect. Credentials are requested securely in the app. After connection, use the Remote workspace under Results.' }
        'm365-cloud-update' { 'Run and complete the separate Office sign-in. To include rollout group membership, first save exact Entra group names in Settings > Cloud Update. Report data opens with portal-style device rows; choose Rollout summary, Progress by wave or Release in the dataset selector for statistics. The default CSV folder is set under Settings > Reports.' }
        default { 'Choose your inputs, review the options, then run. Live output and any reports appear under Results. Only inputs for the selected source are shown.' }
    }
    $ui.Controls.Form.Children.Clear()
    $ui.FieldControls = @{}; $ui.FieldRows = @{}; $ui.FieldErrors = @{}; $ui.Selectors = @(); $ui.ScriptPicker = $null
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
        $ui.Selectors += [pscustomobject]@{ Definition = $definition; Control = $combo; Label = $label }
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
            $presentation.Hint = 'A folder for each selected app''s device details, device summary and user-status CSVs. The default is set under Settings > Reports.'
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
            if ($field.Name -eq 'WhatIf') { $control.Add_Checked({ Update-EndpointRunLabel }); $control.Add_Unchecked({ Update-EndpointRunLabel }) }
            elseif ($field.Name -eq 'IncludeWaveGroups') { $control.Add_Checked({ Update-EndpointFields }); $control.Add_Unchecked({ Update-EndpointFields }) }
            elseif ($field.Name -eq 'ResolveDeviceNames') { $control.Add_Checked({ Update-EndpointRunLabel }); $control.Add_Unchecked({ Update-EndpointRunLabel }) }
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
            $control = [Windows.Controls.TextBox]::new()
            $control.Text = if ($field.Type.IsArray) { [string]::Join("`r`n", [string[]]@($field.Default)) } else { [string]$field.Default }
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
        $errorText = [Windows.Controls.TextBlock]::new()
        $errorText.TextWrapping = 'Wrap'; $errorText.Visibility = 'Collapsed'
        $errorText.Margin = $ui.Window.FindResource('Spacing.Hint.Margin')
        $errorText.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Error')
        [Windows.Automation.AutomationProperties]::SetName($errorText, "$($presentation.Label) validation error")
        [Windows.Automation.AutomationProperties]::SetLiveSetting($errorText, [Windows.Automation.AutomationLiveSetting]::Polite)
        $null = $row.Children.Add($errorText)
        $ui.FieldErrors[$field.Name] = $errorText
        if ($control -is [Windows.Controls.TextBox]) { $control.Add_TextChanged({ Clear-EndpointFieldErrors }) }
        elseif ($control -is [Windows.Controls.ComboBox]) {
            $control.Add_SelectionChanged({ Clear-EndpointFieldErrors })
            if ($control.IsEditable) {
                $control.AddHandler([Windows.Controls.TextBox]::TextChangedEvent, [Windows.Controls.TextChangedEventHandler]{ Clear-EndpointFieldErrors })
            }
        }
        elseif ($control -is [Windows.Controls.CheckBox]) {
            $control.Add_Checked({ Clear-EndpointFieldErrors }); $control.Add_Unchecked({ Clear-EndpointFieldErrors })
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
        if ($field.Name -in @('OutputPath', 'ExportFolder', 'OutputFile', 'CsvPath', 'DeviceListPath', 'UserListPath', 'BeforeCsv', 'AfterCsv')) {
            $browse = [Windows.Controls.Button]::new(); $browse.Content = 'Browse...'
            $browse.HorizontalAlignment = 'Left'
            $browse.Margin = $ui.Window.FindResource('Spacing.Browse.Margin')
            $browse.Tag = [pscustomobject]@{ Control = $control; Name = $field.Name }
            $browse.Add_Click({
                param($sender)
                try {
                    if ($sender.Tag.Name -in @('OutputPath', 'ExportFolder')) {
                        $picker = [Microsoft.Win32.OpenFolderDialog]::new()
                        $picker.InitialDirectory = if (Test-Path -LiteralPath $sender.Tag.Control.Text -PathType Container) { $sender.Tag.Control.Text } else { $script:Ui.ReportFolder }
                        if ($picker.ShowDialog($script:Ui.Window)) { $sender.Tag.Control.Text = $picker.FolderName }
                    }
                    elseif ($sender.Tag.Name -in @('OutputFile', 'CsvPath')) {
                        $picker = New-EndpointReportSaveDialog $sender.Tag.Control.Text
                        if ($picker.ShowDialog($script:Ui.Window)) { $sender.Tag.Control.Text = $picker.FileName }
                    }
                    else {
                        $picker = [Microsoft.Win32.OpenFileDialog]::new()
                        $picker.Filter = if ($sender.Tag.Name -in @('BeforeCsv','AfterCsv')) { 'CSV report (*.csv)|*.csv' }
                            elseif ($sender.Tag.Name -eq 'UserListPath' -and $script:Ui.Workflow.Id -in @('add-members-to-group','remove-members-from-group')) { 'User lists|*.txt;*.csv;*.xlsx|All files|*.*' } else { 'Text files|*.txt|All files|*.*' }
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
    for ($i = 1; $i -lt $ui.Selectors.Count; $i++) {
        $selector = $ui.Selectors[$i]
        $parameters = @($selector.Definition.Options | ForEach-Object { $_.Parameters })
        $firstRow = $workflow.Fields | Where-Object { $_.Name -in $parameters -and $targetPanel.Children.Contains($ui.FieldRows[$_.Name]) } | Select-Object -First 1
        if ($firstRow) {
            $targetPanel.Children.Remove($selector.Label)
            $targetPanel.Children.Remove($selector.Control)
            $index = $targetPanel.Children.IndexOf($ui.FieldRows[$firstRow.Name])
            $targetPanel.Children.Insert($index, $selector.Label)
            $targetPanel.Children.Insert($index + 1, $selector.Control)
        }
    }
    if ($modePanel) {
        $container = $modePanel.Parent
        $ui.Controls.Form.Children.Remove($container)
        $index = if ($reportPanel) { $ui.Controls.Form.Children.IndexOf($reportPanel.Parent) } else { $ui.Controls.Form.Children.Count }
        $ui.Controls.Form.Children.Insert($index, $container)
    }
    $container = $advancedPanel.Parent
    $ui.Controls.Form.Children.Remove($container)
    $null = $ui.Controls.Form.Children.Add($container)
    Restore-EndpointFormDraft
    Update-EndpointFields
    if ($ui.ContainsKey('ReportWorkspaces')) { Switch-EndpointReportWorkspace $workflow.Id }
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
    param([Parameter(Mandatory)][Windows.Window]$Window, [ValidateSet('Light','Dark','CatppuccinMocha','GruvboxDark')][string]$Theme)
    $Theme = @('Light','Dark','CatppuccinMocha','GruvboxDark') | Where-Object { $_ -eq $Theme } | Select-Object -First 1
    if (-not $Window.Resources.Contains('Theme.LightPalette')) {
        $light = @{}
        foreach ($key in @($Window.Resources.Keys)) {
            if ($key -is [string] -and $key.StartsWith('Color.')) { $light[$key] = $Window.Resources[$key] }
        }
        $Window.Resources['Theme.LightPalette'] = $light
    }
    $paletteKey = "Theme.${Theme}Palette"
    if (-not $Window.Resources.Contains($paletteKey)) { throw "The $Theme theme palette is missing." }
    $palette = $Window.Resources[$paletteKey]
    foreach ($key in $palette.Keys) {
        $Window.Resources[$key] = $palette[$key]
        $Window.Resources[$key.Replace('Color.', 'Brush.')] = [Windows.Media.SolidColorBrush]::new($palette[$key])
    }
    $Window.Resources['Theme.Current'] = $Theme
}

function Get-EndpointThemePreference {
    param([AllowNull()][string]$Path)
    return (Get-EndpointSettings $Path).Appearance.Theme
}

function ConvertTo-EndpointTenantId {
    param([AllowNull()][string]$Value)
    $tenantId = if ($Value) { $Value.Trim() } else { '' }
    if (-not $tenantId) { return '' }
    if ($tenantId -ieq 'organizations') { return 'organizations' }
    $parsed = [guid]::Empty
    if ([guid]::TryParse($tenantId, [ref]$parsed)) { return $parsed.ToString() }
    if ($tenantId.Length -gt 253 -or [uri]::CheckHostName($tenantId) -ne [System.UriHostNameType]::Dns) {
        throw 'Enter a tenant GUID, tenant domain, or organizations; leave empty to use the account default.'
    }
    return $tenantId
}

function Get-EndpointTenantPreference {
    param([AllowNull()][string]$Path)
    return (Get-EndpointSettings $Path).Graph.TenantId
}

function Save-EndpointThemePreference {
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('Light','Dark','CatppuccinMocha','GruvboxDark')][string]$Theme)
    Save-EndpointSettingsSection $Path Appearance @{ Theme = $Theme }
}

function Save-EndpointTenantPreference {
    param([Parameter(Mandatory)][string]$Path, [AllowNull()][string]$TenantId)
    $normalized = ConvertTo-EndpointTenantId $TenantId
    Save-EndpointSettingsSection $Path Graph @{ TenantId = $normalized }
    return $normalized
}

function ConvertTo-EndpointReportFolder {
    param([AllowNull()][string]$Value)
    $folder = if ([string]::IsNullOrWhiteSpace($Value)) { Join-Path $env:TEMP 'endpoint-toolbox' } else { [Environment]::ExpandEnvironmentVariables($Value.Trim()) }
    if (-not [IO.Path]::IsPathFullyQualified($folder) -or $folder -match '[\x00-\x1f<>"|?*]|%[^%]+%') {
        throw 'Enter a full local or UNC folder path, optionally using environment variables such as %TEMP%. Leave empty to reset to %TEMP%\endpoint-toolbox.'
    }
    $folder = [IO.Path]::GetFullPath($folder)
    if (Test-Path -LiteralPath $folder -PathType Leaf) { throw 'The report folder points to a file. Choose a folder instead.' }
    return $folder
}

function Get-EndpointReportFolderPreference {
    param([AllowEmptyString()][string]$Path)
    return ConvertTo-EndpointReportFolder (Get-EndpointSettings $Path).Reports.Folder
}

function Save-EndpointReportFolderPreference {
    param([Parameter(Mandatory)][string]$Path, [AllowNull()][string]$ReportFolder)
    $folder = ConvertTo-EndpointReportFolder $ReportFolder
    $null = New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop
    Save-EndpointSettingsSection $Path Reports @{ Folder = $folder }
    return $folder
}

function Set-EndpointReportFolderDefaults {
    param([Parameter(Mandatory)][string]$Folder)
    $ui = $script:Ui
    foreach ($workflow in $ui.Catalog) {
        foreach ($field in $workflow.Fields) {
            if (-not $field.Default -or $field.Name -notin @('OutputPath','ExportFolder','OutputFile','CsvPath')) { continue }
            $old = [string]$field.Default
            $field.Default = if ($field.Name -in @('OutputFile','CsvPath')) { Join-Path $Folder ([IO.Path]::GetFileName($old)) } else { $Folder }
            if ($ui['FormDrafts'] -and $ui.FormDrafts.ContainsKey($workflow.Id)) {
                $values = $ui.FormDrafts[$workflow.Id].Values
                if ($values[$field.Name] -eq $old) { $values[$field.Name] = $field.Default }
            }
            if ($ui.Workflow -and $ui.Workflow.Id -eq $workflow.Id -and $ui.FieldControls[$field.Name].Text -eq $old) {
                $ui.FieldControls[$field.Name].Text = $field.Default
            }
        }
    }
    $ui.ReportFolder = $Folder
}

function New-EndpointReportSaveDialog {
    param([string]$CurrentPath = '', [ValidateSet('Csv','Png')][string]$Format = 'Csv')
    $folder = if ($script:Ui['ReportFolder']) { $script:Ui.ReportFolder } else { ConvertTo-EndpointReportFolder '' }
    $null = New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop
    $picker = [Microsoft.Win32.SaveFileDialog]::new()
    $picker.Filter = if ($Format -eq 'Png') { 'PNG image (*.png)|*.png' } else { 'CSV report (*.csv)|*.csv' }
    $picker.DefaultExt = ".$($Format.ToLowerInvariant())"
    $picker.InitialDirectory = $folder
    if ($CurrentPath) {
        $picker.FileName = [IO.Path]::GetFileName($CurrentPath)
        $parent = Split-Path $CurrentPath -Parent
        if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) { $picker.InitialDirectory = $parent }
    }
    return $picker
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
}

function Set-EndpointThemeChoice {
    param([ValidateSet('Light','Dark','CatppuccinMocha','GruvboxDark')][string]$Theme)
    $ui = $script:Ui
    if ($ui['ChangingTheme'] -or $Theme -eq $ui.Window.Resources['Theme.Current']) { return }
    $ui.ChangingTheme = $true
    try {
        if ($ui.ThemePath) { Save-EndpointThemePreference $ui.ThemePath $Theme }
        Set-EndpointTheme $ui.Window $Theme
    }
    finally {
        try {
            if ($ui.Settings) { $ui.Settings.Controls.ThemeSelector.SelectedValue = $ui.Window.Resources['Theme.Current'] }
        }
        finally { $ui.ChangingTheme = $false }
    }
}

function Invoke-EndpointShortcut {
    param([Windows.Input.Key]$Key, [Windows.Input.ModifierKeys]$Modifiers, [Windows.DependencyObject]$Focus, [bool]$Repeat)
    $ui = $script:Ui
    $node = $Focus
    while ($node) {
        if ($node -is [Windows.Controls.Primitives.TextBoxBase] -or $node -is [Windows.Controls.PasswordBox] -or
            $node -is [Windows.Controls.ComboBox] -or $node -is [Windows.Controls.ComboBoxItem]) {
            $ui.ThemeShortcutUntil = 0L
            return $false
        }
        $node = if ($node -is [Windows.Media.Visual] -or $node -is [Windows.Media.Media3D.Visual3D]) {
            [Windows.Media.VisualTreeHelper]::GetParent($node)
        } else { [Windows.LogicalTreeHelper]::GetParent($node) }
    }
    if ($Repeat) { return $false }
    $now = [Environment]::TickCount64
    $pending = $ui['ThemeShortcutUntil'] -gt $now
    $ui.ThemeShortcutUntil = 0L
    if ($Modifiers -eq [Windows.Input.ModifierKeys]::Control -and $Key -eq 'OemComma') {
        Show-EndpointSettings
        return $true
    }
    if ([int]$Modifiers -ne 0) { return $false }
    if ($Key -eq 'T') {
        $ui.ThemeShortcutUntil = $now + 2000
        return $true
    }
    if ($pending) {
        $theme = switch ($Key) {
            'L' { 'Light' }
            'D' { 'Dark' }
            'G' { 'GruvboxDark' }
            'C' { 'CatppuccinMocha' }
        }
        if ($theme) {
            try { Set-EndpointThemeChoice $theme }
            catch { Show-EndpointError $_ }
            return $true
        }
    }
    return $false
}

function Register-EndpointShortcuts {
    param([Windows.Window]$Window)
    $Window.Add_Deactivated({ $script:Ui.ThemeShortcutUntil = 0L })
    $Window.Add_PreviewLostKeyboardFocus({ $script:Ui.ThemeShortcutUntil = 0L })
    $Window.Add_PreviewMouseDown({ $script:Ui.ThemeShortcutUntil = 0L })
    $Window.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if (Invoke-EndpointShortcut $eventArgs.Key $eventArgs.KeyboardDevice.Modifiers $eventArgs.OriginalSource $eventArgs.IsRepeat) {
            $eventArgs.Handled = $true
        }
    })
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

function ConvertTo-EndpointDnsSuffix {
    param([AllowNull()][string]$Value)
    $suffix = if ($Value) { $Value.Trim().TrimStart('.').TrimEnd('.') } else { '' }
    if ($suffix -and ($suffix.Length -gt 253 -or $suffix -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$')) {
        throw 'The DNS suffix must contain only letters, digits, hyphens and dots, for example corp.example.com.'
    }
    return $suffix
}

function Get-EndpointRemoteSettings {
    param([Parameter(Mandatory)][string]$Path)
    return [pscustomobject]@{ DnsSuffix = (Get-EndpointSettings $Path).Remote.DnsSuffix }
}

function Save-EndpointRemoteSettings {
    param([Parameter(Mandatory)][string]$Path, [AllowNull()][string]$DnsSuffix)
    $suffix = ConvertTo-EndpointDnsSuffix $DnsSuffix
    Save-EndpointSettingsSection $Path Remote @{ DnsSuffix = $suffix }
    return $suffix
}

function Get-EndpointCloudUpdateGroups {
    param([Parameter(Mandatory)][string]$Path)
    (Get-EndpointSettings $Path).CloudUpdate.GroupNames
}

function Get-EndpointWUfBSettings {
    param([AllowNull()][string]$Path)
    $settings = (Get-EndpointSettings $Path).WUfB
    [pscustomobject]@{ WorkspaceId = $settings.WorkspaceId; AzureTenantId = $settings.AzureTenantId }
}

function Save-EndpointWUfBSettings {
    param([Parameter(Mandatory)][string]$Path, [string]$WorkspaceId = '', [string]$AzureTenantId = '')
    $normalized = (ConvertTo-EndpointSettingsDocument @{
        SchemaVersion = 2; WUfB = @{ WorkspaceId = $WorkspaceId; AzureTenantId = $AzureTenantId }
    }).WUfB
    $current = (Get-EndpointSettings $Path).WUfB
    $changes = @{}
    foreach ($key in $normalized.Keys) {
        if ($normalized[$key] -cne $current[$key]) { $changes[$key] = $normalized[$key] }
    }
    if ($changes.Count) { Save-EndpointSettingsSection $Path WUfB $changes }
    Get-EndpointWUfBSettings $Path
}

function Set-EndpointWUfBDefaults {
    param([object]$Settings)
    $ui = $script:Ui
    $workflow = $ui.Catalog | Where-Object Id -eq 'wufb-report'
    foreach ($field in $workflow.Fields | Where-Object Name -in @('WorkspaceId','AzureTenantId')) {
        $old = $field.Default
        $field.Default = $Settings.($field.Name)
        if ($ui.FormDrafts.ContainsKey($workflow.Id) -and $ui.FormDrafts[$workflow.Id].Values[$field.Name] -eq $old) {
            $ui.FormDrafts[$workflow.Id].Values[$field.Name] = $field.Default
        }
        if ($ui.Workflow -and $ui.Workflow.Id -eq $workflow.Id -and $ui.FieldControls[$field.Name].Text -eq $old) {
            $ui.FieldControls[$field.Name].Text = $field.Default
        }
    }
}

function Save-EndpointCloudUpdateGroups {
    param([Parameter(Mandatory)][string]$Path, [AllowNull()][string]$Text)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $names = [string[]]@($Text -split '\r\n|\r|\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $seen.Add($_) })
    Save-EndpointSettingsSection $Path CloudUpdate @{ GroupNames = $names }
    return $names
}

function Set-EndpointCloudUpdateGroupsArgument {
    param([Parameter(Mandatory)][hashtable]$Arguments, [AllowNull()][string]$Path)
    if (-not $Arguments['IncludeWaveGroups']) { return }
    try { $names = @(if ($Path) { Get-EndpointCloudUpdateGroups $Path }) }
    catch { throw "Cloud Update group settings could not be loaded. Fix them under Settings > Cloud Update. $($_.Exception.Message)" }
    if (-not $names.Count) { throw 'Add at least one rollout group under Settings > Cloud Update, or turn off rollout group membership.' }
    $Arguments.WaveGroupNames = [string[]]$names
}

function Confirm-EndpointAction {
    param([Windows.Window]$Owner, [string]$Message, [string]$Title)
    return [Windows.MessageBox]::Show($Owner, $Message, $Title, 'YesNo', 'Warning', 'No') -eq 'Yes'
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
        <DataGrid Name="HistoryGrid" Grid.Row="2" AutomationProperties.Name="Run history" AutoGenerateColumns="False"
                  SelectionUnit="Cell" SelectionMode="Extended" ClipboardCopyMode="ExcludeHeader">
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
        <Label Content="DNS _suffix (optional)" Target="{Binding ElementName=DnsSuffixBox}"
               Padding="0" Margin="{DynamicResource Spacing.Label.Margin}" Foreground="{DynamicResource Brush.Text.Primary}"/>
        <Grid HorizontalAlignment="Left">
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <TextBox Name="DnsSuffixBox" MaxLength="253" Width="360" Margin="{DynamicResource Spacing.Button.Margin}"
                   AutomationProperties.Name="DNS suffix" ToolTip="For example corp.example.com"/>
          <Button Name="SaveRemoteSettingsButton" Grid.Column="1" Content="_Save" Margin="0"
                  AutomationProperties.Name="Save remote settings"/>
          <TextBlock Name="RemoteSettingsStatus" Grid.Row="1" Grid.ColumnSpan="2" TextWrapping="Wrap" Margin="{DynamicResource Spacing.Hint.Margin}"
                     AutomationProperties.Name="Remote settings status" AutomationProperties.LiveSetting="Polite"/>
        </Grid>
      </StackPanel>
    </TabItem>
    <TabItem Name="GraphTab" Header="_Graph" AutomationProperties.Name="Graph">
      <StackPanel>
        <TextBlock Text="Optional default tenant for Home Graph connect/reconnect. A tenant entered on Home takes precedence. Saving this setting does not change an active connection."
                   TextWrapping="Wrap" Foreground="{DynamicResource Brush.Text.Secondary}" Margin="{DynamicResource Spacing.Panel.Margin}"/>
        <Label Name="TenantIdLabel" Content="Default tenant ID or domain (optional)" Target="{Binding ElementName=TenantIdBox}"
               Padding="0" Margin="{DynamicResource Spacing.Label.Margin}" Foreground="{DynamicResource Brush.Text.Primary}"/>
        <Grid HorizontalAlignment="Left">
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <TextBox Name="TenantIdBox" MaxLength="253" Width="420" Margin="{DynamicResource Spacing.Button.Margin}"
                   AutomationProperties.Name="Default tenant ID or domain" AutomationProperties.LabeledBy="{Binding ElementName=TenantIdLabel}"/>
          <Button Name="SaveTenantSettingsButton" Grid.Column="1" Content="_Save" Margin="0"
                  AutomationProperties.Name="Save tenant setting"/>
          <TextBlock Name="TenantSettingsStatus" Grid.Row="1" Grid.ColumnSpan="2" TextWrapping="Wrap" Margin="{DynamicResource Spacing.Hint.Margin}"
                     AutomationProperties.Name="Tenant setting status" AutomationProperties.LiveSetting="Polite"/>
        </Grid>
      </StackPanel>
    </TabItem>
    <TabItem Name="WUfBTab" Header="_WUfB" AutomationProperties.Name="WUfB">
      <StackPanel>
        <TextBlock Text="Saved defaults for the read-only Windows Update for Business task. Azure sign-in is separate from Home Graph. Saving does not connect or grant access; per-run inputs can override these defaults."
                   TextWrapping="Wrap" Foreground="{DynamicResource Brush.Text.Secondary}" Margin="{DynamicResource Spacing.Panel.Margin}"/>
        <Label Name="WUfBWorkspaceLabel" Content="Log Analytics Workspace ID" Target="{Binding ElementName=WUfBWorkspaceBox}"
               Foreground="{DynamicResource Brush.Text.Primary}"/>
        <TextBox Name="WUfBWorkspaceBox" MaxLength="36" AutomationProperties.Name="Log Analytics Workspace ID"
                 AutomationProperties.LabeledBy="{Binding ElementName=WUfBWorkspaceLabel}" Margin="{DynamicResource Spacing.Field.Margin}"/>
        <Label Name="WUfBTenantLabel" Content="Azure tenant ID (optional)" Target="{Binding ElementName=WUfBTenantBox}"
               Foreground="{DynamicResource Brush.Text.Primary}"/>
        <TextBox Name="WUfBTenantBox" MaxLength="36" AutomationProperties.Name="Azure tenant ID"
                 AutomationProperties.LabeledBy="{Binding ElementName=WUfBTenantLabel}" Margin="{DynamicResource Spacing.Field.Margin}"/>
        <Button Name="SaveWUfBSettingsButton" Content="_Save" HorizontalAlignment="Left" AutomationProperties.Name="Save WUfB settings"/>
        <TextBlock Name="WUfBSettingsStatus" TextWrapping="Wrap" Margin="{DynamicResource Spacing.Hint.Margin}"
                   AutomationProperties.Name="WUfB settings status" AutomationProperties.LiveSetting="Polite"/>
      </StackPanel>
    </TabItem>
    <TabItem Name="CloudUpdateTab" Header="_Cloud Update" AutomationProperties.Name="Cloud Update">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <TextBlock Text="Enter exact Entra group display names, one per line. These groups are required only when rollout group membership is enabled in the Cloud Update report."
                   TextWrapping="Wrap" Foreground="{DynamicResource Brush.Text.Secondary}" Margin="{DynamicResource Spacing.Panel.Margin}"/>
        <Label Name="CloudGroupsLabel" Grid.Row="1" Content="Rollout _group names" Target="{Binding ElementName=CloudGroupsBox}"
               Foreground="{DynamicResource Brush.Text.Primary}"/>
        <TextBox Name="CloudGroupsBox" Grid.Row="2" AcceptsReturn="True" VerticalContentAlignment="Top"
                 VerticalScrollBarVisibility="Auto" AutomationProperties.Name="Rollout group names"
                 AutomationProperties.LabeledBy="{Binding ElementName=CloudGroupsLabel}"/>
        <TextBlock Name="CloudGroupsStatus" Grid.Row="3" TextWrapping="Wrap" Margin="{DynamicResource Spacing.Hint.Margin}"
                   AutomationProperties.Name="Cloud Update settings status" AutomationProperties.LiveSetting="Polite"/>
        <Button Name="SaveCloudGroupsButton" Grid.Row="4" Content="_Save" HorizontalAlignment="Left" Margin="{DynamicResource Spacing.Panel.Margin}"
                AutomationProperties.Name="Save Cloud Update groups"/>
      </Grid>
    </TabItem>
    <TabItem Name="AppearanceTab" Header="_Appearance" AutomationProperties.Name="Appearance">
      <StackPanel>
        <Label Name="ThemeLabel" Content="_Theme" Target="{Binding ElementName=ThemeSelector}"
               Foreground="{DynamicResource Brush.Text.Primary}"/>
        <ComboBox Name="ThemeSelector" SelectedValuePath="Tag" HorizontalAlignment="Left" MinWidth="180"
                  AutomationProperties.Name="Theme" AutomationProperties.LabeledBy="{Binding ElementName=ThemeLabel}">
          <ComboBoxItem Content="Light" Tag="Light"/>
          <ComboBoxItem Content="Dark" Tag="Dark"/>
          <ComboBoxItem Content="Catppuccin Mocha" Tag="CatppuccinMocha"/>
          <ComboBoxItem Content="Gruvbox Dark" Tag="GruvboxDark"/>
        </ComboBox>
        <TextBlock Text="Shortcuts: Ctrl+, opens Settings. Press T, then L (Light), D (Dark), G (Gruvbox Dark), or C (Catppuccin Mocha). Shortcuts are ignored in text fields and dropdowns."
                   TextWrapping="Wrap" Foreground="{DynamicResource Brush.Text.Secondary}" Margin="{DynamicResource Spacing.Hint.Margin}"/>
      </StackPanel>
    </TabItem>
    <TabItem Name="ReportsTab" Header="Re_ports" AutomationProperties.Name="Reports">
      <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel MaxWidth="640" HorizontalAlignment="Left">
        <TextBlock Text="Default folder for report CSVs and Export view. Initially %TEMP%\endpoint-toolbox. Per-run paths take precedence; optional exports remain optional. Saving creates the folder if needed. Existing reports are not moved."
                   TextWrapping="Wrap" Foreground="{DynamicResource Brush.Text.Secondary}" Margin="{DynamicResource Spacing.Panel.Margin}"/>
        <Grid Margin="{DynamicResource Spacing.Panel.Margin}">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Label Name="ReportFolderLabel" Grid.ColumnSpan="3" Content="Default report _folder" Target="{Binding ElementName=ReportFolderBox}"
                 Padding="0" Margin="{DynamicResource Spacing.Label.Margin}" Foreground="{DynamicResource Brush.Text.Primary}"/>
          <TextBox Name="ReportFolderBox" Grid.Row="1" Margin="{DynamicResource Spacing.Button.Margin}"
                   AutomationProperties.Name="Default report folder" AutomationProperties.LabeledBy="{Binding ElementName=ReportFolderLabel}"/>
          <Button Name="BrowseReportFolderButton" Grid.Row="1" Grid.Column="1" Content="_Browse..." Margin="{DynamicResource Spacing.Button.Margin}"
                  AutomationProperties.Name="Browse default report folder"/>
          <Button Name="SaveReportFolderButton" Grid.Row="1" Grid.Column="2" Content="_Save" Margin="0"
                  AutomationProperties.Name="Save default report folder"/>
          <TextBlock Name="ReportFolderStatus" Grid.Row="2" Grid.ColumnSpan="3" TextWrapping="Wrap" Margin="{DynamicResource Spacing.Hint.Margin}"
                     AutomationProperties.Name="Report folder settings status" AutomationProperties.LiveSetting="Polite"/>
        </Grid>
        <TextBlock Text="Delete all reports permanently removes only CSV files directly in the saved folder. Subfolders, other file types, reports saved elsewhere, logs, and in-app results are unchanged."
                   TextWrapping="Wrap" Foreground="{DynamicResource Brush.Text.Secondary}" Margin="{DynamicResource Spacing.Panel.Margin}"/>
        <Button Name="DeleteReportsButton" Content="_Delete all reports..." HorizontalAlignment="Left"
                AutomationProperties.Name="Delete all reports" ToolTip="Confirm deletion of CSV files in the saved report folder only"/>
        <TextBlock Name="DeleteReportsStatus" TextWrapping="Wrap" Margin="{DynamicResource Spacing.Hint.Margin}"
                   AutomationProperties.Name="Report deletion status" AutomationProperties.LiveSetting="Polite"/>
      </StackPanel>
      </ScrollViewer>
    </TabItem>
  </TabControl>
  <Button Name="CloseSettingsButton" Grid.Row="1" Content="C_lose" HorizontalAlignment="Right" Margin="{DynamicResource Spacing.Dialog.Buttons.Margin}"
          AutomationProperties.Name="Close settings"/>
</Grid>
'@)
    $controls = @{}
    foreach ($name in @('SettingsTabs','HistoryTab','LogsTab','HistoryButton','ClearHistoryButton','HistoryGrid','HistoryStatus','OpenActivityLogsButton','RemoteTab','DnsSuffixBox','SaveRemoteSettingsButton','RemoteSettingsStatus','GraphTab','TenantIdBox','SaveTenantSettingsButton','TenantSettingsStatus','WUfBTab','WUfBWorkspaceBox','WUfBTenantBox','SaveWUfBSettingsButton','WUfBSettingsStatus','CloudUpdateTab','CloudGroupsBox','CloudGroupsStatus','SaveCloudGroupsButton','AppearanceTab','ThemeSelector','ReportsTab','ReportFolderBox','BrowseReportFolderButton','ReportFolderStatus','SaveReportFolderButton','DeleteReportsButton','DeleteReportsStatus','CloseSettingsButton')) {
        $controls[$name] = $dialog.Content.FindName($name)
        if (-not $controls[$name]) { throw "Required settings control is missing: $name" }
    }
    $dialog.Tag = @{ Controls = $controls; SavedSuffix = ''; SavedTenantId = ''; SavedCloudGroups = ''; SavedReportFolder = '' }
    $controls.ThemeSelector.SelectedValue = $Owner.Resources['Theme.Current']
    $controls.ThemeSelector.Add_SelectionChanged({
        param($sender, $eventArgs)
        if ($sender.SelectedValue) {
            try { Set-EndpointThemeChoice $sender.SelectedValue }
            catch { Show-EndpointError $_ }
        }
    })
    Register-EndpointShortcuts $dialog
    $dialog.Add_Closing({
        param($sender, $eventArgs)
        $dnsChanged = $sender.Tag.Controls.DnsSuffixBox.Text -cne $sender.Tag.SavedSuffix
        $tenantChanged = $sender.Tag.Controls.TenantIdBox.Text -cne $sender.Tag.SavedTenantId
        $groupsChanged = $sender.Tag.Controls.CloudGroupsBox.Text -cne $sender.Tag.SavedCloudGroups
        $reportFolderChanged = $sender.Tag.Controls.ReportFolderBox.Text -cne $sender.Tag.SavedReportFolder
        if (($dnsChanged -or $tenantChanged -or $groupsChanged -or $reportFolderChanged) -and
            -not (Confirm-EndpointAction $sender 'Discard unsaved settings changes?' 'Unsaved settings')) {
            $eventArgs.Cancel = $true
        }
    })
    $controls.HistoryButton.Add_Click({
        try { Update-EndpointHistory; Write-EndpointUiRecord -Event 'HistoryViewed' }
        catch { Show-EndpointError $_ }
    })
    $controls.ClearHistoryButton.Add_Click({
        try {
            if ($script:Ui.Active) { throw 'Wait for the running operation before clearing metadata.' }
            if (-not (Test-Path -LiteralPath $script:Ui.HistoryPath)) { Update-EndpointHistory; return }
            if (-not (Confirm-EndpointAction $script:Ui.Settings.Window 'Clear all saved run history? Activity logs and reports will not be deleted.' 'Clear run history')) { return }
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
    $controls.DnsSuffixBox.Add_TextChanged({
        Set-EndpointLiveText $script:Ui.Settings.Controls.RemoteSettingsStatus ''
    })
    $controls.SaveRemoteSettingsButton.Add_Click({
        try {
            if (-not $script:Ui.RemoteSettingsPath) { throw 'Persistent settings are disabled in offline smoke tests.' }
            try { $suffix = ConvertTo-EndpointDnsSuffix $script:Ui.Settings.Controls.DnsSuffixBox.Text }
            catch {
                $script:Ui.Settings.Controls.RemoteSettingsStatus.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Error')
                Set-EndpointLiveText $script:Ui.Settings.Controls.RemoteSettingsStatus $_.Exception.Message
                $null = $script:Ui.Settings.Controls.DnsSuffixBox.Focus()
                return
            }
            $saved = Save-EndpointRemoteSettings $script:Ui.RemoteSettingsPath $suffix
            $script:Ui.Settings.Controls.DnsSuffixBox.Text = $saved
            $script:Ui.Settings.Window.Tag.SavedSuffix = $saved
            $message = if ($saved) { "Saved. UNC shares will use the suffix $saved." } else { 'Saved. UNC shares will use the computer name as typed.' }
            $script:Ui.Settings.Controls.RemoteSettingsStatus.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Secondary')
            Set-EndpointLiveText $script:Ui.Settings.Controls.RemoteSettingsStatus $message
        }
        catch { Show-EndpointError $_ }
    })
    $controls.TenantIdBox.Add_TextChanged({
        Set-EndpointLiveText $script:Ui.Settings.Controls.TenantSettingsStatus ''
    })
    $controls.SaveTenantSettingsButton.Add_Click({
        try {
            if (-not $script:Ui.ThemePath) { throw 'Persistent settings are disabled in offline smoke tests.' }
            try { $tenantId = ConvertTo-EndpointTenantId $script:Ui.Settings.Controls.TenantIdBox.Text }
            catch {
                $script:Ui.Settings.Controls.TenantSettingsStatus.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Error')
                Set-EndpointLiveText $script:Ui.Settings.Controls.TenantSettingsStatus $_.Exception.Message
                $null = $script:Ui.Settings.Controls.TenantIdBox.Focus()
                return
            }
            $saved = Save-EndpointTenantPreference $script:Ui.ThemePath $tenantId
            $script:Ui.Settings.Controls.TenantIdBox.Text = $saved
            $script:Ui.Settings.Window.Tag.SavedTenantId = $saved
            $message = if ($saved) { "Saved. Home will use $saved when its tenant field is empty." } else { 'Saved. Home will use the account default when its tenant field is empty.' }
            $script:Ui.Settings.Controls.TenantSettingsStatus.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Secondary')
            Set-EndpointLiveText $script:Ui.Settings.Controls.TenantSettingsStatus $message
        }
        catch { Show-EndpointError $_ }
    })
    $controls.CloudGroupsBox.Add_TextChanged({
        Set-EndpointLiveText $script:Ui.Settings.Controls.CloudGroupsStatus ''
    })
    $controls.SaveCloudGroupsButton.Add_Click({
        try {
            if (-not $script:Ui.CloudUpdateSettingsPath) { throw 'Persistent settings are disabled in offline smoke tests.' }
            $saved = @(Save-EndpointCloudUpdateGroups $script:Ui.CloudUpdateSettingsPath $script:Ui.Settings.Controls.CloudGroupsBox.Text)
            $text = $saved -join "`r`n"
            $script:Ui.Settings.Controls.CloudGroupsBox.Text = $text
            $script:Ui.Settings.Window.Tag.SavedCloudGroups = $text
            Set-EndpointLiveText $script:Ui.Settings.Controls.CloudGroupsStatus "Saved $($saved.Count) rollout group name(s)."
        }
        catch { Show-EndpointError $_ }
    })
    $controls.SaveWUfBSettingsButton.Add_Click({
        try {
            if ($script:Ui.Active) { throw 'Wait for the running operation to finish before changing WUfB defaults.' }
            if (-not $script:Ui['WUfBSettingsPath']) { throw 'Persistent settings are disabled in offline smoke tests.' }
            $saved = Save-EndpointWUfBSettings $script:Ui.WUfBSettingsPath $script:Ui.Settings.Controls.WUfBWorkspaceBox.Text $script:Ui.Settings.Controls.WUfBTenantBox.Text
            Set-EndpointWUfBDefaults $saved
            Set-EndpointLiveText $script:Ui.Settings.Controls.WUfBSettingsStatus 'Saved. No Azure connection or permissions were changed.'
        }
        catch { Set-EndpointLiveText $script:Ui.Settings.Controls.WUfBSettingsStatus "Not saved. $($_.Exception.Message)" }
    })
    $controls.CloseSettingsButton.Add_Click({ $script:Ui.Settings.Window.Close() })
    $controls.ReportFolderBox.Add_TextChanged({
        Set-EndpointLiveText $script:Ui.Settings.Controls.ReportFolderStatus ''
        Set-EndpointLiveText $script:Ui.Settings.Controls.DeleteReportsStatus ''
    })
    $controls.BrowseReportFolderButton.Add_Click({
        try {
            $picker = [Microsoft.Win32.OpenFolderDialog]::new()
            $picker.InitialDirectory = $script:Ui.ReportFolder
            if ($picker.ShowDialog($script:Ui.Settings.Window)) { $script:Ui.Settings.Controls.ReportFolderBox.Text = $picker.FolderName }
        }
        catch { Show-EndpointError $_ }
    })
    $controls.SaveReportFolderButton.Add_Click({
        try {
            if (-not $script:Ui.ThemePath) { throw 'Persistent settings are disabled in offline smoke tests.' }
            $folder = Save-EndpointReportFolderPreference $script:Ui.ThemePath $script:Ui.Settings.Controls.ReportFolderBox.Text
            Set-EndpointReportFolderDefaults $folder
            $script:Ui.Settings.Controls.ReportFolderBox.Text = $folder
            $script:Ui.Settings.Window.Tag.SavedReportFolder = $folder
            $script:Ui.Settings.Controls.ReportFolderStatus.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Secondary')
            Set-EndpointLiveText $script:Ui.Settings.Controls.ReportFolderStatus 'Saved. Default report paths updated; per-run overrides and existing reports are unchanged.'
        }
        catch {
            $script:Ui.Settings.Controls.ReportFolderStatus.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Error')
            Set-EndpointLiveText $script:Ui.Settings.Controls.ReportFolderStatus $_.Exception.Message
            $null = $script:Ui.Settings.Controls.ReportFolderBox.Focus()
        }
    })
    $controls.DeleteReportsButton.Add_Click({
        $deleted = 0; $files = @(); $confirmed = $false
        $status = $script:Ui.Settings.Controls.DeleteReportsStatus
        $status.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Secondary')
        try {
            if ($script:Ui.Active -or $script:Ui.PendingBatches.Count) { throw 'Wait for the running operation to finish before deleting reports.' }
            if (-not $script:Ui.ThemePath) { throw 'Report deletion is disabled in offline smoke tests.' }
            if ($script:Ui.Settings.Controls.ReportFolderBox.Text -cne $script:Ui.Settings.Window.Tag.SavedReportFolder) {
                throw 'Save or discard the edited report folder before deleting reports.'
            }
            $folder = Get-EndpointReportFolderPreference $script:Ui.ThemePath
            if (-not (Test-Path -LiteralPath $folder -PathType Container -ErrorAction Stop)) {
                Set-EndpointLiveText $status 'The saved report folder does not exist. No reports were deleted.'
                return
            }
            $files = @(Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction Stop |
                Where-Object { $_.Extension -ieq '.csv' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                Sort-Object FullName)
            if (-not $files.Count) {
                Set-EndpointLiveText $status 'No CSV reports were found directly in the saved folder.'
                return
            }
            $message = "Permanently delete $($files.Count) CSV report(s) directly in:`r`n$folder`r`n`r`nSubfolders, other file types, and reports saved elsewhere will not be deleted. This cannot be undone."
            if (-not (Confirm-EndpointAction $script:Ui.Settings.Window $message 'Delete all reports')) {
                Set-EndpointLiveText $status 'Cancelled. No reports were deleted.'
                return
            }
            if ($script:Ui.Active -or $script:Ui.PendingBatches.Count) { throw 'An operation started during confirmation. Wait for it to finish before deleting reports.' }
            $confirmed = $true
            foreach ($file in $files) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $deleted++
            }
            Set-EndpointLiveText $status "Deleted $deleted CSV report(s). Subfolders and other files are unchanged."
            Write-EndpointUiRecord -Event 'ReportsDeleted' -State "Deleted: $deleted"
        }
        catch {
            $status.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Error')
            $message = if ($confirmed) { "Deleted $deleted of $($files.Count) CSV report(s) before deletion stopped. $($_.Exception.Message)" } else { $_.Exception.Message }
            Set-EndpointLiveText $status $message
        }
    })
    $dialog.Add_KeyDown({ param($sender,$eventArgs) if ($eventArgs.Key -eq 'Escape') { $eventArgs.Handled = $true; $sender.Close() } })
    return @{ Window = $dialog; Controls = $controls }
}

function Show-EndpointSettings {
    try {
        $created = $false
        if (-not $script:Ui.Settings) {
            $script:Ui.Settings = New-EndpointSettingsWindow $script:Ui.Window
            $script:Ui.Settings.Window.Add_Closed({ $script:Ui.Settings = $null })
            $created = $true
        }
        $script:Ui.Settings.Window.Show()
        $null = $script:Ui.Settings.Window.Activate()
        if ($created) {
            $script:Ui.Settings.Controls.HistoryTab.IsSelected = $true
            try {
                $folder = Get-EndpointReportFolderPreference $script:Ui.ThemePath
                $script:Ui.Settings.Controls.ReportFolderBox.Text = $folder
                $script:Ui.Settings.Window.Tag.SavedReportFolder = $folder
            }
            catch { Set-EndpointLiveText $script:Ui.Settings.Controls.ReportFolderStatus "Saved report folder could not be loaded. $($_.Exception.Message)" }
            if ($script:Ui.RemoteSettingsPath) {
                try {
                    $suffix = (Get-EndpointRemoteSettings $script:Ui.RemoteSettingsPath).DnsSuffix
                    $script:Ui.Settings.Controls.DnsSuffixBox.Text = $suffix
                    $script:Ui.Settings.Window.Tag.SavedSuffix = $suffix
                }
                catch { Set-EndpointLiveText $script:Ui.Settings.Controls.RemoteSettingsStatus "Saved remote settings could not be loaded. $($_.Exception.Message)" }
            }
            if ($script:Ui.ThemePath) {
                try {
                    $tenantId = Get-EndpointTenantPreference $script:Ui.ThemePath
                    $script:Ui.Settings.Controls.TenantIdBox.Text = $tenantId
                    $script:Ui.Settings.Window.Tag.SavedTenantId = $tenantId
                }
                catch { Set-EndpointLiveText $script:Ui.Settings.Controls.TenantSettingsStatus "Saved tenant setting could not be loaded. $($_.Exception.Message)" }
            }
            if ($script:Ui.ContainsKey('CloudUpdateSettingsPath') -and $script:Ui.CloudUpdateSettingsPath) {
                try {
                    $text = @(Get-EndpointCloudUpdateGroups $script:Ui.CloudUpdateSettingsPath) -join "`r`n"
                    $script:Ui.Settings.Controls.CloudGroupsBox.Text = $text
                    $script:Ui.Settings.Window.Tag.SavedCloudGroups = $text
                }
                catch { Set-EndpointLiveText $script:Ui.Settings.Controls.CloudGroupsStatus "Saved Cloud Update settings could not be loaded. $($_.Exception.Message)" }
            }
            if ($script:Ui['WUfBSettingsPath']) {
                try {
                    $saved = Get-EndpointWUfBSettings $script:Ui.WUfBSettingsPath
                    $script:Ui.Settings.Controls.WUfBWorkspaceBox.Text = $saved.WorkspaceId
                    $script:Ui.Settings.Controls.WUfBTenantBox.Text = $saved.AzureTenantId
                }
                catch { Set-EndpointLiveText $script:Ui.Settings.Controls.WUfBSettingsStatus "Saved WUfB settings could not be loaded. $($_.Exception.Message)" }
            }
        }
        Update-EndpointHistory
        Write-EndpointUiRecord -Event 'HistoryViewed'
    }
    catch { Show-EndpointError $_ }
}

function Close-EndpointSettingsBeforeMainWindow {
    param([ComponentModel.CancelEventArgs]$EventArgs)
    if (-not $script:Ui.Settings) { return }
    $script:Ui.Settings.Window.Close()
    if ($script:Ui.Settings) { $EventArgs.Cancel = $true }
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

function Clear-EndpointScriptPickerDrafts {
    $ui = $script:Ui
    if ($ui.ContainsKey('FormDrafts')) {
        foreach ($draft in $ui.FormDrafts.Values) { $draft.Picker = $null }
    }
    if ($ui.ScriptPicker) { Reset-EndpointScriptChoices }
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

function Update-EndpointReportVisual {
    $controls = $script:Ui.Controls
    $panel = $controls.ReportVisualPanel
    $panel.Children.Clear()
    if ($controls['ExportReportVisualButton']) {
        $controls.ExportReportVisualButton.IsEnabled = $null -ne $controls.ReportVisualSelector.SelectedItem
    }
    if (-not $controls.ReportVisualSelector.SelectedItem) { return }
    Add-EndpointReportCharts $panel $controls.ReportVisualSelector.SelectedItem.Charts
}

function Add-EndpointReportCharts {
    param([Windows.Controls.StackPanel]$Panel, [object[]]$Charts, [switch]$ForExport)
    foreach ($chart in $Charts) {
        $card = [Windows.Controls.Border]::new()
        $card.Padding = $panel.FindResource('Padding.Section')
        $card.Margin = $panel.FindResource('Spacing.Panel.Margin')
        $card.CornerRadius = $panel.FindResource('CornerRadius.Default')
        $card.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'Brush.Background.Elevated')
        $content = [Windows.Controls.StackPanel]::new()
        $card.Child = $content

        $title = [Windows.Controls.TextBlock]::new()
        $title.Text = if ($chart.PSObject.Properties['Metric'] -and $chart.Metric) {
            '{0} | Available points: {1:N0}' -f $chart.Title, $chart.Total
        } else { '{0} | Total: {1:N0}' -f $chart.Title, $chart.Total }
        $title.FontSize = $panel.FindResource('Font.Size.Heading')
        $title.FontWeight = 'SemiBold'
        $title.TextWrapping = 'Wrap'
        [Windows.Automation.AutomationProperties]::SetHeadingLevel($title, [Windows.Automation.AutomationHeadingLevel]::Level2)
        $null = $content.Children.Add($title)
        $basis = [Windows.Controls.TextBlock]::new()
        $basis.Text = Protect-EndpointText $chart.Basis
        $basis.TextWrapping = 'Wrap'
        $basis.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text.Secondary')
        $null = $content.Children.Add($basis)

        foreach ($bar in $chart.Bars) {
            $metric = $chart.PSObject.Properties['Metric'] -and $chart.Metric
            $share = if ($metric) { if ($chart.Scale) { $bar.Value / $chart.Scale } else { 0 } }
                elseif ($chart.Total) { $bar.Count / $chart.Total } else { 0 }
            $label = [Windows.Controls.TextBlock]::new()
            $label.Text = if ($metric) { '{0}: {1:N2} {2}' -f (Protect-EndpointText $bar.Label), $bar.Value, $chart.Unit }
                else { '{0}: {1:N0} ({2:P1})' -f (Protect-EndpointText $bar.Label), $bar.Count, $share }
            if ($bar.PSObject.Properties['Cumulative']) { $label.Text += ' | Cumulative: {0:P1}' -f $bar.Cumulative }
            $label.TextWrapping = 'Wrap'
            $label.Margin = $panel.FindResource('Spacing.Hint.Margin')
            $null = $content.Children.Add($label)

            $track = [Windows.Controls.Grid]::new()
            $track.Height = $panel.FindResource('Control.Height.ChartBar')
            $track.SetResourceReference([Windows.Controls.Panel]::BackgroundProperty, 'Brush.Background.Secondary')
            foreach ($part in @($share, (1 - $share))) {
                $column = [Windows.Controls.ColumnDefinition]::new()
                $column.Width = [Windows.GridLength]::new($part, [Windows.GridUnitType]::Star)
                $track.ColumnDefinitions.Add($column)
            }
            $fill = [Windows.Shapes.Rectangle]::new()
            $fill.SetResourceReference([Windows.Shapes.Shape]::FillProperty, "Brush.Chart.$($bar.Color)")
            $null = $track.Children.Add($fill)
            $null = $content.Children.Add($track)
            if (-not $ForExport -and $bar.PSObject.Properties['Dataset'] -and $bar.Count) {
                $button = [Windows.Controls.Button]::new()
                $button.Content = "View $($label.Text)"
                $button.HorizontalAlignment = 'Left'
                $button.Tag = $bar
                $button.Add_Click({
                    param($sender)
                    try { Show-EndpointReportCategory $sender.Tag }
                    catch { Show-EndpointError $_ }
                })
                $null = $content.Children.Add($button)
            }
        }
        $null = $panel.Children.Add($card)
    }
}

function Export-EndpointReportVisualPng {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Charts,
        [ValidateSet('Light','Dark','CatppuccinMocha','GruvboxDark')][string]$Theme = 'Light',
        [Func[bool]]$CancellationCheck
    )
    if (-not $Charts.Count) { throw 'Select a visual summary with charts before exporting.' }
    if ([IO.Path]::GetExtension($Path) -ine '.png') { throw 'Visual summary export requires a .png filename.' }
    if ($CancellationCheck -and $CancellationCheck.Invoke()) { throw 'Visual summary export was cancelled.' }
    $reader = [Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'MainWindow.xaml'))
    try { $resourcesWindow = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }
    $temporary = $null
    try {
        Set-EndpointTheme $resourcesWindow $Theme
        $root = [Windows.Controls.Border]::new()
        $root.Resources = $resourcesWindow.Resources
        $root.Background = $root.FindResource('Brush.Background.Primary')
        $root.Padding = $root.FindResource('Padding.Section')
        [Windows.Documents.TextElement]::SetFontFamily($root, $root.FindResource('Font.Family.UI'))
        [Windows.Documents.TextElement]::SetFontSize($root, $root.FindResource('Font.Size.Body'))
        [Windows.Documents.TextElement]::SetForeground($root, $root.FindResource('Brush.Text.Primary'))
        $panel = [Windows.Controls.StackPanel]::new()
        $root.Child = $panel
        $heading = [Windows.Controls.TextBlock]::new()
        $heading.Text = Protect-EndpointText $Title
        $heading.FontSize = $root.FindResource('Font.Size.Title')
        $heading.FontWeight = 'SemiBold'
        $heading.TextWrapping = 'Wrap'
        $null = $panel.Children.Add($heading)
        $caption = [Windows.Controls.TextBlock]::new()
        $caption.Text = "Exported $([datetime]::UtcNow.ToString('u')). Charts summarize retrieved data; grid filters do not change them."
        $caption.TextWrapping = 'Wrap'
        $caption.Foreground = $root.FindResource('Brush.Text.Secondary')
        $caption.Margin = $root.FindResource('Spacing.Panel.Margin')
        $null = $panel.Children.Add($caption)
        Add-EndpointReportCharts $panel $Charts -ForExport
        $width = 1200
        $root.Measure([Windows.Size]::new($width, [double]::PositiveInfinity))
        $height = [int][Math]::Ceiling($root.DesiredSize.Height)
        if ($height -le 0 -or $height -gt 20000) { throw 'This visual summary is too large for a single PNG image. Select a smaller summary.' }
        $root.Arrange([Windows.Rect]::new(0, 0, $width, $height))
        $root.UpdateLayout()
        if ($CancellationCheck -and $CancellationCheck.Invoke()) { throw 'Visual summary export was cancelled.' }
        $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($width, $height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($root)
        $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $temporary = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) ".endpoint-chart-$([guid]::NewGuid().ToString('N')).tmp"
        $stream = [IO.File]::Create($temporary)
        try { $encoder.Save($stream) }
        finally { $stream.Dispose() }
        if ($CancellationCheck -and $CancellationCheck.Invoke()) { throw 'Visual summary export was cancelled.' }
        [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
    }
    finally {
        if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        $resourcesWindow.Close()
    }
}

function Invoke-EndpointReportVisualExport {
    $ui = $script:Ui
    $startedOperation = $false
    try {
        if ($ui.Active -or $ui.PendingBatches.Count) { throw 'Wait for the current operation to finish before exporting charts.' }
        if ($ui.Faulted) { throw 'The desktop host is faulted. Restart the application before another operation.' }
        $visual = $ui.Controls.ReportVisualSelector.SelectedItem
        if (-not $visual -or -not $visual.Charts.Count) { throw 'Select a visual summary with charts before exporting.' }
        $picker = New-EndpointReportSaveDialog -Format Png
        $picker.FileName = "VisualSummary_$([datetime]::Now.ToString('yyyyMMdd-HHmmss')).png"
        if (-not $picker.ShowDialog($ui.Window)) { return }
        $ui.Active = [pscustomobject]@{
            Engine=$ui.Graph; WorkflowId='visual-summary-export'; Operation='VisualExport'
            Start=[datetime]::UtcNow; RunId=[guid]::NewGuid().ToString()
            Failures=$false; Warnings=$false; PendingApproval=$false; IsRemote=$false; Completed=$false; State=''
        }
        $startedOperation = $true
        $ui.ActivitySummary = $null; $ui.DiagnosticCount = 0
        Write-EndpointUiRecord -Event 'RunRequested' -State 'Running' -Required
        $ui.Graph.RunFile((Join-Path $PSScriptRoot 'Export-ReportVisual.ps1'), @{
            Path=$picker.FileName; Title=$visual.Title; Charts=$visual.Charts; Theme=[string]$ui.Window.Resources['Theme.Current']
        }, $true)
        $ui.Controls.RunButton.IsEnabled=$false; $ui.Controls.CancelButton.IsEnabled=$true
        $ui.Controls.Form.IsEnabled=$false; $ui.Controls.WorkflowList.IsEnabled=$false; $ui.Controls.Search.IsEnabled=$false
        $ui.Controls.SendCommandButton.IsEnabled=$false; $ui.Controls.DisconnectButton.IsEnabled=$false
        $ui.Controls.Progress.IsIndeterminate=$true
        Set-EndpointLiveText $ui.Controls.Status 'Exporting the selected visual summary to PNG. No new report data is requested.'
    }
    catch {
        if ($startedOperation) { $ui.Active = $null }
        Show-EndpointError $_
    }
}

function Clear-EndpointReportVisuals {
    $controls = $script:Ui.Controls
    $script:Ui.ReportCategory = $null
    if ($controls['ReportVisualTab']) {
        if ($controls.ReportVisualTab.IsSelected) { $controls.ActivityTab.IsSelected = $true }
        $controls.ReportVisualSelector.Items.Clear()
        $controls.ReportVisualTab.Visibility = 'Collapsed'
    }
}

function Set-EndpointReportVisual {
    param([string]$Name, [object[]]$Charts)
    $ui = $script:Ui
    $selector = $ui.Controls.ReportVisualSelector
    $title = Protect-EndpointText $Name
    $replace = $ui.Active.WorkflowId -eq 'user-sign-in-history' -or
        ($ui.Active.PSObject.Properties['Operation'] -and $ui.Active.Operation -eq 'CloudPcHistory')
    $existing = @(if ($replace) { $selector.Items | Where-Object Title -eq $title })
    $selected = $existing.Count -and [object]::ReferenceEquals($selector.SelectedItem, $existing[0])
    foreach ($item in $existing) { $selector.Items.Remove($item) }
    $visual = [pscustomobject]@{ Title = $title; Charts = $Charts }
    $null = $selector.Items.Add($visual)
    $ui.Controls.ReportVisualTab.Visibility = 'Visible'
    if ($selected) { $selector.SelectedItem = $visual }
    elseif ($selector.SelectedIndex -lt 0) { $selector.SelectedIndex = 0 }
    if ($ui.Active.PSObject.Properties['Operation'] -and $ui.Active.Operation -eq 'CloudPcHistory') {
        $selector.SelectedItem = $visual
        $ui.Controls.DatasetSelector.SelectedItem = 'Cloud PC connection history'
    }
}

function Save-EndpointReportPublication {
    param($Event)
    $active = $script:Ui.Active
    $signIns = $active.WorkflowId -eq 'user-sign-in-history'
    $history = $active.PSObject.Properties['Operation'] -and $active.Operation -eq 'CloudPcHistory'
    if (-not ($signIns -or $history)) { return $false }
    $part = switch ($Event.Kind) {
        'Rows' { 'Rows' }
        'ReportVisual' { 'Charts' }
        'Stage' { if ($signIns -and $Event.Name -eq 'Sign-in paging') { 'Paging' } }
    }
    if (-not $part) { return $false }
    if (-not $active.PSObject.Properties['ReportPublication']) {
        $active | Add-Member -NotePropertyName ReportPublication -NotePropertyValue @{}
    }
    $active.ReportPublication[$part] = $Event
    return $true
}

function Complete-EndpointReportPublication {
    $ui = $script:Ui
    $active = $ui.Active
    if (-not $active.PSObject.Properties['ReportPublication'] -or $active.State -eq 'Cancelled' -or $active.Failures) { return }
    $publication = $active.ReportPublication
    $signIns = $active.WorkflowId -eq 'user-sign-in-history'
    if (-not $publication.ContainsKey('Rows') -or -not $publication.ContainsKey('Charts') -or
        ($signIns -and -not $publication.ContainsKey('Paging'))) {
        throw 'The report refresh did not return matching rows, charts and paging information. Previous results were retained.'
    }
    Add-EndpointRows $publication.Rows.Name $publication.Rows.Data
    if ($signIns) {
        $ui.SignInPaging.HasMore = $publication.Paging.Data.HasMore
        $ui.SignInPaging.Received = $publication.Paging.Data.Received
        $ui.SignInPaging.ContinuationId = $publication.Paging.Data.ContinuationId
        Update-EndpointSignInPagingControls
    }
    Set-EndpointReportVisual $publication.Charts.Name $publication.Charts.Data
}

function Show-EndpointReportCategory {
    param($Bar)
    $ui = $script:Ui
    if (-not $ui.Datasets.ContainsKey([string]$Bar.Dataset)) { throw 'The supporting report rows are not available yet.' }
    $ui.Controls.DatasetSelector.SelectedItem = $Bar.Dataset
    $ui.ReportCategory = $Bar
    $ui.Controls.ResultsTab.IsSelected = $true
    Update-EndpointResults
    $null = $ui.Controls.ClearReportCategory.Focus()
}

function Switch-EndpointReportWorkspace {
    param([string]$WorkflowId)
    $ui = $script:Ui
    $key = if ($WorkflowId -in @('intune-assignment-win32-deployment-exports','app-install-investigation')) { $WorkflowId } else { 'Shared' }
    if ($ui.ReportWorkspace -eq $key) { return }
    $c = $ui.Controls
    $ui.ReportWorkspaces[$ui.ReportWorkspace] = @{
        Datasets=$ui.Datasets; DatasetNames=@($c.DatasetSelector.Items); Dataset=$c.DatasetSelector.SelectedItem
        Category=$ui['ReportCategory']; Filter=$c.ResultFilter.Text
        Charts=@($c.ReportVisualSelector.Items); Chart=$c.ReportVisualSelector.SelectedItem
        Artifacts=@($c.Artifacts.Items); Activity=$c.Activity.Text
        Summary=$c.RunSummary.Text; Timing=$c.RunTiming.Text
        Tab=$c.Tabs.SelectedItem; HasResults=$c.ResultsTab.IsEnabled
    }
    $ui.ReportWorkspace = $key
    $saved = $ui.ReportWorkspaces[$key]
    $ui.ReportWorkspaces.Remove($key)
    $c.DatasetSelector.Items.Clear()
    $c.ResultsGrid.ItemsSource = $null
    Clear-EndpointReportVisuals
    $c.Artifacts.Items.Clear()
    if ($saved) {
        $ui.Datasets = $saved.Datasets
        foreach ($name in $saved.DatasetNames) { $null = $c.DatasetSelector.Items.Add($name) }
        $c.DatasetSelector.SelectedItem = $saved.Dataset
        $ui.ReportCategory = $saved.Category
        $c.ResultFilter.Text = $saved.Filter
        foreach ($chart in $saved.Charts) { $null = $c.ReportVisualSelector.Items.Add($chart) }
        if ($saved.Charts.Count) { $c.ReportVisualTab.Visibility = 'Visible'; $c.ReportVisualSelector.SelectedItem = $saved.Chart }
        foreach ($artifact in $saved.Artifacts) { $null = $c.Artifacts.Items.Add($artifact) }
        $c.Activity.Text = $saved.Activity; $c.RunSummary.Text = $saved.Summary; $c.RunTiming.Text = $saved.Timing
        $c.ResultsTab.IsEnabled = $saved.HasResults
        if ($saved.Tab -and $saved.Tab.IsEnabled -and $saved.Tab.Visibility -eq 'Visible') { $c.Tabs.SelectedItem = $saved.Tab }
        if ($saved.HasResults -or $saved.Charts.Count -or $saved.Activity) { $c.OutputTab.IsSelected = $true }
    } else {
        $ui.Datasets = @{}
        $c.ResultFilter.Clear()
        $c.Activity.Clear(); $c.RunTiming.Text = ''; $c.RunSummary.Text = 'Run a task to see its output here.'
        $c.ResultsTab.IsEnabled = $false
        $c.ActivityTab.IsSelected = $true
    }
    $c.BackToRollout.Visibility = if ($key -eq 'app-install-investigation' -and
        $ui.ReportWorkspaces['intune-assignment-win32-deployment-exports'] -and
        $ui.ReportWorkspaces['intune-assignment-win32-deployment-exports'].HasResults) { 'Visible' } else { 'Collapsed' }
    Update-EndpointResults
}

function Open-EndpointFailureInvestigation {
    param([Data.DataRowView]$Row)
    $ui = $script:Ui
    if ($ui.Active -or $ui.PendingBatches.Count) { throw 'Wait for the current report to finish before opening another investigation.' }
    $device = [guid]::Parse([string]$Row['ManagedDeviceId'])
    $app = [guid]::Parse([string]$Row['ApplicationId'])
    if ($device -eq [guid]::Empty -or $app -eq [guid]::Empty) { throw 'This row does not contain usable app and managed device IDs.' }
    $controls = $ui.Controls
    $tables = @{}
    foreach ($name in $ui.Datasets.Keys) {
        if ($name -match '_(?<app>[a-f0-9-]{36})_\d{8}-\d{6}-[a-f0-9]{32}_DeviceStatus$') {
            $tables[$Matches['app']] = $ui.Datasets[$name]
        }
    }
    if (-not $tables.ContainsKey($app.ToString()) -or -not $ui['RolloutTenantId']) {
        throw 'The selected failure has no retained rollout snapshot or verified tenant. Run the rollout report before opening diagnostics.'
    }
    $ui.DiagnosticSnapshot = @{ Tables=$tables; TenantId=$ui.RolloutTenantId; AppId=$app.ToString() }
    $ui.Controls.Search.Clear()
    $ui.Controls.WorkflowList.SelectedItem = $ui.Catalog | Where-Object Id -eq 'app-install-investigation'
    $ui.FieldControls.DeviceSearchBy.SelectedItem = 'Intune device ID'
    $ui.FieldControls.DeviceSearchValue.Text = $device.ToString()
    $ui.FieldControls.AppSearchBy.SelectedItem = 'App ID'
    $ui.FieldControls.AppSearchValue.Text = $app.ToString()
    $controls.ConfigureTab.IsSelected = $true
    Set-EndpointLiveText $ui.Controls.Status 'Diagnostics will reuse the rollout snapshot. Choose Run report or Back to rollout.'
    $null = $ui.FieldControls.DeviceSearchValue.Focus()
}

function Restore-EndpointRollout {
    $ui = $script:Ui
    if ($ui.Active -or $ui.PendingBatches.Count) { return }
    $c = $ui.Controls
    $c.Search.Clear()
    $c.WorkflowList.SelectedItem = $ui.Catalog | Where-Object Id -eq 'intune-assignment-win32-deployment-exports'
    Set-EndpointLiveText $c.Status 'Rollout results restored. No new report was requested.'
}

function Get-EndpointSingleSelectedReportRow {
    $ui = $script:Ui
    $grid = $ui.Controls.ResultsGrid
    if (-not $grid.IsEnabled -or $ui.Active -or $ui.PendingBatches.Count) { return }
    $row = $null
    foreach ($cell in $grid.SelectedCells) {
        if ($null -eq $row) { $row = $cell.Item }
        elseif (-not [object]::ReferenceEquals($row, $cell.Item)) { return }
    }
    if ($row -is [Data.DataRowView]) { return $row }
}

function Get-EndpointCloudPcHistoryRow {
    $ui = $script:Ui
    if (-not $ui.Workflow -or $ui.Workflow.Id -ne 'cloudpc-inventory' -or
        $ui.Controls.DatasetSelector.SelectedItem -ne 'All Cloud PCs') { return }
    $row = Get-EndpointSingleSelectedReportRow
    $id = [guid]::Empty
    if ($row -and $row.Row.Table.Columns.Contains('CloudPCId') -and
        [guid]::TryParse([string]$row['CloudPCId'], [ref]$id) -and $id -ne [guid]::Empty) { return $row }
}

function Get-EndpointWUfBDeviceRow {
    $ui = $script:Ui
    if (-not $ui.Workflow -or $ui.Workflow.Id -ne 'wufb-report') { return }
    $row = Get-EndpointSingleSelectedReportRow
    if ($row -and $row.Row.Table.Columns.Contains('DeviceId') -and [string]$row['DeviceId']) { return $row }
}

function Update-EndpointWUfBActions {
    $ui = $script:Ui
    foreach ($name in @('OpenWUfBUpdates','OpenWUfBAlerts')) {
        if (-not $ui.Controls[$name]) { continue }
        $ui.Controls[$name].Visibility = if ($ui.Workflow -and $ui.Workflow.Id -eq 'wufb-report' -and
            $ui.Datasets.ContainsKey([string]$ui.Controls.DatasetSelector.SelectedItem) -and
            $ui.Datasets[[string]$ui.Controls.DatasetSelector.SelectedItem].Columns.Contains('DeviceId')) { 'Visible' } else { 'Collapsed' }
        $ui.Controls[$name].IsEnabled = $null -ne (Get-EndpointWUfBDeviceRow)
    }
}

function Register-EndpointWUfBActions {
    $controls = $script:Ui.Controls
    $controls.ResultsGrid.Add_SelectedCellsChanged({ Update-EndpointWUfBActions })
    $controls.ResultsGrid.Add_IsEnabledChanged({ Update-EndpointWUfBActions })
    foreach ($definition in @(
        @{ Button = 'OpenWUfBUpdates'; Dataset = 'Update records' },
        @{ Button = 'OpenWUfBAlerts'; Dataset = 'Alerts' }
    )) {
        $controls[$definition.Button].Tag = $definition.Dataset
        $controls[$definition.Button].Add_Click({
            param($sender)
            try {
                $row = Get-EndpointWUfBDeviceRow
                if (-not $row) { throw 'Select cells in one WUfB device row after the report finishes.' }
                $script:Ui.Controls.ResultFilter.Clear()
                Show-EndpointReportCategory ([pscustomobject]@{
                    Dataset = [string]$sender.Tag; Column = 'DeviceId'; Label = [string]$row['DeviceId']
                })
            }
            catch { Show-EndpointError $_ }
        })
    }
}

function Update-EndpointCloudPcHistoryAction {
    $ui = $script:Ui
    if (-not $ui.Controls['OpenCloudPcHistory']) { return }
    $ui.Controls.OpenCloudPcHistory.Visibility = if ($ui.Workflow -and $ui.Workflow.Id -eq 'cloudpc-inventory' -and
        $ui.Controls.DatasetSelector.SelectedItem -eq 'All Cloud PCs') { 'Visible' } else { 'Collapsed' }
    $ui.Controls.OpenCloudPcHistory.IsEnabled = -not $ui.Active -and
        -not ($ui['PendingBatches'] -and $ui.PendingBatches.Count) -and $null -ne (Get-EndpointCloudPcHistoryRow)
}

function Invoke-EndpointCloudPcHistory {
    $ui = $script:Ui
    $startedOperation = $false
    try {
        if ($ui.Active -or $ui.PendingBatches.Count) { throw 'Wait for the current operation to finish before loading Cloud PC history.' }
        $row = Get-EndpointCloudPcHistoryRow
        if (-not $row) { throw 'Select cells in one Cloud PC inventory row with a valid Cloud PC ID.' }
        if ($ui.Faulted) { throw 'The desktop host is faulted. Restart the application before another operation.' }
        if (-not $ui['CloudInventoryTenant']) { throw 'The inventory tenant is not verified. Run All Cloud PCs again.' }
        $id = [guid]$row['CloudPCId']
        $name = [string]$row['CloudPCName']
        $ui.Active = [pscustomobject]@{
            Engine=$ui.Graph; WorkflowId='cloudpc-inventory'; Operation='CloudPcHistory'
            Start=[datetime]::UtcNow; RunId=[guid]::NewGuid().ToString()
            Failures=$false; Warnings=$false; PendingApproval=$false; IsRemote=$false; Completed=$false; State=''
        }
        $startedOperation = $true
        $ui.ActivitySummary = $null; $ui.DiagnosticCount = 0
        Write-EndpointUiRecord -Event 'RunRequested' -State 'Running' -Required
        $ui.Graph.RunFile((Join-Path $PSScriptRoot 'Invoke-GraphSession.ps1'), @{
            Action='CloudPcHistory'; WorkflowId='cloudpc-inventory'; CloudPcId=$id; CloudPcName=$name
            InventoryTenant=$ui.CloudInventoryTenant; RequiredTenant=$ui.Workflow.ConfiguredTenant
        }, $true)
        $ui.Controls.RunButton.IsEnabled=$false; $ui.Controls.CancelButton.IsEnabled=$true
        $ui.Controls.Form.IsEnabled=$false; $ui.Controls.WorkflowList.IsEnabled=$false; $ui.Controls.Search.IsEnabled=$false
        $ui.Controls.SendCommandButton.IsEnabled=$false; $ui.Controls.DisconnectButton.IsEnabled=$false
        $ui.Controls.Progress.IsIndeterminate=$true
        Update-EndpointCloudPcHistoryAction
        Set-EndpointLiveText $ui.Controls.Status 'Loading selected Cloud PC connection history from Graph beta using existing consent...'
    }
    catch {
        if ($startedOperation) { $ui.Active = $null }
        Update-EndpointCloudPcHistoryAction
        Show-EndpointError $_
    }
}

function Get-EndpointFailureInvestigationRow {
    $row = Get-EndpointSingleSelectedReportRow
    if ($null -eq $row -or -not $row.Row.Table.Columns.Contains('ErrorByOS')) { return }
    $device = [guid]::Empty; $app = [guid]::Empty
    if ([guid]::TryParse([string]$row['ManagedDeviceId'], [ref]$device) -and $device -ne [guid]::Empty -and
        [guid]::TryParse([string]$row['ApplicationId'], [ref]$app) -and $app -ne [guid]::Empty) { return $row }
}

function Register-EndpointFailureInvestigationAction {
    $controls = $script:Ui.Controls
    $controls.ResultsGrid.Add_SelectedCellsChanged({
        $script:Ui.Controls.OpenFailureInvestigation.IsEnabled = $null -ne (Get-EndpointFailureInvestigationRow)
    })
    $controls.ResultsGrid.Add_IsEnabledChanged({
        $script:Ui.Controls.OpenFailureInvestigation.IsEnabled = $null -ne (Get-EndpointFailureInvestigationRow)
    })
    $controls.OpenFailureInvestigation.Add_Click({
        try {
            $row = Get-EndpointFailureInvestigationRow
            if (-not $row) { throw 'Select cells in one failure row with a managed device ID, after the report finishes.' }
            Open-EndpointFailureInvestigation $row
        } catch { Show-EndpointError $_ }
    })
}

function Get-EndpointErrorCodeActionValues {
    $ui = $script:Ui
    if ($ui.Controls.DatasetSelector.SelectedItem -ne 'Error code details') { return }
    $row = Get-EndpointSingleSelectedReportRow
    if ($null -eq $row -or -not [object]::ReferenceEquals($row.Row.Table, $ui.Datasets['Error code details']) -or
        -not $row.Row.Table.Columns.Contains('HexCode') -or -not $row.Row.Table.Columns.Contains('Reference')) { return }
    $code = [string]$row['HexCode']
    $reference = [string]$row['Reference']
    [pscustomobject]@{
        Code = if ($code -cmatch '\A0x[0-9A-F]{8}\z') { $code }
        Reference = if ($reference -cin @(
            'https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/app-install-error-codes'
            'https://learn.microsoft.com/en-us/windows/win32/msi/error-codes'
        )) { $reference }
    }
}

function Update-EndpointErrorCodeActions {
    $controls = $script:Ui.Controls
    if (-not $controls['ErrorCodeActions']) { return }
    $values = Get-EndpointErrorCodeActionValues
    $controls.CopyErrorCode.IsEnabled = $null -ne $values -and [bool]$values.Code
    $controls.SearchErrorCode.IsEnabled = $controls.CopyErrorCode.IsEnabled
    $controls.OpenErrorCodeReference.IsEnabled = $null -ne $values -and [bool]$values.Reference
}

function Register-EndpointErrorCodeActions {
    $controls = $script:Ui.Controls
    $controls.ResultsGrid.Add_SelectedCellsChanged({ Update-EndpointErrorCodeActions })
    $controls.ResultsGrid.Add_IsEnabledChanged({ Update-EndpointErrorCodeActions })
    $controls.CopyErrorCode.Add_Click({
        try {
            $values = Get-EndpointErrorCodeActionValues
            if ($null -eq $values -or -not $values.Code) { throw 'Select cells in one row with a numeric error code.' }
            [Windows.Clipboard]::SetText($values.Code)
        } catch { Show-EndpointError $_ }
    })
    $controls.SearchErrorCode.Add_Click({
        try {
            $values = Get-EndpointErrorCodeActionValues
            if ($null -eq $values -or -not $values.Code) { throw 'Select cells in one row with a numeric error code.' }
            Start-Process "https://www.bing.com/search?q=$($values.Code)" -ErrorAction Stop
        } catch { Show-EndpointError $_ }
    })
    $controls.OpenErrorCodeReference.Add_Click({
        try {
            $values = Get-EndpointErrorCodeActionValues
            if ($null -eq $values -or -not $values.Reference) { throw 'Select cells in one row with a Microsoft Learn reference.' }
            Start-Process $values.Reference -ErrorAction Stop
        } catch { Show-EndpointError $_ }
    })
}

function New-EndpointSignInCalendar {
    param([string]$DateList, [string]$Label)
    $calendar = [Windows.Controls.Calendar]::new()
    $calendar.SelectionMode = 'MultipleRange'
    [Windows.Automation.AutomationProperties]::SetName($calendar, $Label)
    $style = [Windows.Style]::new([Windows.Controls.Primitives.CalendarDayButton])
    $style.Setters.Add([Windows.Setter]::new([Windows.UIElement]::IsHitTestVisibleProperty, $false))
    $style.Setters.Add([Windows.Setter]::new([Windows.UIElement]::FocusableProperty, $false))
    $calendar.CalendarDayButtonStyle = $style
    $calendar.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -in @('Tab','Escape')) { return }
        if ($eventArgs.Key -in @('PageUp','PageDown')) {
            $step = if ($eventArgs.Key -eq 'PageUp') { -1 } else { 1 }
            $sender.DisplayDate = $sender.DisplayDate.AddMonths($step)
        }
        $eventArgs.Handled = $true
    })
    foreach ($date in $DateList.Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
        $calendar.SelectedDates.Add([datetime]::ParseExact($date, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture))
    }
    if ($calendar.SelectedDates.Count) {
        $calendar.DisplayDate = $calendar.SelectedDates[$calendar.SelectedDates.Count - 1]
    }
    return $calendar
}

function Show-EndpointSignInDays {
    param([Data.DataRowView]$Row)
    $dialog = [Windows.Window]::new()
    $dialog.Owner = $script:Ui.Window
    $dialog.Title = Protect-EndpointText "Sign-in days - $($Row['DeviceName'])"
    $dialog.SizeToContent = 'WidthAndHeight'
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.Resources.MergedDictionaries.Add($dialog.Owner.Resources)
    $dialog.SetResourceReference([Windows.Window]::BackgroundProperty, 'Brush.Background.Primary')
    $dialog.SetResourceReference([Windows.Window]::ForegroundProperty, 'Brush.Text.Primary')
    $dialog.SetResourceReference([Windows.Window]::FontFamilyProperty, 'Font.Family.UI')
    $dialog.SetResourceReference([Windows.Window]::FontSizeProperty, 'Font.Size.Body')
    $panel = [Windows.Controls.StackPanel]::new()
    $panel.Margin = $dialog.FindResource('Spacing.Dialog.Margin')
    $dialog.Content = $panel
    $title = [Windows.Controls.TextBlock]::new()
    $title.Text = 'Highlighted dates are successful Entra sign-in days (UTC). Use Page Up or Page Down to change month.'
    $title.TextWrapping = 'Wrap'
    $title.MaxWidth = 460
    $null = $panel.Children.Add($title)
    $calendars = [Windows.Controls.WrapPanel]::new()
    $null = $panel.Children.Add($calendars)
    foreach ($side in @(
        @{ Title = 'Assigned Intune user'; User = 'IntunePrimaryUser'; Dates = 'AssignedSignInDaysUtc' }
        @{ Title = 'Observed top user'; User = 'ObservedTopUser'; Dates = 'ObservedSignInDaysUtc' }
    )) {
        $column = [Windows.Controls.StackPanel]::new()
        $column.Margin = $dialog.FindResource('Spacing.Button.Margin')
        $label = [Windows.Controls.TextBlock]::new()
        $user = [string]$Row[$side.User]
        $label.Text = "$($side.Title): $(if ($user) { $user } else { 'Not available' })"
        $label.TextWrapping = 'Wrap'
        $label.MaxWidth = 220
        $null = $column.Children.Add($label)
        $dates = [string]$Row[$side.Dates]
        if ($dates) {
            $null = $column.Children.Add((New-EndpointSignInCalendar $dates $label.Text))
        } else {
            $empty = [Windows.Controls.TextBlock]::new()
            $empty.Text = 'No dates available.'
            $null = $column.Children.Add($empty)
        }
        $null = $calendars.Children.Add($column)
    }
    $close = [Windows.Controls.Button]::new()
    $close.Content = '_Close'; $close.IsCancel = $true; $close.HorizontalAlignment = 'Right'
    $close.Margin = $dialog.FindResource('Spacing.Dialog.Buttons.Margin')
    $close.Tag = $dialog
    $close.Add_Click({ param($sender) $sender.Tag.Close() })
    $null = $panel.Children.Add($close)
    $null = $dialog.ShowDialog()
}

function Update-EndpointResults {
    $ui = $script:Ui
    if (-not $ui.ContainsKey('ResultFilterState')) {
        $timer = [Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [timespan]::FromMilliseconds(50)
        $timer.Add_Tick({
            $measure = if ($script:Ui.ContainsKey('FilterTickTiming')) { [Diagnostics.Stopwatch]::StartNew() } else { $null }
            try { Receive-EndpointResultFilter }
            catch {
                $script:Ui.ResultFilterState.Timer.Stop()
                $script:Ui.Controls.ResultFilterStatus.Text = 'Filtering failed. Change the filter to try again.'
                Show-EndpointError $_
            }
            finally { if ($measure) { $script:Ui.FilterTickTiming = [Math]::Max($script:Ui.FilterTickTiming, $measure.ElapsedMilliseconds) } }
        })
        $ui.ResultFilterState = @{ Timer=$timer; Version=0; Task=$null; View=$null; Table=$null; Filter=$null }
    }
    $state = $ui.ResultFilterState
    $name = $ui.Controls.DatasetSelector.SelectedItem
    Update-EndpointCloudPcHistoryAction
    Update-EndpointWUfBActions
    if ($ui.Controls['ErrorCodeActions']) {
        $ui.Controls.ErrorCodeActions.Visibility = if ($name -eq 'Error code details' -and $ui.Datasets.ContainsKey([string]$name)) { 'Visible' } else { 'Collapsed' }
        Update-EndpointErrorCodeActions
    }
    $category = $ui['ReportCategory']
    if ($category -and $category.Dataset -ne $name) { $ui.ReportCategory = $null; $category = $null }
    if ($ui.Controls['ClearReportCategory']) {
        $ui.Controls.ClearReportCategory.Visibility = if ($category) { 'Visible' } else { 'Collapsed' }
        if ($category) { $ui.Controls.ClearReportCategory.Content = "Clear category: $($category.Label)" }
    }
    if (-not $name -or -not $ui.Datasets.ContainsKey([string]$name)) {
        if ($ui.Controls['OpenSignInDays']) { $ui.Controls.OpenSignInDays.Visibility = 'Collapsed' }
        if ($ui.Controls['OpenFailureInvestigation']) { $ui.Controls.OpenFailureInvestigation.Visibility = 'Collapsed' }
        if ($state.Task) { $state.Cancellation.Cancel() }
        $state.Version++; $state.Table = $null; $state.View = $null; $state.Filter = $null
        $ui.Controls.ResultsGrid.ItemsSource = $null; $ui.Controls.ResultsGrid.IsEnabled = $true
        $ui.Controls.SaveResultsButton.IsEnabled = $false; $ui.Controls.ResultFilterStatus.Text = ''
        if ($state.Task) { $state.Timer.Start() } else { $state.Timer.Stop() }
        return
    }
    $table = $ui.Datasets[[string]$name]
    if ($ui.Controls['OpenSignInDays']) {
        $ui.Controls.OpenSignInDays.Visibility = if ($table.Columns.Contains('ObservedSignInDaysUtc')) { 'Visible' } else { 'Collapsed' }
    }
    if ($ui.Controls['OpenFailureInvestigation']) {
        $ui.Controls.OpenFailureInvestigation.Visibility = if ($table.Columns.Contains('ErrorByOS')) { 'Visible' } else { 'Collapsed' }
    }
    $filter = $ui.Controls.ResultFilter.Text
    if ([object]::ReferenceEquals($state.Table, $table) -and $state.Filter -ceq $filter -and
        [object]::ReferenceEquals($state['Category'], $category)) { return }
    if ($state.Task) { $state.Cancellation.Cancel() }
    $state.Version++; $state.Table = $table; $state.Filter = $filter; $state.Category = $category
    $state.Due = [datetime]::UtcNow.AddMilliseconds(200)
    if (-not $filter -and -not $category) {
        $state.View = $table.DefaultView
        if ($table.ExtendedProperties['PreparedForDesktop']) {
            $ui.Controls.ResultsGrid.ItemsSource = [EndpointToolbox.ReportRows]::new($state.View)
        } else { $ui.Controls.ResultsGrid.ItemsSource = $state.View }
        $ui.Controls.ResultsGrid.IsEnabled = $true; $ui.Controls.SaveResultsButton.IsEnabled = $true
        $ui.Controls.ResultFilterStatus.Text = ''
        if ($state.Task) { $state.Timer.Start() } else { $state.Timer.Stop() }
        return
    }
    $state.View = $null
    $ui.Controls.ResultsGrid.IsEnabled = $false; $ui.Controls.SaveResultsButton.IsEnabled = $false
    $ui.Controls.ResultFilterStatus.Text = 'Filtering report...'
    $state.Timer.Start()
}

function Receive-EndpointResultFilter {
    $ui = $script:Ui
    $state = $ui.ResultFilterState
    if ($state.Task) {
        if (-not $state.Task.IsCompleted) { return }
        try {
            $view = $state.Task.GetAwaiter().GetResult()
            if ($state.TaskVersion -eq $state.Version) {
                $state.View = $view
                $ui.Controls.ResultsGrid.ItemsSource = $view
                $ui.Controls.ResultsGrid.IsEnabled = $true; $ui.Controls.SaveResultsButton.IsEnabled = $true
                $ui.Controls.ResultFilterStatus.Text = ''
            }
        }
        catch {
            if ($state.TaskVersion -eq $state.Version) {
                $ui.Controls.ResultFilterStatus.Text = 'Filtering failed. Change the filter to try again.'
                $state.Cancellation.Dispose(); $state.Cancellation = $null
                $state.Task = $null; $state.Timer.Stop()
                Show-EndpointError $_
                return
            }
            if (-not $state.Task.IsCanceled) { Write-Verbose "Superseded report filter failed: $($_.Exception.Message)" }
        }
        $state.Cancellation.Dispose(); $state.Cancellation = $null
        $state.Task = $null
    }
    if ($null -eq $state.Table -or (-not $state.Filter -and -not $state['Category']) -or $null -ne $state.View) { $state.Timer.Stop(); return }
    if ([datetime]::UtcNow -lt $state.Due) { return }
    # Non-prepared tables can still receive rows on the UI thread during a run.
    if ($ui.Active -and -not $state.Table.ExtendedProperties['PreparedForDesktop']) {
        $ui.Controls.ResultFilterStatus.Text = 'Waiting for report rows to finish loading.'
        return
    }
    $state.TaskVersion = $state.Version
    $state.Cancellation = [Threading.CancellationTokenSource]::new()
    $defaultView = $state.Table.DefaultView
    $useDefaultView = -not $defaultView.Sort -and $defaultView.Count -eq $state.Table.Rows.Count
    $category = $state['Category']
    $column = if ($category) { $category.Column }
    $value = if ($category) { $category.Label }
    $state.Task = [EndpointToolbox.ReportFilter]::Start($state.Table, $defaultView, $useDefaultView, $defaultView.Sort, $state.Filter, $state.Cancellation.Token, $column, $value)
}

function Invoke-EndpointRun {
    param([ValidateSet('New','More','All')][string]$SignInAction = 'New')
    $ui = $script:Ui
    if ($ui.Active -or $ui.PendingBatches.Count) { return }
    $workflow = $ui.Workflow
    try {
        Clear-EndpointFieldErrors
        if ($ui.Faulted) { throw 'The desktop host is faulted. Restart the application before another operation.' }
        $workflow = $ui.Workflow
        if (-not $workflow) { throw 'Select a workflow.' }
        $values = @{}
        foreach ($field in $workflow.Fields) {
            $control = $ui.FieldControls[$field.Name]
            $values[$field.Name] = if ($field.Type -eq [switch]) { [bool]$control.IsChecked } elseif ($control -is [Windows.Controls.ComboBox] -and -not $control.IsEditable) { [string]$control.SelectedItem } else { $control.Text }
        }
        if ($SignInAction -ne 'New') {
            if ($workflow.Id -ne 'user-sign-in-history' -or -not $ui['SignInPaging'] -or -not $ui.SignInPaging.HasMore) {
                throw 'No sign-in page is available to continue. Run a new report.'
            }
            $arguments = $ui.SignInPaging.Arguments.Clone()
        }
        else { $arguments = Get-EndpointArguments $workflow $values $ui.Inactive }
        if ($workflow.Id -eq 'app-install-investigation' -and $ui['DiagnosticSnapshot'] -and
            $arguments.AppSearchBy -eq 'App ID' -and $arguments.AppSearchValue -eq $ui.DiagnosticSnapshot.AppId) {
            $arguments.DeploymentSnapshot = $ui.DiagnosticSnapshot.Tables
            $arguments.SnapshotTenantId = $ui.DiagnosticSnapshot.TenantId
        }
        if ($workflow.Id -eq 'm365-cloud-update') {
            try { Set-EndpointCloudUpdateGroupsArgument $arguments $ui.CloudUpdateSettingsPath }
            catch { Throw-EndpointFieldError 'IncludeWaveGroups' $_.Exception.Message }
        }
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
        $requiresGraph = $workflow.Kind -eq 'Graph' -or ($workflow.Id -eq 'm365-cloud-update' -and $arguments['IncludeWaveGroups']) -or
            ($workflow.Id -eq 'wufb-report' -and $arguments['ResolveDeviceNames'])
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
        if ($workflow.Id -eq 'intune-assignment-win32-deployment-exports') {
            $ui.DiagnosticSnapshot = $null; $ui.RolloutTenantId = ''
        }
        if ($SignInAction -eq 'New') {
            if ($workflow.Id -eq 'cloudpc-inventory') { $ui.CloudInventoryTenant = '' }
            $ui.SignInPaging = if ($workflow.Id -eq 'user-sign-in-history') { @{ Arguments=$arguments.Clone(); HasMore=$false; Received=0; ContinuationId='' } } else { $null }
            $ui.Datasets = @{}; $ui.Controls.DatasetSelector.Items.Clear(); $ui.Controls.ResultsGrid.ItemsSource = $null
            $ui.Controls.ResultsTab.IsEnabled = $false
        }
        if ($SignInAction -eq 'New') { Clear-EndpointReportVisuals }
        $ui.Controls.Artifacts.Items.Clear(); $ui.Controls.Activity.Clear(); $ui.Choice = $null
        $engine = if ($workflow.Kind -eq 'Remote') { $ui.Remote } else { $ui.Graph }
        if ($workflow.Kind -eq 'Remote') { $ui.RemoteTarget = [string]$arguments['Device'] }
        $ui.Active = [pscustomobject]@{ Engine = $engine; WorkflowId = $workflow.Id; Operation = 'Report'; SignInAction = $SignInAction; Start = [datetime]::UtcNow; RunId = [guid]::NewGuid().ToString(); Failures = $false; Warnings = $false; PendingApproval = $false; IsRemote = $workflow.Kind -eq 'Remote'; Completed = $false; State = '' }
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
        if ($workflow.Id -eq 'user-sign-in-history') {
            $invocation.SignInAction = $SignInAction
            $invocation.SignInContinuationId = $ui.SignInPaging.ContinuationId
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
        Update-EndpointSignInPagingControls
    }
    catch {
        Write-EndpointUiRecord -Event 'RunStartFailed' -State 'Failed' -Message $_
        $ui.Active = $null
        Update-EndpointErrorCodeActions
        $field = $_.Exception.Data['EndpointField']
        if ($field -and (Show-EndpointFieldError $field $_.Exception.Message)) { return }
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
        if ($Action -in @('Connect','Disconnect')) { Clear-EndpointScriptPickerDrafts }
        $ui.Active = [pscustomobject]@{ Engine=$ui.Graph; WorkflowId="graph-session-$($Action.ToLowerInvariant())"; Start=[datetime]::UtcNow; RunId=[guid]::NewGuid().ToString(); Failures=$false; Warnings=$false; PendingApproval=$false; IsRemote=$false; Completed=$false; State='' }
        $ui.ActivitySummary=$null; $ui.DiagnosticCount=0
        Show-EndpointGraphSession ([pscustomobject]@{State='Unverified';Account='';Message="$Action in progress. Wait for the worker result; no task is running."})
        Write-EndpointUiRecord -Event 'RunRequested' -State 'CheckingGraph' -Required
        $ui.Graph.RunFile((Join-Path $PSScriptRoot 'Invoke-GraphSession.ps1'), @{
            Action=$Action
            TenantId=$(if ($Action -eq 'Connect') { Get-EndpointGraphTenant $ui.Controls.GraphTenant.Text $ui.ThemePath } else { '' })
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

function Get-EndpointGraphTenant {
    param([AllowNull()][string]$Override, [AllowNull()][string]$SettingsPath)
    $tenantId = ConvertTo-EndpointTenantId $Override
    if ($tenantId) { return $tenantId }
    if ($SettingsPath) { return Get-EndpointTenantPreference $SettingsPath }
    return ''
}

function Add-EndpointRows {
    param([string]$Name, [object]$Rows)
    $ui = $script:Ui
    $replace = $ui.Active -and $ui.Datasets.ContainsKey($Name) -and (
        ($Name -eq 'Sign-in events' -and $ui.Active.WorkflowId -eq 'user-sign-in-history') -or
        ($Name -eq 'Cloud PC connection history' -and $ui.Active.PSObject.Properties['Operation'] -and $ui.Active.Operation -eq 'CloudPcHistory'))
    if ($Rows -is [EndpointToolbox.PreparedReport]) {
        $table = $Rows.Table
        if ($ui.Datasets.ContainsKey($Name) -and -not $replace) { throw "A prepared report was published more than once: $Name" }
        $ui.Datasets[$Name] = $table
        if (-not $ui.ContainsKey('ActivitySummary') -or $null -eq $ui.ActivitySummary) {
            $ui.Active.Failures = $ui.Active.Failures -or $Rows.HasFailures
            $ui.Active.Warnings = $ui.Active.Warnings -or $Rows.HasWarnings
            $ui.Active.PendingApproval = $ui.Active.PendingApproval -or $Rows.PendingApproval
        }
        if (-not $replace) { $null = $ui.Controls.DatasetSelector.Items.Add($Name) }
        $ui.Controls.ResultsTab.IsEnabled = $true
        if ($replace) { Update-EndpointResults }
        return
    }
    if ($replace) { $ui.Datasets.Remove($Name); $ui.Controls.DatasetSelector.Items.Remove($Name) }
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
    $retainReport = $ui.Active.WorkflowId -eq 'user-sign-in-history' -or
        ($ui.Active.PSObject.Properties['Operation'] -and $ui.Active.Operation -eq 'CloudPcHistory')
    Write-EndpointUiRecord -Event 'CancellationRequested' -State 'Cancelling'
    $ui.Active.Engine.Cancel()
    $ui.PendingBatches.Clear()
    if ($ui.Active.PSObject.Properties['Operation'] -and $ui.Active.Operation -eq 'Report' -and
        -not ($ui.Active.WorkflowId -eq 'user-sign-in-history' -and $ui.Active.PSObject.Properties['SignInAction'] -and $ui.Active.SignInAction -ne 'New')) { Clear-EndpointReportVisuals }
    $ui.Choice = $null
    $ui.Controls.CancelButton.IsEnabled = $false
    $ui.Controls.Progress.IsIndeterminate = $true
    Set-EndpointLiveText $ui.Controls.Status $(if ($retainReport) {
        'Stopping worker; uncommitted report refresh discarded. Previously displayed rows and charts are retained.'
    } else { 'Stopping worker; queued display output discarded. Existing results are partial. Waiting only for the current operation to stop.' })
    Add-EndpointActivity 'Cancellation requested' $(if ($retainReport) {
        'Uncommitted rows, charts and paging updates will not replace the previous report. Files already saved remain available.'
    } else { 'Queued log/report rendering was discarded. Displayed data may be incomplete; files already saved remain available. Requests already submitted to remote services cannot be undone.' })
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
            if (Save-EndpointReportPublication $event) { continue }
            switch ($event.Kind) {
                'OperationSummary' {
                    $ui.ActivitySummary = $event.Data
                    if ($event.Data.Failed -gt 0) { $ui.Active.Failures = $true }
                    if ($event.Data.NotFound -gt 0 -or -not $event.Data.CountsComplete) { $ui.Active.Warnings = $true }
                    if ($event.Data.PendingApproval -gt 0) { $ui.Active.PendingApproval = $true }
                }
                { $_ -in @('Rows', 'Summary') } { Add-EndpointRows $event.Name $event.Data }
                'ReportVisual' {
                    Set-EndpointReportVisual $event.Name $event.Data
                }
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
                'GraphSession' {
                    Show-EndpointGraphSession $event.Data
                    if ($ui.Active.WorkflowId -eq 'cloudpc-inventory' -and $ui.Active.PSObject.Properties['Operation'] -and
                        $ui.Active.Operation -eq 'Report' -and $event.Data.State -eq 'Checked') {
                        $ui.CloudInventoryTenant = [string]$event.Data.TenantId
                    }
                    if ($ui.Active.WorkflowId -eq 'intune-assignment-win32-deployment-exports') {
                        $ui.RolloutTenantId = if ($event.Data.State -eq 'Checked') { [string]$event.Data.TenantId } else { '' }
                    }
                }
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
            Complete-EndpointReportPublication
            $scriptDiscovery = $ui.Active.PSObject.Properties['Operation'] -and $ui.Active.Operation -eq 'ScriptDiscovery'
            $visualExport = $ui.Active.PSObject.Properties['Operation'] -and $ui.Active.Operation -eq 'VisualExport'
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
                elseif ($ui.Active.State -eq 'Cancelled' -and ($ui.Active.WorkflowId -eq 'user-sign-in-history' -or
                    ($ui.Active.PSObject.Properties['Operation'] -and $ui.Active.Operation -eq 'CloudPcHistory'))) {
                    'Cancelled; uncommitted refresh discarded, previous report retained'
                }
                elseif ($ui.Active.State -eq 'Cancelled') { 'Cancelled; queued display output discarded, results may be incomplete' }
                elseif ($ui.Active.Failures) { 'Partial failure / failed; review datasets and diagnostics' }
                elseif ($ui.Active.PendingApproval) { 'Completed; one or more actions pending approval' }
                elseif ($ui.Active.Warnings) { 'Finished with warnings - review script output' }
                elseif ($visualExport) { 'PNG saved; open Saved reports to view the image' } else { 'Script finished - review output' }
            $rows = 0
            if (-not $homeOperation -and -not $scriptDiscovery -and -not $visualExport) { foreach ($table in $ui.Datasets.Values) { $rows += $table.Rows.Count } }
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
            elseif ($visualExport) { Set-EndpointLiveText $ui.Controls.Status $state }
            else { Set-EndpointLiveText $ui.Controls.Status "$state | $rows data rows. Review script output for the original action outcomes and warnings." }
            $taskTitle = $ui.Catalog | Where-Object Id -eq $ui.Active.WorkflowId | Select-Object -ExpandProperty Title -First 1
            if ($visualExport) { $taskTitle = 'Visual summary PNG export' }
            if (-not $taskTitle) { $taskTitle = $ui.Active.WorkflowId }
            if (-not $homeOperation) {
                $runSummary = if ($scriptDiscovery) { "$taskTitle`: $state. No device status report was run." } else { "$taskTitle`: $state." }
                if (-not $scriptDiscovery -and -not $visualExport -and $ui.Active.WorkflowId -ne 'm365-cloud-update') { $runSummary += " $rows report rows. Script output is authoritative for action outcomes, skipped items and pending approvals." }
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
            if ($rows -and -not $ui.Active.Failures -and $ui.Active.State -ne 'Cancelled' -and -not $visualExport) { $ui.Controls.ResultsTab.IsSelected = $true }
            if ($ui.Active.WorkflowId -eq 'remote-endpoint' -and $ui.Remote.Connected) { $ui.Controls.RemoteTab.IsSelected = $true }
            $ui.Controls.Progress.IsIndeterminate = $false; $ui.Controls.Progress.Value = 0
            $ui.Controls.RunButton.IsEnabled = $true; $ui.Controls.CancelButton.IsEnabled = $false
            $ui.Controls.Form.IsEnabled = $true; $ui.Controls.WorkflowList.IsEnabled = $true
            $ui.Controls.Search.IsEnabled = $true
            if (-not $homeOperation) { Update-EndpointRunTiming -Finished }
            $ui.Active = $null
            Update-EndpointCloudPcHistoryAction
            Update-EndpointErrorCodeActions
            if ($ui.Controls['OpenFailureInvestigation'] -and $ui.Controls.OpenFailureInvestigation.Visibility -eq 'Visible') {
                $ui.Controls.OpenFailureInvestigation.IsEnabled = $null -ne (Get-EndpointFailureInvestigationRow)
            }
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
    if (-not $bridgeVersion -or $bridgeVersion.GetRawConstantValue() -ne 13) {
        throw 'An older desktop hosting bridge is loaded. Launch Start-EndpointToolboxUI.ps1 to open the updated application in a fresh PowerShell process.'
    }
    $preferencesPath = if ($ValidateOnly -or $SmokeTest) { '' } else { Join-Path $env:LOCALAPPDATA 'EndpointToolbox\settings.json' }
    if ($preferencesPath) { Initialize-EndpointSettings $preferencesPath }
    else { $null = Read-EndpointSettingsDocument (Join-Path $PSScriptRoot 'EndpointToolbox.defaults.json') }
    $reportFolder = Get-EndpointReportFolderPreference $preferencesPath
    $catalog = @(Get-EndpointCatalog -ReportFolder $reportFolder)
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
        foreach ($theme in @('Dark','CatppuccinMocha','GruvboxDark')) { Set-EndpointTheme $window $theme }
        Set-EndpointTheme $window Light
        $settings = New-EndpointSettingsWindow $window
        $settings.Window.Close()
    }
    if ($ValidateOnly) { $window.Close(); return $catalog }
    $logRoot = if ($SmokeTest) { '' } else { Join-Path $env:LOCALAPPDATA 'EndpointToolbox\Logs' }
    if ($logRoot) { Write-EndpointActivityRecord -LogRoot $logRoot -Event 'AppStarted' }
    $controls = @{}
    foreach ($name in @('ContextLabel','Status','Progress','Search','SearchEmpty','SettingsButton','WorkflowList','WorkflowTitle','CategoryLabel','RiskBadge','RiskLabel','Description','ScriptPath','Form','FormScroll','WorkflowGuide','ExecutionHint','WorkspaceTabs','ConfigureTab','OutputTab','RunSummary','RunTiming','ActivityTab','ResultsTab','RunButton','CancelButton','DisconnectButton','SaveResultsButton','SaveLogButton','SaveRemoteLogButton','OpenArtifactButton','Tabs','DatasetSelector','ResultFilter','ResultFilterStatus','ResultsGrid','Activity','Artifacts','RemoteTab','RemoteStatus','RemoteCommandPicker','RemoteCommandDescription','RemoteCommand','SendCommandButton','RemoteOutput','RemoteBusyIndicator')) {
        $controls[$name] = $window.FindName($name)
        if (-not $controls[$name]) { throw "Required desktop control is missing: $name" }
    }
    foreach ($name in @('HomeButton','HomePanel','TaskPanel','GraphTenant','GraphConnectButton','GraphCheckButton','GraphDisconnectButton','GraphStopButton','OpenPimButton','ReturnToTaskButton','GraphSessionStatus','GraphSessionDetails','ReportVisualTab','ReportVisualSelector','ReportVisualPanel','ExportReportVisualButton','ClearReportCategory','OpenSignInDays','OpenWUfBUpdates','OpenWUfBAlerts','OpenCloudPcHistory','OpenFailureInvestigation','ErrorCodeActions','CopyErrorCode','OpenErrorCodeReference','SearchErrorCode','SignInPagingActions','LoadMoreSignIns','RetrieveAllSignIns','SignInPagingStatus')) {
        $controls[$name]=$window.FindName($name)
        if (-not $controls[$name]) { throw "Required desktop control is missing: $name" }
    }
    $script:Ui = @{
        Window = $window; Controls = $controls; Settings = $null; Catalog = $catalog; Workflow = $null; FieldControls = @{}; FieldRows = @{}
        Selectors = @(); Inactive = @(); Datasets = @{}; PendingBatches = [Collections.Generic.Queue[object]]::new()
        ReportWorkspace = 'Shared'; ReportWorkspaces = @{}
        Graph = [EndpointToolbox.DesktopEngine]::new(); Remote = [EndpointToolbox.DesktopEngine]::new()
        Active = $null; Choice = $null; ScriptPicker = $null; Timer = [Windows.Threading.DispatcherTimer]::new()
        HistoryPath = Join-Path $env:LOCALAPPDATA 'EndpointToolbox\history.jsonl'
        LogRoot = $logRoot
        ThemePath = if ($SmokeTest) { '' } else { Join-Path $env:LOCALAPPDATA 'EndpointToolbox\settings.json' }
        ReportFolder = $reportFolder
        RecentDevicesPath = if ($SmokeTest) { '' } else { Join-Path $env:LOCALAPPDATA 'EndpointToolbox\recent-devices.json' }
        RemoteSettingsPath = $preferencesPath
        CloudUpdateSettingsPath = $preferencesPath
        WUfBSettingsPath = $preferencesPath
        ActivitySummary = $null; DiagnosticCount = 0
        TestMode = [bool]$SmokeTest
        RemoteTarget = ''
        Timings = @{ Events = 0; Rows = 0; Binding = 0; Completion = 0 }
        Faulted = $false
        ReceivingEvents = $false
        ActivityBuffer = $null; RemoteBuffer = $null
        FormDrafts = @{}; RemoteCommandSelection = $null; RemoteCommandSelectionChanging = $false
        GraphContext = $null
        GraphSession = $null
    }
    try { Set-EndpointWUfBDefaults (Get-EndpointWUfBSettings $script:Ui.WUfBSettingsPath) }
    catch { Show-EndpointError $_ }
    Initialize-EndpointTheme
    Register-EndpointShortcuts $window
    $controls.RemoteCommandPicker.ItemsSource = $remoteCommands
    $controls.RemoteCommandPicker.Add_SelectionChanged({ Update-EndpointRemoteCommandSelection })
    $controls.WorkflowList.Add_SelectionChanged({ New-EndpointForm })
    Set-EndpointNavigation -InitiallyCollapsed
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
        param($sender, $eventArgs)
        $item = [Windows.Controls.ItemsControl]::ContainerFromElement($sender, $eventArgs.OriginalSource)
        if ($item -is [Windows.Controls.ListBoxItem] -and $script:Ui.Workflow) {
            $script:Ui.Controls.HomePanel.Visibility='Collapsed'
            $script:Ui.Controls.TaskPanel.Visibility='Visible'
        }
    })
    $controls.WorkflowList.Add_KeyDown({
        param($sender,$eventArgs)
        if ($eventArgs.Key -eq 'Return' -and $eventArgs.OriginalSource -isnot [Windows.Controls.Primitives.ToggleButton] -and $script:Ui.Controls.WorkflowList.SelectedItem -and $script:Ui.Workflow) {
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
    $controls.BackToRollout = $window.FindName('BackToRollout')
    $controls.BackToRollout.Add_Click({ try { Restore-EndpointRollout } catch { Show-EndpointError $_ } })
    $controls.RunButton.Add_Click({ Invoke-EndpointRun })
    $controls.LoadMoreSignIns.Add_Click({ Invoke-EndpointRun -SignInAction More })
    $controls.RetrieveAllSignIns.Add_Click({ Invoke-EndpointRun -SignInAction All })
    $controls.CancelButton.Add_Click({ Stop-EndpointOperation })
    $controls.DatasetSelector.Add_SelectionChanged({ try { Update-EndpointResults } catch { Show-EndpointError $_ } })
    $controls.ResultFilter.Add_TextChanged({ try { Update-EndpointResults } catch { Show-EndpointError $_ } })
    $controls.ReportVisualSelector.Add_SelectionChanged({ try { Update-EndpointReportVisual } catch { Show-EndpointError $_ } })
    $controls.ExportReportVisualButton.Add_Click({ Invoke-EndpointReportVisualExport })
    $controls.ClearReportCategory.Add_Click({
        try { $script:Ui.ReportCategory = $null; Update-EndpointResults; $null = $script:Ui.Controls.ResultFilter.Focus() }
        catch { Show-EndpointError $_ }
    })
    $controls.ResultsGrid.Add_AutoGeneratingColumn({
        param($sender, $eventArgs)
        if ($eventArgs.PropertyName -in @('AssignedSignInDaysUtc','ObservedSignInDaysUtc')) { $eventArgs.Cancel = $true }
    })
    $controls.ResultsGrid.Add_CurrentCellChanged({
        $ui = $script:Ui
        $item = $ui.Controls.ResultsGrid.CurrentCell.Item
        $ui.Controls.OpenSignInDays.IsEnabled = $item -is [Data.DataRowView] -and $item.Row.Table.Columns.Contains('ObservedSignInDaysUtc')
    })
    $controls.ResultsGrid.Add_SelectedCellsChanged({ Update-EndpointCloudPcHistoryAction })
    $controls.OpenCloudPcHistory.Add_Click({ Invoke-EndpointCloudPcHistory })
    Register-EndpointFailureInvestigationAction
    Register-EndpointWUfBActions
    Register-EndpointErrorCodeActions
    $controls.OpenSignInDays.Add_Click({
        try {
            $grid = $script:Ui.Controls.ResultsGrid
            $item = $grid.CurrentCell.Item
            if ($grid.IsEnabled -and $item -is [Data.DataRowView] -and $item.Row.Table.Columns.Contains('ObservedSignInDaysUtc')) { Show-EndpointSignInDays $item }
        }
        catch { Show-EndpointError $_ }
    })
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
            $picker = New-EndpointReportSaveDialog
            if ($picker.ShowDialog($script:Ui.Window)) {
                $table = $script:Ui.Datasets[[string]$name]
                $rows = foreach ($row in $script:Ui.ResultFilterState.View) {
                    $values = [ordered]@{}
                    foreach ($column in $table.Columns) {
                        if ($column.ColumnName -notin @('AssignedSignInDaysUtc','ObservedSignInDaysUtc')) { $values[$column.ColumnName] = $row[$column.ColumnName] }
                    }
                    [pscustomobject]$values
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
        else { Close-EndpointSettingsBeforeMainWindow $eventArgs }
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
            $selectedWorkflow = $script:Ui.Workflow
            Set-EndpointNavigation 'no-such-task-offline-fixture'
            if ($script:Ui.Workflow -ne $selectedWorkflow -or $controls.SearchEmpty.Visibility -ne 'Visible') { throw 'An empty search changed the selected task or did not show its empty state.' }
            Set-EndpointNavigation
            if ($controls.WorkflowList.SelectedItem -ne $selectedWorkflow -or $controls.SearchEmpty.Visibility -ne 'Collapsed') { throw 'Clearing search did not restore the selected task.' }
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
            if ($total.Elapsed.TotalSeconds -gt 10) { throw "Preparing and binding 100000 fixture rows exceeded 10 seconds: $($total.Elapsed.TotalSeconds). Maximum UI tick: $maxTick ms." }
            [pscustomobject]@{ WorkflowsRendered = $catalog.Count; Rows = $table.Rows.Count; MaxTickMilliseconds = $maxTick; TotalSeconds = [Math]::Round($total.Elapsed.TotalSeconds, 2); Stages = $script:Ui.Timings }
        }
        else { $null = $window.ShowDialog() }
    }
    finally {
        $script:Ui.Timer.Stop()
        if ($script:Ui.ContainsKey('ResultFilterState')) {
            $script:Ui.ResultFilterState.Timer.Stop()
            if ($script:Ui.ResultFilterState.Task) { $script:Ui.ResultFilterState.Cancellation.Cancel() }
        }
        if ($script:Ui.Settings) { $script:Ui.Settings.Window.Close() }
        try { $script:Ui.Remote.Dispose() } finally { $script:Ui.Graph.Dispose(); Write-EndpointUiRecord -Event 'AppClosed' }
        if ($SmokeTest -and (Test-Path -LiteralPath $script:Ui.HistoryPath)) { Remove-Item -LiteralPath $script:Ui.HistoryPath -ErrorAction Stop }
    }
}

function Set-EndpointWindowIcon {
    param([Parameter(Mandatory)] [System.Windows.Window]$Window)
    $iconPath = Join-Path $PSScriptRoot 'endpoint-toolbox-nobkg.png'
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
    $identityType::Set('EndpointToolbox')
}

Export-ModuleMember -Function Start-EndpointToolboxUI, Get-EndpointCatalog, Test-EndpointCatalogCoverage, Get-EndpointArguments, Protect-EndpointText
