# Endpoint Toolbox: project overview and architecture

**Status:** implementation overview as of November 5, 2026.

This document explains the Endpoint Toolbox desktop application: what it does, how it is structured, how the main components work together, and what has been built so far. It covers the application and its cataloged business scripts in this repository.

For detailed operating instructions, permissions and workflow-specific cautions, see the [README](README.md).

## 1. Purpose

Endpoint Toolbox is a Windows desktop front end for existing administrative PowerShell scripts. It brings Intune, Microsoft Entra and remote endpoint work into one application, without replacing those scripts with a new management backend.

The application currently exposes **26 cataloged workflows**:

| Area | Workflows |
|---|---|
| Inventory | Device investigation dashboard, mobile device inventory, All Cloud PCs, Cloud PC last login, Find Entra users by name |
| Device reports | Device user usage, expedited quality updates, remediation and platform script status, stale AD-synced Entra devices, Microsoft 365 Apps Cloud Update |
| Apps and assignments | Discovered apps, Win32 app installation investigation, Win32 deployment status, assignments to All Devices/Users, assignments to a group, Win32 app deletion |
| Groups | View Entra group membership (all member types, optional nested expansion), add or remove direct user or device memberships, add users' most recently synced devices, create dynamic direct reports groups |
| Device actions | Read/change Intune primary users, request Intune sync, Entra/Autopilot cleanup |
| Remote support | Connect to a Windows endpoint and run reviewed PowerShell commands |

It is a local administrative application, not a web service, background agent or replacement for Intune/Entra authorization. Actions run using the operator's authenticated Graph context or remote Windows credentials.

## 2. Technology and design approach

- **PowerShell 7.6 or newer:** application orchestration and existing administrative scripts.
- **WPF/XAML:** the Windows interface, shared styles and layout.
- **C# hosting bridge:** asynchronous PowerShell execution, host prompts, remote runspaces and structured event delivery.
- **Microsoft Graph PowerShell modules:** required by the relevant business scripts.
- **MSAL.PS:** separately installed prerequisite for the Office Cloud Update report's interactive authentication.
- **PowerShell data file:** explicit workflow catalog.
- **JSON:** editable saved remote commands.
- **JSON Lines and CSV:** local activity logs, history and reports.
- **Pester and native WPF fixtures:** offline behavioral and layout checks.

The application launches directly from the repository. There is no separate .NET build or installer requirement: the C# bridge is compiled into the PowerShell process at runtime.

The central architectural decision is to **separate presentation from administrative behavior**. The UI collects inputs, hosts prompts and displays results; the business scripts retain responsibility for Graph requests, matching rules, permissions and confirmations.

This is not a conventional compiled C# MVVM application. WPF layout lives in XAML, while a PowerShell module manages controls, events and application state.

## 3. Project structure

Paths below are relative to the application's [Desktop folder](.).

| Component | Responsibility |
|---|---|
| [Start-EndpointToolboxUI.ps1](Start-EndpointToolboxUI.ps1) | Entry point, module loading, launch-error reporting and fresh-process handling for an incompatible loaded bridge |
| [EndpointToolboxUI.psm1](EndpointToolboxUI.psm1) | Main application controller: catalog loading, generated forms, input validation, dialogs, task execution, event processing, results, remote workspace and UI logging |
| [MainWindow.xaml](MainWindow.xaml) | Main window, shared control styles, task navigation, configuration workspace and output tabs |
| [WorkflowCatalog.psd1](WorkflowCatalog.psd1) | Reviewed workflow IDs, script paths, categories, descriptions, defaults, input-source selectors and capabilities |
| [Hosting/DesktopPowerShellHost.cs](Hosting/DesktopPowerShellHost.cs) | PowerShell host/engine, prompt requests, asynchronous pipelines, worker events, report views, cancellation and remote session ownership |
| [Invoke-WorkflowPresentation.ps1](Invoke-WorkflowPresentation.ps1) | Adapter between original scripts and desktop presentation: app-selection data, structured result summaries and generated-file discovery |
| [ActivityLogging.ps1](ActivityLogging.ps1) | Shared activity-record writing, retention, rollover, bounded diagnostic text and outcome classification |
| [RemoteCommands.json](RemoteCommands.json) | Friendly names, descriptions and literal PowerShell text for 29 saved remote commands |
| [Install-EndpointToolboxShortcut.ps1](Install-EndpointToolboxShortcut.ps1) | Optional per-user desktop shortcut setup |
| [Tests](Tests) | Pester suites and synthetic fixtures |
| [README.md](README.md) | Operator instructions, behavioral caveats, dependencies and validation commands |

Business scripts remain outside the desktop implementation:

- [Intune](../Intune): device reporting/actions, application reporting and Win32 removal.
- [entra](../entra): group membership operations.
- [PSRemote-Endpoint.ps1](../PSRemote-Endpoint.ps1): endpoint connection workflow.

The running code and catalog determine actual behavior.

## 4. How a task runs

```text
Operator starts the launcher
    |
    v
Validate catalog, script coverage and saved commands
    |
    v
Load WPF window and generate the selected task's form
    |
    v
Validate inputs and bind typed PowerShell parameters
    |
    v
Worker engine -> presentation adapter -> business script
    |                                      |
    |                                      +-> Graph / endpoint / CSV files
    v
Queued events: output, progress, prompts, data, summaries, files
    |
    v
WPF dispatcher processes bounded batches
    |
    v
Script output / Report data / Saved reports / activity records
```

### Startup and discovery

The catalog explicitly lists approved scripts; the application does not execute arbitrary scripts discovered in a folder.

The remediation/platform-script status and expedited quality updates workflows offer **Load scripts** and **Load policies**, respectively. These actions run the cataloged script in the Graph worker through the regular access preflight and return choices without creating report rows. The operator filters and selects one item before starting the device-status report.

Catalog loading parses each script's PowerShell syntax tree to obtain parameter names, types, supported values and help. Catalog metadata supplies friendly presentation and explicit defaults. Coverage validation rejects missing or uncataloged business scripts rather than silently ignoring them.

Saved remote commands are also validated at startup for schema, required fields, unique names and valid PowerShell syntax. Validation does not execute their command text.

### Dynamic forms

Forms are generated from script parameters plus catalog metadata:

- Switches become checkboxes.
- Supported-value lists become dropdowns.
- Strings become text fields.
- Arrays become multiline inputs with one value per line.
- Input-source selectors show only relevant parameters.
- Script/report selection prompts can present searchable, single-choice lists while keeping selection and lookup logic in the business script.
- Report/export and advanced options are grouped separately.

Ordinary task inputs are converted to typed parameter values, not evaluated as PowerShell code. The remote command editor is the intentional exception.

### Execution and UI responsiveness

The application uses persistent local worker engines for Graph-oriented work and remote-session work. An idle remote connection can remain open while another workflow is selected, but the UI permits only one active task or remote command at a time.

The catalog's `Office` execution kind runs Cloud Update in the local non-remote worker, without Graph preflight: the original script owns its separate MSAL sign-in and Office API authorization. The desktop adapter blocks missing MSAL.PS before invocation, supplies TEMP when no export folder is provided, and presents existing release/rollout/wave data and portal-style device rows. Rollout statistics remain in grid datasets and script output; the top card shows run status and timing only. No Office authentication context is represented as verified Home Graph access.

Cloud Update's optional `IncludeWaveGroups` switch adds Graph preflight only when selected. The desktop reads group names saved under Settings > Cloud Update; the list is empty by default. Standalone use requires `-WaveGroupNames` when the switch is set. It reads the configured groups and their transitive device members, then correlates against uniquely named Entra devices; duplicate/missing names remain Unknown. Matching group names enrich the device grid/portal CSV without changing Office wave assignments. Office and Graph tenants must match. Default runs do not call Graph.

Pipelines run asynchronously rather than on the WPF UI thread. The C# bridge queues events, and the UI processes them in bounded batches. Report preparation happens in the worker; read-only indexed views avoid eagerly materializing every report row in WPF.

This separation is important for large reports, scrolling output and a responsive Stop button.

### Prompts and cancellation

The custom host converts script prompts into WPF dialogs, including text, choices, credentials and secure-string input. Credentials are returned as secure PowerShell objects, not ordinary output text.

For supported app-selection prompts, the adapter supplies matching apps to a grid and translates the user's selections back to the original script's index response.

Stop requests worker cancellation and discards queued display backlog. It does **not** undo accepted requests, roll back deletions or forcibly terminate a worker thread. Interrupted results are labeled incomplete or uncertain instead of being presented as successful.

## 5. Interface structure

The window uses a searchable, category-grouped task sidebar and two main workspaces:

1. **Configure:** task explanation, inputs, execution mode and optional settings.
2. **Run & results:**
   - **Script output:** diagnostics, progress text, summaries and detailed timings.
   - **Report data:** structured rows with filtering, sorting, copying and export.
   - **Saved reports:** files produced by the current run.
   - **Remote workspace:** connected-device commands and their output.

Shared styles now provide compact, consistent text fields, dropdowns, buttons and password fields. Multiline inputs and output panes are top-aligned. Credential dialogs are smaller, while app-selection dialogs retain room for their grids.

The remote output and editor have a draggable divider. Task description and summary/timing chrome are hidden while Remote workspace is displayed to preserve usable terminal space; this information remains available outside that tab.

These are implemented layout improvements, **not a claim of completed accessibility certification**. Keyboard, screen-reader, contrast and DPI/scaling acceptance still require dedicated manual checks.

## 6. Remote workspace

The connection script retains its ping/WinRM checks and Negotiate/EnableNetworkAccess behavior. The host owns the created session and attempts cleanup on disconnect or application close.

Remote commands are explicitly routed to the connected endpoint. A missing remote session is an error, not permission to fall back to local execution.

The saved-command catalog was built from the frequently used cleanup and troubleshooting notes. Each entry has:

```json
{
  "Name": "System - Current time",
  "Description": "Show the remote computer's current date and time.",
  "Command": "Get-Date"
}
```

Entries belong inside the catalog's `Commands` array, alongside `SchemaVersion: 1`. Selecting an entry fills the editable command box; the operator must still review it and click **Run on endpoint**.

Output resembles a simple PowerShell session: `PS [device]>`, command text, results and necessary errors/warnings. A separate animated running/stopping indicator disappears when work ends and is excluded from saved output.

This is a command workspace, **not a full terminal emulator**. Full-screen native applications, nested interactive sessions and multiple simultaneous remote sessions are not supported.

## 7. Logging, history and reports

These serve different purposes:

| Output | Location / format | Purpose |
|---|---|---|
| Master activity | `%LOCALAPPDATA%\EndpointToolbox\Logs\master-YYYY-MM-DD.jsonl` | App lifecycle, task selection, runs, exports and errors |
| Per-task activity | Same folder, `task-<workflow-id>-YYYY-MM-DD.jsonl` | Task lifecycle, compact diagnostics and outcome summaries |
| Run history | `%LOCALAPPDATA%\EndpointToolbox\history.jsonl` | Minimal run identifiers, times, states and row counts |
| Recent remote devices | `%LOCALAPPDATA%\EndpointToolbox\recent-devices.json` | Up to 10 computer names with confirmed remote connections, most recent first; fills the Computer name dropdown only |
| CSV reports | Workflow-selected output location; often TEMP by default | Detailed reusable results |
| Saved output | Operator-selected file | Explicitly saved console or remote transcript |

Activity records use UTC times, the local Windows username and correlated run IDs. Logs roll over at approximately 5 MB per segment and retain the current UTC day plus the preceding 29 days, with pruning on a subsequent write. Reports are not deleted by that retention process.

Automatic diagnostics are bounded: up to 20 warnings/errors per run, with first-line messages truncated and common secrets redacted. Activity logs do not intentionally store full console output, credentials or parameter payloads.

Automatic remote records are deliberately narrower: connection/device/outcome information, not command text, returned content or remote error details. Explicitly saved transcripts and CSVs may still contain sensitive information and must be reviewed before sharing.

Local logs are operational records, not tamper-proof compliance storage. A run-log initialization failure blocks execution; later logging problems are surfaced rather than silently discarded.

### Outcome summaries

Summaries use structured result rows or explicit counters, not guesses based on console text. They distinguish successes, failures, pending approval, skipped/preview and incomplete/unknown work where applicable.

The unit matters: a count may refer to apps, devices, users, directory objects or report rows. An accepted action request is not proof that the endpoint completed it, and successful report retrieval does not mean every reported device is healthy.

## 8. Significant changes built so far

1. **Desktop integration:** cataloged existing scripts, generated forms, embedded prompts, asynchronous execution and result workspaces.
2. **Win32 deployment reporting:** consolidated the duplicate reporting task into one workflow with device details, per-device summaries and user status.
3. **Resilient Win32 removal:** individual dependency/deletion errors no longer terminate processing of the remaining selected apps. Assignment-lookup failures skip the affected app rather than allowing unchecked deletion.
4. **Activity logging:** master and per-task records, run correlation, retention, bounded diagnostics and privacy rules.
5. **Win32 removal reporting:** one CSV per run with `AppName`, `AppVersion`, `AppId`, `Status` and `Reason`, plus glanceable final counts. Pending approval and uncertain cancellation outcomes are not marked as completed deletions.
6. **Saved remote commands:** 29 reviewed starter entries with friendly names, editable text and explicit execution. Profile cleanup templates require an explicitly chosen retained profile and exclude loaded/special profiles.
7. **Simpler remote output:** terminal-like formatting without timing noise, plus a temporary busy indicator.
8. **UI density improvements:** compact shared inputs, matching credential fields, smaller dialogs, usable output panes and a resizable remote editor/output split.

The original scripts have not all been rewritten. Most administrative behavior remains in them; deliberate script changes are limited to specific reporting, reliability and outcome-counting needs documented in the [README](README.md).

## 9. Testing and current acceptance status

The [test directory](Tests) covers catalog validation, script integration, hosting, deployment/reporting, activity logging, remote command safety, session isolation and desktop UX.

Tests use synthetic data, replaced Graph/network commands and isolated runspaces. Native STA fixtures exercise real WPF controls and dialogs without requiring a tenant mutation or live endpoint connection.

Recent verification established:

- Compact layouts and usable output at 1000 x 700 and 1400 x 940.
- Matching credential field heights, secure credential submission and dialog cancellation.
- Wide app-selection layout and preserved selection responses.
- All 10 targeted remote-session/catalog tests passing.
- Launcher validation passing.

Two known suite limitations must not be hidden:

- The broader desktop fixture intermittently exceeds its existing 250 ms UI-processing threshold and can stop before its later checks. That threshold has not been relaxed.
- A workflow-baseline comparison has a known stale treatment of the Win32 removal script's `OutputPath` parameter after the reporting changes.

This is not a statement that every current full-suite test passes. Live Graph authentication/MFA, tenant RBAC/MAA, approved mutations, domain WinRM/UNC, screen-reader use and display scaling remain manual acceptance requirements.

## 10. Running and maintaining the project

From the repository root:

```powershell
# Launch the application.
pwsh.exe -NoProfile -STA -File .\Desktop\Start-EndpointToolboxUI.ps1

# Validate scripts, catalogs and startup configuration without opening the app.
pwsh.exe -NoProfile -STA -File .\Desktop\Start-EndpointToolboxUI.ps1 -ValidateOnly

# Exercise the synthetic form/report smoke checks.
pwsh.exe -NoProfile -STA -File .\Desktop\Start-EndpointToolboxUI.ps1 -SmokeTest

# Run the offline regression suites.
Invoke-Pester -Script .\Desktop\Tests -PassThru
```

Graph modules and optional ImportExcel must be installed deliberately as required by the selected workflow. The app does not automatically install dependencies or request a combined set of Graph permissions. Windows PowerShell 5.1 is not supported.

Close and relaunch the application after updates. The launcher detects an incompatible already-loaded C# bridge and starts a fresh PowerShell process when necessary.

### Adding a workflow

1. Put the reviewed business script under the appropriate folder outside Desktop.
2. Add an explicit entry with a stable unique ID and path to the [workflow catalog](WorkflowCatalog.psd1).
3. Reuse typed form generation and add labels/hints or source selectors where needed.
4. Extend the [presentation adapter](Invoke-WorkflowPresentation.ps1) only when structured results or exports need mapping.
5. Preserve original authorization, confirmations and supported preview behavior.
6. Add focused offline tests, then validate catalog coverage and native layout.

### Adding a saved remote command

Add a unique `Name`, explanatory `Description` and literal `Command` to [RemoteCommands.json](RemoteCommands.json). Review destructive operations carefully, never embed credentials, validate syntax and restart the app. A saved command must remain review-before-run, never execute-on-selection.

### Where to make future changes

- **Appearance/shared sizing:** [MainWindow.xaml](MainWindow.xaml).
- **Generated forms/dialogs/event wiring:** [EndpointToolboxUI.psm1](EndpointToolboxUI.psm1).
- **Workflow metadata:** [WorkflowCatalog.psd1](WorkflowCatalog.psd1).
- **Administrative behavior:** the relevant original business script.
- **Result mapping/outcome presentation:** [Invoke-WorkflowPresentation.ps1](Invoke-WorkflowPresentation.ps1).
- **Worker/host/session mechanics:** [DesktopPowerShellHost.cs](Hosting/DesktopPowerShellHost.cs).
- **Activity retention/record formatting:** [ActivityLogging.ps1](ActivityLogging.ps1).

Keep changes in the layer that owns the responsibility, retain remote/local execution isolation, and verify actual outcomes rather than interpreting the absence of an exception as success.
