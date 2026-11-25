<#
.SYNOPSIS
    Lists Cloud PCs and their provisioning status.
.DESCRIPTION
    Reads all pages of the Windows 365 Cloud PC inventory, including records that
    have not been provisioned. Returns one object per Cloud PC without changing it.
    Names, status and other properties are those returned by Microsoft Graph; they
    may differ from the Intune portal because of permissions or service timing.
.EXAMPLE
    .\Get-IntuneCloudPCs.ps1
.NOTES
    Requires Microsoft.Graph.Authentication, CloudPC.Read.All or CloudPC.ReadWrite.All
    consent and Windows 365 service authorization. Uses the Global Graph beta endpoint for provisioning
    status and device type; beta APIs can change and are not supported for production
    use by Microsoft.
#>
[CmdletBinding()]
param()

$context = Get-MgContext -ErrorAction Stop
if (-not $context) {
    #Connect-MgGraph -NoWelcome | Out-Null
    Connect-MgGraph -Scopes 'https://graph.microsoft.com/.default' -NoWelcome -ErrorAction Stop | Out-Null
    $context = Get-MgContext -ErrorAction Stop
}
if (-not $context -or $context.Environment -ne 'Global') { throw 'An active Global Microsoft Graph connection is required.' }

$fields = 'id,displayName,managedDeviceName,provisioningPolicyName,imageDisplayName,servicePlanName,productType,status,userPrincipalName,lastModifiedDateTime,onPremisesConnectionName,diskEncryptionState,partnerAgentInstallResults,managedDeviceId,aadDeviceId,provisioningType,gracePeriodEndDateTime'
$uri = "https://graph.microsoft.com/beta/deviceManagement/virtualEndpoint/cloudPCs?`$select=$fields"
$expectedPath = '/beta/deviceManagement/virtualEndpoint/cloudPCs'
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$cloudPCs = [Collections.Generic.List[object]]::new()
while ($uri) {
    $address = [uri]$uri
    if (-not $address.IsAbsoluteUri -or $address.Scheme -ne 'https' -or
        $address.Host -ne 'graph.microsoft.com' -or -not $address.IsDefaultPort -or
        $address.UserInfo -or $address.Fragment -or $address.AbsolutePath -cne $expectedPath -or
        -not $seen.Add($uri)) {
        throw 'Graph returned an unexpected or repeated Cloud PC page; the report was not completed.'
    }
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers @{ Prefer = 'include-unknown-enum-members' } -OutputType Hashtable -ErrorAction Stop
    if ($page -isnot [System.Collections.IDictionary] -or $page['value'] -isnot [array]) {
        throw 'Graph did not return a valid Cloud PC collection; the report was not completed.'
    }
    foreach ($cloudPC in $page['value']) {
        if ($cloudPC -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace([string]$cloudPC['id'])) {
            throw 'Graph returned a Cloud PC without an ID; the report was not completed.'
        }
        $cloudPCs.Add($cloudPC)
    }
    $uri = [string]$page['@odata.nextLink']
}

$results = @(foreach ($cloudPC in $cloudPCs) {
    $status = [string]$cloudPC['status']
    $statusLabel = switch ($status) {
        'notProvisioned' { 'Not provisioned' }
        'provisioning' { 'Provisioning' }
        'provisioned' { 'Provisioned' }
        'provisionedWithWarnings' { 'Provisioned with warnings' }
        'inGracePeriod' { 'In grace period' }
        'deprovisioning' { 'Deprovisioning' }
        'failed' { 'Failed' }
        'pendingProvision' { 'Pending' }
        default { $status }
    }
    $partners = @(foreach ($agent in $cloudPC['partnerAgentInstallResults']) {
        if ($agent -is [System.Collections.IDictionary] -and $agent['isThirdPartyPartner'] -eq $true) {
            "$($agent['partnerAgentName']): $($agent['installStatus'])"
        }
    })
    [pscustomobject]@{
        DeviceName = [string]$cloudPC['managedDeviceName']
        ProvisioningPolicy = [string]$cloudPC['provisioningPolicyName']
        Image = [string]$cloudPC['imageDisplayName']
        CloudPCSize = [string]$cloudPC['servicePlanName']
        DeviceType = [string]$cloudPC['productType']
        Status = $statusLabel
        UserPrincipalName = [string]$cloudPC['userPrincipalName']
        LastModifiedDateTime = [string]$cloudPC['lastModifiedDateTime']
        AzureNetworkConnection = [string]$cloudPC['onPremisesConnectionName']
        EncryptionStatus = [string]$cloudPC['diskEncryptionState']
        ThirdPartyConnectors = $partners -join '; '
        CloudPCName = [string]$cloudPC['displayName']
        CloudPCId = [string]$cloudPC['id']
        IntuneDeviceId = [string]$cloudPC['managedDeviceId']
        EntraDeviceId = [string]$cloudPC['aadDeviceId']
        ProvisioningType = [string]$cloudPC['provisioningType']
        GracePeriodEndDateTime = [string]$cloudPC['gracePeriodEndDateTime']
        RawStatus = $status
    }
})
Write-Host "Found $($results.Count) Cloud PC record(s) within your access scope."
$results
