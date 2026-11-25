# Endpoint Toolbox desktop

A Windows WPF front end for the 29 business scripts in the repository root and service folders. The interface uses a searchable, collapsible category sidebar and focused task pages with separate configuration and results views.

## Launch

Requires Windows and **PowerShell 7.6 or newer**. Windows PowerShell 5.1 is not supported. Keep the repository together on disk.

```powershell
pwsh.exe -NoProfile -STA -File .\Desktop\Start-EndpointToolboxUI.ps1
```

Run [Install-EndpointToolboxShortcut.ps1](Install-EndpointToolboxShortcut.ps1) for a per-user shortcut. The shortcut leaves the PowerShell console visible so Windows Web Account Manager (WAM) can obtain a parent window handle for Graph sign-in. Keep that console open while using the app. The running app has its own Windows taskbar identity and uses the supplied 32×32 icon; the shortcut uses its `.ico` version. No elevation or execution-policy bypass is added. Recreate older hidden-console shortcuts, and recreate the shortcut if the repository moves.

The Windows taskbar identity is `EndpointToolbox`. After updating from an older version, an existing taskbar pin may need to be removed and pinned again to group with the running app.

Settings, history and activity logs are stored under `%LOCALAPPDATA%\EndpointToolbox`. Data from the previous folder is not moved automatically. To retain it, close the app and copy the old folder's contents into the new folder, taking care not to overwrite newer files.

Under **Settings > Graph**, set an optional default tenant ID or domain for Home **Connect / reconnect**. The Home tenant field overrides this setting for an individual connection. Leave both blank to use the account default. Saving the setting does not change an active Graph connection; reconnect to use a changed value.

### Universal settings and deployment defaults

All user preferences now share `%LOCALAPPDATA%\EndpointToolbox\settings.json`, with sections for Appearance, Graph, Remote, CloudUpdate, WUfB and Reports. Administrators can prepopulate [EndpointToolbox.defaults.json](EndpointToolbox.defaults.json), kept beside the desktop module (in `Desktop` in a ZIP deployment).

Precedence is **built-in defaults < deployed defaults < individual user overrides**. Settings editors show the effective values and save only their section to the user's file, never to the deployed file. The paired WUfB fields save only changed values, so editing the workspace does not freeze an inherited Azure tenant. Users may override any preference. Empty strings and empty group lists deliberately clear configured defaults; an empty report folder uses `%TEMP%\endpoint-toolbox`. To inherit a deployed value again, close the app and remove that specific key from the user's JSON. Restart after editing deployment defaults; updates apply to settings without user overrides. These are defaults, not enforced policy.

Copy the supplied JSON template to an administrator-owned file and populate only the values you want to deploy. Sections and keys are optional, except for numeric `SchemaVersion: 2`. Supported keys:

| Section | Keys |
|---|---|
| `Appearance` | `Theme`: Light, Dark, CatppuccinMocha or GruvboxDark |
| `Graph` | `TenantId`: GUID, domain, `organizations`, or empty |
| `Remote` | `DnsSuffix`: DNS suffix or empty; used only for Explorer UNC |
| `CloudUpdate` | `GroupNames`: array of exact Entra group display names |
| `WUfB` | `WorkspaceId`, `AzureTenantId`: nonempty GUIDs or empty |
| `Reports` | `Folder`: full local/UNC path or empty; environment variables supported |

For example, deployment defaults for a Graph domain and remote suffix can be:

```json
{
  "SchemaVersion": 2,
  "Graph": { "TenantId": "example.invalid" },
  "Remote": { "DnsSuffix": "corp.example.invalid" },
  "CloudUpdate": { "GroupNames": [] }
}
```

No real tenant/workspace identifiers are shipped in the template. Do not put passwords, tokens or credentials in either JSON file. Defaults do not authenticate users, change scopes or grant access; Graph, Office and Azure retain their separate authentication flows.

On the first normal launch after upgrading, existing flat preferences and the legacy Remote, Cloud Update and WUfB files are validated and consolidated automatically. The old flat file is backed up as `settings.json.legacy.bak`; sidecars remain for recovery but are no longer read after migration. History, recent devices and logs stay separate. Invalid JSON, unsupported versions, unknown keys or invalid values produce explicit errors; migration and subsequent saves do not overwrite invalid shared settings. Correct the named file and relaunch.

### Build a distributable ZIP

On Windows with PowerShell 7.6+, run:

```powershell
.\Desktop\Packaging\Build-EndpointToolboxBundle.ps1 -OutputDirectory C:\Builds -Version 1.0.0
```

To include an administrator-prepopulated file without modifying the repository template:

```powershell
.\Desktop\Packaging\Build-EndpointToolboxBundle.ps1 -OutputDirectory C:\Builds -Version 1.0.0 -ConfigurationPath C:\Deployment\EndpointToolbox.defaults.json
```

The build validates and includes this file as `Desktop\EndpointToolbox.defaults.json`. Without `-ConfigurationPath`, it includes the repository template. Per-user settings are never included.

The ZIP contains `EndpointToolbox.exe` and the app files, not Git metadata, tests, PowerShell, or PowerShell modules. Extract the **whole ZIP** and run `EndpointToolbox.exe` from its root. The launcher uses the machine-managed PowerShell 7.6+ installation at `Program Files\PowerShell\7\pwsh.exe`; no .NET SDK or Git is needed on client PCs. IT still supplies the workflow modules, including `Microsoft.Graph.Authentication` for Graph, `MSAL.PS` for Cloud Update, and optional `ImportExcel` for XLSX. The ZIP is a payload for your own Intune packaging, not an installer.

**Known EXE sign-in limitation:** the hidden-console launch can fail Graph WAM authentication with **A window handle must be configured**. See the [failure analysis and EXE implementation options](Packaging/README.md) before deploying. The build still creates the EXE; the documented console, WPF-parenting, custom-client and device-code changes are implementation candidates, not completed EXE fixes.

Supplying an approved `-SigningCertificate` signs and verifies the staged launcher and PowerShell scripts, modules and data files without modifying the repository. Without it, the build adds no signatures. Signatures are not timestamped. Client computers must trust the signer, and separately installed workflow modules and application-control policies still require attention. The build runs `-ValidateOnly` against its staged payload; `-SmokeTest` requires adding the offline `Desktop\Tests\Fixtures\HostFixture.ps1` to a separate test copy.

Close the existing app window after an update, then rerun the launcher. If an incompatible compiled bridge is still loaded in your PowerShell session, the launcher opens a fresh process automatically. A .NET SDK is not needed; the [hosting bridge](Hosting/DesktopPowerShellHost.cs) compiles against the installed runtime.

## Layout and workflow

1. **Connect on Home:** activate the needed role in PIM, then connect to Graph using existing consent and check the connection. **Connect / reconnect** signs out an existing Graph session before connecting, clearing its in-memory authentication cache before a new sign-in attempt. It does not sign out the Windows authentication broker or request additional consent. **Check connection** and task preflight reuse the current connection; they do not force token renewal. A verified directory role does not guarantee Intune service authorization: if Intune returns 401/403 after PIM activation, use **Connect / reconnect**, confirm the account/tenant, and retry. Continued failures require checking Intune access and Entra sign-in/Conditional Access results. **Home / Graph connection** stays accessible from the sidebar, even while a task runs. Returning to the selected task preserves its inputs.
2. **Find a task:** all sidebar categories start collapsed when the app opens. Expand a category or search by task, category or script name, including tasks in collapsed categories. Search does not switch tasks or clear the current inputs or results; select a match to open it. Clearing search restores the selected task and expands its category.
3. **Configure:** read the short task guide, choose targets and inputs, then review options and execution mode. Inputs for other sources disappear rather than remaining disabled on screen. Plain-English labels include examples, and tooltips retain the original parameter names/help.
4. **Review mode:** supported actions offer an explicit **Preview only (WhatIf)** checkbox. It is not enabled automatically. The footer and primary button clearly indicate preview versus the original operation.
5. **Run:** the app switches to **Results > Script output**, checks Graph access for Graph tasks, then starts the original script if the checks pass. Cloud Update uses its own Office sign-in; remote support uses endpoint credentials. Original prompts appear in-app. Errors, warnings, skipped items, assignment warnings and approval codes remain visible in the original script output.
6. **Use the output:** **Report data** contains structured report rows where available, with filtering, copy and export. The report view is not rebuilt when the filter is unchanged. **Saved reports** lists the script's generated CSVs and exported visual-summary PNGs. Export buttons live beside the output they save, not beside the Run button.

In report data and Settings history, click a cell, Shift-click another for a range (including a column), or Ctrl-click individual cells. Press Ctrl+C to copy the selection without column headers. Multiple columns are tab-separated; use **Export view** for the complete filtered report. Report filtering runs in the background after a short pause in typing. The grid and export are unavailable until the latest filter is applied; reports still receiving rows are filtered after loading finishes.

Task inputs and input-source selections are retained in memory when switching or searching tasks, until the app closes. Loaded script/policy choices are also retained while navigating, but must be reloaded after connecting or disconnecting Graph. Field validation appears beside the relevant input and moves keyboard focus to it.

Report/export settings and advanced controls are collapsed until needed. There is only one active task or remote command at a time. Stop requests cancellation; it cannot roll back requests already accepted by Intune, Entra or a remote endpoint.

Inputs use consistent compact spacing, including matching username/password fields in smaller sign-in dialogs. Multi-value inputs remain multiline and scroll as needed; app-selection dialogs keep their wider grid. Output panes are top-aligned. In **Remote workspace**, drag the divider above the saved-command picker to resize the output and command editor. Long command descriptions scroll without displacing the output or action buttons. The task description and run summary/timing card are hidden while this tab is selected to leave more room for the remote terminal; they remain available on the other tabs.

### All Cloud PCs

Open **Inventory > All Cloud PCs** and run the read-only task. **Report data** lists every Cloud PC record returned by Graph, including unprovisioned, failed and grace-period records and multiple records assigned to the same user. It shows the portal's main columns: device name, provisioning policy, image, Cloud PC size, device type, status, user, modification time, network connection, encryption and available third-party connector status. IDs, provisioning type, grace-period end and the raw Graph status are also included. Filter, copy or export the view; no CSV is created automatically.

The report uses the [Graph beta Cloud PC list API](https://learn.microsoft.com/en-us/graph/api/virtualendpoint-list-cloudpcs?view=graph-rest-beta) because provisioning status and product type are not available in v1.0. Beta APIs can change and Microsoft does not support them for production use. It requires existing delegated `CloudPC.Read.All` (least privilege) or `CloudPC.ReadWrite.All` consent, the app's reader-role preflight and Windows 365 service authorization. Home does not grant consent or request the higher permission. Results reflect the signed-in account's access and service timing, so exact parity with the portal is not guaranteed. Missing fields remain blank, including device names for records not yet provisioned; image is the provisioning image, not necessarily the current OS. The task does not modify Cloud PCs.

The [standalone script](../Intune/Devices/Get-IntuneCloudPCs.ps1) returns the same rows:

```powershell
.\Intune\Devices\Get-IntuneCloudPCs.ps1
```

### Device investigation dashboard

Open **Inventory > Device investigation dashboard**, choose **Device name**, **Serial number** or **User UPN**, and enter an exact value. In **Report data**, use **Device overview** for Intune compliance, last sync, primary users and record identifiers. Choose **Entra records** or **Autopilot records** for the relevant source details; each dataset can be filtered, copied or exported.

In **Visual summary → Device record reconciliation**, select a finding to open its supporting rows in **Reconciliation queue**. The queue flags separate overview records with the same name, conflicting or shared identifiers, missing or invalid Entra IDs, and records without a confirmed match. It shows the reason, recorded IDs, Intune last sync, Entra approximate last sign-in and Autopilot last contact where available. Counts are findings, not unique devices: a record can have more than one finding. An empty queue means nothing was flagged in this search, and missing Autopilot registration can be expected. The queue is for investigation, not deletion decisions.

The search starts with Intune's exact device name, serial or *associated-user* UPN. A UPN search is not an exhaustive list of every device owned, registered or primarily used by that person. Name searches also find exact Entra and Autopilot display names; serial searches also find Autopilot serials. Related Entra records are looked up using recorded device IDs. Autopilot inventory is paged and filtered locally, which can take time in large tenants. The dashboard does not retrieve additional Intune devices just because an Autopilot record references them.

Autopilot uses the plain list endpoint without `$select`, which can cause HTTP 500 responses on that endpoint. Only the dashboard's explicit report fields are displayed or exported; additional response properties such as product keys are not included.

ID-based matches, shared or conflicting IDs, and serial-only candidates are labeled separately. An **Entra only** or **Autopilot candidate** row means no confirmed match among the Intune records returned by this search, not proof that the record is orphaned. Duplicate names or IDs are not collapsed into a single device. Blank fields and no match mean data was not returned, not that a device is healthy, unregistered or safe to delete. Service data can be stale. Failed lookups stop the report instead of presenting a partial investigation as complete.

Requires existing `DeviceManagementManagedDevices.Read.All`, `Device.Read.All`, `User.Read.All` and `DeviceManagementServiceConfig.Read.All` consent, the app's reader-role preflight, and service authorization. Results contain device identifiers and user data; handle exports appropriately. No devices or assignments are changed.

The [standalone script](../Intune/Devices/Get-EndpointDeviceInvestigation.ps1) returns the overview as pipeline objects:

```powershell
.\Intune\Devices\Get-EndpointDeviceInvestigation.ps1 -SearchBy 'Device name' -SearchValue 'PC-123'
```

### Find Entra users by name

Open **Inventory > Find Entra users by name**. Enter names one per line as `First Last` or `Last, First`, or choose a text file with one name per line. The lookup is read-only and returns one row per matching user with UPN, mail, title, department and account state.

- **Found**: one exact display-name or first/last-name match.
- **Multiple**: several users match exactly; confirm by UPN or department.
- **PossibleMatch**: no exact match, but a user has the same surname and first initial (for example Mike / Michael). Review before use.
- **NotFound** and **Failed** are reported per name.

The summary counts names. Only Found counts as succeeded; Multiple and PossibleMatch count as unresolved. Requires existing `User.Read.All` consent. The [standalone script](../entra/Find-EntraUsersByName.ps1) accepts `-Names` or `-UserListPath`.

### View Entra group membership

Open **Groups > View Entra group membership** and choose an exact group display name or Entra group object ID. Names that do not match or match multiple groups stop the report; use the ID to disambiguate duplicate names. This is the single app task replacing **Get Entra group members** and **Entra group devices**. There is no member-type selector: **Report data > Members** includes every returned type, such as users, devices, groups, contacts and service principals, with available names, UPNs, mail and object IDs.

**Expand nested groups** is unchecked by default. When off, only direct members are returned and nested group objects are not expanded. When on, the report includes direct members and members inside nested groups at every depth, including the group objects themselves, as a **flat list**. Each object ID appears once regardless of how many membership paths reach it; this is not a hierarchy or membership-path report. Use the `MemberType` column to distinguish objects; filter, copy or **Export view** as needed. No CSV is written automatically. Entra object IDs are not Intune managed-device IDs.

The read-only workflow requires existing `Directory.Read.All` consent and the app's reader-role preflight. Hidden-membership groups also require `Member.Read.Hidden` and a supported Entra role. Graph may return only object type and ID for objects the caller cannot fully read; such rows are retained and a warning is shown. Empty groups show a zero count; failed or invalid pages stop the report instead of presenting partial results. The task uses Graph beta [members](https://learn.microsoft.com/en-us/graph/api/group-list-members?view=graph-rest-beta) or [transitiveMembers](https://learn.microsoft.com/en-us/graph/api/group-list-transitivemembers?view=graph-rest-beta) to include service principals, because [v1.0 members can omit them](https://learn.microsoft.com/en-us/graph/api/group-list-members?view=graph-rest-1.0). Microsoft notes that beta APIs can change and are not supported for production use. Expansion does not establish effective Intune policy targeting or change group membership.

The [standalone script](../entra/Get-EntraGroupMembers.ps1) returns the same rows:

```powershell
.\entra\Get-EntraGroupMembers.ps1 -GroupName 'Application Users'
.\entra\Get-EntraGroupMembers.ps1 -GroupName 'Application Users' -ExpandNestedGroups
.\entra\Get-EntraGroupMembers.ps1 -GroupId '00000000-0000-0000-0000-000000000001' -ExpandNestedGroups
```

The legacy [device-only CSV script](../Intune/Devices/Get-EntraGroupDevices.ps1) remains unchanged for existing command-line callers, but no longer has a separate app task.

### Add users or devices to an Entra group

Open **Groups > Add users or devices to Entra group**. Choose the group by object ID or exact name, then paste user UPNs or device hostnames, one per line, or choose a list file. Devices use a text file; users can use text, CSV or XLSX. For CSV/XLSX, select the UPN column (XLSX requires ImportExcel). There is no built-in list.

The workflow skips existing direct members and shows a result for each match. As before, if several Entra device objects share a hostname, it adds all matching devices; if a UPN returns multiple users, it adds none for that UPN. The app asks for run confirmation; Add does not support preview. Use [Add-EntraGroupMembers.ps1](../entra/Add-EntraGroupMembers.ps1) in place of either former standalone add script.

### Remove users or devices from an Entra group

Open **Groups > Remove users or devices from Entra group**. Choose the group by object ID or exact name, then enter user UPNs or device hostnames, one per line. You can also supply a text list or a CSV/XLSX user list with a UPN column (XLSX requires ImportExcel).

Select **Preview only (WhatIf)** to review matches without changing membership. A real run requires confirmation and reports an outcome per input. The workflow removes only direct membership references, never the users or devices themselves. It skips ambiguous matches and leaves inherited membership alone. Dynamic, role-assignable, synchronized, hidden-membership and Exchange-managed groups are not supported.

The workflow requires `Group.Read.All` and `User.Read.All` or `Device.Read.All` for the chosen input. Real removal additionally requires `GroupMember.ReadWrite.All` and permission to update the group. The [standalone script](../entra/Remove-EntraGroupMembers.ps1) supports the same input modes and `-WhatIf`.

### Create direct reports group

Under **Groups**, enter the manager's exact Entra display name or UPN. The workflow resolves the object ID and creates `Entra.Users.DirectReports.<FirstLast>` as a dynamic, non-mail-enabled security group. The suffix uses Entra's `givenName` followed by `surname` with whitespace removed, not the display name; `Johnson, Kurt` becomes `KurtJohnson`. Both name fields must be populated or creation stops. The description uses `Dynamic direct reports group for <manager display name>. Created by <creator UPN> on <yyyy-MM-dd>.` with the UTC creation date. **Preview only (WhatIf)** shows the generated details without creating a group; real runs request confirmation.

The rule `Direct Reports for "<manager-object-id>"` includes **the manager and immediate reports**, not nested reports. Membership processing is asynchronous. Duplicate names require a unique UPN; existing group names stop creation without updating anything. Check Entra before retrying an uncertain or cancelled create.

Requires existing `User.Read.All` and `Group.ReadWrite.All` consent, service authorization to create dynamic groups (typically Groups Administrator), and appropriate Entra ID P1 licensing. The app uses its existing Groups role preflight; Intune Administrator alone does not guarantee service authorization. See [CLI usage and prerequisites](../README.md#create-direct-reports-groups).

### Win32 app install diagnostics

Open **Apps and assignments > Win32 app install diagnostics**. Choose **Device name** or **Intune device ID**, and **App name** or **App ID**. Enter exact names or object IDs. Duplicate names stop the lookup; use IDs to choose the intended records. The standalone task retrieves a deployment report. When opened from **Failure triage**, it reuses the rollout report already in memory.

Under **Report data**, choose:

- **Diagnostic findings:** compares recognized Windows release requirements against the reported build, compares configured and reported processor architectures, and flags mixed reported outcomes and failure rows older than the app's last edit. It also shows current include/exclude group membership for the linked device and reported users where Graph allows the lookup. Dependency results are compared by managed device ID only when the dependency was included in the retained rollout. Otherwise, its status is unavailable and no extra full export is started.
- **Error code details:** appears when the selected device has reported failures. It shows a plain-language meaning and next check for supported codes, current detection settings for `0x87D1041C` (without script contents), and any exact match in the app's configured return codes. A match does not prove that the installer returned that code. The original error columns are preserved; a valid nonzero hex value takes precedence over the other reported value. When diagnostics reuse a rollout, **RolloutImpact** counts distinct managed devices with a failure for that code out of all identified devices in the retained report for that app. Select cells in one row to **Copy code**, **Open Microsoft reference**, or **Search this code**. The explanations are offline; only clicking a browser action opens a page, and the search query contains only the normalized hex code.
- **App investigation:** selected device/app identity, reported states and raw error codes, device last sync, configured installation context and available app requirements metadata.
- **Device deployment rows:** every report row matching the selected managed device ID, including individual user contexts, versions, raw status/error columns and any timestamps Intune returns. Conflicting rows are retained, not collapsed into a claim of success.
- **App assignments:** current target types, groups, intents and filters. Current membership is evidence, not proof of effective targeting at the time of failure. Filter outcomes, intent precedence, custom requirement and detection rules, and supersedence are not evaluated.
- **Suggested checks:** reporting freshness, assignment review, requirements/detection and Intune Management Extension log checks, with Microsoft troubleshooting links. These are guidance, not confirmed root causes.

No matching report rows means **outcome unknown**, not installed or unassigned. An installation failure in a successfully retrieved report is evidence, not a failure to retrieve the investigation. Lookup, assignment/filter or export failures stop the run without publishing incomplete investigation datasets. Blank metadata means unavailable. Current assignment/app configuration may differ from the configuration when an older installation status was reported.

Requires existing `DeviceManagementManagedDevices.Read.All`, `DeviceManagementApps.Read.All`, `Group.Read.All` and `DeviceManagementConfiguration.Read.All` consent, the reader-role preflight and Intune service authorization. Membership checks also require directory access to the device and users (such as `Device.Read.All` and `User.Read.All`); if unavailable, the report marks those checks as unavailable. No additional consent is requested automatically. Diagnostics use Graph data, not endpoint logs or remoting.

The workflow reuses [Get-Win32AppDeploymentStatus.ps1](../Intune/Assignments/Get-Win32AppDeploymentStatus.ps1) and its beta Graph export job, rather than the deprecated app `deviceStatuses` API. It temporarily downloads the selected app's **fleet-wide** device report, so large deployments can take time (the existing five-minute export-job timeout applies). It filters by Intune managed device ID locally, then removes its unique scratch folder; cleanup failures produce a warning with the path. Temporary files include device/user details. The app exposes only matching device rows and does not create permanent report files automatically; use the grid's copy/export actions to save results. Existing fleet-wide deployment reporting is unchanged.

This task does not install, retry, sync, collect endpoint logs or remediate anything. Beta APIs can change. See Microsoft's [app troubleshooting guide](https://learn.microsoft.com/en-us/troubleshoot/mem/intune/app-management/troubleshoot-app-install) and [assignment filter evaluation guidance](https://learn.microsoft.com/en-us/intune/fundamentals/filters/troubleshoot).

The [standalone script](../Intune/Assignments/Get-IntuneAppInvestigation.ps1) returns the overview as pipeline objects:

```powershell
.\Intune\Assignments\Get-IntuneAppInvestigation.ps1 -DeviceSearchBy 'Device name' -DeviceSearchValue 'PC-123' -AppSearchBy 'App name' -AppSearchValue 'Example App'
```

### Win32 app deployment status

Open **Results > Visual summary** for per-app bars with counts and percentages. Device status counts one worst-known state per identified device; rows without a device ID are excluded and disclosed. The optional user export chart sums the available installed, failed and not-installed device counts across user report rows. It is not a count of unique users or devices. The charts use the active theme's palette and summarize the full report independently of grid filters. Existing grids and CSV exports are unchanged.

There is now **one deployment reporting task** backed by [Get-Win32AppDeploymentStatus.ps1](../Intune/Assignments/Get-Win32AppDeploymentStatus.ps1). The duplicate under Devices has been removed. "Device version" was only the former script's folder location, not a separate type of app.

For rollout triage, choose an app under **Visual summary** and open a cluster in **Win32 failures by error code**. The **Failure triage** dataset counts one entry per managed device ID and code, even if multiple user-context rows report that code. Rows without usable IDs are kept separately. Click a cell in one identified row, then choose **Open app diagnostics setup…** and **Run report**. The prefilled task reuses the original rollout data without requesting another export. **Win32 app deployment status** and **Win32 app install diagnostics** keep separate results for the current app session. Use **Back to rollout** or select **Win32 app deployment status** in the sidebar to return to its saved dataset, chart category and text filter. Running either task again replaces only that task's results.

Enable **Look up OS version and last sync for failed devices** before running to add charts by error code and reported OS version or sync age. This opt-in requires `DeviceManagementManagedDevices.Read.All` and adds one read per unique failed device. Only verified ID matches with usable context appear in those charts; missing context and lookup failures remain visible in the queue. The context describes the current Intune record, not necessarily the device state when the failure occurred. Clusters are investigation leads, not failure rates, diagnoses, or proof of effective targeting.

Enter part of an app name, for example `Chrome`, or a pattern such as `*Adobe*`. A plain search is treated as `*search*`; matching is case-insensitive. If several app objects match, select one or several with checkboxes. IDs can also be supplied and combined with names; duplicate app IDs are reported only once.

For each selected app, the report exports:

- **DeviceStatus.csv:** complete device/user detail rows, including original error and version columns, plus app metadata and a readable installation state.
- **DeviceSummary.csv:** one worst-known state per identified device, so multiple user records do not inflate device counts. Rows with missing device IDs remain separate and are explicitly marked. Raw rows remain available for investigating conflicting or unknown states. Unclassified states are surfaced conservatively rather than assumed installed; this aggregation is not a guarantee of matching every portal view/localization.
- **UserStatus.csv:** Intune's per-user deployment report, enabled by default. Uncheck **Include user deployment status** for device-only reporting.

The script preserves raw Intune columns and adds localized status columns instead of replacing raw codes. A report failure is shown explicitly; device files already exported remain available if a subsequent user export fails. Reporting is read-only and does not deploy or remove software.

CLI output defaults to TEMP. The UI uses **Settings > Reports**, initially `%TEMP%\endpoint-toolbox`, unless overridden for a run. In PowerShell, `-IncludeUserStatus:$false` selects device-only reports; `-OpenReport` opens the completed CSVs.

### Windows Update for Business reporting

Open **Device reports > Windows Update for Business reporting**. Save a Log Analytics Workspace ID (GUID) and optional Azure tenant GUID under **Settings > WUfB**, or supply them in the task form. Preferences are in the `WUfB` section of `%LOCALAPPDATA%\EndpointToolbox\settings.json` and can inherit deployed defaults; per-run overrides are retained in memory and never written to activity history. No organization-specific workspace ID is embedded in the catalog.

Run the task using **Az.Accounts 5.0+**, already installed in PowerShell 7. It first checks the current Azure context and reuses it when it represents a user in the public cloud, matches the requested tenant (if supplied), and can acquire a Log Analytics token. Token acquisition can silently refresh an expired token; consecutive reports in the same app worker no longer call interactive sign-in unconditionally. When the tenant field is blank, the current compatible context's tenant is used. Home Graph is still separate: a Graph connection cannot substitute for an Azure context.

If there is no compatible context, the task signs in separately to Azure. If acquiring a token from a compatible context reports an authentication-renewal error, the task warns and attempts sign-in once, pinned to that same account and tenant. Cancellation or an unexpected account/tenant stops the run before workspace queries; unrelated token/network errors and workspace permission failures are surfaced rather than triggering repeated login attempts. **Use Azure device-code sign-in** selects the flow only when sign-in is needed; it does not force a new login when an existing session is usable. Changing the workspace within the same tenant does not itself require another login, but the account must have query access to that workspace.

The script creates new Azure contexts with process scope and keeps context autosave disabled. It can reuse a compatible context already loaded into the process, but does not add context/token persistence of its own or reuse a separate terminal's in-memory session. Public-cloud Log Analytics tokens are held as `SecureString`, and queries use the [Azure Monitor query API](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/api/access-api). Existing workspace/table query access, typically **Log Analytics Reader**, is required; Azure/Conditional Access can require renewed authentication and still enforce authorization. No scopes, consent, modules or role assignments are added automatically. Home Graph is not required by default, and its session is never changed by the report.

**Resolve missing computer names using Graph** is optional and **off by default**; it is not saved as a WUfB settings preference. Enable it only if your organization's security/privacy policy permits directory-name enrichment. Connect on **Home** first with existing delegated **Device.Read.All** consent and a supported reader role (Global Reader, Intune Administrator or Global Administrator). The Graph session must use the public cloud and the **same tenant** as the actual Azure session. Graph is used only for names; Azure workspace access is still required. The report never signs in to Graph or requests additional consent automatically.

When enabled, batched lookups match the latest WUfB clients' **AzureADDeviceId** to Entra **deviceId**, not the Graph object ID, Intune managed-device ID or computer name. Only blank/whitespace names and names consisting entirely of `#` are replaced; existing telemetry names are preserved. Entra `displayName` can differ from the current Windows hostname. Name filtering uses the resulting names, while duplicate names retain separate device IDs. Unmatched/deleted devices, blank Graph display names, ambiguous IDs and GlobalDeviceId-only records remain unresolved with a warning; names are never guessed. Permission, tenant, API or malformed-response failures stop the report without partial datasets; correct the issue or explicitly turn the option off to run without Graph.

An enabled run adds **Device name resolution**, showing device ID, original WUfB name, final name, source and resolution outcome for the scoped devices. This does **not** change `AllowDeviceNameInDiagnosticData` or any endpoint policy, upload names to WUfB, or change compliance evidence. It does expose directory names in the app, copied data and exports even when telemetry names are suppressed. Protect that data and obtain organizational approval before use.

During sign-in only, the script disables Azure PowerShell's console tenant/subscription selector with a process-scoped `LoginExperienceV2` override, then restores the prior override (or removes its own) even when sign-in fails. Reusing an existing session leaves that configuration untouched. Microsoft browser/broker or device-code authentication remains interactive when required; user-level Azure preferences are not changed. Queries use the signed-in tenant and explicit workspace GUID, not the selected subscription. Supply the workspace's Azure tenant GUID when the account can access multiple tenants.

The task validates and reads `UCClient`, `UCClientUpdateStatus`, `UCServiceUpdateStatus`, `UCUpdateAlert` and `UCDeviceAlert` for the signed-in tenant. Required schema/access failures, malformed or partial API responses, unidentified devices and results exceeding 100,000 rows per query stop the report without publishing partial datasets. Unavailable optional fields produce warnings and remain blank. **Data health** shows returned record counts, latest returned snapshots and missing optional columns.

**Report data** opens with **Devices**, one row per identified device in the latest `UCClient` snapshot. Exact device names optionally restrict scope; duplicate names retain distinct IDs, while an unmatched requested name stops the report. Select cells in one device row and choose **View selected device's updates** or **View selected device's alerts** for an ID-filtered view of already retrieved records. No additional network query is made. Charts likewise open supporting rows. Filter, copy or **Export view**; CSVs are not created automatically.

Other datasets are **Fleet overview**, **Missing security updates**, **Failed updates**, **Pending restarts**, **Update records**, **Service states**, **Alerts**, **Error summary**, **Observed updates**, **Compliance trend**, and **Data health**. Device rows include reported security/quality status, OS/build/edition/architecture, known installed quality-update KB and timestamps, restart evidence, active alerts/errors, OS servicing/end-of-service and available quality pause/deferral/deadline/grace values. Error summary distinguishes unique affected devices from active alert records. Resolved alerts remain inspectable; they do not count as current failures.

**Stalled candidates** lists in-progress update records whose last reported state is at least the configured stale threshold old, with state age and evidence freshness. This is an investigation cue, not proof a device is currently stuck. Servicing/end-of-service and approaching-end-of-service alerts are available in the device and alert datasets.

Headline security compliance is `100 * CompliantDevices / EvaluatedDevices`, using **OSSecurityUpdateStatus** (`Latest`, `NotLatest`, `MultipleSecurityUpdatesMissing`), not the separate Autopatch policy-compliance fields. The denominator contains only fresh, classifiable device records. Stale and unknown devices remain visible alongside numerator, denominator and total; no evaluated devices yields a blank percentage, not 0% or 100%. Default freshness is a successful Windows Update scan within **7 days**, plus a recent snapshot. Future/absent scan timestamps are Unknown. Change **Treat telemetry as stale after (days)** deliberately.

Enter an optional exact KB, such as `KB5132043`, to add **KB investigation** and its outcome chart. Results distinguish installed, failed, pending restart, in progress, not installed, needs attention, unknown and **Newer build (inferred coverage)**. Exact installation requires reported installation state with fresh transition evidence, or an installation state corroborated by a fresh matching current OS build. Uninstall states take precedence over historical installation timestamps. Conflicting deployment states are Unknown. A higher OS revision in the same observed KB target/version branch is explicitly inferred coverage, never proof this exact KB was installed. No record is Unknown, not missing; a different OS branch is not enough to prove non-applicability.

**Observed updates is not a complete update catalog.** It lists retained workspace observations, never labels the highest observed KB Microsoft's latest release. Known installed quality KBs are shown only when an installed update record matches the current OS build; missing KB/time fields remain blank. **Pending restarts** uses reported current restart state, not a historical restart-required timestamp alone. Failed update rows retain their evidence freshness so stale failures are not mistaken for live checks.

WUfB is delayed telemetry: [Microsoft documents daily snapshots and typical update-event latency of 24-36 hours](https://learn.microsoft.com/en-us/windows/deployment/update/wufb-reports-use). Ingestion time is not device scan/report time. The default retained query window is **28 days**, configurable from 1-90 days and limited by actual workspace retention. Compliance trend evaluates each retained day's device scans relative to its snapshot; it is omitted for exact-name scoped runs to avoid showing unrelated fleet totals. Devices that never reported, or disappeared from the latest snapshot, are not counted. This task cannot establish whole-Intune-fleet coverage or complete installation history.

Standalone use returns the same device rows:

```powershell
.\Intune\Devices\Get-WUfBReport.ps1 -WorkspaceId '<workspace-guid>' -TargetKB KB5132043
# Optional, using an existing same-tenant delegated Graph session with Device.Read.All:
.\Intune\Devices\Get-WUfBReport.ps1 -WorkspaceId '<workspace-guid>' -ResolveDeviceNames
```

The [script](../Intune/Devices/Get-WUfBReport.ps1) is read-only. Protect exports containing device names, IDs and diagnostic details.

### Expedited quality updates

Open **Results > Visual summary** for overall update status and device update substatus. The charts count the rows returned by Intune for the selected policy, prefer localized labels when present, and show up to eight reported values per chart. Theme colors distinguish individual bars, not severity. Less common values and missing values are shown separately in neutral colors; the grid shows the full detail.

Connect on **Home / Graph connection**, then open **Device reports → Expedited quality updates**. On **Configure**, select **Load policies**, filter the list by name, and choose one policy to enable **Run report**. Policies with the same name show their IDs so you can tell them apart. Loading the list does not start a report or deploy updates; **Run report** retrieves device status for the selected policy.

The workflow uses the existing `DeviceManagementConfiguration.Read.All` permission and Graph access check. The standalone script still accepts `-PolicyName`; it also supports `-ListPolicies` and selection with `-PolicyId`.

### Remediation and platform script status

After running a script report with returned device records, open **Results > Visual summary**. Remediation reports show separate detection and remediation breakdowns; platform script reports show run status. The bars, counts and percentages summarize the run-state records returned by Intune, not all devices targeted by the script. Skipped and unknown results remain visible where applicable; the view does not infer a failure or recurrence from missing data.

Under **Device reports**, choose **Remediation and platform script status**. Select **All**, **Remediation** or **Platform script**, then select **Load scripts**. The app checks Graph access and loads the matching Intune scripts into a searchable list; filter by script name or type and select exactly one before running the report. Loading choices does not retrieve device status. The report is read-only and does not run or modify the selected script.

The CSV and **Report data** include the selected script and device identity, last state update, and the status details Intune provides. Remediations include detection/remediation states, sync/update times and detection/remediation output or errors. Platform scripts include run state, result message and error details. A device run state is the latest state Intune reports; no rows means Intune returned no device run states, not that the script succeeded.

The list and report use the Microsoft Graph beta `deviceHealthScripts` and `deviceManagementScripts` endpoints. The report rechecks the selected script ID before retrieving its `deviceRunStates`. It requires existing `DeviceManagementScripts.Read.All` consent and an active reader role supported by Home. Beta API behavior can change. CSV output uses the saved report folder in the app and contains device and script execution details; review it before sharing.

For command-line use, `-ListScripts` returns the available script IDs and names; pass a selected ID with its explicit `-ScriptType` to run a report.

### User sign-in history

Open **Inventory > User sign-in history** and enter one exact UPN or primary email address. Choose a rolling lookback of 1–30 days (30 by default), and optionally select **Show failed sign-ins only**. The default **Paged events** retrieves one page of up to 100 individual interactive and non-interactive events, including available IDs, failure, device and location details. Member and guest accounts are supported.

Use **Report data > Load more** to append the next page, or **Retrieve all** to fetch all remaining events. Continuations retain the original inputs and time window, remain in memory only, and reject account or tenant changes. Failed continuations retain previous rows for retry. Use **Run report** to apply edited inputs. **Detailed events** retrieves everything in one run and remains the CLI default. **Export view** exports only loaded visible rows; no CSV is created automatically.

Paged results explicitly show **Incomplete** while more pages remain, even if a failures-only page contains no visible rows. Page timings appear in script output. The grouped summary API has been removed; all queries are date-filtered. Speed still depends on Graph.

**Visual summary** charts loaded events by UTC day and outcome, failure code, application and client app. It states received versus shown counts and whether more pages are available. Missing timestamps and failures-only exclusions are explicit. Charts are refreshed from the accumulated rows after successful paging; no extra summary query is made. Cancelled or failed refreshes retain the last successful rows, charts and retryable paging position. Grid filters do not change them.

Both views retain the same authentication, app-side role and scope checks without requesting new consent. Graph enforces service authorization.

The report uses the Microsoft Graph beta sign-in API because non-interactive events require it. Microsoft states that beta APIs can change and are not supported for production applications. Results are limited by Entra retention and licensing, so a 30-day request does not guarantee 30 days of history. A missing error code is **Unknown**; failures-only mode excludes such rows with a warning. Conditional Access policy details are not requested, and missing fields do not mean success. Requires existing `AuditLog.Read.All` and `User.Read.All` consent, an authorized active sign-in reader role and Entra P1/P2 licensing. See the [user guide](../HELP.md#user-sign-in-history).

### Microsoft 365 Apps Cloud Update

The **Visual summary** shows rollout status using the service's reported device counts for the selected channel, not counts from the paged inventory grid.

Under **Device reports**, run **Microsoft 365 Apps Cloud Update** for the **Monthly Enterprise Channel**. [Get-M365CloudUpdateReport.ps1](../entra/Get-M365CloudUpdateReport.ps1) retains its interactive MSAL sign-in. **By default, Home Graph sign-in is not required or reused**; the selected Office account/tenant can differ from Home. `organizations` allows a work or school account; optionally supply a tenant ID/domain. The Office service enforces authorization. A successful Home role check does not establish access to this separate service.

Install **MSAL.PS** deliberately in PowerShell 7 before running: `Install-Module MSAL.PS -Scope CurrentUser`. The desktop blocks a missing module rather than allowing the script's standalone automatic installation. It never requests elevation or changes execution policy.

**Report data** selects the portal-style **Cloud Update devices** rows (the data exported to `$PortalCsv`) first. Choose **Rollout summary**, **Progress by wave** or **Release** in the dataset selector to view statistics and release details in the grid. Office update failures are reported as rollout statistics, not failures to retrieve the report. API/paging/export errors still fail the run, and interrupted reports are incomplete.

The top summary shows run status without report statistics. Expand it for timing; detailed statistics remain in the grid datasets and Script output.

**Report & export settings > Report folder** defaults to the folder saved under **Settings > Reports**, initially `%TEMP%\endpoint-toolbox`, not a repository folder. Each run saves the device, full inventory and rollout summary CSVs under **Saved reports**. Select **Do not save CSV reports** to retain only the in-app datasets and summary. TEMP files may be removed by Windows; copy reports elsewhere when needed. Reports include device/user details and require appropriate handling.

**Include rollout group membership (Graph)** is unchecked by default. When checked, connect on Home first with existing `Group.Read.All` and `Device.Read.All` delegated consent and an active reader role supported by the app (Global Reader or Intune Administrator). Both Office and Graph sign-ins must use the **same tenant**. No Graph sign-in or additional consent is requested automatically.

Under **Settings > Cloud Update**, enter one exact Entra group display name per line and save. The list is empty unless configured in deployment defaults or the `CloudUpdate.GroupNames` section of the user's `settings.json`. At least one configured name is required when the optional membership lookup is enabled; the basic report does not require groups. Groups are not discovered from Office portal settings. For standalone use, supply `-WaveGroupNames` together with `-IncludeWaveGroups`; desktop settings are not read by the standalone script.

The optional **Group** column is added to the device grid and portal-style CSV, not the raw inventory or summary CSV. All matching configured groups are listed, even across waves, separated by `; `. Nested device members are included. Office inventory IDs are not Entra object IDs, so correlation uses case-insensitive exact computer names that are unique in both inventories. Missing or duplicate names are **Unknown**, with a warning and incomplete correlation counts. A uniquely matched device outside these groups shows **No configured wave group** only when every configured group was resolved. Current membership is not proof of the reason for an Office wave assignment; the original **Wave** column is never changed.

Group lookups follow Graph pagination. A missing or ambiguous configured group name generates a warning, but does not stop the remaining group lookups or CSV exports. Verified memberships are retained; otherwise-unmatched rows remain **Unknown (group lookup incomplete)** rather than being mislabeled as remaining-wave devices. Script output reports unresolved groups, and the run status indicates warnings for incomplete correlation, even if every device has a known membership in another group. The app never substitutes fuzzy matches or queries groups that are not in the saved list.

Unreadable membership, invalid pages or mismatched tenants still fail the optional lookup explicitly. Base Office rows remain visible as incomplete, with an Unknown group; these errors stop before CSV export. CLI opt-in also requires an already-connected authorized Graph session.

This workflow uses **undocumented config.office.com backend APIs**, not a supported public Microsoft Graph reporting contract. Microsoft can change them without notice. Actual sign-in, service authorization and live responses require operator validation.

### Win32 app deletion

| Task | Matching and selection |
|---|---|
| Delete Win32 apps | Names/patterns and IDs can be combined. Check the specific matching versions to use. The original justification request, assignment warnings, ShouldProcess confirmations and Multi-Admin Approval behavior are preserved. Selecting a row does not bypass deletion confirmation. |

The UI converts your row/checkbox selection into the original script's index response. You do not type app numbers. It never silently selects every match. Skipping every pattern retains the original script's "Nothing to delete/report on" error. Cancel stops the run, rather than approving or choosing an app.

An individual app failure does not stop the remaining selected apps. Intune dependency/supersedence blocks are shown as deletion errors; relationships are not removed automatically. If assignment lookup fails, that app is skipped rather than deleted without checking its assignments. Review Script output for failed apps and pending approvals before retrying.

Every deletion run saves a uniquely named `Win32AppRemoval_<timestamp>_<run-id>.csv` in the **Report & export settings > Report folder**, defaulting to the saved report folder. It contains only app name, version, ID, status and reason. Find it under **Saved reports**, or inspect the same rows under **Report data**. CLI use also supports `-OutputPath`.

The final Script output summary shows apps targeted, succeeded, failed, pending approval, skipped/preview and not processed/unknown. Counts refer to resolved, selected apps, not the number of wildcard expressions entered. Approval requests are not successes. Preview and declined confirmations have their own statuses and still produce a CSV. Reports are pre-created before deletion requests; a report-write failure prevents starting deletions. A cancellation attempts to save completed outcomes and leaves unstarted apps as `NotProcessed`; an interrupted deletion request is `NotConfirmed`, not a confirmed failure. Verify Intune before retrying an uncertain request. A process crash or storage failure can leave an incomplete report; remote actions cannot be rolled back.

### Script preservation

The prior UI-event edits have been removed from the business scripts. **11 scripts remain unchanged by the desktop work.** The deployment report is deliberately consolidated as requested; its duplicate has been removed. Win32 app deletion isolates per-app failures and exports per-run outcomes. Deployment, sync, device usage and the two assignment-listing scripts retain small outcome counters for accurate activity summaries. Remote logging in the cleanup script is optional; see [cleanup logging configuration](../README.md#cleanup-logging-configuration). The credential was not put back into source.

All presentation integration is now under Desktop in [Invoke-WorkflowPresentation.ps1](Invoke-WorkflowPresentation.ps1). It invokes the original script in an isolated invocation scope, reads existing result variables when the invocation ends, and reports files at known output paths only when their metadata changed during the run. Multi-app CSV datasets are loaded from the original exports. It does not rewrite Graph requests, matching logic or parameter defaults.

The Desktop adapter presents existing app-match collections at the original Read-Host point. Result tables are not fabricated from console messages. Some actions report outcomes only through their original text; **Script output is authoritative**, including pending approvals and partially completed operations. Cancellation can leave partial effects without a complete table.

### Authentication and dependencies

The app opens on **Home** without signing in automatically. Use **Connect / reconnect** to sign in once to the same persistent worker that runs all Graph tasks. Authentication uses delegated access with `ContextScope Process`; the Home connection is not a remote endpoint credential and does not inherit a separate terminal's in-memory Graph session. Home does not persist authentication across process exits. If hosting the UI in an existing PowerShell process, use **Disconnect Graph** to clear its Graph context before closing. Original business scripts and their CLI authentication behavior are unchanged.

Home offers an optional tenant ID/domain. **Connect / reconnect** requests only `https://graph.microsoft.com/.default`, using the existing delegated Microsoft Graph consent for the signed-in user/application. It does not combine the catalog's workflow scopes or add role-management permissions to the sign-in request. The previous read/admin scope profiles were removed because they could trigger **Need admin approval** even for an account already authorized to use the scripts.

If the EXE only flickers on Connect and the activity log reports **A window handle must be configured**, close the app and launch the signed script from the extracted bundle with a visible PowerShell console instead:

```powershell
pwsh.exe -NoProfile -STA -File C:\Deployment\EndpointToolbox\Desktop\Start-EndpointToolboxUI.ps1
```

Replace the example path with your extracted bundle location and keep the console open. This does not require the EXE, rebuilding, device-code authentication, or a custom Entra app registration. The EXE hides the console, which prevents WAM from obtaining its required window handle. Disabling WAM with `Set-MgGraphOption` is not a solution for the default Graph application ID in current modules: [Microsoft documents that this setting only applies to custom client IDs](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.authentication/set-mggraphoption). Signing is not the cause of this authentication error.

For contributors who want to retain the EXE, see [implementation options and required validation](Packaging/README.md). Live sign-in with the visible-console workaround has not yet been confirmed in this investigation.

The [Microsoft identity platform `.default` behavior](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc#the-default-scope) returns existing consented Graph permissions without prompting for additional scopes when consent already exists. This is not a consent bypass: if there is no existing delegated grant or tenant policy requires approval, Microsoft can still show a consent/approval screen. PIM activates directory roles; it does not grant application consent. Missing permissions are reported by the access check rather than requested automatically. A tenant administrator must review an insufficient application grant.

**Check connection** makes live `/me`, transitive membership and directory `roleAssignments` requests, rather than trusting `Get-MgContext`. Home displays the account, tenant, delegated scopes, supported active roles and UTC check time. Role verification includes active role-assignable group membership, handles pagination, and counts only tenant-wide active assignments, not PIM eligibility or administrative-unit-scoped assignments. Built-in role template IDs are used instead of localized display names. Custom roles and group ownership are not evaluated. This verification currently supports the Global Graph environment and user/delegated authentication only.

**Open Microsoft Entra PIM** opens the portal; the app never activates a role automatically. Activate the needed role, allow for propagation, then **Check connection** again. Reconnect if the token needs refreshing after elevation. The check is point-in-time, not a continuous monitor. **Disconnect Graph** signs out the shared app worker. Home remains viewable while work runs, but connect/check/disconnect are disabled until the single worker operation finishes; Stop remains available.

Before **every Graph task**, [Invoke-GraphSession.ps1](Invoke-GraphSession.ps1) repeats the live check in that worker, validates the delegated scopes declared in [WorkflowCatalog.psd1](WorkflowCatalog.psd1), checks the configured tenant where one exists, and enforces these conservative role prerequisites:

| Operation | Active tenant-wide built-in role |
|---|---|
| Most reports, primary-user read mode and supported previews | Global Reader **or** Intune Administrator |
| User sign-in history: both views | Global Reader, Reports Reader, Security Reader, Security Operator, **or** Security Administrator |
| Real Intune sync, primary-user changes and Win32 app deletion | Intune Administrator |
| Real Entra group membership changes | Groups Administrator **or** Intune Administrator (app preflight only; Graph enforces target-group authorization) |
| Real Entra / Autopilot cleanup | Intune Administrator **and** Cloud Device Administrator |

Global Administrator satisfies these role checks but is not recommended merely to run the app. Group tasks accept the operator's Intune Administrator elevation rather than imposing Groups Administrator as the only option. This does not claim Intune Administrator grants general Entra group/device deletion rights: when using that role alone, the app warns that target-group authorization is still determined by Graph, including group ownership and group-specific restrictions. Missing scopes, unreadable role checks and tenant mismatches still block execution. Group owners without a supported active role and scoped/custom-role operators may have valid service access that this conservative policy cannot prove; the desktop blocks rather than bypasses the check. Direct CLI use retains the original behavior.

If authentication, scopes, active roles or tenant cannot be verified, the task stops **before its business script runs**. Its configured inputs remain available: elevate/reconnect on Home, return and retry without restarting the task mid-batch. Missing-role messages name the role to activate. `ForceInteractive` is rejected in desktop runs; reconnect from Home instead so the identity is checked before business execution. The original scripts can still manage their own connection if invoked directly.

The footer says **Selected**, not **Ready**, when a task is selected, and explicitly states **Sign-in and permissions not verified**: selection alone does not check access. A context observed after a script is informational, not a new live check. Home checks preserve existing task report data and summaries.

Reading role assignments requires an existing consented permission such as `Directory.Read.All` or `RoleManagement.Read.Directory`, as well as directory read authorization; Home does not request those permissions automatically. If the tenant denies the role-verification APIs after `/me` succeeds, Home still shows the confirmed account/tenant but explicitly marks roles unverified, surfaces the error, and blocks tasks. You may need your tenant administrator to enable this read access. This is not a universal permission test: Intune RBAC/scope tags, licensing, conditional access, service-specific permissions, token/role propagation and expiration during a long run can still cause failures after preflight. Existing confirmations and mutation safeguards are unchanged. No real tenant operation is used merely to test write access.

Microsoft.Graph.Authentication is needed for Graph workflows. For sync, the execution worker checks for `Get-MgDeviceManagementManagedDevice` and `Sync-MgDeviceManagementManagedDevice`, not a fixed module layout. Microsoft.Graph.DeviceManagement **2.38.1 provides both**. Do not install an overlapping Actions module or use `-AllowClobber` just to satisfy the UI.

Check command availability in PowerShell 7 before installing anything:

```powershell
Get-Command Get-MgDeviceManagementManagedDevice, Sync-MgDeviceManagementManagedDevice
```

If needed, deliberately install missing dependencies:

```powershell
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser
# Only for Windows Update for Business reporting:
Install-Module Az.Accounts -MinimumVersion 5.0 -Scope CurrentUser
# Only for XLSX user input:
Install-Module ImportExcel -Scope CurrentUser
```

For CSV/XLSX user membership input, choose the file, select **Read columns from file**, then choose the UPN column. XLSX needs ImportExcel. The app does not install modules automatically.

| Workflow family | Access considerations; tenant roles/RBAC still apply |
|---|---|
| Device investigation | DeviceManagementManagedDevices.Read.All, Device.Read.All, User.Read.All and DeviceManagementServiceConfig.Read.All |
| Device inventory / Cloud PCs / primary-user read | Managed-device read; user/group reads where used |
| Device usage | Managed-device read, AuditLog.Read.All, Directory.Read.All; group reads for group scope |
| Discovered apps | App/device/report reads; group/directory reads for group scope |
| Quality updates | DeviceManagementConfiguration.Read.All / report access |
| Remediation and platform script status | DeviceManagementScripts.Read.All |
| Stale synced devices | Device.Read.All or Directory.Read.All |
| App deployment / assignments | DeviceManagementApps.Read.All; group/filter reads where used |
| Group member report | Directory.Read.All; Member.Read.Hidden and an appropriate role for hidden membership |
| Group membership additions | Group.Read.All, User.Read.All or Device.Read.All, and GroupMember.ReadWrite.All |
| User lookup by name | User.Read.All |
| Group membership removal | Group.Read.All; User.Read.All or Device.Read.All; GroupMember.ReadWrite.All for removal |
| Direct reports group creation | User.Read.All and Group.ReadWrite.All; dynamic user membership licensing and group creation authorization |
| Primary-device membership | Managed-device read, Device.Read.All, GroupMember.ReadWrite.All |
| Primary-user changes | DeviceManagementManagedDevices.ReadWrite.All and Intune Set primary user RBAC |
| Intune sync | Managed-device read/write and privileged-operation access |
| Entra / Autopilot cleanup | Device.ReadWrite.All, managed-device read, Autopilot service configuration permissions and appropriate roles |
| Win32 deletion | DeviceManagementApps.ReadWrite.All; tenant Multi-Admin Approval may apply |
| Remote support | Windows credentials and remote authorization, independent of Graph |

These are informational, not permission grants. Read the original script's Notes for exact requirements. Some original group scripts can reuse an existing different tenant in CLI use; desktop preflight blocks a mismatch with the script's configured tenant rather than silently switching. Inspect Home for a fresh account/tenant check or **Connection & script details** for the last observed context.

### Important original behavior

- Primary users default to read. The operation selector explicitly switches to assignment/removal. Per-device Yes/No approval remains mandatory, even if ShouldProcess prompts are suppressed.
- Preview is available only where the original script supports WhatIf. It may still write CSV files. Sync and hostname/UPN group-add scripts do not gain a fictitious preview.
- Primary-device membership uses Intune userPrincipalName and latest eligible Windows sync, not the primary-user relationship. Its fixed CSV path is overwritten even in preview.
- Duplicate hostnames in the group-add script add all matching Entra objects.
- Autopilot and Entra deletion approvals remain separate. AutoDeleteAutopilot suppresses only the Autopilot prompt.
- App deletion removes app objects and assignments, not installed software. An approval code is pending approval, not a completed deletion.

### Remote workspace

Choose **Remote endpoint session**, enter the computer, then connect using the secure in-app credential dialog. The **Remote workspace** appears under Results. Commands are routed only to the connected endpoint, never silently to the local computer.

The **Computer name** field is an editable dropdown. Type a new name, or pick one of the last 10 computers you successfully connected to. A name is added only after the session is actually established; failed, refused or cancelled connections are not saved. The list is stored per user in `%LOCALAPPDATA%\EndpointToolbox\recent-devices.json` (computer names only, most recent first, duplicates merged case-insensitively). Choosing a name only fills the field; nothing connects until you select **Connect to endpoint**. To clear the list, delete that file. Offline smoke tests never read or write it.

For **Also open the administrative share in Windows Explorer (UNC)**, save an optional suffix in the **DNS suffix (optional)** field under **Settings > Remote**. The suffix is appended only when the computer name has no dot; a qualified name is used as entered. Leave the setting empty to use the name as typed. The setting uses `Remote.DnsSuffix` in the unified configuration.

Remote output uses a simple `PS [device]>` command echo and plain results without timestamps, `Output:` labels or run-timing lines. Connection details stay in the connection status above it; errors and warnings remain visible. Detailed activity and timings are still available in **Script output**. An animated running/stopping indicator appears at the bottom of the remote output area while the worker is busy and disappears on completion, failure or cancellation. It is not part of copied/saved remote output and indicates worker activity, not endpoint progress. This is still a command workspace rather than an interactive terminal emulator.

The original ping, WinRM, Negotiate and EnableNetworkAccess behavior remains. WinRM/network/domain configuration and an authorized privileged account are required. The app owns the created session and attempts cleanup on disconnect/close. An idle remote session can coexist with Graph work, but execution is serialized.

**Saved commands** offers 29 starter commands based on the endpoint cleanup and troubleshooting notes. Selecting a friendly name replaces the command editor text and shows a description/warning; it **does not execute anything**. If the editor contains a custom or modified command, confirmation is required before replacing it. Review or edit the command, then click **Run on endpoint**. Custom commands still work. A connected remote session is required for execution, and automatic activity logs still exclude command text and returned data.

The editable reference file is [RemoteCommands.json](RemoteCommands.json). It has `SchemaVersion: 1` and a `Commands` array; every entry requires unique `Name`, `Description` and `Command` strings. JSON uses `\\` for a literal backslash and `\n` for a line break. Restart the app after editing. Startup validation checks the schema, names and PowerShell syntax without running commands. Treat this file as executable administrative content: review changes and do not store credentials or personal data in it.

The starter list covers disk usage, temporary files, crash dumps, Windows.old, profiles, update cache, DISM/SFC, upgrade staging files, Intune's PushLaunch task, reboot flags, hotfixes and event logs. Cleanup commands are destructive where noted. Profile preview/removal templates require replacing `REPLACE_WITH_PROFILE_FOLDER` with the primary user's profile folder name and exclude loaded/special profiles; they do not assume the remoting account is the user to retain. Preview the profile list first. Cleanup errors are surfaced rather than silently ignored; sizing commands still omit inaccessible files. Update-cache cleanup attempts to restore services that were running. No automatic reboot was added.

This is a PowerShell command workspace, not a full terminal: full-screen native programs, nested interactive sessions and multiple simultaneous remote sessions are not supported. UNC is an explicit Windows Explorer handoff, not a file browser. A PowerShell drive's credentials do not guarantee Explorer share access.

### Retention and exports

**Settings > Reports** stores the default report folder in `%LOCALAPPDATA%\EndpointToolbox\settings.json`, initially `%TEMP%\endpoint-toolbox`. Enter an absolute local or UNC folder, use **Browse...**, then **Save**; environment variables are expanded, and saving creates the folder if needed. Empty resets to the initial default. Report folder fields, default CSV file paths, **Export view** and **Export PNG** use this setting. Per-run overrides and optional exports are preserved. Saving updates untouched default paths in current forms and drafts but does not move existing reports or change already-running requests. Theme and Graph tenant preferences are retained. Standalone scripts keep their existing defaults.

**Delete all reports...** on the Reports tab confirms the saved folder and CSV count before permanently removing only its direct CSV files. It does not recurse or delete linked files, other file types, reports in override folders, logs, history, or in-memory data. Active runs and unsaved folder edits block deletion. Failures stop the operation and show how many files were deleted before the error; there is no rollback.

In **Visual summary**, choose a report and select **Export PNG...** to save all of its charts in one 1200-pixel-wide image, including content below the scroll area. Export preserves the selected theme, summary title, UTC export time, chart labels, units, percentages and data-coverage notes; navigation buttons are omitted. Charts retain their existing top-N, sampling and paging limitations, independently of grid filters. Rendering and encoding use the existing STA worker without Graph requests or changes to authentication. The image appears under **Saved reports**; direct PDF export is not included. Cancelled or failed writes leave an existing destination unchanged. Very large summaries exceeding 20,000 pixels in height are explicitly rejected rather than clipped. PNG images may contain sensitive report details and are not removed by the CSV-only **Delete all reports...** action.

Expand the run summary in Results to see the local start time and live worker elapsed time. On completion (including cancellation/failure), it shows the worker end time/runtime, display-processing end time, additional display-processing time after the worker ended, and total time. The same timing summary is included in Script output for Save log. Worker timing is recorded on the worker state transition, not when the UI eventually drains its event queue. It includes script execution, output formatting and the Desktop presentation adapter; display time is the additional queue/grid preparation afterward, not an isolated rendering benchmark. Worker and UI processing overlap.

The consolidated Win32 deployment script also prints `Report started`, `Report ended` and `Report elapsed` when run directly in a terminal (and in the app). This measures the script body, including sign-in/selection and CSV generation, but excludes the Desktop adapter's subsequent CSV loading. Compare matching app selections and user-status options; timestamps and duration do not imply a successful report.

The **Theme** selector in **Settings > Appearance** offers Light, Dark, [Catppuccin Mocha](https://catppuccin.com/palette/) and [Gruvbox Dark](https://github.com/morhetz/gruvbox). It switches appearance immediately without clearing inputs, results or output. The choice is saved per user in `%LOCALAPPDATA%\EndpointToolbox\settings.json` and restored on the next launch; existing Light and Dark preferences continue to work, and new users start in Light. Main pages, generated forms, report/history grids, dropdowns, Settings and script-input dialogs share the theme. Text boxes, password fields and dropdowns retain visible borders when unfocused. Windows-managed title bars, message boxes, file/folder pickers and external sign-in windows retain their Windows appearance. A preference read/write failure is reported rather than silently ignored. Offline smoke tests never read or write the user's preference.

**Keyboard shortcuts:** Press **Ctrl+,** to open Settings. To change themes, press and release **T**, then press **L** (Light), **D** (Dark), **G** (Gruvbox Dark), or **C** (Catppuccin Mocha) within two seconds. Shortcuts do not capture keys in text fields, password fields, or dropdowns.

**Results > Visual summary** also shows mobile device compliance, ownership and OS; Cloud PC provisioning status and product type; and Entra group membership by direct member type (without expanding nested groups). **Stale AD-synced Entra devices** shows days since last Entra sign-in for the returned records. The configured stale threshold still applies, and **Unknown** timestamps are shown separately and are not confirmed stale. Charts use the active theme and summarize the full report independently of grid filters.

Mobile inventory also groups returned records by platform and OS version, including missing values. Win32 failure-code charts show cumulative percentages over all failure entries with a code, including clusters outside the displayed top eight; a device can contribute to multiple codes.

In **All Cloud PCs > Report data**, select cells from one Cloud PC row and choose **Load Cloud PC connection history...**. This explicitly requests seven days for that Cloud PC through Microsoft Graph beta using the existing Cloud PC read consent and the same verified tenant. The returned history and visuals show service-reported usage, remote sign-in duration, median round-trip time and median bandwidth; missing or invalid values are excluded, not treated as zero. Up to 40 points per metric are sampled for display; all returned rows remain in the dataset. Data depends on service authorization, availability and retention; beta APIs can change and are not supported by Microsoft for production applications. Failed, empty or cancelled requests do not remove the inventory. This differs from the Intune logon proxy in **Cloud PC last login**.

- **Discovered apps:** Choose **All devices**, **Single device**, or **Entra group** under **Scope**. For **Single device**, enter its exact Intune device name or its Intune managed device ID (not its Entra device ID). Use the managed device ID if the name matches more than one device. The platform and optional **App name** filters still apply. The device filter is applied to the downloaded report, so the Intune export may still take time. With an **App name** filter, select a matching app in **Visual summary** to see distinct device counts for up to eight reported versions, with less common and missing versions shown separately. A device can count under more than one version.
- **Cloud PC last login:** Shows recency of the latest Intune-reported Windows user logon, not a Windows 365 connection or device sync. No logon reported and lookup failures are separate.
- **Device user usage:** In **Visual summary > Primary-user review**, select **View Mismatch**, **View Unassigned**, **View Inconclusive**, or **View Match** to open the supporting **Devices** rows. Use **Clear category** to restore all categories; the text filter still applies. Mismatches start with the largest difference in active days. Select a cell in a device row and choose **View selected device's sign-in days…** to compare the assigned user's dates with the observed user's dates. The observed user is the unique account with the most distinct successful Entra sign-in days (UTC); ties are inconclusive. Recency remains available in the visual selector. Results depend on the configured lookback and available audit retention; they are not Windows logons or time spent on the device. No assignment is changed, and the detailed sign-in CSV is unchanged.
- **Compare Win32 report runs:** In **Apps and assignments**, select the older and newer `DeviceSummary.csv` exports from the Win32 deployment report. Use the same app, tenant and deployment scope. The comparison runs offline and matches by device ID, so renames do not count as new devices. Only the app ID is verified; the CSVs cannot establish tenant, scope or export order. Use the category or common-transition charts to open the matching **Device changes** rows. Moves to or from **Installed** are labeled improved or regressed only for recognized non-installed statuses; unknown or localized changes are shown as **Other status change**. Unidentified records are excluded and counted separately. **No longer reported** means absent from the newer export, not necessarily unenrolled or removed.

The sidebar **Settings** button opens Settings without changing the current task, report selection or run summary. Its **History** tab has a dedicated read-only run-history grid, **Refresh history** and **Clear history**. History loads when Settings opens; refresh it to see newly completed runs. An empty history displays an empty-state message. Clearing history requires confirmation and is blocked while an operation is running. The **Logs** tab contains **Open activity logs**. The **Remote** tab stores the optional UNC DNS suffix; closing with an unsaved change requires confirmation. Close Settings with its close button or Esc.

History at `%LOCALAPPDATA%\EndpointToolbox\history.jsonl` stores run/workflow IDs, UTC times, overall state and row count only. No inputs, targets, usernames, tenant IDs, credentials, command text, justification, report paths or detailed logs are stored there.

**Open activity logs** opens `%LOCALAPPDATA%\EndpointToolbox\Logs`:

- `master-YYYY-MM-DD.jsonl`: app startup/close, task selection, runs, cancellation requests, exports and app/task errors.
- `task-<workflow-id>-YYYY-MM-DD.jsonl`: that task's run lifecycle, outcome counts and compact diagnostics. Run IDs correlate task records with master records. Records include the local Windows username and UTC time.
- Logs retain the current UTC day and the preceding 29 days, pruned on the next write. Daily files roll over into numbered segments at 5 MB. Pruning applies only to activity-log filenames in this folder, never reports or history.
- Automatic diagnostics are limited to the first 20 errors/warnings per run, at most 500 characters of their first line. Counts are not limited. Logging failures appear in Script output; inability to start a run log blocks that run before script execution.
- Logs contain no full console output, Graph context, credentials, justification, parameter payloads or report data. Remote activity records contain only connection/disconnection lifecycle, device and outcome; **remote commands and returned content are never automatically logged**, including remote error messages.

Tasks publish a compact end-of-run summary from their structured results or existing counters. Read-only success means report data was retrieved, not that every device/application in the report is healthy. Some summaries count report rows or membership outcomes rather than unique devices; the entity label identifies the unit. Duplicate-hostname membership additions count each object, plus unresolved/failed name lookups. Affected/requested counts mean accepted action requests, not verified installation, sync or primary-user completion. Already-satisfied targets count as successes without new effects. Unknown or cancelled outcomes are marked incomplete, not invented as successes; failures before target resolution can have no counts.

Detailed output stays in memory unless explicitly saved. CSV reports (including Win32 deletion reports) and the optional cleanup logging webhook are separate from activity-log retention. The remote workspace output has a separate manual save action. Common signed-URL parameters and bearer tokens are redacted, but arbitrary script/remote output and CSV reasons may contain sensitive details. Inspect exports before sharing. Clear history removes only run history, not activity logs or reports. These local per-user files are operational logs, not tamper-proof compliance audit storage.

## Offline validation

```powershell
Invoke-Pester -Script .\Desktop\Tests -PassThru
pwsh.exe -NoProfile -STA -File .\Desktop\Start-EndpointToolboxUI.ps1 -ValidateOnly
pwsh.exe -NoProfile -STA -File .\Desktop\Start-EndpointToolboxUI.ps1 -SmokeTest
pwsh.exe -NoProfile -STA -File .\Desktop\Tests\Fixtures\DesktopUiFixture.ps1 -SettingsOnly
pwsh.exe -NoProfile -STA -File .\Desktop\Tests\Fixtures\ThemeFixture.ps1
```

Tests replace all Graph/network commands. The Graph suite verifies shared Home authentication across successive worker invocations, active versus expired roles, group-assigned and scoped roles, missing scopes, tenant mismatches, disconnected/forbidden checks, pagination and blocking before business execution. Native UX tests cover Home navigation, preserved inputs and serialized connection controls. Existing suites verify unchanged-script parity, consolidated deployment selection/exports/summaries, command discovery, prompts, preview, pending approval, cancellation, exit codes and remote isolation. App-investigation tests cover exact names/IDs, ambiguity, all matching user contexts, raw errors, unknown outcomes, paged assignments/filters, temporary-report cleanup and failures without partial datasets. Direct reports tests cover manager resolution, naming, rule/description payloads, duplicate guards, preview, uncertain outcomes and native confirmation refusal/cancellation. SmokeTest verifies unauthenticated Home startup, constructs all 29 forms and their input-source options, checks grouped navigation/hidden inactive inputs/search behavior, then processes exactly 100,000 synthetic rows with an enforced maximum UI-processing tick of 250 ms.

The offline suite includes native WPF app-selection dialogs and primary-action visibility at two window sizes. The focused `-SettingsOnly` fixture checks the dedicated history grid, refresh/clear/error handling, log-folder handoff, close/reopen/Esc and unchanged report state without first running the large-report performance fixture. A live dispatcher regression streams 2,000 log messages and slow-to-format output from a long-running worker, checks heartbeat gaps stay below 500 ms, and clicks Cancel while the worker is still running. SmokeTest enforces exact row counts and the processing threshold rather than assuming responsiveness. This measures UI batching, not network latency or full interactive accessibility.

Script output shows progress, text messages, prompts, warnings/errors, saved-file locations and timing, not duplicate object rows or formatted pipeline tables. Full report rows remain in Report data and the script's CSV files. This suppression applies only to script success-stream objects; the remote command workspace retains its normal formatted output, and running original scripts directly in a terminal is unchanged.

Grid tables, redaction, outcome classification and their data-view indexes are prepared in the worker, then handed to WPF as complete datasets. An indexed, read-only view avoids WPF eagerly caching every row. Filtering, column sorting and Save results remain available. UI event delivery uses time-limited batches and appends/scrolls each diagnostic log once per batch; modal script prompts prevent nested event processing.

Cancel requests a worker stop and immediately discards queued log/report rendering, including pending grid rows. It retains already-displayed data, saved-file references and diagnostics, and labels the run's results as incomplete. New runs become available when the worker has stopped, without waiting to render the discarded backlog. Cancellation does not forcibly kill a thread or undo submitted Graph jobs/actions; an in-flight command must still return or honor PowerShell's stop request. A backlog regression cancels 100,000 pending grid rows plus 20,000 output events and verifies that the next run succeeds.

After the report-display optimization, all 18 forms and the 100,000-row smoke test passed in 4.60 seconds with a maximum processing tick of 166 ms (250 ms limit). SmokeTest also enforces a 10-second total preparation/binding limit.

The desktop regression suite passed all 58 tests. A separate synthetic report with 100,000 rows and 20 columns completed in 6.28 seconds, including 0.19 seconds of display processing after worker completion. The native regression enforces complete row/column counts, no duplicate scrolling rows, preserved diagnostics, functional filtering/sorting, a 30-second total limit and a 2-second post-worker display limit. These measurements do not predict live Intune export time.

A native dispatcher run measured a maximum heartbeat gap of 223 ms during the long-running output fixture, with Cancel verified while the worker was busy. Timing tests verify that worker runtime stops before UI queue processing finishes and resets for the next run. Each report run has a unique filename identifier so rapid repeated runs remain separate and visible in Saved reports.

Real Graph/MFA/Conditional Access, designated test-resource mutations, tenant MAA, domain WinRM/UNC, screen-reader use and 100%/150%/200% display scaling remain authorized manual acceptance gates. Offline validation and synthetic rendering are not production certification.

## Adding a task

1. Add the reviewed business script under the appropriate service folder in the repository root, not Desktop.
2. Add a unique stable ID, category, explicit path and capabilities to [WorkflowCatalog.psd1](WorkflowCatalog.psd1). Graph tasks also need explicit `GraphScopes` and a supported `GraphRole` policy; cover read/change/preview modes in access tests. Duplicate basenames are allowed, duplicate IDs/paths are not. Uncataloged scripts block launch instead of being auto-executed.
3. Keep the business script unchanged. Describe mutually exclusive sources in the catalog; use the existing typed binding and add plain-English labels/hints in the Desktop module.
4. If needed, add a reviewed presentation mapping for existing result variables/export paths in the Desktop adapter. Do not infer destructive success from text, or bypass original prompts.
5. Add synthetic tests for matching/selection, defaults, outputs, errors, authentication parity and confirmations. Run the tests and desktop smoke check.

Ordinary task inputs are typed parameters, never evaluated as PowerShell code. Only the explicitly labeled remote workspace accepts administrator-written commands.
