function ConvertTo-Win32CodeValue {
    param([string]$Text, [switch]$HexColumn)
    $Text = $Text.Trim()
    if ($Text -match '^0x([a-f0-9]{1,8})$' -or ($HexColumn -and $Text -match '^([a-f0-9]{1,8})$')) {
        return [Convert]::ToInt64($Matches[1], 16)
    }
    $value = 0L
    if (-not $HexColumn -and $Text -match '^[+-]?\d{1,10}$' -and [long]::TryParse($Text, [ref]$value) -and
        $value -ge [int]::MinValue -and $value -le [uint32]::MaxValue) {
        return ($value -band 4294967295L)
    }
}

function Get-Win32ReportedCode {
    param([string]$ErrorCode, [string]$HexErrorCode)
    $value = ConvertTo-Win32CodeValue $HexErrorCode -HexColumn
    if (-not $value) { $value = ConvertTo-Win32CodeValue $ErrorCode }
    if ($value) { return ('0x{0:X8}' -f $value) }
    if ($ErrorCode.Trim() -and $null -eq (ConvertTo-Win32CodeValue $ErrorCode)) { return "Reported: $($ErrorCode.Trim())" }
    if ($HexErrorCode.Trim() -and $null -eq (ConvertTo-Win32CodeValue $HexErrorCode -HexColumn)) { return "Reported: $($HexErrorCode.Trim())" }
    return 'No error code reported'
}

function Test-Win32FailureRow {
    param([string]$InstallState, [string]$InstallStateFriendly)
    $state = $InstallState.Trim()
    return ($state -in @('-1','2','Error','Failed') -or
        ($state -notmatch '^-?\d+$' -and $InstallStateFriendly -in @('Error','Failed')))
}

function Get-Win32ErrorExplanation {
    param([string]$Code, [System.Collections.IDictionary]$App)
    $intune = 'https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/app-install-error-codes'
    $msi = 'https://learn.microsoft.com/en-us/windows/win32/msi/error-codes'
    $value = ConvertTo-Win32CodeValue $Code
    $signed = if ($null -ne $value) { if ($value -gt [int]::MaxValue) { $value - 4294967296L } else { $value } }
    $meaning = 'No documented explanation in the built-in lookup.'
    $next = 'Check the exact code in the vendor or Microsoft documentation. Do not infer a root cause from the number alone.'
    $source = $intune
    $detection = ''
    if ($Code -eq '0x87D1041C') {
        $meaning = 'Intune reported installation success but did not detect the app afterward.'
        $next = 'Compare the configured detection rule with the artifact the package actually installs, including version, path, and registry view where relevant.'
        $rules = @($App['detectionRules'])
        if (-not @($rules | Where-Object { $_ }).Count) {
            $rules = @($App['rules'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['ruleType'] -eq 'detection' })
        }
        $detection = (@(foreach ($rule in $rules) {
            if ($rule -isnot [System.Collections.IDictionary]) { continue }
            $kind = switch -Wildcard ([string]$rule['@odata.type']) {
                '*ProductCode*' { 'MSI product code' }
                '*FileSystem*' { 'File or folder' }
                '*Registry*' { 'Registry' }
                '*PowerShellScript*' { 'PowerShell script' }
                default { 'Detection rule' }
            }
            $keys = if ($kind -eq 'PowerShell script') { @('runAs32Bit','enforceSignatureCheck') } else {
                @('productCode','productVersion','productVersionOperator','path','fileOrFolderName','keyPath','valueName',
                    'detectionType','detectionValue','operator','comparisonValue','check32BitOn64System')
            }
            $settings = @(foreach ($key in $keys) {
                if ($rule.Contains($key) -and $null -ne $rule[$key] -and [string]$rule[$key] -ne '') { "$key=$($rule[$key])" }
            })
            if ($settings.Count) { "$kind ($($settings -join ', '))" } else { $kind }
        }) -join '; ')
        if (-not $detection) { $detection = 'Detection settings were not returned.' }
    }
    elseif ($null -ne $value) {
        # Only unwrap HRESULTs from FACILITY_WIN32, not arbitrary Intune codes.
        $installer = if (($value -band 4294901760L) -eq 2147942400L) { $value -band 65535L } else { $value }
        $entry = switch ($installer) {
            1603 { @('A fatal Windows Installer error occurred (1603). This is a generic failure.', 'Check the package prerequisites, install context, and vendor-specific troubleshooting for this package.') }
            1618 { @('Windows Installer reported that another installation was already running (1618).', 'Check for overlapping installer activity before retrying.') }
            1619 { @('Windows Installer could not open the package (1619).', 'Check that the package contains the expected MSI and that the install command references it correctly.') }
            1638 { @('Windows Installer reported that another version is already installed (1638).', 'Check the installed version and the package upgrade or supersedence configuration.') }
            3010 { @('Windows Installer indicates success with a restart required (3010).', 'Compare the configured return-code handling with the intended restart behavior.') }
        }
        if ($entry) {
            $meaning = if ($installer -eq $value) { "If this is a Windows Installer return code: $($entry[0])" } else {
                "This HRESULT wraps Windows error $installer. For an MSI installation: $($entry[0])"
            }
            $next = $entry[1]; $source = $msi
        }
    }
    if ($Code -eq 'No error code reported') {
        $meaning = 'This failure row did not provide a nonzero error code.'
        $next = 'Review the original deployment row and other diagnostic findings.'
        $source = $null
    }
    $mapping = (@(if ($null -ne $value) {
        foreach ($item in $App['returnCodes']) {
            if ($item -isnot [System.Collections.IDictionary]) { continue }
            $configured = ConvertTo-Win32CodeValue ([string]$item['returnCode'])
            if ($null -ne $configured -and $configured -eq $value) { "$($item['returnCode']) -> $($item['type'])" }
        }
    }) -join '; ')
    [pscustomobject]@{
        Meaning=$meaning; NextCheck=$next
        HexCode=if ($null -ne $value) { $Code }
        SignedDecimal=$signed; UnsignedDecimal=$value
        DetectionSettings=$detection
        ReturnCodeConfiguration=if ($mapping) { "$mapping (configuration match only; installer exit code not verified)" }
        Reference=$source
    }
}

Export-ModuleMember -Function Get-Win32ReportedCode, Test-Win32FailureRow, Get-Win32ErrorExplanation
