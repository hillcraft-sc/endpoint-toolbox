# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

<#
.SYNOPSIS
    Deletes stale Entra ID device objects, skipping any that are still managed by Intune.

.DESCRIPTION
    Connects to Microsoft Graph and, for each device name provided, looks up every Entra ID device
    object with that display name. Each Entra object is checked against Intune by matching its
    Entra deviceId to managedDevices.azureADDeviceId. Only Entra objects with NO matching Intune
    managed device are deleted, so when a name appears more than once only the orphaned records
    are removed and the one Intune still manages is kept.

    Additional safety checks - the Entra object is skipped (not deleted) when:
      - It is linked to an Intune managed device (matched by ID).
      - An Intune device with the same name has no Entra device ID yet, so the link can't be proven.
      - It is an Autopilot device object (physicalIds contains [ZTDID]), unless
        -DeleteFromAutopilot is used.
      - -DeleteFromAutopilot is used but the Autopilot deletion fails.
      - Any Graph lookup for that name fails.

    Every Entra delete prompts for confirmation unless -Confirm:$false is passed. Autopilot deletes
    prompt separately unless -AutoDeleteAutopilot is passed. Use -WhatIf to preview.

    Every Entra object evaluated is recorded in a results CSV in -OutputPath. A real run always
    saves the CSV; a -WhatIf run saves it only when -ExportCsv is used.

.PARAMETER DeviceListPath
    Path to a text file containing one device name per line. Blank lines and lines starting with
    '#' are ignored. Cannot be combined with -Devices.

.PARAMETER Devices
    One or more device names supplied directly. Accepts a single name, an array, or a
    comma-separated string. Cannot be combined with -DeviceListPath.

.PARAMETER OutputPath
    The folder the results CSV is saved to. Defaults to the current
    user's temp folder. Created automatically if it doesn't already exist.

.PARAMETER ExportCsv
    Save each evaluated Entra object to a CSV in -OutputPath during a -WhatIf run. Real runs
    always save the CSV.

.PARAMETER DeleteFromAutopilot
    For Autopilot-linked Entra objects that aren't in Intune, delete the Autopilot registration
    first, then the Entra object. Prompts before each Autopilot delete unless -AutoDeleteAutopilot
    is also used. If the Autopilot delete is declined, the Entra object is still deleted; if it
    fails, the Entra object is kept.

.PARAMETER AutoDeleteAutopilot
    Delete Autopilot registrations without prompting. Requires -DeleteFromAutopilot.

.PARAMETER OpenReport
    Open the results CSV in its default application once the script completes. With -WhatIf it requires -ExportCsv.

.EXAMPLE
    .\Remove-EntraDevice.ps1 -Devices "LO-L-ZyMZkbIQJQ" -WhatIf

    Shows which Entra objects named LO-L-ZyMZkbIQJQ would be deleted without deleting anything.

.EXAMPLE
    .\Remove-EntraDevice.ps1 -DeviceListPath "C:\temp\devices.txt"

    Evaluates every device in devices.txt and prompts before each delete.

.EXAMPLE
    .\Remove-EntraDevice.ps1 -DeviceListPath "C:\temp\devices.txt" -ExportCsv

    Evaluates every device, prompts before each delete, and saves a results CSV.

.EXAMPLE
    .\Remove-EntraDevice.ps1 -Devices "PC-1,PC-2" -Confirm:$false

    Deletes the orphaned Entra objects for PC-1 and PC-2 without prompting.

.EXAMPLE
    .\Remove-EntraDevice.ps1 -DeviceListPath "C:\temp\devices.txt" -DeleteFromAutopilot

    Removes the Autopilot registration and then the Entra object for each orphaned device,
    prompting before each Autopilot delete and each Entra delete.

.NOTES
    Requires an active Microsoft Graph connection with permissions to read Intune devices and
    delete Entra devices (e.g. DeviceManagementManagedDevices.Read.All, Device.ReadWrite.All).
    Autopilot registrations are read on every run (DeviceManagementServiceConfig.Read.All);
    -DeleteFromAutopilot needs DeviceManagementServiceConfig.ReadWrite.All.
    Deleting devices also requires the Cloud Device Administrator (or higher) Entra role.

    Author:         eric@hillcraft.email
    Created:        2026-09-30
    Last Modified:  2026-09-30
#>
[CmdletBinding(DefaultParameterSetName = 'ByDevice', SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByFile')]
    [ValidateNotNullOrEmpty()]
    [string]$DeviceListPath,

    [Parameter(Mandatory, ParameterSetName = 'ByDevice')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Devices,

    [string]$OutputPath = "$env:TEMP",

    # Also save a local copy of the results.
    [switch]$ExportCsv,

    # Open the results CSV once the script completes.
    [switch]$OpenReport,

    # Delete the Autopilot registration before deleting the Entra object.
    [switch]$DeleteFromAutopilot,

    # Skip the per-device prompt for Autopilot deletes. Requires -DeleteFromAutopilot.
    [switch]$AutoDeleteAutopilot
)

if ($AutoDeleteAutopilot -and -not $DeleteFromAutopilot) {
    throw "-AutoDeleteAutopilot requires -DeleteFromAutopilot."
}

if ($OpenReport -and -not $ExportCsv -and $WhatIfPreference) {
    throw "-OpenReport requires -ExportCsv when used with -WhatIf."
}

$ErrorActionPreference = "Stop"

if (Get-MgContext) {
    Write-Host "Connected to MgGraph..."
}
else {
    Write-Host "Not connected to MgGraph. Connecting..."
    Connect-MgGraph -NoWelcome | Out-Null
    #-Scopes "Device.ReadWrite.All","DeviceManagementManagedDevices.Read.All" -NoWelcome
}

function Get-GraphCollection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [hashtable]$Headers = @{}
    )

    $items = @()
    $next = $Uri

    do {
        if ($Headers.Count -gt 0) {
            $response = Invoke-MgGraphRequest -Method GET -Uri $next -Headers $Headers
        }
        else {
            $response = Invoke-MgGraphRequest -Method GET -Uri $next
        }

        if ($response.value) {
            $items += $response.value
        }
        $next = $response.'@odata.nextLink'
    }
    while ($next)

    return $items
}

if ($DeviceListPath) {
    if (-not (Test-Path -Path $DeviceListPath)) {
        throw "Device list file not found: $DeviceListPath"
    }
    $DeviceNames = Get-Content -Path $DeviceListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
}
else {
    # Also accept a single comma-separated string, not just a real array
    $DeviceNames = $Devices | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

$DeviceNames = @($DeviceNames | Sort-Object -Unique)

Write-Host "Devices to evaluate: $($DeviceNames.Count)" -ForegroundColor Yellow

$emptyGuid = '00000000-0000-0000-0000-000000000000'
$results = @()
$runBy = (Get-MgContext).Account
$runId = [guid]::NewGuid().ToString()

# Real runs always keep a CSV record; previews only when -ExportCsv is used
$saveCsv = $ExportCsv -or -not $WhatIfPreference
$finalCsv = $null
if ($saveCsv) {
    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force -WhatIf:$false -Confirm:$false | Out-Null
    }
    $finalCsv = Join-Path $OutputPath "RemoveEntraDevice-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
}

$loggedOnUser = try { whoami /upn 2>$null } catch { $null }
if (-not $loggedOnUser -or $LASTEXITCODE -ne 0) { $loggedOnUser = "$env:USERDOMAIN\$env:USERNAME" }

# Rows are appended as they happen so the log survives Ctrl+C or a crash mid-run
function Add-ResultRow {
    param([hashtable]$Values)

    $row = [ordered]@{
        RunId             = $runId
        Timestamp         = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        RunBy             = $runBy
        LoggedOnUser      = $loggedOnUser
        WhatIfRun         = [bool]$WhatIfPreference
        DeviceName        = $null
        EntraObjectId     = $null
        EntraDeviceId     = $null
        OperatingSystem   = $null
        TrustType         = $null
        AccountEnabled    = $null
        LastSignIn        = $null
        IntuneDeviceId    = $null
        AutopilotZtdId    = $null
        AutopilotId       = $null
        AutopilotSerial   = $null
        AutopilotPurchaseOrder = $null
        AutopilotAction   = $null
        AutopilotDecision = $null
        EntraAction       = $null
        EntraDecision     = $null
        Reason            = $null
    }
    foreach ($key in $Values.Keys) { $row[$key] = $Values[$key] }

    $obj = [PSCustomObject]$row
    $script:results += $obj
    if ($saveCsv) {
        $obj | Export-Csv -Path $finalCsv -NoTypeInformation -Encoding UTF8 -Append -WhatIf:$false -Confirm:$false
    }
}

$autopilotByEntraId = @{}
$autopilotById = @{}
Write-Host "Retrieving Autopilot registrations..." -ForegroundColor Cyan
$autopilotDevices = @(Get-GraphCollection -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities")
foreach ($ap in $autopilotDevices) {
    $autopilotById[$ap.id] = $ap
    if ($ap.azureActiveDirectoryDeviceId) {
        $autopilotByEntraId[$ap.azureActiveDirectoryDeviceId] = $ap
    }
}
Write-Host "Autopilot registrations: $($autopilotDevices.Count)" -ForegroundColor DarkGray

foreach ($name in $DeviceNames) {
    Write-Host "`n$name" -ForegroundColor Cyan
    $escapedName = $name -replace "'", "''"

    try {
        $entraFilter = [System.Uri]::EscapeDataString("displayName eq '$escapedName'")
        $entraUri = "https://graph.microsoft.com/v1.0/devices?`$filter=$entraFilter&`$select=id,deviceId,displayName,operatingSystem,trustType,accountEnabled,approximateLastSignInDateTime,physicalIds&`$top=999"
        $entraDevices = @(Get-GraphCollection -Uri $entraUri)

        $intuneFilter = [System.Uri]::EscapeDataString("deviceName eq '$escapedName'")
        $intuneUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$intuneFilter&`$select=id,deviceName,azureADDeviceId"
        $intuneByName = @(Get-GraphCollection -Uri $intuneUri)
    }
    catch {
        Write-Warning "Lookup failed for $name, skipping: $_"
        Add-ResultRow @{ DeviceName = $name; EntraAction = 'Error'; Reason = "Lookup failed: $($_.Exception.Message)" }
        continue
    }

    if ($entraDevices.Count -eq 0) {
        Write-Warning "Not found in Entra: $name"
        Add-ResultRow @{
            DeviceName     = $name
            IntuneDeviceId = ($intuneByName.id -join ';')
            EntraAction    = 'NotFound'
            Reason         = 'No Entra device with this name'
        }
        continue
    }

    Write-Host "  Entra objects: $($entraDevices.Count)  |  Intune devices with this name: $($intuneByName.Count)" -ForegroundColor DarkGray

    # An Intune record with no Entra ID yet could belong to any of the Entra objects, so none can be proven safe
    $unlinkedIntune = @($intuneByName | Where-Object { -not $_.azureADDeviceId -or $_.azureADDeviceId -eq $emptyGuid })

    foreach ($entra in $entraDevices) {
        $action = $null
        $reason = $null
        $intuneMatch = @()
        $autopilotAction = $null
        $autopilotDecision = $null
        $entraDecision = $null
        $ztdId = (@($entra.physicalIds) -match '^\[ZTDID\]' | Select-Object -First 1) -replace '^\[ZTDID\]:?', ''
        $ap = $autopilotByEntraId[$entra.deviceId]
        if (-not $ap -and $ztdId) { $ap = $autopilotById[$ztdId] }

        try {
            # Match on ID rather than name so a renamed Intune device is still caught
            $matchFilter = [System.Uri]::EscapeDataString("azureADDeviceId eq '$($entra.deviceId)'")
            $matchUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$matchFilter&`$select=id,deviceName,azureADDeviceId"
            $intuneMatch = @(Get-GraphCollection -Uri $matchUri)
        }
        catch {
            $action = 'Error'
            $reason = "Intune ID lookup failed: $($_.Exception.Message)"
        }

        if (-not $action) {
            if ($intuneMatch.Count -gt 0) {
                $action = 'Skipped'
                $reason = "Managed by Intune ($($intuneMatch[0].deviceName))"
            }
            elseif ($unlinkedIntune.Count -gt 0) {
                $action = 'Skipped'
                $reason = 'Intune device with this name has no Entra device ID; cannot prove which object it uses'
            }
            elseif ($ztdId -and -not $DeleteFromAutopilot) {
                $action = 'Skipped'
                $reason = 'Autopilot device object'
            }
            else {
                $baseReason = if ($ztdId) { 'Not in Intune (Autopilot object)' } else { 'Not in Intune' }

                if ($ztdId -and $DeleteFromAutopilot) {
                    if (-not $ap) {
                        $autopilotAction = 'NotFound'
                    }
                    elseif ($WhatIfPreference) {
                        Write-Host "What if: Deleting Autopilot registration $($ap.id) (serial $($ap.serialNumber), PO $($ap.purchaseOrderIdentifier))"
                        $autopilotAction = 'WhatIf'
                        $autopilotDecision = 'WhatIf'
                    }
                    else {
                        if ($AutoDeleteAutopilot) {
                            $approved = $true
                            $autopilotDecision = 'Auto-approved (-AutoDeleteAutopilot)'
                        }
                        else {
                            $approved = $PSCmdlet.ShouldContinue("Delete Autopilot registration for $($entra.displayName) (serial $($ap.serialNumber), PO $($ap.purchaseOrderIdentifier), id $($ap.id))?", "Delete from Autopilot")
                            $autopilotDecision = if ($approved) { 'Approved at prompt' } else { 'Declined at prompt' }
                        }

                        if ($approved) {
                            try {
                                Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$($ap.id)" | Out-Null
                                $autopilotAction = 'Deleted'
                            }
                            catch {
                                $autopilotAction = 'Error'
                                $action = 'Error'
                                $reason = "Autopilot delete failed, Entra object kept: $($_.Exception.Message)"
                            }
                        }
                        else {
                            $autopilotAction = 'Declined'
                            $baseReason = "$baseReason; Autopilot deletion declined"
                        }
                    }
                }

                if (-not $action) {
                    # ConfirmImpact is High, so the Entra delete prompts unless -Confirm:$false set ConfirmPreference to None
                    $entraPrompts = -not $WhatIfPreference -and $ConfirmPreference -ne 'None'
                    if ($PSCmdlet.ShouldProcess("$($entra.displayName) [ObjectId $($entra.id), DeviceId $($entra.deviceId)]", "Delete Entra device")) {
                        $entraDecision = if ($entraPrompts) { 'Approved at prompt' } else { 'Auto-approved (-Confirm:$false)' }
                        try {
                            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/devices/$($entra.id)" | Out-Null
                            $action = 'Deleted'
                            $reason = $baseReason
                        }
                        catch {
                            # Removing the Autopilot registration can take the Entra object with it
                            if ($autopilotAction -eq 'Deleted' -and $_.Exception.Message -match '404|NotFound|does not exist') {
                                $action = 'Deleted'
                                $reason = "$baseReason; removed with Autopilot registration"
                            }
                            else {
                                $action = 'Error'
                                $reason = "Delete failed: $($_.Exception.Message)"
                            }
                        }
                    }
                    else {
                        $action = if ($WhatIfPreference) { 'WhatIf' } else { 'Declined' }
                        $entraDecision = if ($WhatIfPreference) { 'WhatIf' } else { 'Declined at prompt' }
                        $reason = $baseReason
                    }
                }
            }
        }

        $color = switch ($action) {
            'Deleted' { 'Green' }
            'Error'   { 'Red' }
            'Skipped' { 'Yellow' }
            default   { 'Gray' }
        }
        Write-Host "  $action : $($entra.id) - $reason" -ForegroundColor $color
        if ($ap) {
            Write-Host "    Autopilot: serial $($ap.serialNumber), PO $($ap.purchaseOrderIdentifier)" -ForegroundColor DarkGray
        }

        Add-ResultRow @{
            DeviceName        = $name
            EntraObjectId     = $entra.id
            EntraDeviceId     = $entra.deviceId
            OperatingSystem   = $entra.operatingSystem
            TrustType         = $entra.trustType
            AccountEnabled    = $entra.accountEnabled
            LastSignIn        = $entra.approximateLastSignInDateTime
            IntuneDeviceId    = ($intuneMatch.id -join ';')
            AutopilotZtdId    = $ztdId
            AutopilotId       = $ap.id
            AutopilotSerial   = $ap.serialNumber
            AutopilotPurchaseOrder = $ap.purchaseOrderIdentifier
            AutopilotAction   = $autopilotAction
            AutopilotDecision = $autopilotDecision
            EntraAction       = $action
            EntraDecision     = $entraDecision
            Reason            = $reason
        }
    }
}

if ($results.Count -eq 0) {
    Write-Warning "No devices were evaluated."
    return
}

Write-Host "`nEntra summary:" -ForegroundColor Cyan

$results |
Group-Object -Property EntraAction |
Sort-Object Count -Descending |
Select-Object Name, Count |
Format-Table -AutoSize

if ($DeleteFromAutopilot) {
    Write-Host "Autopilot summary:" -ForegroundColor Cyan

    $results |
    Where-Object { $_.AutopilotAction } |
    Group-Object -Property AutopilotAction |
    Sort-Object Count -Descending |
    Select-Object Name, Count |
    Format-Table -AutoSize
}

if ($saveCsv) {
    Write-Host "`nReport saved to:" -ForegroundColor Green
    Write-Host $finalCsv
}

if ($OpenReport -and $finalCsv -and (Test-Path $finalCsv)) {
    Invoke-Item -Path $finalCsv
}