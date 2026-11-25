# EXE Graph sign-in: failure analysis and implementation options

## Status

This is implementation guidance, not an implemented EXE authentication fix. The
[build script](Build-EndpointToolboxBundle.ps1) still creates `EndpointToolbox.exe`,
and the [EXE launcher](EndpointToolboxLauncher.cs) still starts PowerShell with
`CreateNoWindow = true`. Code signing does not resolve the window-handle problem.

The visible-console [script launch](../README.md#launch) is the current workaround.
The [shortcut installer](../Install-EndpointToolboxShortcut.ps1) no longer requests
a hidden console. Live sign-in through that workaround has not been verified as
part of this investigation. None of the EXE changes below has been implemented
or verified end-to-end.

## Observed failure

On Windows with PowerShell 7.6.10 and Microsoft.Graph.Authentication 2.38.1,
the signed EXE opened the WPF app, but clicking **Connect / reconnect** briefly
changed the screen without completing sign-in. The activity log reported:

```text
InteractiveBrowserCredential authentication failed: A window handle must be configured.
```

Look in `%LOCALAPPDATA%\EndpointToolbox\Logs` for the `TaskError` entries in
`task-graph-session-connect-<UTC-date>.jsonl`. The matching `RunId` correlates the
request, warnings, error and completion records.

The EXE is a launcher, not a compiled replacement for the PowerShell app. It
starts a console-less `pwsh.exe`, which loads WPF and a persistent Graph worker.
That worker calls `Connect-MgGraph` in
[Invoke-GraphSession.ps1](../Invoke-GraphSession.ps1). Current Graph authentication
uses Windows Web Account Manager (WAM) for the default Graph application on
Windows. WAM needs a parent HWND; the console-less launch does not supply the
console window expected by this authentication path. Having a WPF window open
does not automatically pass its HWND to Graph.

### Why the initial WAM-disable attempt did not fix it

The rebuilt, signed payload was inspected and contained the attempted
`Set-MgGraphOption -DisableLoginByWAM $true` change. It still produced the same
WAM warning and window-handle error.

[Microsoft documents](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.authentication/set-mggraphoption)
that this option only disables WAM with a **custom client ID**; the default
application keeps WAM enabled. Older module versions expose
`EnableLoginByWAM` instead. Detecting these parameter names does not prove that
the default application can use browser sign-in.

That attempted workaround was removed. These options can persist across
PowerShell sessions, so do not treat them as isolated worker-only preferences.
Mock tests proving that the setter was called were insufficient to establish
real SDK behavior.

## Option 1: Keep the EXE, allow a visible PowerShell console

This is the smallest implementation candidate when neither device-code sign-in
nor a custom app registration is available. It keeps normal delegated WAM
authentication, but the result is not a console-free desktop app.

1. In [EndpointToolboxLauncher.cs](EndpointToolboxLauncher.cs), change the normal
   child-process launch to permit a console, starting with
   `CreateNoWindow = false`. Do not add a hidden window style. With a GUI launcher
   that has no console, verify that Windows actually gives the child a usable
   console HWND; do not assume the flag alone proves this.
2. Keep the existing PowerShell version check, `-NoProfile -STA`, working
   directory, process waiting, error reporting and exit-code handling. Review
   standard-error redirection when testing the visible console, rather than
   removing diagnostics just to make the window appear.
3. Keep the console alive throughout the app session, including reconnects.
   Document that closing the console can terminate the app. Test both direct
   Explorer launch and launch from Windows Terminal or an existing console.
4. Preserve `-ValidateOnly` and `-SmokeTest`. If console visibility becomes a
   launcher option, validate arguments and document the default.
5. Rebuild and re-sign the bundle; test the extracted EXE, not only the script.

Changing the compiler target from `winexe` to `exe` alone does not address the
child-process configuration. The Graph authentication runs in `pwsh.exe`, not in
the launcher process.

## Option 2: Keep WAM and parent sign-in to the WPF window

This is the native console-free direction, but requires a supported connection
between the Graph authentication implementation and the WPF HWND.

- Obtain the main window's HWND on the WPF dispatcher after its native window
  exists, using `WindowInteropHelper`. Pass only the handle or a suitable
  provider across the hosting boundary; workers must not access WPF controls.
- MSAL exposes `WithParentActivityOrWindow` for this purpose. However, the
  installed Graph 2.38.1 `Connect-MgGraph` command has **no public parent-window
  parameter**. Adding an invented parameter or passing an HWND to the existing
  script will not work.
- First investigate an upstream Graph SDK feature/fix that accepts the HWND.
  Otherwise, a maintained SDK change or a deliberate authentication redesign
  is needed. Direct MSAL authentication is not a drop-in fix: confirm application
  registration rights, supported client identity, token refresh, Graph context
  compatibility, dependency loading, cancellation and ownership of credentials.
- Do not use reflection into private SDK fields, a fabricated window handle,
  or credentials/tokens passed through command-line arguments or files.
- If changing the public hosting bridge, update the launcher's compatibility
  detection and its tests. The bridge currently compiles at runtime without
  NuGet dependencies; adding an authentication library changes that design.

See Microsoft's [WAM parent-window requirements](https://learn.microsoft.com/en-us/entra/msal/dotnet/acquiring-tokens/desktop-mobile/wam#parent-window-handles).

## Option 3: Custom Entra public-client app and browser sign-in

This can keep the console hidden, but requires tenant administrator cooperation.
Existing consent for Microsoft's Graph PowerShell application does not
automatically apply to a new application.

1. Register an approved public-client desktop application with the appropriate
   browser redirect configuration and delegated Graph permissions. Obtain the
   required consent; do not use a client secret or an app-only certificate flow
   as a substitute for this app's delegated user/role checks.
2. Add validated client-ID configuration through
   [Settings.ps1](../Settings.ps1), deployment defaults and the Graph settings UI.
   These settings do not exist today; unknown JSON keys are currently rejected.
3. In the persistent Graph worker, disable WAM using the option supported by the
   installed module and pass the approved `ClientId` and tenant to
   `Connect-MgGraph`. Account for the option's persistence and effects on other
   Graph PowerShell sessions; document any intentional preference change.
4. Retain `ContextScope Process`, the existing `.default` consent model,
   reconnect sign-out behavior and live account, tenant, scope and role checks.
   Browser sign-in does not bypass Conditional Access or consent requirements.

See [Graph authentication commands](https://learn.microsoft.com/en-us/powershell/microsoftgraph/authentication-commands)
and [Set-MgGraphOption](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.authentication/set-mggraphoption).

## Option 4: Device-code sign-in

`Connect-MgGraph -UseDeviceCode` (also named `-UseDeviceAuthentication`) avoids
the WAM parent-window requirement without a custom app registration. It is not
usable where tenant policy blocks device-code authentication.

This requires more than adding a switch: display the Microsoft sign-in URL and
short-lived code clearly on Home, provide copy/open actions and cancellation,
and handle expiry, denial and retry. The hidden console must not be the only
place instructions appear. Do not persist codes or tokens in activity logs,
history or diagnostic exports; review the existing host output and warning
paths before routing the SDK's device-code message through them. Keep delegated
consent and access preflight unchanged, and do not silently switch flows after
the user cancels or tenant policy rejects a sign-in.

See [Connect-MgGraph](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.authentication/connect-mggraph).

## Acceptance checks for any implementation

- Record Windows, PowerShell and Graph Authentication versions. Test the actual
  supported module versions, not only mocks; this SDK behavior is version-sensitive.
- Add focused offline tests to the existing deployment, Graph session, hosting
  or desktop UX suites as appropriate. Do not call a real tenant in automated
  offline tests.
- Run `-ValidateOnly` and `-SmokeTest`, but do not count them as authentication
  tests: they do not prove that WAM or a browser can sign in.
- With an approved test tenant/account, manually launch the newly extracted,
  signed EXE from Explorer, click Connect, and verify that the sign-in UI is
  usable and the live account/tenant and access result appear on Home.
- Verify reconnect, disconnect, cancellation, failure, a second run in the same
  process, and process restart. Test window ownership/focus for a WPF-parented
  flow and console lifetime for a console-based flow.
- Test missing consent, unverified roles and tenant mismatch without starting
  a mutating workflow. Confirm errors remain visible on Home and in redacted
  diagnostics without exposing authentication secrets.
- Preserve execution policy, signature verification, non-elevated launch,
  process-scoped Graph context, remote-worker isolation and original business
  script authentication behavior.
- Build with a new version/output ZIP, sign the staged payload, verify its
  signatures and distribute the whole ZIP. Do not edit an already signed
  deployed script in place. The build's startup validation is not sufficient
  evidence of a working Connect button.
