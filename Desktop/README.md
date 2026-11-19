# Endpoint Toolbox desktop

A Windows WPF front end for the 22 business scripts in the repository root and service folders. The redesigned interface follows the Packaging Toolkit's sidebar-and-task-page layout: real category headings, readable task names, focused input cards, one primary action and a separate output workspace.

## Launch

Requires Windows and **PowerShell 7.6 or newer**. Windows PowerShell 5.1 is not supported. Keep the repository together on disk.

```powershell
pwsh.exe -NoProfile -STA -File .\Desktop\Start-EndpointToolboxUI.ps1
```

Run [Install-EndpointToolboxShortcut.ps1](Install-EndpointToolboxShortcut.ps1) for a per-user shortcut. The running app has its own Windows taskbar identity and uses the supplied 32×32 icon; the shortcut uses its `.ico` version. Close and relaunch an already-running instance to apply the taskbar identity change. No elevation or execution-policy bypass is added. Recreate the shortcut if the repository moves.

Close the existing app window after an update, then rerun the launcher. If an incompatible compiled bridge is still loaded in your PowerShell session, the launcher opens a fresh process automatically. A .NET SDK is not needed; the [hosting bridge](Hosting/DesktopPowerShellHost.cs) compiles against the installed runtime.

## Layout and workflow

1. **Connect on Home:** connect to Graph using existing consent, activate the needed role in PIM and check the connection. **Home / Graph connection** stays accessible from the sidebar, even while a task runs. Returning to the selected task preserves its inputs.
2. **Find a task:** search or browse the sidebar's category headings. Category names are not repeated in each menu item.
3. **Configure:** read the short task guide. Choose an input source; inputs for other sources disappear rather than remaining disabled on screen. Plain-English labels include examples, and tooltips retain the original parameter names/help.
4. **Review mode:** supported actions offer an explicit **Preview only (WhatIf)** checkbox. It is not enabled automatically. The footer and primary button clearly indicate preview versus the original operation.
5. **Run:** the app switches to **Run & results > Script output**, checks Graph access for Graph tasks, then starts the original script if the checks pass. Cloud Update uses its own Office sign-in; remote support uses endpoint credentials. Original prompts appear in-app. Errors, warnings, skipped items, assignment warnings and approval codes remain visible in the original script output.
6. **Use the output:** **Report data** contains structured report rows where available, with filtering, copy and export. **Saved reports** lists the script's generated CSVs. Export buttons live beside the output they save, not beside the Run button.

Report/export settings and advanced controls are collapsed until needed. There is only one active task or remote command at a time. Stop requests cancellation; it cannot roll back requests already accepted by Intune, Entra or a remote endpoint.

Inputs use consistent compact spacing, including matching username/password fields in smaller sign-in dialogs. Multi-value inputs remain multiline and scroll as needed; app-selection dialogs keep their wider grid. Output panes are top-aligned. In **Remote workspace**, drag the divider above the saved-command picker to resize the output and command editor. Long command descriptions scroll without displacing the output or action buttons. The task description and run summary/timing card are hidden while this tab is selected to leave more room for the remote terminal; they remain available on the other tabs.

### Find Entra users by name

Open **Inventory > Find Entra users by name**. Enter names one per line as `First Last` or `Last, First`, or choose a text file with one name per line. The lookup is read-only and returns one row per matching user with UPN, mail, title, department and account state.

- **Found**: one exact display-name or first/last-name match.
- **Multiple**: several users match exactly; confirm by UPN or department.
- **PossibleMatch**: no exact match, but a user has the same surname and first initial (for example Mike / Michael). Review before use.
- **NotFound** and **Failed** are reported per name.

The summary counts names. Only Found counts as succeeded; Multiple and PossibleMatch count as unresolved. Requires existing `User.Read.All` consent. The [standalone script](../entra/Find-EntraUsersByName.ps1) accepts `-Names` or `-UserListPath`.

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

### Win32 app deployment status

There is now **one deployment reporting task** backed by [Get-Win32AppDeploymentStatus.ps1](../Intune/Assignments/Get-Win32AppDeploymentStatus.ps1). The duplicate under Devices has been removed. "Device version" was only the former script's folder location, not a separate type of app.

Enter part of an app name, for example `Chrome`, or a pattern such as `*Adobe*`. A plain search is treated as `*search*`; matching is case-insensitive. If several app objects match, select one or several with checkboxes. IDs can also be supplied and combined with names; duplicate app IDs are reported only once.

For each selected app, the report exports:

- **DeviceStatus.csv:** complete device/user detail rows, including original error and version columns, plus app metadata and a readable installation state.
- **DeviceSummary.csv:** one worst-known state per identified device, so multiple user records do not inflate device counts. Rows with missing device IDs remain separate and are explicitly marked. Raw rows remain available for investigating conflicting or unknown states. Unclassified states are surfaced conservatively rather than assumed installed; this aggregation is not a guarantee of matching every portal view/localization.
- **UserStatus.csv:** Intune's per-user deployment report, enabled by default. Uncheck **Include user deployment status** for device-only reporting.

The script preserves raw Intune columns and adds localized status columns instead of replacing raw codes. A report failure is shown explicitly; device files already exported remain available if a subsequent user export fails. Reporting is read-only and does not deploy or remove software.

Output defaults to TEMP in CLI and UI. In PowerShell, `-IncludeUserStatus:$false` selects device-only reports; `-OpenReport` opens the completed CSVs.

### Expedited quality updates

Connect on **Home / Graph connection**, then open **Device reports → Expedited quality updates**. On **Configure**, select **Load policies**, filter the list by name, and choose one policy to enable **Run report**. Policies with the same name show their IDs so you can tell them apart. Loading the list does not start a report or deploy updates; **Run report** retrieves device status for the selected policy.

The workflow uses the existing `DeviceManagementConfiguration.Read.All` permission and Graph access check. The standalone script still accepts `-PolicyName`; it also supports `-ListPolicies` and selection with `-PolicyId`.

### Remediation and platform script status

Under **Device reports**, choose **Remediation and platform script status**. Select **All**, **Remediation** or **Platform script**, then select **Load scripts**. The app checks Graph access and loads the matching Intune scripts into a searchable list; filter by script name or type and select exactly one before running the report. Loading choices does not retrieve device status. The report is read-only and does not run or modify the selected script.

The CSV and **Report data** include the selected script and device identity, last state update, and the status details Intune provides. Remediations include detection/remediation states, sync/update times and detection/remediation output or errors. Platform scripts include run state, result message and error details. A device run state is the latest state Intune reports; no rows means Intune returned no device run states, not that the script succeeded.

The list and report use the Microsoft Graph beta `deviceHealthScripts` and `deviceManagementScripts` endpoints. The report rechecks the selected script ID before retrieving its `deviceRunStates`. It requires existing `DeviceManagementScripts.Read.All` consent and an active reader role supported by Home. Beta API behavior can change. CSV output defaults to TEMP and contains device and script execution details; review it before sharing.

For command-line use, `-ListScripts` returns the available script IDs and names; pass a selected ID with its explicit `-ScriptType` to run a report.

### Microsoft 365 Apps Cloud Update

Under **Device reports**, run **Microsoft 365 Apps Cloud Update** for the **Monthly Enterprise Channel**. [Get-M365CloudUpdateReport.ps1](../entra/Get-M365CloudUpdateReport.ps1) retains its interactive MSAL sign-in. **By default, Home Graph sign-in is not required or reused**; the selected Office account/tenant can differ from Home. `organizations` allows a work or school account; optionally supply a tenant ID/domain. The Office service enforces authorization. A successful Home role check does not establish access to this separate service.

Install **MSAL.PS** deliberately in PowerShell 7 before running: `Install-Module MSAL.PS -Scope CurrentUser`. The desktop blocks a missing module rather than allowing the script's standalone automatic installation. It never requests elevation or changes execution policy.

**Report data** selects the portal-style **Cloud Update devices** rows (the data exported to `$PortalCsv`) first. Choose **Rollout summary**, **Progress by wave** or **Release** in the dataset selector to view statistics and release details in the grid. Office update failures are reported as rollout statistics, not failures to retrieve the report. API/paging/export errors still fail the run, and interrupted reports are incomplete.

The top summary/timing card shows run status and timing only, without report statistics. Detailed statistics remain in the grid datasets and Script output.

**Report & export settings > Report folder** defaults to **TEMP**, like other reports, not a repository folder. Each run saves the device, full inventory and rollout summary CSVs under **Saved reports**. Select **Do not save CSV reports** to retain only the in-app datasets and summary. TEMP files may be removed by Windows; copy reports elsewhere when needed. Reports include device/user details and require appropriate handling. Standalone CLI defaults and output remain unchanged unless the new optional `-IncludeWaveGroups` switch is supplied.

**Include rollout group membership (Graph)** is unchecked by default. When checked, connect on Home first with existing `Group.Read.All` and `Device.Read.All` delegated consent and an active reader role supported by the app (Global Reader or Intune Administrator). Both Office and Graph sign-ins must use the **same tenant**. No Graph sign-in or additional consent is requested automatically.

Only the groups you list under **Rollout group names** (one exact Entra group display name per line) are considered; they are not discovered from the Office portal settings. The list is required when this option is checked and is ignored otherwise. From the command line, pass `-WaveGroupNames 'Group A','Group B'`. Devices that are in none of the listed groups are reported as having no configured group.

The optional **Group** column is added to the device grid and portal-style CSV, not the raw inventory or summary CSV. All matching listed groups are listed, separated by `; `. Nested device members are included. Office inventory IDs are not Entra object IDs, so correlation uses case-insensitive exact computer names that are unique in both inventories. Missing or duplicate names are **Unknown**, with a warning and incomplete correlation counts. A uniquely matched device outside these groups shows **No configured wave group** only when every listed group was resolved. Current membership is not proof of the reason for an Office wave assignment; the original **Wave** column is never changed.

Group lookups follow Graph pagination. A missing or ambiguous configured group name generates a warning, but does not stop the remaining group lookups or CSV exports. Verified memberships are retained; otherwise-unmatched rows remain **Unknown (group lookup incomplete)** rather than being mislabeled as remaining-wave devices. Script output reports unresolved groups, and the run status indicates warnings for incomplete correlation, even if every device has a known membership in another group. Check the exact group display names you entered; the app never substitutes fuzzy matches or queries unrelated groups.

Unreadable membership, invalid pages or mismatched tenants still fail the optional lookup explicitly. Base Office rows remain visible as incomplete, with an Unknown group; these errors stop before CSV export. CLI opt-in also requires an already-connected authorized Graph session.

This workflow uses **undocumented config.office.com backend APIs**, not a supported public Microsoft Graph reporting contract. Microsoft can change them without notice. Actual sign-in, service authorization and live responses require operator validation.

### Win32 app deletion

| Task | Matching and selection |
|---|---|
| Delete Win32 apps | Names/patterns and IDs can be combined. Check the specific matching versions to use. The original justification request, assignment warnings, ShouldProcess confirmations and Multi-Admin Approval behavior are preserved. Selecting a row does not bypass deletion confirmation. |

The UI converts your row/checkbox selection into the original script's index response. You do not type app numbers. It never silently selects every match. Skipping every pattern retains the original script's "Nothing to delete/report on" error. Cancel stops the run, rather than approving or choosing an app.

An individual app failure does not stop the remaining selected apps. Intune dependency/supersedence blocks are shown as deletion errors; relationships are not removed automatically. If assignment lookup fails, that app is skipped rather than deleted without checking its assignments. Review Script output for failed apps and pending approvals before retrying.

Every deletion run saves a uniquely named `Win32AppRemoval_<timestamp>_<run-id>.csv` in the **Report & export settings > Report folder** (TEMP by default). It contains only app name, version, ID, status and reason. Find it under **Saved reports**, or inspect the same rows under **Report data**. CLI use also supports `-OutputPath`.

The final Script output summary shows apps targeted, succeeded, failed, pending approval, skipped/preview and not processed/unknown. Counts refer to resolved, selected apps, not the number of wildcard expressions entered. Approval requests are not successes. Preview and declined confirmations have their own statuses and still produce a CSV. Reports are pre-created before deletion requests; a report-write failure prevents starting deletions. A cancellation attempts to save completed outcomes and leaves unstarted apps as `NotProcessed`; an interrupted deletion request is `NotConfirmed`, not a confirmed failure. Verify Intune before retrying an uncertain request. A process crash or storage failure can leave an incomplete report; remote actions cannot be rolled back.

### Script preservation

The prior UI-event edits have been removed from the business scripts. **11 scripts remain unchanged by the desktop work.** The deployment report is deliberately consolidated as requested; its duplicate has been removed. Win32 app deletion isolates per-app failures and exports per-run outcomes. Deployment, sync, device usage and the two assignment-listing scripts retain small outcome counters for accurate activity summaries. The cleanup script now saves a results CSV on every real run; see [cleanup results](../README.md#cleanup-results).

All presentation integration is now under Desktop in [Invoke-WorkflowPresentation.ps1](Invoke-WorkflowPresentation.ps1). It invokes the original script in an isolated invocation scope, reads existing result variables when the invocation ends, and reports files at known output paths only when their metadata changed during the run. Multi-app CSV datasets are loaded from the original exports. It does not rewrite Graph requests, matching logic or parameter defaults.

The Desktop adapter presents existing app-match collections at the original Read-Host point. Result tables are not fabricated from console messages. Some actions report outcomes only through their original text; **Script output is authoritative**, including pending approvals and partially completed operations. Cancellation can leave partial effects without a complete table.

### Authentication and dependencies

The app opens on **Home** without signing in automatically. Use **Connect / reconnect** to sign in once to the same persistent worker that runs all Graph tasks. Authentication uses delegated access with `ContextScope Process`; the Home connection is not a remote endpoint credential and does not inherit a separate terminal's in-memory Graph session. Home does not persist authentication across process exits. If hosting the UI in an existing PowerShell process, use **Disconnect Graph** to clear its Graph context before closing. Original business scripts and their CLI authentication behavior are unchanged.

Home offers an optional tenant ID/domain. **Connect / reconnect** requests only `https://graph.microsoft.com/.default`, using the existing delegated Microsoft Graph consent for the signed-in user/application. It does not combine the catalog's workflow scopes or add role-management permissions to the sign-in request. The previous read/admin scope profiles were removed because they could trigger **Need admin approval** even for an account already authorized to use the scripts.

The [Microsoft identity platform `.default` behavior](https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc#the-default-scope) returns existing consented Graph permissions without prompting for additional scopes when consent already exists. This is not a consent bypass: if there is no existing delegated grant or tenant policy requires approval, Microsoft can still show a consent/approval screen. PIM activates directory roles; it does not grant application consent. Missing permissions are reported by the access check rather than requested automatically. A tenant administrator must review an insufficient application grant.

**Check connection** makes live `/me`, transitive membership and directory `roleAssignments` requests, rather than trusting `Get-MgContext`. Home displays the account, tenant, delegated scopes, supported active roles and UTC check time. Role verification includes active role-assignable group membership, handles pagination, and counts only tenant-wide active assignments, not PIM eligibility or administrative-unit-scoped assignments. Built-in role template IDs are used instead of localized display names. Custom roles and group ownership are not evaluated. This verification currently supports the Global Graph environment and user/delegated authentication only.

**Open Microsoft Entra PIM** opens the portal; the app never activates a role automatically. Activate the needed role, allow for propagation, then **Check connection** again. Reconnect if the token needs refreshing after elevation. The check is point-in-time, not a continuous monitor. **Disconnect Graph** signs out the shared app worker. Home remains viewable while work runs, but connect/check/disconnect are disabled until the single worker operation finishes; Stop remains available.

Before **every Graph task**, [Invoke-GraphSession.ps1](Invoke-GraphSession.ps1) repeats the live check in that worker, validates the delegated scopes declared in [WorkflowCatalog.psd1](WorkflowCatalog.psd1), checks the configured tenant where one exists, and enforces these conservative role prerequisites:

| Operation | Active tenant-wide built-in role |
|---|---|
| Reports, primary-user read mode and supported previews | Global Reader **or** Intune Administrator |
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
# Only for XLSX user input:
Install-Module ImportExcel -Scope CurrentUser
```

For CSV/XLSX user membership input, choose the file, select **Read columns from file**, then choose the UPN column. XLSX needs ImportExcel. The app does not install modules automatically.

| Workflow family | Access considerations; tenant roles/RBAC still apply |
|---|---|
| Device inventory / Cloud PCs / primary-user read | Managed-device read; user/group reads where used |
| Device usage | Managed-device read, AuditLog.Read.All, Directory.Read.All; group reads for group scope |
| Discovered apps | App/device/report reads; group/directory reads for group scope |
| Quality updates | DeviceManagementConfiguration.Read.All / report access |
| Remediation and platform script status | DeviceManagementScripts.Read.All |
| Stale synced devices | Device.Read.All or Directory.Read.All |
| App deployment / assignments | DeviceManagementApps.Read.All; group/filter reads where used |
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

Choose **Remote endpoint session**, enter the computer, then connect using the secure in-app credential dialog. The **Remote workspace** appears under Run & results. Commands are routed only to the connected endpoint, never silently to the local computer.

The **Computer name** field is an editable dropdown. Type a new name, or pick one of the last 10 computers you successfully connected to. A name is added only after the session is actually established; failed, refused or cancelled connections are not saved. The list is stored per user in `%LOCALAPPDATA%\EndpointToolbox\recent-devices.json` (computer names only, most recent first, duplicates merged case-insensitively). Choosing a name only fills the field; nothing connects until you select **Connect to endpoint**. To clear the list, delete that file. Offline smoke tests never read or write it.

Remote output uses a simple `PS [device]>` command echo and plain results without timestamps, `Output:` labels or run-timing lines. Connection details stay in the connection status above it; errors and warnings remain visible. Detailed activity and timings are still available in **Script output**. An animated running/stopping indicator appears at the bottom of the remote output area while the worker is busy and disappears on completion, failure or cancellation. It is not part of copied/saved remote output and indicates worker activity, not endpoint progress. This is still a command workspace rather than an interactive terminal emulator.

The original ping, WinRM, Negotiate and EnableNetworkAccess behavior remains. WinRM/network/domain configuration and an authorized privileged account are required. The app owns the created session and attempts cleanup on disconnect/close. An idle remote session can coexist with Graph work, but execution is serialized.

**Saved commands** offers 29 starter commands based on the endpoint cleanup and troubleshooting notes. Selecting a friendly name replaces the command editor text and shows a description/warning; it **does not execute anything**. Review or edit the command, then click **Run on endpoint**. Custom commands still work. A connected remote session is required for execution, and automatic activity logs still exclude command text and returned data.

The editable reference file is [RemoteCommands.json](RemoteCommands.json). It has `SchemaVersion: 1` and a `Commands` array; every entry requires unique `Name`, `Description` and `Command` strings. JSON uses `\\` for a literal backslash and `\n` for a line break. Restart the app after editing. Startup validation checks the schema, names and PowerShell syntax without running commands. Treat this file as executable administrative content: review changes and do not store credentials or personal data in it.

The starter list covers disk usage, temporary files, crash dumps, Windows.old, profiles, update cache, DISM/SFC, upgrade staging files, Intune's PushLaunch task, reboot flags, hotfixes and event logs. Cleanup commands are destructive where noted. Profile preview/removal templates require replacing `REPLACE_WITH_PROFILE_FOLDER` with the primary user's profile folder name and exclude loaded/special profiles; they do not assume the remoting account is the user to retain. Preview the profile list first. Cleanup errors are surfaced rather than silently ignored; sizing commands still omit inaccessible files. Update-cache cleanup attempts to restore services that were running. No automatic reboot was added.

This is a PowerShell command workspace, not a full terminal: full-screen native programs, nested interactive sessions and multiple simultaneous remote sessions are not supported. UNC is an explicit Windows Explorer handoff, not a file browser. A PowerShell drive's credentials do not guarantee Explorer share access. If your environment needs a fully qualified name for the share, set an optional **DNS suffix** (for example `corp.example.com`) under **Settings > Remote**. It is saved per user in `%LOCALAPPDATA%\EndpointToolbox\remote-settings.json`, passed to the script as `-DnsSuffix` only when UNC is selected, and ignored for a computer name that already contains a dot. Leave it empty to use the name as typed. From the command line, use `.\PSRemote-Endpoint.ps1 -Device PC1 -UNC -DnsSuffix corp.example.com`.

### Retention and exports

Run & results shows the local start time and live worker elapsed time. On completion (including cancellation/failure), it shows the worker end time/runtime, display-processing end time, additional display-processing time after the worker ended, and total time. The same timing summary is included in Script output for Save log. Worker timing is recorded on the worker state transition, not when the UI eventually drains its event queue. It includes script execution, output formatting and the Desktop presentation adapter; display time is the additional queue/grid preparation afterward, not an isolated rendering benchmark. Worker and UI processing overlap.

The consolidated Win32 deployment script also prints `Report started`, `Report ended` and `Report elapsed` when run directly in a terminal (and in the app). This measures the script body, including sign-in/selection and CSV generation, but excludes the Desktop adapter's subsequent CSV loading. Compare matching app selections and user-status options; timestamps and duration do not imply a successful report.

The **Dark mode** toggle at the bottom of the sidebar switches appearance immediately without clearing inputs, results or output. The choice is saved per user in `%LOCALAPPDATA%\EndpointToolbox\settings.json` and restored on the next launch; new users start in light mode. Main pages, generated forms, report/history grids, dropdowns, Settings and script-input dialogs share the theme. Text boxes, password fields and dropdowns retain visible borders when unfocused in either theme. Windows-managed title bars, message boxes, file/folder pickers and external sign-in windows retain their Windows appearance. A preference read/write failure is reported rather than silently ignored. Offline smoke tests never read or write the user's preference.

The gear button beside the toggle opens **Settings** without changing the current task, report selection or run summary. Its **History** tab has a dedicated read-only run-history grid, **Refresh history** and **Clear history**. History loads when Settings opens; refresh it to see newly completed runs. An empty history displays an empty-state message. Clearing history is blocked while an operation is running. The **Logs** tab contains **Open activity logs**. Close Settings with its close button or Esc.

History at `%LOCALAPPDATA%\EndpointToolbox\history.jsonl` stores run/workflow IDs, UTC times, overall state and row count only. No inputs, targets, usernames, tenant IDs, credentials, command text, justification, report paths or detailed logs are stored there.

**Open activity logs** opens `%LOCALAPPDATA%\EndpointToolbox\Logs`:

- `master-YYYY-MM-DD.jsonl`: app startup/close, task selection, runs, cancellation requests, exports and app/task errors.
- `task-<workflow-id>-YYYY-MM-DD.jsonl`: that task's run lifecycle, outcome counts and compact diagnostics. Run IDs correlate task records with master records. Records include the local Windows username and UTC time.
- Logs retain the current UTC day and the preceding 29 days, pruned on the next write. Daily files roll over into numbered segments at 5 MB. Pruning applies only to activity-log filenames in this folder, never reports or history.
- Automatic diagnostics are limited to the first 20 errors/warnings per run, at most 500 characters of their first line. Counts are not limited. Logging failures appear in Script output; inability to start a run log blocks that run before script execution.
- Logs contain no full console output, Graph context, credentials, justification, parameter payloads or report data. Remote activity records contain only connection/disconnection lifecycle, device and outcome; **remote commands and returned content are never automatically logged**, including remote error messages.

Tasks publish a compact end-of-run summary from their structured results or existing counters. Read-only success means report data was retrieved, not that every device/application in the report is healthy. Some summaries count report rows or membership outcomes rather than unique devices; the entity label identifies the unit. Duplicate-hostname membership additions count each object, plus unresolved/failed name lookups. Affected/requested counts mean accepted action requests, not verified installation, sync or primary-user completion. Already-satisfied targets count as successes without new effects. Unknown or cancelled outcomes are marked incomplete, not invented as successes; failures before target resolution can have no counts.

Detailed output stays in memory unless explicitly saved. CSV reports (including Win32 deletion and cleanup reports) are separate from activity-log retention. The remote workspace output has a separate manual save action. Common signed-URL parameters and bearer tokens are redacted, but arbitrary script/remote output and CSV reasons may contain sensitive details. Inspect exports before sharing. Clear history removes only run history, not activity logs or reports. These local per-user files are operational logs, not tamper-proof compliance audit storage.

## Offline validation

```powershell
Invoke-Pester -Script .\Desktop\Tests -PassThru
pwsh.exe -NoProfile -STA -File .\Desktop\Start-EndpointToolboxUI.ps1 -ValidateOnly
pwsh.exe -NoProfile -STA -File .\Desktop\Start-EndpointToolboxUI.ps1 -SmokeTest
pwsh.exe -NoProfile -STA -File .\Desktop\Tests\Fixtures\DesktopUiFixture.ps1 -SettingsOnly
pwsh.exe -NoProfile -STA -File .\Desktop\Tests\Fixtures\ThemeFixture.ps1
```

Tests replace all Graph/network commands. The Graph suite verifies shared Home authentication across successive worker invocations, active versus expired roles, group-assigned and scoped roles, missing scopes, tenant mismatches, disconnected/forbidden checks, pagination and blocking before business execution. Native UX tests cover Home navigation, preserved inputs and serialized connection controls. Existing suites verify unchanged-script parity, consolidated deployment selection/exports/summaries, command discovery, prompts, preview, pending approval, cancellation, exit codes and remote isolation. Direct reports tests cover manager resolution, naming, rule/description payloads, duplicate guards, preview, uncertain outcomes and native confirmation refusal/cancellation. SmokeTest verifies unauthenticated Home startup, constructs all 22 forms and their input-source options, checks grouped navigation/hidden inactive inputs/search behavior, then processes exactly 100,000 synthetic rows with an enforced maximum UI-processing tick of 250 ms.

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
