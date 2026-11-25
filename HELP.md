# Endpoint Toolbox user guide

Endpoint Toolbox brings Intune, Microsoft Entra, Microsoft 365 Apps Cloud Update, and Windows remote support tasks into one Windows application. Use it to investigate and report on your environment, or, where authorized, request changes. The scripts are also available for use directly in PowerShell.

This guide is for administrators and support staff. Examples such as `Example Group`, `Example-PC`, and `user@example.invalid` are placeholders: replace them with values from your own organization.

> **Before making changes:** Confirm the account, tenant, targets, permissions, and operation. Use **Preview only (WhatIf)** where offered, read the results, and follow your organization's change procedures. A preview is not automatically enabled and is not available for every action.

## Contents

- [Get started](#get-started)
- [Understand sign-in and permissions](#understand-sign-in-and-permissions)
- [Use the application](#use-the-application)
- [Settings, reports, and privacy](#settings-reports-and-privacy)
- [Choose the right task](#choose-the-right-task)
- [Task and script reference](#task-and-script-reference)
- [Run scripts directly](#run-scripts-directly)
- [Troubleshooting](#troubleshooting)
- [Glossary](#glossary)

## Get started

### 1. Check prerequisites

- Use **Windows** with **PowerShell 7.6 or newer**. Windows PowerShell 5.1 is not supported.
- Keep the application files together. For a packaged release, extract the entire ZIP before starting `EndpointToolbox.exe`.
- Graph tasks require the Microsoft Graph Authentication module, existing delegated permissions, an authorized account, and the applicable Entra and Intune roles/RBAC. Some workflows have additional requirements described below.
- Cloud Update requires **MSAL.PS** and its own Office sign-in. Remote support requires network access, WinRM, and separate device administrator credentials.
- Windows Update for Business reporting requires **Az.Accounts 5.0+**, its own Azure sign-in and existing Log Analytics workspace/table query access.
- XLSX user lists require **ImportExcel**. CSV and text lists do not.
- The app does not automatically install modules or grant permissions. Ask your administrator to provide missing dependencies or consent.

See [desktop authentication and dependencies](Desktop/README.md#authentication-and-dependencies) for module installation, role verification, and the full permission reference.

### 2. Open the app

From the repository root in PowerShell 7, run:

```powershell
pwsh.exe -NoProfile -STA -File .\Desktop\Start-EndpointToolboxUI.ps1
```

Alternatively, run the packaged `EndpointToolbox.exe` from the extracted bundle. A per-user shortcut can be created with `.\Desktop\Install-EndpointToolboxShortcut.ps1`. If the app files move, recreate the shortcut.

### 3. Run a read-only task

1. If your task uses Graph, activate any required role through your organization's PIM process.
2. Select **Home / Graph connection**, enter a tenant ID or domain if needed, and select **Connect / reconnect**. Complete Microsoft sign-in.
3. Use **Check connection** to review the account, tenant, consented scopes, and verified active roles.
4. Choose a task in the sidebar, for example **Inventory > All Cloud PCs**. Enter any requested inputs.
5. Select **Run report**. Read **Script output**, then inspect **Report data** and any **Visual summary** or **Saved reports**.

The app does not sign in at startup. Selecting a task does not verify its access; preflight occurs when you run it. A read-only report being retrieved successfully does not mean every item in the report is healthy.

## Understand sign-in and permissions

### Home Graph connection

**Connect / reconnect** establishes a delegated Graph connection in the app's worker. It signs out the previous worker connection first and requests `.default`, using existing Graph consent. Microsoft may still request consent or administrator approval if the tenant requires it; the app does not grant consent. **Disconnect Graph** signs the worker out.

The optional Home tenant field applies to that connection and overrides **Settings > Graph**. If both are blank, the account's default tenant is used. A changed saved setting does not affect a connection that is already active; reconnect.

**Check connection** verifies account, tenant, scopes, and supported active tenant-wide built-in roles. The app checks Graph access again before each Graph task. Eligible PIM roles must be activated; eligibility alone is not active authorization. Role verification requires existing directory/role read consent and authorization. Custom roles, administrative-unit-scoped roles, and group ownership are not evaluated by the app's conservative preflight, so it may block an operator who has other service permissions.

| Task type | App's supported active role check |
|---|---|
| Most reports, primary-user read, and supported previews | Global Reader or Intune Administrator |
| User sign-in history: both views | Global Reader, Reports Reader, Security Reader, Security Operator, or Security Administrator |
| Intune sync, primary-user changes, and Win32 deletion | Intune Administrator |
| Entra group changes | Groups Administrator or Intune Administrator; Graph still enforces target-group authorization |
| Real Entra / Autopilot cleanup | Intune Administrator **and** Cloud Device Administrator |

Global Administrator also satisfies these checks but is not recommended solely for this app. Consent, role activation, Intune RBAC/scope tags, licensing, Conditional Access, and service authorization are separate requirements. A passing preflight does not guarantee that the service will accept a later request. After PIM activation, reconnect if the token needs refreshing.

### Separate sign-ins

- **Cloud Update** uses a separate interactive Office sign-in. Home Graph is not required for the basic report. Optional group enrichment requires Home Graph in the **same tenant** as the Office sign-in.
- **Windows Update for Business reporting** uses separate Azure sign-in and the workspace saved under **Settings > WUfB**. It does not use or change Home Graph.
- **Remote endpoint session** uses device administrator credentials and WinRM, not the Home Graph identity.
- **Compare Win32 report runs** is local and does not require Graph.

### Common permissions

The exact permissions depend on the task and selected options. Read the task's notes and the [permission table](Desktop/README.md#authentication-and-dependencies); the following are examples, not grants:

- Intune device reports: `DeviceManagementManagedDevices.Read.All`; app reports: `DeviceManagementApps.Read.All`.
- Entra group reports: group/directory read permissions; membership changes additionally need suitable write permission and target-group authorization.
- Intune changes require the relevant read/write or privileged-operation permissions and Intune RBAC.
- Reading role assignments for Home requires a consented permission such as `Directory.Read.All` or `RoleManagement.Read.Directory`, plus authorization to read them.

## Use the application

### Find and configure a task

1. All sidebar categories start collapsed when the app opens. Expand an area, or use the search box to search task, category, or script names. Select the result to open it. Clicking expandable headings does not leave a highlighted border; keyboard navigation still shows a focus cue.
2. On **Configure**, read the task description. Pick an input source where offered: for example, device names, a text file, or an Entra group.
3. Fill in the visible fields. For multiline fields, use one value per line. A file selector chooses an existing file; the script does not create its input list.
4. Expand report/export or advanced options as needed. For CSV/XLSX user lists, choose **Read columns from file** and select the column containing UPNs.
5. For a change task, check the target and operation again. Enable **Preview only (WhatIf)** if available and desired. Follow any further confirmations or selection dialogs.
6. Select the primary run button. Prompts from scripts appear in the app; do not assume that closing or cancelling a prompt approves an action.

Switching tasks or searching preserves task drafts in memory until the app closes. Loaded policy/script choices must be reloaded after a Graph connect or disconnect. Validation appears next to the relevant field. Only one task or remote command runs at a time.

### Read and save results

- **Script output** contains progress, warnings, errors, prompts, outcomes, and timing. It is the authoritative place to check for partial failures, skipped items, pending approvals, and incomplete operations. Use **Save output...** if you need to keep it.
- **Report data** contains structured rows when the task provides them. Choose a dataset where available, filter it, select cells, and use **Ctrl+C** or **Export view...**. Export view saves the filtered view; copied cells do not include headers.
- **Visual summary** provides charts for supported reports. Charts summarize retrieved data independently of the text filter. Read their labels: counts may refer to rows, devices, users, or findings rather than the same unit. Select a summary and choose **Export PNG...** to save all its charts, including those below the visible area, as one image with the current theme, titles, labels, units and coverage notes. The image retains the charts' top-N/sampling and paging limitations; it is not an export of every data row. Export runs in the background without new Graph requests. No direct PDF export is provided.
- **Saved reports** lists CSVs generated by the script and exported visual-summary PNGs. Select one and open it. The app's default folder is set under **Settings > Reports**, initially `%TEMP%\endpoint-toolbox`, which Windows may clean; copy files elsewhere if they must be retained. Images can contain user, device and app details; review them before sharing.

Filtering can take time on large datasets. Wait until the latest filter has applied before using the grid or exporting. Some tasks produce console outcomes rather than a complete structured table; inspect the original output.

### Preview, confirmations, and stopping

**WhatIf** shows supported operations without making the corresponding changes, but a script can still perform reads and write report files. Not every task supports it: in particular, Intune sync and the combined group-add task make real requests after their normal confirmations. Individual scripts may require additional per-item approval even when `-Confirm:$false` is used.

**Stop** requests cancellation. It does not undo requests already accepted by a service or guarantee that an in-flight request failed. Check the service and the output before retrying an interrupted operation. A request accepted, a sync requested, or an approval pending is not the same as a completed and verified change.

### Example: report group members

1. Connect on Home using an account authorized to read the directory and ensure the required role and permissions are verified.
2. Select **Groups > View Entra group membership**, enter the exact display name or object ID of your group, and run the report.
3. If a name is missing or matches multiple groups, correct it or use the object ID. Direct members are listed by default; enable **Expand nested groups** to include indirect members in a flat, deduplicated list.
4. Review the rows and warnings, then use **Export view...** if you need to save the current filtered view.

### Example: review a Win32 rollout

1. Connect on Home, choose **Apps and assignments > Win32 app deployment status**, and enter part of the app name or an app ID.
2. Run the report and, if multiple app objects match, select the intended version or versions. Do not select an app merely because its name looks similar.
3. Review the device summary, full device/user rows, and any user report. The default report includes user status; turn it off if only device reporting is needed.
4. In **Visual summary**, choose the app and an error-code cluster to investigate. Select a device row and open **app diagnostics setup** to inspect available evidence without rerunning the retained rollout export.
5. Treat reported failures and diagnostic suggestions as investigation leads, not proof of root cause. Save any reports needed beyond the current session.

### Example: work safely with a change

1. Verify the correct tenant and choose a small, reviewed target list.
2. Choose a task such as **Read / change Intune primary users**, explicitly select the intended operation and input source, and check each value.
3. Where offered, enable **Preview only (WhatIf)** and review all proposed targets and warnings. A preview is not a substitute for authorization.
4. When approved, turn preview off and run the real operation. Respond to each required confirmation; do not assume one approval covers every target.
5. Review the per-target outcome and verify the resulting state in the appropriate service. If the operation is interrupted or approval is pending, check before retrying.

## Settings, reports, and privacy

Open **Settings** from the sidebar or press **Ctrl+,**:

| Tab | What it does |
|---|---|
| **History** | Displays run history; refresh it or clear it after confirmation. Clearing history does not delete logs or reports. |
| **Logs** | Opens the activity-log folder. |
| **Remote** | Saves an optional DNS suffix used only for the Explorer UNC handoff when a computer name is unqualified. |
| **Graph** | Saves an optional default tenant ID/domain for future Home connections. |
| **WUfB** | Saves the Log Analytics workspace GUID and optional Azure tenant GUID. |
| **Cloud Update** | Saves the optional rollout group names, one exact display name per line. Empty by default. |
| **Appearance** | Changes the theme immediately and saves the preference. |
| **Reports** | Saves the default report folder, initially `%TEMP%\endpoint-toolbox`, for CSV reports, Export view and Export PNG dialogs. |

Save edited Graph, Remote, WUfB, Cloud Update, or Reports settings before closing. The app asks before discarding unsaved Graph, Remote, Cloud Update or Reports edits. The theme can also be changed by pressing and releasing **T**, then **L**, **D**, **G**, or **C** within two seconds, outside text fields and dropdowns.

Administrators can deploy shared defaults in [EndpointToolbox.defaults.json](Desktop/EndpointToolbox.defaults.json). Settings shows the effective values; your saved preferences override them in one per-user JSON file. Empty values deliberately clear an admin default. Deployment updates affect values you have not overridden after restarting the app. See [deployment configuration](Desktop/README.md#universal-settings-and-deployment-defaults) for the format and inheritance rules.

Under **Reports**, enter a full folder path or select **Browse...**, then **Save**. Environment variables such as `%TEMP%` are supported. Saving creates the folder if needed; leave the setting empty and save to reset to `%TEMP%\endpoint-toolbox`. The choice persists in `settings.json` and applies to default report paths and **Export view**. Existing CSV filenames are retained. Per-run path overrides are preserved, and optional CSV exports remain optional. Existing reports are not moved; Windows can remove files under TEMP. Standalone PowerShell scripts retain their own defaults.

**Delete all reports...** permanently deletes only CSV files directly inside the saved report folder, after confirmation showing the folder and file count. Exported PNG images are not deleted. Subfolders, other non-CSV files, linked files, reports saved elsewhere, logs, history, and in-app results remain unchanged. Wait for any running task to finish and save or discard folder edits first. Locked or inaccessible files stop deletion with an explicit error and the number already deleted; deletion is not rolled back.

The Reports folder field, **Browse...**, and **Save** share one row. Remote and Graph also place **Save** beside their text fields. Save feedback appears below each input row; deletion feedback has its own area below **Delete all reports...**.

Settings and operational data are per user under `%LOCALAPPDATA%\EndpointToolbox`:

- `history.jsonl`: compact history (run/workflow IDs, UTC times, state, and row count).
- `Logs`: daily master and per-task activity logs; the current UTC day and previous 29 days are retained, pruned on a later write. Logs are operational records, not tamper-proof audit storage.
- `recent-devices.json`: up to 10 successfully connected remote computer names.
- `settings.json`: all preferences grouped into sections. Old per-setting files are migrated automatically and retained only for recovery. See [desktop retention details](Desktop/README.md#retention-and-exports) for the full storage and logging behavior.

History does not store input lists or credentials. Remote activity logging does not automatically store commands or returned output, but can include the device and connection outcome. Explicitly saved output and CSVs may contain user names, device identifiers, errors, or other sensitive information. Review and protect exports before sharing; clearing history does not clear them.

## Choose the right task

Tasks are grouped by what you are investigating or managing, not simply by whether they produce a report.

| Menu | Purpose |
|---|---|
| **Inventory** | Discover and investigate device or user records, including a user's sign-in history. |
| **Device reports** | Review device usage, update deployment, script execution status, and stale-device activity. |
| **Apps and assignments** | Inventory apps, review assignments, investigate deployments, compare reports, or delete app objects. |
| **Groups** | Inspect group membership (including nested device members) or create/change groups and memberships. |
| **Device actions** | Read/change primary users, request Intune sync, or clean up device objects. |
| **Remote support** | Connect to an endpoint and run commands in its remote session. |

| I want to... | Choose |
|---|---|
| Investigate one device across Intune, Entra, and Autopilot | **Inventory > Device investigation dashboard** |
| See mobile or Cloud PC inventory | **Mobile device inventory** or **All Cloud PCs** |
| Compare a device's assigned primary user with sign-in activity | **Device reports > Device user usage** |
| Investigate a user's sign-in failures | **Inventory > User sign-in history** |
| Investigate or report a Win32 app rollout | **Apps and assignments > Win32 app install diagnostics** or **Win32 app deployment status** |
| See who is in a group or change its direct members | **Groups > View Entra group membership**, **Add users or devices**, or **Remove users or devices** |
| Include devices and other members inside nested groups | **Groups > View Entra group membership**, with **Expand nested groups** enabled |
| Read or change a device's Intune primary user | **Device actions > Read / change Intune primary users** |
| Ask devices to check in | **Device actions > Request Intune sync** |
| Connect to an endpoint using WinRM | **Remote support > Remote endpoint session** |

## Task and script reference

Each entry identifies the app task, its underlying script, what to enter, and how to interpret the result. The app may present friendly labels instead of the PowerShell parameter names. Unless otherwise noted, report tasks are read-only and use the Home Graph connection; script-specific requirements still apply.

### Inventory

#### Device investigation dashboard

**Script:** [Get-EndpointDeviceInvestigation.ps1](Intune/Devices/Get-EndpointDeviceInvestigation.ps1) | **Type:** Read-only

Search an exact device name, serial number, or Intune-associated user UPN to investigate Intune, Entra, and Autopilot records. In **Report data**, select **Device overview**, **Entra records**, or **Autopilot records**. The visual reconciliation summary can open a queue of duplicate names, conflicting/shared IDs, missing IDs, and unconfirmed links.

The UPN search is not an exhaustive list of every device owned or used by the user. Autopilot inventory may take time to page. An Entra-only row or serial-only candidate is not proof of an orphan or a safe deletion target; missing fields are not proof of a healthy or unregistered device. Failed lookups stop the report instead of presenting it as complete. Requires existing managed-device, device, user, and Autopilot configuration read permissions and service authorization. See the [detailed dashboard notes](Desktop/README.md#device-investigation-dashboard).

#### Mobile device inventory

**Script:** [Export-IntuneMobileDevices.ps1](Intune/Devices/Export-IntuneMobileDevices.ps1) | **Type:** Read-only

Report iOS/iPadOS and Android Intune inventory, compliance, and ownership. Choose all supported mobile platforms or narrow the platform; choose a report folder if needed. The default comes from **Settings > Reports**. The visual summary includes OS versions by platform, counting returned records and identifying missing values. Inspect the rows and use the saved CSV for further analysis. Requires managed-device read access.

#### All Cloud PCs

**Script:** [Get-IntuneCloudPCs.ps1](Intune/Devices/Get-IntuneCloudPCs.ps1) | **Type:** Read-only

Lists Windows 365 Cloud PC records and provisioning status, including failed, unprovisioned, and grace-period records. Run it without a target list; inspect **Report data** and **Visual summary**, and use **Export view...** to save rows. No CSV is generated automatically. Blank fields mean the service did not return data.

Requires existing `CloudPC.Read.All` or `CloudPC.ReadWrite.All` consent and Windows 365 authorization. It uses Graph beta, which can change and is not supported by Microsoft for production applications. Returned results depend on account access and service timing.

To investigate a connection, select cells from one Cloud PC row under **Report data**, then choose **Load Cloud PC connection history...**. The app requests the last seven days for that Cloud PC only, using the existing Graph connection and consent. The history dataset and visual summary show available service-reported usage, remote sign-in time, median round-trip time and median bandwidth; missing metrics are not zero. Charts sample up to 40 points per metric; the dataset contains all returned rows. The beta report is subject to service availability, authorization and retention, and does not provide complete client-side performance telemetry. Inventory remains available after an empty, failed or cancelled request.

#### Cloud PC last login

**Script:** [Get-CloudPCsLastLogin.ps1](Intune/Devices/Get-CloudPCsLastLogin.ps1) | **Type:** Read-only

Reports Intune-reported Windows user logon information for Cloud PCs and produces a CSV in the selected report folder. Use the visual summary to review recency. A missing logon is not proof the Cloud PC has never been used: this is not a Windows 365 connection report or an Intune sync report. Dates are shown in Eastern time with offset.

#### Find Entra users by name

**Script:** [Find-EntraUsersByName.ps1](entra/Find-EntraUsersByName.ps1) | **Type:** Read-only

Enter names one per line as `First Last` or `Last, First`, or choose a text file. The report returns available identity details such as UPN, mail, title, department, and account state. **Found** is a unique exact match; **Multiple** requires disambiguation; **PossibleMatch** is only a same-surname, same-initial lead; **NotFound** and **Failed** are reported separately. Confirm identities before using them in a change. Requires `User.Read.All`.

#### User sign-in history

**Script:** [Get-EntraUserSignInHistory.ps1](entra/Get-EntraUserSignInHistory.ps1) | **Type:** Read-only

Enter one exact user principal name or primary email address, select a lookback from 1 to 30 days (30 by default), and run. The report resolves exactly one user; a missing or ambiguous match stops the lookup.

The default **Paged events** view requests up to 100 individual interactive and non-interactive events first, within an exact rolling UTC window. One day means the last 24 hours. The report includes available failure details, application, device, location, and event/correlation IDs. Member and guest users are supported.

Under **Report data**, choose **Load more** to append the next API page or **Retrieve all** to fetch every remaining page. The original user, filters and time window are retained; editing the form does not change a continuation. Run a new report to apply edited inputs. Continuations are in memory only and reject account or tenant changes. Failed page requests retain earlier displayed rows for retry. A restart requires a new report.

The paging status says **Incomplete** while more pages remain. An empty failures-only page does not prove that later pages have no failures. **Export view** exports only loaded, visible rows. **Detailed events** retrieves every page in one run and remains the command-line default; it can take substantially longer. The grouped summary API has been removed. Page timings appear in script output; speed still depends on Graph. No CSV is created automatically.

**Visual summary** shows daily UTC outcomes, ranked failure codes, applications and client apps using only loaded, displayed report rows. It identifies the number received versus shown and whether more pages remain. Daily charts omit events with invalid timestamps; failures-only excludes success and unknown outcomes. Loading more refreshes the charts without a separate summary request. Cancelled or failed refreshes keep the last successful rows and charts; retry resumes from their paging position. Grid filters do not change chart totals.

Select **Show failed sign-ins only** to show events with a nonzero error code. Events without a valid code are Unknown and are excluded from that view with a warning. Failed authentication can include interrupted flows; examine the reported reason rather than assuming a cause. No records does not prove the user never attempted to sign in: available history depends on tenant retention, permissions, and licensing.

Requires existing `AuditLog.Read.All` and `User.Read.All` consent, an authorized active role for the selected view, and Entra P1/P2 licensing. Both views use Microsoft Graph beta; Microsoft says beta APIs can change and are not supported for production applications. Conditional Access policy details are not requested. Sign-in data can be sensitive; protect exports.

Both views use the same existing authentication, app-side role and scope checks. Paging does not request additional consent. Graph remains authoritative.

### Device reports

#### Device user usage

**Script:** [Get-DeviceUserUsage.ps1](Intune/Devices/Get-DeviceUserUsage.ps1) | **Type:** Read-only

Choose device names, a text file, or an Entra group. Group scope includes transitive device members. Set the lookback period (30 days by default) and report folder, then run. The script compares the Intune primary user with the account observed on the most distinct UTC days in successful Entra sign-in records. It prints a per-device summary and exports detailed sign-ins; for a single device it also prints per-user and per-day breakdowns.

Use **Visual summary > Primary-user review** to see mismatches, unassigned, inconclusive, or matching devices, and select a device to compare sign-in days. A tie is inconclusive; sign-ins are not Windows logons or time spent on a device. Available history depends on tenant audit retention. This report does not change primary users. Requires managed-device, audit-log and directory read permissions, plus group read for group scope.

#### Windows Update for Business reporting

**Script:** [Get-WUfBReport.ps1](Intune/Devices/Get-WUfBReport.ps1) | **Type:** Read-only, separate Azure sign-in

Save your Log Analytics Workspace ID (GUID) and optional Azure tenant GUID under **Settings > WUfB**. Open the reporting task, optionally enter exact device names and a KB such as `KB5132043`, and run. A compatible existing Azure user session is reused; otherwise complete Azure sign-in with existing workspace query access. No CSV import or Home Graph connection is required by default.

**Resolve missing computer names using Graph** is unchecked by default. If organizational policy permits, enable it and connect on **Home** with existing **Device.Read.All** delegated consent and a supported reader role in the same tenant as Azure. It fills blank or `#`-suppressed names using WUfB's Entra device ID and the directory's device display name, preserving existing names. **Device name resolution** shows original names, sources and unresolved outcomes; unresolved names are never guessed. Lookup errors stop the report rather than silently dropping enrichment. No endpoint diagnostic-data policy is changed, but directory names become visible in reports, copied data and exports. Standalone callers can use `-ResolveDeviceNames` with an existing same-tenant Graph session.

**Devices** shows security/quality status, installed OS/build, available installed quality-update KB/time, restart evidence, alerts, error codes, scan/snapshot times and servicing/policy details. Select cells in one row to open its updates or alerts by device ID; duplicate computer names are not combined. Choose the other datasets for fleet compliance, missing security updates, failures, restart waiting times, errors/recommendations, service states, retained trends and data health. Charts open supporting device rows. Use **Export view** for the currently filtered dataset.

Security compliance means the latest security update **for each OS version**, not Intune compliance or an Autopatch policy target. The percentage excludes stale/unknown records, which are counted separately; the default stale threshold is 7 days since a successful update scan. A blank percentage means no records could be evaluated.

**KB investigation** distinguishes installation evidence, failure, restart/in-progress states and unknown records. **Newer build (inferred coverage)** is separate from proof of installing the exact KB. No KB record does not mean missing, and a resolved failure or old restart-required timestamp does not mean a current failure/restart. The observed KB list is not Microsoft's complete update catalog.

Reports are delayed WUfB snapshots, not live endpoint checks, and cover only devices in the latest workspace snapshot. The default 28-day lookback is limited by workspace retention; scoped device-name runs omit fleet trends. Missing fields remain blank. See [detailed reporting rules](Desktop/README.md#windows-update-for-business-reporting).

#### Expedited quality updates

**Script:** [Get-QualityUpdates-Report.ps1](Intune/Devices/Get-QualityUpdates-Report.ps1) | **Type:** Read-only

After connecting on Home, select **Load policies**, filter the list, and choose one policy. Policies with identical names show their IDs. Running the report exports per-device update status to CSV in the selected report folder; the visual summary breaks down statuses returned by Intune. A report can legitimately contain zero device rows. Loading or reporting does not deploy an update. Requires `DeviceManagementConfiguration.Read.All` and appropriate service access.

#### Remediation and platform script status

**Script:** [Get-IntuneScriptDeviceStatus.ps1](Intune/Devices/Get-IntuneScriptDeviceStatus.ps1) | **Type:** Read-only

Choose **All**, **Remediation**, or **Platform script**, select **Load scripts**, and search for and select one script before running the report. The output shows Intune's latest available device run states and writes a CSV to the selected report folder. Remediation rows may include detection/remediation output and errors; platform script rows include run status and available result/error details.

Loading the list does not retrieve the device states. The task does not run or modify the selected script; no rows do not establish success. Requires `DeviceManagementScripts.Read.All`; Graph beta endpoints can change. Protect exports containing execution details.

#### Microsoft 365 Apps Cloud Update

**Script:** [Get-M365CloudUpdateReport.ps1](entra/Get-M365CloudUpdateReport.ps1) | **Type:** Read-only, separate Office sign-in

Reports Monthly Enterprise Channel release, rollout statistics, and device details. Install MSAL.PS beforehand and use an Office-authorized account; the script notes an enabled Office Apps Administrator role. The app uses a separate interactive Office sign-in, not Home Graph. The default tenant is `organizations`, or enter a tenant ID/domain. The app uses the folder from **Settings > Reports**; choose another folder or **Do not save CSV reports**. The report offers device rows, rollout summary, progress by wave, and release datasets. CSV exports include portal-style devices, full inventory, and summary.

To add optional **Group** information:

1. Open **Settings > Cloud Update**, enter one exact Entra group display name per line, and save. The list is empty by default.
2. Connect on Home to the same tenant used for Office, with existing `Group.Read.All` and `Device.Read.All` consent and a supported reader role.
3. Enable **Include rollout group membership (Graph)** and run. The basic Office report works without this option or a group list.

The script correlates by unique, case-insensitive exact computer name, including transitive device members. Missing/duplicate names can be **Unknown**. Missing or ambiguous groups produce warnings and incomplete correlation; known matches are retained and unmatched devices are not labeled outside the configured groups until all groups resolve. The Office wave is not changed. Standalone use requires explicit `-WaveGroupNames`; its default export folder differs from the app's saved report folder, and its missing-MSAL installation behavior differs from the desktop's prerequisite check. This task uses undocumented Office backend APIs that may change. See [Cloud Update workflow notes](Desktop/README.md#microsoft-365-apps-cloud-update).

#### Stale AD-synced Entra devices

**Script:** [Get-StaleSyncedDevices.ps1](Intune/Devices/Get-StaleSyncedDevices.ps1) | **Type:** Read-only

Select an age threshold (90 days by default) and an output folder. The report exports currently or formerly AD-synced Entra device records with old approximate Entra sign-in activity, plus records whose activity is unknown. Cloud-only devices and AD computers without an Entra device object are outside this report. Unknown is not confirmed stale, and approximate Entra sign-in is not AD `lastLogonTimestamp`. Investigate before taking action; the report deletes nothing. Requires device/directory read access.

### Apps and assignments

#### Discovered apps

**Script:** [Get-DiscoveredApps.ps1](Intune/Devices/Get-DiscoveredApps.ps1) | **Type:** Read-only

Choose a platform and scope: **All devices**, **Single device**, or **Entra group**. Optionally filter by an app name or wildcard. For one device, enter its exact Intune device name or managed-device ID; use the ID if a name is ambiguous. The downloaded Intune inventory is filtered locally, so even a single-device report can take time. Large exports may take up to 30 minutes. CSV output uses the saved report folder unless overridden.

With an app-name filter, a selected app's visual summary shows distinct device counts by reported version; a device can appear under multiple versions. Requires applicable app, managed-device, group and directory read permissions. Discovered inventory is not proof of an effective app assignment.

#### Win32 app install diagnostics

**Script:** [Get-IntuneAppInvestigation.ps1](Intune/Assignments/Get-IntuneAppInvestigation.ps1) | **Type:** Read-only

Choose an exact device name or Intune managed-device ID and an exact app name or app ID. Duplicate names stop the lookup; use IDs to disambiguate. Run it directly as a task, or open its setup from a **Win32 app deployment status** failure-triage row to reuse the retained rollout report.

Review **Diagnostic findings**, **Error code details** when present, **App investigation**, **Device deployment rows**, **App assignments**, and **Suggested checks**. Findings compare available requirements, membership, reported states, and timing; they are evidence and suggestions, not a confirmed root cause. Current assignments do not prove effective targeting at the time of failure. No report rows means outcome unknown, not installed or unassigned. The task does not install, retry, sync, or remediate.

Requires managed-device, app, group, and configuration reads; membership checks also need directory access. A standalone investigation may temporarily download a fleet-wide deployment report, filter it locally, and clean its scratch folder; a cleanup failure is warned. See [diagnostic details](Desktop/README.md#win32-app-install-diagnostics).

#### Win32 app deployment status

**Script:** [Get-Win32AppDeploymentStatus.ps1](Intune/Assignments/Get-Win32AppDeploymentStatus.ps1) | **Type:** Read-only

Enter an app ID, part of a name, or a wildcard; names and IDs can be combined. If multiple apps match, choose the intended app versions in the selection dialog. Each selected app receives a full device-detail CSV and a per-device summary CSV. A user-status CSV is also exported by default; turn off **Include user deployment status** for device-only reports. The output folder defaults to the saved report folder and each export job defaults to a 300-second timeout.

Full rows may contain several user contexts for one device. The device summary uses one worst-known state per identified device; missing IDs are disclosed. Review raw rows for conflicting or unrecognized statuses. Optionally look up OS version and last sync for failed devices; this adds reads and requires `DeviceManagementManagedDevices.Read.All`. If a later user export fails, already saved device files may still be available; check Script output. Requires app/report read access and uses beta export APIs.

#### Compare Win32 report runs

**Script:** [Compare-Win32DeviceSummary.ps1](Reports/Compare-Win32DeviceSummary.ps1) | **Type:** Local, read-only

Compare two `DeviceSummary.csv` files previously exported by **Win32 app deployment status**. Select the older file as **Before** and the newer as **After**. Choose exports for the same app, tenant, and deployment scope.

The script checks that the files have the expected summary columns and the same valid app ID, then matches identified devices by device ID. It reports newly reported, no longer reported, unchanged, improved, regressed, and other status changes. Rows without usable identity are excluded and counted; duplicate device IDs stop the comparison. A rename is not a new device. Only recognized transitions to/from Installed are called improved or regressed; unrecognized or localized changes remain other changes. The files cannot prove tenant, scope, or export order. **No longer reported** means missing from the later export, not necessarily removed or unenrolled. No Graph connection is required.

#### Apps assigned to All Devices / Users

**Script:** [Get-AppsAssignedToAllDevices.ps1](Intune/Assignments/Get-AppsAssignedToAllDevices.ps1) | **Type:** Read-only

Find app assignments to the built-in All Devices target; optionally include All Users. Choose an app type (Win32 by default), optional intent, and output folder. A timestamped CSV shows apps, targets, intents, and assignment filters. No matching assignments produce a warning rather than a CSV. Failed assignment lookups can leave results incomplete, so inspect warnings. Target and filter configuration is not proof that an app effectively applies to every device or user. Requires `DeviceManagementApps.Read.All`.

#### Apps assigned to an Entra group

**Script:** [Get-IntuneAppAssignmentsForGroup.ps1](Intune/Assignments/Get-IntuneAppAssignmentsForGroup.ps1) | **Type:** Read-only

Enter an exact group display name or object ID. Optionally filter app type (All by default) and intent, then choose an output folder. The report exports direct include and exclude assignments, their intent, and any assignment filter. It does not calculate effective assignments for every group member. No matches produce a warning rather than a CSV; individual lookup failures can make results incomplete. Requires app and group read access.

#### Delete Win32 apps

**Script:** [Remove-Win32App.ps1](Intune/Apps/Remove-Win32App.ps1) | **Type:** Destructive

Select app names/patterns, IDs, or both. If a name matches multiple versions, choose the intended objects; nothing is selected automatically. Supply the required business justification when prompted. Use **Preview only (WhatIf)** first, review targets and assignment warnings, and follow confirmations for a real deletion.

Deleting an app object also removes its assignments; it does **not** uninstall software already installed on devices. If assignments cannot be checked, that app is skipped. Dependency and supersedence blocks are reported, not bypassed. A Multi-Admin Approval request is **pending**, not a completed deletion. A unique per-run outcome CSV, including preview and pending/failed outcomes, is saved to the chosen report folder. An interrupted request can be unconfirmed; verify Intune before retrying. Requires `DeviceManagementApps.ReadWrite.All` and Intune authorization.

### Groups

#### View Entra group membership

**Script:** [Get-EntraGroupMembers.ps1](entra/Get-EntraGroupMembers.ps1) | **Type:** Read-only

This single task replaces **Get Entra group members** and **Entra group devices**. Choose an exact group display name or object ID. Missing or duplicate names stop the lookup; use the ID if names are duplicated. The report returns all member types automatically, including users, devices, groups, contacts and service principals, with properties available to the caller.

Leave **Expand nested groups** unchecked for direct members only. Enable it to include members of nested groups at every depth in a flat, deduplicated list, including group objects. **Report data > Members** supports filtering, copying and **Export view**; no CSV is created automatically. Empty groups yield an empty report. Limited object details remain visible as type/ID with a warning; failed pages stop the report without partial results. Entra object IDs are not Intune managed-device IDs, and this report does not determine effective policy targeting.

Requires `Directory.Read.All`; hidden-membership groups also need `Member.Read.Hidden` and a supported role. Uses Graph beta to include service principals, so API behavior can change.

Standalone callers can add `-ExpandNestedGroups` and use `-GroupName` or `-GroupId`. The legacy [device-only CSV script](Intune/Devices/Get-EntraGroupDevices.ps1) is still available from the command line, but not as a separate app task.

#### Add users or devices to Entra group

**Script:** [Add-EntraGroupMembers.ps1](entra/Add-EntraGroupMembers.ps1) | **Type:** Change, no script-backed preview

Choose the target by group ID or exact name, then one source: user UPNs, a user list file, device names, or a device text file. Enter one value per line. User lists can be text, CSV, or XLSX; choose the UPN column for CSV/XLSX, and install ImportExcel for XLSX. Review the target and list before confirming: this task makes real membership requests and does not offer WhatIf.

Already-direct members are skipped. If multiple Entra devices share a hostname, **all** matching device objects are added; multiple users for one UPN are not added. The results describe membership outcomes, not a separate saved CSV. Requires group read/write and the applicable user or device read permission, plus authorization to change the target group.

#### Remove users or devices from Entra group

**Script:** [Remove-EntraGroupMembers.ps1](entra/Remove-EntraGroupMembers.ps1) | **Type:** Change; preview available

Select a group ID or exact name, and a user UPN or device-name source, either entered or from a file. User CSV/XLSX input requires a selected UPN column; XLSX requires ImportExcel. Start with **Preview only (WhatIf)**, review matched identities, then confirm a real removal if appropriate.

Only direct membership references are removed; the user/device objects themselves are not deleted and inherited membership is not removed. Ambiguous matches are skipped. Dynamic, role-assignable, synchronized, hidden-membership, and Exchange-managed groups are blocked; device removal from Microsoft 365 groups is also blocked. Review per-item outcomes. Requires group/member reads and, for real removal, `GroupMember.ReadWrite.All` and target-group authorization.

#### Create direct reports group

**Script:** [New-EntraDirectReportsGroup.ps1](entra/New-EntraDirectReportsGroup.ps1) | **Type:** Change; preview available

Enter a manager's exact Entra display name or UPN. Preview shows the intended group and rule; a real run asks for confirmation. The generated non-mail-enabled dynamic security group is named `Entra.Users.DirectReports.<FirstLast>`, using the manager's Entra first and last names. Both fields must exist, and an existing group name blocks creation.

The dynamic direct-reports rule includes the **manager and immediate reports**, not nested reports. Membership processing is asynchronous. Verify the service before retrying an uncertain create. Requires `User.Read.All`, `Group.ReadWrite.All`, group-creation authorization, and suitable Entra dynamic-membership licensing.

#### Add users' most recently synced devices

**Script:** [Add-PrimaryUserDevicesToEntraGroup.ps1](entra/Add-PrimaryUserDevicesToEntraGroup.ps1) | **Type:** Change; preview available

Choose the target group by ID or exact name and provide a text file of user UPNs. For each UPN, the script selects the most recently synced eligible Windows device whose Intune `userPrincipalName` matches within the lookback period (30 days by default). An optional corporate-owned-only filter narrows eligibility. This is **not** a lookup of a separate Intune primary-device property.

Use preview and review per-user outcomes before a real run. The app places `PrimaryUserDeviceGroupResults.csv` in the saved report folder by default; the standalone script retains `C:\temp\PrimaryUserDeviceGroupResults.csv`. This file is **overwritten even in preview**; choose another path if it must be retained. Requires managed-device read, device read, and group membership write permissions. The standalone script may reconnect if required scopes are missing.

### Device actions

#### Read / change Intune primary users

**Script:** [Get-IntuneDevicePrimaryUser.ps1](Intune/Devices/Get-IntuneDevicePrimaryUser.ps1) | **Type:** Read or change; preview available for changes

Choose **Read primary users** (the default), **Assign a new primary user**, or **Remove the primary user**. Select devices by exact names, Intune managed-device IDs, text file, or group display name. Names must resolve uniquely; group members are matched by Entra device ID to Intune records. Supply a UPN or user object ID when assigning. An optional CSV path saves results.

This changes the Intune primary-user association, not the user or device object. Windows Entra-joined or hybrid-joined devices are supported for changes; the user must be licensed and eligible. Changes require appropriate write consent and Intune Set primary user RBAC. Each device requires its own Yes/No approval in addition to ShouldProcess, even if its confirmation is suppressed. A **ChangeRequested** or **RemovalRequested** outcome is not a verified change; changes can take time to appear.

#### Request Intune sync

**Script:** [Invoke-IntuneSync.ps1](Intune/Devices/Invoke-IntuneSync.ps1) | **Type:** Change, no WhatIf

Choose device names, a text file, or an Entra group, and run only after reviewing the targets. The script requests syncs for found Intune devices in batches of up to 100, with a 90-second pause between batches. Missing devices are skipped with warnings. There is no CSV and no WhatIf: requests are real.

Optionally enable **Verify sync** to poll for a newer `LastSyncDateTime`; the default timeout is 10 minutes and the polling interval 30 seconds. A request accepted does not prove a device checked in, and an unconfirmed sync is not necessarily a failed request. Requires managed-device read/write and privileged-operation permissions, Intune authorization, and the Graph PowerShell commands for managed-device lookup and sync.

#### Entra / Autopilot cleanup

**Script:** [Remove-EntraDevice.ps1](Intune/Devices/Remove-EntraDevice.ps1) | **Type:** Destructive; preview available

Provide device names or a text list. The script evaluates orphan cleanup safeguards; there is **no age threshold**. It keeps records linked to Intune and skips cases where safety cannot be established, including certain ambiguous or failed lookups. Start with **Preview only (WhatIf)** and review output; use an optional CSV export if needed.

Autopilot deletion is an explicit option and normally has a separate approval. Declining Autopilot deletion does **not** itself prevent a separately approved Entra deletion. Automatic Autopilot approval affects only that prompt. A real run can optionally send results to a logging endpoint configured through `ENDPOINT_TOOLBOX_LOGGING_WEBHOOK` in the launcher's process environment; if it is not set, nothing is sent and you can keep a local CSV instead. Preview never submits it. Never paste the value into source, logs, or reports. See [cleanup logging configuration](README.md#cleanup-logging-configuration). Requires appropriate Entra, Intune, and Autopilot permissions and roles. Verify uncertain outcomes before retrying.

### Remote support

#### Remote endpoint session

**Script:** [PSRemote-Endpoint.ps1](PSRemote-Endpoint.ps1) | **Type:** Privileged remote session

1. Enter a computer name or choose one of the last 10 successful connections. A selection does not connect automatically.
2. Select **Connect to endpoint**. The script checks ping and WinRM, then prompts for device administrator credentials. The connection uses Negotiate and `EnableNetworkAccess`.
3. Under **Results > Remote workspace**, review or enter a command and select **Run on endpoint**. Commands run on the connected endpoint, not silently on the local computer. Disconnect when finished.

The **Saved commands** list is for review: selecting one fills the editor but does not execute it. Some templates are destructive or require placeholder replacement. Review all commands before running. The workspace is not a full terminal; full-screen programs and nested interactive sessions are unsupported. Remote output can be saved explicitly and may contain sensitive data.

Optional **UNC** attempts an administrative-share handoff to Windows Explorer. The DNS suffix in **Settings > Remote** is appended to the share host only when the name has no dot. Opening Explorer or creating a PowerShell drive does not prove Explorer can access the share with those credentials. Network reachability, WinRM and device authorization are required independently of Graph. See [remote workspace details](Desktop/README.md#remote-workspace).

## Run scripts directly

The scripts can also be run in PowerShell outside the desktop application. Open PowerShell 7 from the repository root, establish the connection required by the particular script, and inspect its built-in help first:

```powershell
Get-Help .\Intune\Devices\Get-IntuneDevicePrimaryUser.ps1 -Full
Get-Help .\entra\Get-EntraGroupMembers.ps1 -Examples
```

For example, after connecting to an appropriately authorized Graph session, a read-only group report can be run with:

```powershell
.\entra\Get-EntraGroupMembers.ps1 -GroupName 'Example Group'
```

Replace the placeholder with your own exact group name. The desktop's in-memory Graph connection is not shared with a separate terminal; scripts retain their own CLI authentication behavior. Desktop-only settings are not automatically parameters for standalone scripts. In particular, standalone Cloud Update group enrichment requires explicit `-WaveGroupNames`; the Remote DNS suffix can be passed as `-DnsSuffix`. Read the script help for parameter sets and output locations before running. For scripts supporting it, use `-WhatIf` when reviewing a change; this is not available on all scripts.

## Troubleshooting

| Problem | What to check |
|---|---|
| App will not start | Confirm Windows, PowerShell 7.6+, and that the full app folder or ZIP was extracted. See [launch instructions](Desktop/README.md#launch). |
| Sign-in shows approval or missing scopes | Confirm existing delegated consent with your tenant administrator. PIM role activation is not application consent; Home does not automatically request additional task scopes. |
| Role is unverified or task is blocked | Activate the required supported tenant-wide role, allow propagation, and check again. Confirm directory/role read authorization. If needed, reconnect; custom or scoped roles may not satisfy desktop preflight. |
| Graph or Intune returns 401/403 after preflight | Verify account and tenant, refresh the connection after PIM activation, and check Conditional Access, consent, Intune RBAC/scope tags, and service authorization. Preflight is not a universal service-access test. |
| No rows or missing values | Check the selected scope, filters, exact names/IDs, available reporting data, and service retention. Missing information is not proof of success, failure, inactivity, or a safe deletion target. |
| Report shows warnings or partial results | Review **Script output** and the affected dataset. Do not treat incomplete lookups, Unknown results, or pending approvals as confirmed successes. |
| Policy/script list is empty or out of date | Connect on Home, then use **Load policies** or **Load scripts** again. Choices need reloading after Graph connection changes. |
| Cloud Update group option is blocked | Save at least one exact display name under **Settings > Cloud Update**, connect Home with the required consent, and use the same tenant for Graph and Office. The base report does not need groups. |
| Remote connection fails | Check the computer name, network reachability, ping, WinRM configuration, remote authorization, and supplied device credentials. A Graph sign-in does not authorize WinRM. |
| Report file is missing | Check **Saved reports**, the selected output folder, and Script output for export errors. TEMP can be cleaned by Windows. Some tasks produce in-memory data rather than an automatic CSV. |
| An action was interrupted | Review its output and inspect Intune, Entra, or the endpoint before retrying. Accepted requests cannot be rolled back by Stop. |

If a problem persists, consult [desktop workflow notes](Desktop/README.md) and your organization's support procedures. Protect logs and reports before sharing them.

## Glossary

- **Delegated permission / consent:** An application's permitted access when acting for a signed-in user; this is separate from the user's directory role and Intune RBAC.
- **PIM:** Microsoft Entra Privileged Identity Management. An eligible role may need activation before use.
- **UPN:** User principal name, often resembling an email address.
- **Object ID:** The identifier of an Entra or Intune object. An Entra device object ID, Entra device ID, and Intune managed device ID are different identifiers.
- **Direct / transitive group membership:** Direct members belong to the selected group itself. Transitive membership can also include members of nested groups; each task says which it uses.
- **WhatIf / preview:** An optional simulation of supported changes. It may still read service data or write reports.
- **TEMP:** The current user's temporary folder. Treat it as temporary storage, not a long-term report archive.
