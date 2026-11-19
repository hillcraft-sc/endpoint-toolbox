// Copyright (C) 2026 Eric Hebert
// SPDX-License-Identifier: GPL-3.0-or-later
// See the LICENSE file in the repository root for the full license text.

using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Diagnostics;
using System.Data;
using System.ComponentModel;
using System.Text.RegularExpressions;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Language;
using System.Management.Automation.Runspaces;
using System.Security;
using System.Threading;

namespace EndpointToolbox
{
    // DataView's IBindingList makes WPF eagerly cache every row; expose an indexed, read-only view instead.
    public sealed class ReportRows : IList, ITypedList
    {
        private readonly DataView view;
        public ReportRows(DataView view) { this.view = view; }
        public int Count => view.Count;
        public object this[int index] { get => view[index]; set => throw new NotSupportedException(); }
        public bool IsReadOnly => true;
        public bool IsFixedSize => true;
        public bool IsSynchronized => false;
        public object SyncRoot => this;
        public IEnumerator GetEnumerator() => view.GetEnumerator();
        public void CopyTo(Array array, int index) => ((ICollection)view).CopyTo(array, index);
        public int IndexOf(object value) => ((IList)view).IndexOf(value);
        public bool Contains(object value) => IndexOf(value) >= 0;
        public int Add(object value) => throw new NotSupportedException();
        public void Clear() => throw new NotSupportedException();
        public void Insert(int index, object value) => throw new NotSupportedException();
        public void Remove(object value) => throw new NotSupportedException();
        public void RemoveAt(int index) => throw new NotSupportedException();
        public System.ComponentModel.PropertyDescriptorCollection GetItemProperties(System.ComponentModel.PropertyDescriptor[] accessors) =>
            ((ITypedList)view).GetItemProperties(accessors);
        public string GetListName(System.ComponentModel.PropertyDescriptor[] accessors) => ((ITypedList)view).GetListName(accessors);
    }

    public sealed class PreparedReport
    {
        private static readonly Regex signedValue = new Regex(@"(?i)([?&](?:token|sig|signature|access_token|code)=)[^&\s""<>]+", RegexOptions.Compiled);
        private static readonly Regex bearer = new Regex(@"(?i)(Bearer\s+)[A-Za-z0-9._~+/-]+=*", RegexOptions.Compiled);
        public DataTable Table { get; }
        public bool HasFailures { get; private set; }
        public bool HasWarnings { get; private set; }
        public bool PendingApproval { get; private set; }
        private static string Protect(object value)
        {
            string text = value as string ?? (value == null ? "" : LanguagePrimitives.ConvertTo<string>(value));
            if (text.IndexOf('?') >= 0 || text.IndexOf('&') >= 0)
                text = signedValue.Replace(text, "$1[redacted]");
            if (text.IndexOf("Bearer", StringComparison.OrdinalIgnoreCase) >= 0)
                text = bearer.Replace(text, "$1[redacted]");
            return text;
        }
        public PreparedReport(string name, object rows, DesktopHost host)
        {
            Table = new DataTable(name);
            Table.ExtendedProperties["PreparedForDesktop"] = true;
            Table.BeginLoadData();
            try
            {
                var enumerator = LanguagePrimitives.GetEnumerator(rows);
                if (enumerator == null && rows != null) enumerator = new object[] { rows }.GetEnumerator();
                while (enumerator != null && enumerator.MoveNext())
                {
                    if (host.IsStopping) throw new PipelineStoppedException();
                    if (enumerator.Current == null) continue;
                    var item = PSObject.AsPSObject(enumerator.Current);
                    var row = Table.NewRow();
                    bool hasProperties = false;
                    foreach (var property in item.Properties)
                    {
                        if (property.MemberType != PSMemberTypes.NoteProperty &&
                            property.MemberType != PSMemberTypes.Property &&
                            property.MemberType != PSMemberTypes.AliasProperty) continue;
                        hasProperties = true;
                        if (!Table.Columns.Contains(property.Name)) Table.Columns.Add(property.Name, typeof(string));
                        string value = Protect(property.Value);
                        row[property.Name] = value;
                        if (property.Name.Equals("Status", StringComparison.OrdinalIgnoreCase) ||
                            property.Name.Equals("LoginStatus", StringComparison.OrdinalIgnoreCase) ||
                            property.Name.Equals("EntraAction", StringComparison.OrdinalIgnoreCase) ||
                            property.Name.Equals("AutopilotAction", StringComparison.OrdinalIgnoreCase))
                        {
                            if (Regex.IsMatch(value, @"^(Failed|Error|DirectoryDeviceNotFound|Lookup failed)$", RegexOptions.IgnoreCase)) HasFailures = true;
                        }
                        if (property.Name.Equals("Status", StringComparison.OrdinalIgnoreCase))
                        {
                            if (value.Equals("PendingApproval", StringComparison.OrdinalIgnoreCase)) PendingApproval = true;
                            if (Regex.IsMatch(value, @"^(NotFound|NoEligibleDevice|Unresolved|NotConfirmed)$", RegexOptions.IgnoreCase)) HasWarnings = true;
                        }
                    }
                    if (!hasProperties)
                    {
                        if (!Table.Columns.Contains("Value")) Table.Columns.Add("Value", typeof(string));
                        row["Value"] = Protect(item);
                    }
                    Table.Rows.Add(row);
                }
            }
            finally { Table.EndLoadData(); }
            // Build the view's index before handing the table to WPF.
            _ = Table.DefaultView.Count;
        }
    }

    public sealed class DesktopEvent
    {
        public string Kind { get; set; }
        public string Name { get; set; }
        public object Data { get; set; }
        public DateTime Timestamp { get; } = DateTime.Now;
    }

    public sealed class InputRequest : IDisposable
    {
        private readonly ManualResetEventSlim ready = new ManualResetEventSlim();
        public string Kind { get; }
        public string Caption { get; }
        public string Message { get; }
        public string[] Choices { get; }
        public object Answer { get; private set; }
        public bool Cancelled { get; private set; }
        public bool IsCompleted { get; private set; }
        public InputRequest(string kind, string caption, string message, string[] choices)
        {
            Kind = kind; Caption = caption; Message = message; Choices = choices;
        }
        public void Complete(object answer)
        {
            lock (ready) { if (!IsCompleted) { Answer = answer; IsCompleted = true; ready.Set(); } }
        }
        public void Cancel()
        {
            lock (ready) { if (!IsCompleted) { Cancelled = true; IsCompleted = true; ready.Set(); } }
        }
        public object Wait()
        {
            ready.Wait();
            if (Cancelled) throw new PipelineStoppedException();
            return Answer;
        }
        public void Dispose() { lock (ready) { Answer = null; ready.Dispose(); } }
    }

    public sealed class DesktopHost : PSHost, IHostSupportsInteractiveSession
    {
        private readonly Guid id = Guid.NewGuid();
        private readonly DesktopHostUI ui;
        private readonly object inputLock = new object();
        private InputRequest pending;
        private bool stopping;
        public bool IsStopping { get { lock (inputLock) { return stopping; } } }
        public bool PrepareReportTables { get; set; }
        public ConcurrentQueue<DesktopEvent> Events { get; } = new ConcurrentQueue<DesktopEvent>();
        public int ExitCode { get; private set; }
        public PSSession OwnedSession { get; private set; }
        public string RemoteIdentity { get; private set; } = "";
        public Runspace RemoteRunspace { get; private set; }
        public Runspace LocalRunspace { get; internal set; }
        public bool IsRunspacePushed => RemoteRunspace != null;
        public Runspace Runspace => RemoteRunspace ?? LocalRunspace;
        public override Guid InstanceId => id;
        public override string Name => "EndpointToolbox";
        public override Version Version => new Version(1, 0);
        public override PSHostUserInterface UI => ui;
        public override CultureInfo CurrentCulture => CultureInfo.CurrentCulture;
        public override CultureInfo CurrentUICulture => CultureInfo.CurrentUICulture;
        public DesktopHost() { ui = new DesktopHostUI(this); }
        public void Emit(string kind, string name, object data)
        {
            if (IsStopping && IsPresentationEvent(kind)) return;
            Events.Enqueue(new DesktopEvent { Kind = kind, Name = name, Data = data });
        }
        private static bool IsPresentationEvent(string kind)
        {
            switch (kind)
            {
                case "Rows": case "Summary": case "Output": case "Activity":
                case "Progress": case "Stage": case "Choice": case "ScriptChoices": return true;
                default: return false;
            }
        }
        public void DiscardPendingPresentationEvents()
        {
            int count = Events.Count;
            var retained = new List<DesktopEvent>();
            for (int i = 0; i < count && Events.TryDequeue(out var item); i++)
                if (!IsPresentationEvent(item.Kind)) retained.Add(item);
            foreach (var item in retained) Events.Enqueue(item);
        }
        public void EmitStructured(object value)
        {
            PSObject envelope = PSObject.AsPSObject(value);
            object version = envelope.Properties["Version"]?.Value;
            if (version != null && Convert.ToInt32(version, CultureInfo.InvariantCulture) != 1)
                throw new InvalidOperationException("Unsupported UI event schema version.");
            string type = envelope.Properties["Type"]?.Value as string;
            string name = envelope.Properties["Name"]?.Value as string;
            object data = envelope.Properties["Data"]?.Value;
            if (String.IsNullOrWhiteSpace(type) || String.IsNullOrWhiteSpace(name))
                throw new InvalidOperationException("Invalid UI event: Type and Name are required.");
            switch (type)
            {
                case "Rows": case "Summary": case "Artifact": case "Stage":
                case "Choice": case "ScriptChoices": case "Outcome": case "OperationSummary": case "GraphSession": break;
                case "Session":
                    OwnedSession = PSObject.AsPSObject(data).BaseObject as PSSession;
                    if (OwnedSession == null) throw new InvalidOperationException("Invalid remote session event.");
                    Emit("Stage", "Remote session", "Remote session created.");
                    return;
                default: throw new InvalidOperationException("Unsupported UI event: " + type);
            }
            if (PrepareReportTables && (type == "Rows" || type == "Summary"))
            {
                if (IsStopping) return;
                data = new PreparedReport(name, data, this);
            }
            Emit(type, name, data);
        }
        public void BeginOperation()
        {
            lock (inputLock) { stopping = false; ExitCode = 0; }
        }
        public object Request(string kind, string caption, string message, string[] choices = null)
        {
            using (var request = new InputRequest(kind, caption, message, choices))
            {
                lock (inputLock)
                {
                    if (stopping) throw new PipelineStoppedException();
                    pending = request;
                    Emit("Prompt", caption, request);
                }
                try
                {
                    object answer = request.Wait();
                    if (kind == "Choice")
                        Emit("Decision", caption, choices[(int)answer]);
                    if (kind == "Credential" && answer is PSCredential credential)
                        RemoteIdentity = credential.UserName;
                    return answer;
                }
                finally { lock (inputLock) { pending = null; } }
            }
        }
        public void StopInput()
        {
            lock (inputLock) { stopping = true; pending?.Cancel(); }
        }
        public override void SetShouldExit(int exitCode)
        {
            ExitCode = exitCode;
            Emit("Exit", "Script exit code", exitCode);
        }
        public override void EnterNestedPrompt() { throw new NotSupportedException("Nested prompts are not supported."); }
        public override void ExitNestedPrompt() { throw new NotSupportedException("Nested prompts are not supported."); }
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }
        public void PushRunspace(Runspace runspace)
        {
            if (RemoteRunspace != null) throw new InvalidOperationException("Disconnect the current remote session first.");
            RemoteRunspace = runspace;
            Emit("Stage", "Remote session", "Connected. Commands will run on the remote endpoint.");
        }
        public void PopRunspace()
        {
            RemoteRunspace = null;
            Emit("Stage", "Remote session", "Remote session disconnected.");
        }
        public void ForgetSession() { OwnedSession = null; RemoteRunspace = null; RemoteIdentity = ""; }
    }

    internal sealed class DesktopHostUI : PSHostUserInterface
    {
        private readonly DesktopHost host;
        private readonly DesktopRawUI raw = new DesktopRawUI();
        public DesktopHostUI(DesktopHost host) { this.host = host; }
        public override PSHostRawUserInterface RawUI => raw;
        public override void Write(string value) { host.Emit("Activity", "Output", value); }
        public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) { Write(value); }
        public override void WriteLine(string value) { Write(value + Environment.NewLine); }
        public override void WriteErrorLine(string value) { host.Emit("Error", "Error", value); }
        public override void WriteDebugLine(string message) { host.Emit("Activity", "Debug", message); }
        public override void WriteVerboseLine(string message) { host.Emit("Activity", "Verbose", message); }
        public override void WriteWarningLine(string message) { host.Emit("Warning", "Warning", message); }
        public override void WriteProgress(long sourceId, ProgressRecord record) { host.Emit("Progress", record.Activity, record); }
        public override string ReadLine() { return (string)host.Request("Text", "Script input", "Enter the requested value (see Activity for the original prompt)."); }
        public override SecureString ReadLineAsSecureString() { return (SecureString)host.Request("Secure", "Secure input", "Enter the requested secret."); }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName)
        {
            return (PSCredential)host.Request("Credential", caption, message);
        }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName,
            PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options)
        {
            return PromptForCredential(caption, message, userName, targetName);
        }
        public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
        {
            var labels = new List<string>();
            foreach (var choice in choices) labels.Add(choice.Label.Replace("&", ""));
            return (int)host.Request("Choice", caption, message, labels.ToArray());
        }
        public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions)
        {
            var result = new Dictionary<string, PSObject>();
            foreach (var field in descriptions)
            {
                object value;
                if (field.ParameterTypeFullName == typeof(PSCredential).FullName)
                    value = PromptForCredential(caption, message, null, null);
                else if (field.ParameterTypeFullName == typeof(SecureString).FullName)
                    value = host.Request("Secure", caption, message + Environment.NewLine + field.Name);
                else
                    value = host.Request("Text", caption, message + Environment.NewLine + field.Name);
                result[field.Name] = PSObject.AsPSObject(value);
            }
            return result;
        }
    }

    internal sealed class DesktopRawUI : PSHostRawUserInterface
    {
        public override ConsoleColor BackgroundColor { get; set; } = ConsoleColor.Black;
        public override ConsoleColor ForegroundColor { get; set; } = ConsoleColor.White;
        public override Size BufferSize { get; set; } = new Size(160, 300);
        public override Coordinates CursorPosition { get; set; }
        public override int CursorSize { get; set; } = 1;
        public override bool KeyAvailable => false;
        public override Size MaxPhysicalWindowSize => new Size(160, 60);
        public override Size MaxWindowSize => new Size(160, 60);
        public override Coordinates WindowPosition { get; set; }
        public override Size WindowSize { get; set; } = new Size(160, 60);
        public override string WindowTitle { get; set; } = "Endpoint Toolbox";
        public override void FlushInputBuffer() { }
        public override BufferCell[,] GetBufferContents(Rectangle rectangle) { throw new NotSupportedException("Terminal buffers are not supported."); }
        public override KeyInfo ReadKey(ReadKeyOptions options) { throw new NotSupportedException("Raw terminal key input is not supported."); }
        public override void ScrollBufferContents(Rectangle source, Coordinates destination, Rectangle clip, BufferCell fill) { throw new NotSupportedException(); }
        public override void SetBufferContents(Coordinates origin, BufferCell[,] contents) { throw new NotSupportedException(); }
        public override void SetBufferContents(Rectangle rectangle, BufferCell fill) { throw new NotSupportedException(); }
    }

    public sealed class DesktopEngine : IDisposable
    {
        public const int PresentationVersion = 10;
        public DesktopHost Host { get; } = new DesktopHost();
        private readonly Runspace local;
        private PowerShell pipeline;
        private IAsyncResult invocation;
        private bool cancelling;
        private bool disconnecting;
        private readonly object timingLock = new object();
        private readonly Stopwatch runtime = new Stopwatch();
        private DateTime startedUtc;
        private DateTime? finishedUtc;
        public DateTime StartedUtc { get { lock (timingLock) { return startedUtc; } } }
        public DateTime? FinishedUtc { get { lock (timingLock) { return finishedUtc; } } }
        public TimeSpan Elapsed { get { lock (timingLock) { return runtime.Elapsed; } } }
        public bool Busy => invocation != null;
        public bool HasErrors { get; private set; }
        public bool HasWarnings { get; private set; }
        public bool CapturePipelineObjects { get; set; } = true;
        public bool FormatPipelineOutput { get; set; }
        public bool SuppressScriptObjectOutput { get; set; }
        public string LastState { get; private set; } = "Idle";
        public bool Connected => Host.RemoteRunspace != null &&
            Host.RemoteRunspace.RunspaceStateInfo.State == RunspaceState.Opened;
        public DesktopEngine()
        {
            local = RunspaceFactory.CreateRunspace(Host);
            Host.LocalRunspace = local;
            local.ApartmentState = ApartmentState.STA;
            local.ThreadOptions = PSThreadOptions.ReuseThread;
            local.Open();
        }
        private void Prepare(bool remote)
        {
            if (Busy) throw new InvalidOperationException("Another operation is running.");
            if (local.RunspaceStateInfo.State != RunspaceState.Opened)
                throw new InvalidOperationException("Worker is unavailable. Restart the application to reset it.");
            if (remote && !Connected) throw new InvalidOperationException("No connected remote session. Commands will not run locally.");
            Host.BeginOperation();
            HasErrors = false; HasWarnings = false; cancelling = false; LastState = "Running";
            pipeline = PowerShell.Create();
            pipeline.Runspace = remote ? Host.RemoteRunspace : local;
            pipeline.Streams.Error.DataAdded += (s, e) => { HasErrors = true; Host.Emit("Error", "PowerShell error", pipeline.Streams.Error[e.Index]); };
            pipeline.Streams.Warning.DataAdded += (s, e) => { HasWarnings = true; };
            pipeline.Streams.Verbose.DataAdded += (s, e) => Host.Emit("Activity", "Verbose", pipeline.Streams.Verbose[e.Index]);
            pipeline.Streams.Debug.DataAdded += (s, e) => Host.Emit("Activity", "Debug", pipeline.Streams.Debug[e.Index]);
            pipeline.Streams.Information.DataAdded += (s, e) =>
            {
                var record = pipeline.Streams.Information[e.Index];
                if (!record.Tags.Contains("PSHOST")) Host.Emit("Activity", "Information", record.MessageData);
            };
            pipeline.Streams.Progress.DataAdded += (s, e) => Host.Emit("Progress", pipeline.Streams.Progress[e.Index].Activity, pipeline.Streams.Progress[e.Index]);
        }
        private void Start(bool suppressObjects = false)
        {
            if (suppressObjects)
                pipeline.AddCommand("Microsoft.PowerShell.Core\\Where-Object")
                    .AddParameter("FilterScript", ScriptBlock.Create("$_ -is [string]"));
            if (FormatPipelineOutput)
                pipeline.AddCommand("Microsoft.PowerShell.Utility\\Out-String").AddParameter("Stream").AddParameter("Width", 180);
            var output = new PSDataCollection<PSObject>();
            output.DataAdded += (s, e) =>
            {
                var value = output[e.Index];
                if (CapturePipelineObjects || value.BaseObject is string)
                    Host.Emit("Output", "Pipeline", value);
            };
            lock (timingLock)
            {
                startedUtc = DateTime.UtcNow;
                finishedUtc = null;
                runtime.Restart();
            }
            pipeline.InvocationStateChanged += (sender, args) =>
            {
                if (args.InvocationStateInfo.State == PSInvocationState.Completed ||
                    args.InvocationStateInfo.State == PSInvocationState.Failed ||
                    args.InvocationStateInfo.State == PSInvocationState.Stopped)
                {
                    lock (timingLock)
                    {
                        runtime.Stop();
                        finishedUtc = DateTime.UtcNow;
                    }
                }
            };
            invocation = pipeline.BeginInvoke<PSObject, PSObject>(null, output);
        }
        public void RunFile(string path, Hashtable arguments, bool withSink)
        {
            RunFile(path, arguments, withSink, Array.Empty<string>());
        }
        public void RunFile(string path, Hashtable arguments, bool withSink, string[] requiredCommands)
        {
            Token[] tokens;
            ParseError[] parseErrors;
            var ast = Parser.ParseFile(path, out tokens, out parseErrors);
            if (parseErrors.Length != 0) throw new InvalidOperationException("The selected script does not parse.");
            if (ast.ParamBlock != null)
                foreach (var parameter in ast.ParamBlock.Parameters)
                    if (parameter.Name.VariablePath.UserPath.Equals("CancellationCheck", StringComparison.OrdinalIgnoreCase))
                        arguments["CancellationCheck"] = new Func<bool>(() => Host.IsStopping);
            bool capturesExitCode = ast.Find(node => node is ExitStatementAst, true) != null;
            if (arguments.ContainsKey("ScriptPath")) {
                string businessPath = LanguagePrimitives.ConvertTo<string>(arguments["ScriptPath"]);
                var businessAst = Parser.ParseFile(businessPath, out tokens, out parseErrors);
                if (parseErrors.Length != 0) throw new InvalidOperationException("The business script does not parse.");
                capturesExitCode = businessAst.Find(node => node is ExitStatementAst, true) != null;
            }
            Prepare(false);
            const string script = @"param($path,$arguments,$bridge,$withSink,$capturesExitCode,$requiredCommands)
foreach ($command in $requiredCommands) {
    try { $null = Get-Command -Name $command -ErrorAction Stop }
    catch { throw ""Required command '$command' is unavailable in the desktop worker. Check your Microsoft Graph installation for this PowerShell version. Command discovery failed: $($_.Exception.Message)"" }
}
if ($withSink) {
    $sink = { param($event) $bridge.EmitStructured($event) }.GetNewClosure()
    $arguments['UiEventSink'] = $sink
}
$global:LASTEXITCODE = 0
try { & $path @arguments }
finally {
    if ($capturesExitCode -and $LASTEXITCODE -ne 0) { $bridge.SetShouldExit([int]$LASTEXITCODE) }
    if (Get-Command Get-MgContext -ErrorAction Ignore) {
        $context = Get-MgContext
        if ($context) { $bridge.Emit('Context', 'Graph context', $context) }
    }
}";
            pipeline.AddScript(script).AddArgument(path).AddArgument(arguments).AddArgument(Host).AddArgument(withSink).AddArgument(capturesExitCode).AddArgument(requiredCommands);
            Start(SuppressScriptObjectOutput);
        }
        public void RunCommand(string command)
        {
            Prepare(true);
            pipeline.AddScript(command);
            Start();
        }
        public void Disconnect()
        {
            Prepare(false);
            var session = Host.OwnedSession;
            if (Host.IsRunspacePushed) Host.PopRunspace();
            if (session != null) pipeline.AddCommand("Remove-PSSession").AddParameter("Session", session).AddParameter("ErrorAction", "Stop");
            else pipeline.AddScript("'No application-owned remote session remains.'");
            disconnecting = true;
            Start();
        }
        public void Cancel()
        {
            if (cancelling) return;
            cancelling = true;
            LastState = "Cancelling";
            Host.StopInput();
            Host.DiscardPendingPresentationEvents();
            if (Busy) pipeline.BeginStop(null, null);
            else LastState = "Cancelled";
        }
        public bool Poll()
        {
            if (invocation == null || !invocation.IsCompleted) return false;
            try { pipeline.EndInvoke(invocation); }
            catch (PipelineStoppedException) { cancelling = true; }
            catch (Exception ex) { HasErrors = true; Host.Emit("Error", "Invocation failed", ex.Message); }
            finally
            {
                HasErrors = HasErrors || Host.ExitCode != 0;
                if (disconnecting && !HasErrors) Host.ForgetSession();
                disconnecting = false;
                LastState = cancelling ? "Cancelled" : HasErrors ? "Partial failure / failed" : HasWarnings ? "Completed with warnings" : "Completed";
                Host.Emit("Complete", LastState, Host.ExitCode);
                pipeline.Dispose(); pipeline = null; invocation = null;
            }
            return true;
        }
        public void Dispose()
        {
            Host.StopInput();
            if (pipeline != null) { pipeline.Stop(); pipeline.Dispose(); }
            try
            {
                if (Host.OwnedSession != null)
                {
                    using (var cleanup = PowerShell.Create())
                    {
                        cleanup.Runspace = local;
                        cleanup.AddCommand("Remove-PSSession").AddParameter("Session", Host.OwnedSession).Invoke();
                        if (cleanup.HadErrors) throw new InvalidOperationException("Remote session cleanup failed: " + cleanup.Streams.Error[0]);
                    }
                }
            }
            finally { local.Dispose(); }
        }
    }
}
