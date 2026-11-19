# Copyright (C) 2026 Eric Hebert
# SPDX-License-Identifier: GPL-3.0-or-later
# See the LICENSE file in the repository root for the full license text.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Device,
    [switch]$UNC,

    # Optional DNS suffix appended to the device name for the administrative share, for example
    # corp.example.com. Leave empty to use the name as typed (or pass a full FQDN in -Device).
    [ValidatePattern('^$|^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$')]
    [string]$DnsSuffix
)

# Test if the device is reachable via ping
$ping = Test-Connection -ComputerName $Device -Count 1 -Quiet
if (-not $ping) {
    Write-Error "Device $Device is not reachable."
    return
}

# Test if WinRM is available on the device
try {
    Test-WSMan -ComputerName $Device -ErrorAction Stop | Out-Null
}
catch {
    Write-Error "WinRM check failed for $Device. Remote session will not be attempted. $_"
    return
}

# Prompt for credentials
$Creds = Get-Credential -Message 'Enter your administrator (privileged account) credentials' -Title 'Credentials Needed for Elevation...'

if ($UNC) {
    $shareHost = if ($DnsSuffix -and $Device -notlike '*.*') { "$Device.$DnsSuffix" } else { $Device }
    $uncPath = "\\$shareHost\C$"
    try {
        $Drive = New-PSDrive -Name "UNC_$Device" -PSProvider FileSystem -Root $uncPath -Credential $Creds
    }
    catch {
        Write-Error "Failed to create PSDrive for $Device. $_"
    }

    if ($Drive) {
        start-process explorer.exe $Drive.Root
    }
}

$session = New-PSSession $Device -EnableNetworkAccess -Authentication Negotiate -Credential $Creds
Enter-PSSession $session
