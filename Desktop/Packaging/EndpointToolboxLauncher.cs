using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Endpoint Toolbox")]
[assembly: System.Reflection.AssemblyProduct("Endpoint Toolbox")]

internal static class EndpointToolboxLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        bool diagnostic = args.Length == 1 && (args[0] == "-ValidateOnly" || args[0] == "-SmokeTest");
        try
        {
            if (args.Length != 0 && !diagnostic)
                throw new ArgumentException("Supported arguments: -ValidateOnly or -SmokeTest.");

            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(root, "Desktop", "Start-EndpointToolboxUI.ps1");
            if (!File.Exists(script))
                throw new FileNotFoundException("The app files are missing. Extract the entire Endpoint Toolbox ZIP before launching.");

            string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string pwsh = Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe");
            if (!File.Exists(pwsh))
                throw new FileNotFoundException("IT-managed PowerShell 7.6 or newer is required. Expected: " + pwsh);
            FileVersionInfo version = FileVersionInfo.GetVersionInfo(pwsh);
            if (new Version(version.FileMajorPart, version.FileMinorPart) < new Version(7, 6))
                throw new InvalidOperationException("PowerShell 7.6 or newer is required. Installed version: " + version.FileVersion);

            string arguments = "-NoLogo -NoProfile -STA -File \"" + script + "\"";
            if (diagnostic)
                arguments += " " + args[0];

            using (Process child = Process.Start(new ProcessStartInfo(pwsh, arguments)
            {
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardError = !diagnostic
            }))
            {
                Task<string> errors = diagnostic ? null : child.StandardError.ReadToEndAsync();
                child.WaitForExit();
                if (!diagnostic && child.ExitCode != 0)
                {
                    string detail = errors.GetAwaiter().GetResult().Trim();
                    if (detail.Length > 1200)
                        detail = detail.Substring(0, 1200) + "...";
                    throw new InvalidOperationException("PowerShell exited with code " + child.ExitCode + "."
                        + (detail.Length == 0 ? "" : Environment.NewLine + detail));
                }
                return child.ExitCode;
            }
        }
        catch (Exception error)
        {
            if (!diagnostic)
                MessageBox.Show(error.Message, "Endpoint Toolbox could not start", MessageBoxButtons.OK, MessageBoxIcon.Error);
            else
                Console.Error.WriteLine(error.Message);
            return 1;
        }
    }
}
