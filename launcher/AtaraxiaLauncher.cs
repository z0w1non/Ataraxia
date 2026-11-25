using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class AtaraxiaLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(root, "scripts", "Start-AtaraxiaGui.ps1");
            if (!File.Exists(script))
                throw new FileNotFoundException("The Ataraxia GUI script was not found beside this launcher.", script);

            string shell = FindPowerShell();
            if (shell == null)
                throw new FileNotFoundException("PowerShell 7 (pwsh.exe) or Windows PowerShell (powershell.exe) is required.");

            var command = new StringBuilder();
            // WPF requires STA. Starting the script directly in STA also avoids
            // a hidden PowerShell process exiting before its self-relaunch.
            command.Append("-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File ");
            command.Append(QuoteArgument(script));
            foreach (string arg in args)
            {
                command.Append(' ');
                command.Append(QuoteArgument(arg));
            }

            var start = new ProcessStartInfo
            {
                FileName = shell,
                Arguments = command.ToString(),
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            var childErrors = new StringBuilder();
            start.RedirectStandardError = true;
            start.RedirectStandardOutput = true;
            using (Process child = Process.Start(start))
            {
                if (child == null)
                    throw new InvalidOperationException("PowerShell could not be started.");
                child.ErrorDataReceived += (sender, eventArgs) =>
                {
                    if (eventArgs.Data != null) childErrors.AppendLine(eventArgs.Data);
                };
                child.BeginErrorReadLine();
                child.BeginOutputReadLine();
                child.WaitForExit();
                if (child.ExitCode != 0)
                {
                    child.WaitForExit();
                    string details = childErrors.ToString().Trim();
                    throw new InvalidOperationException("PowerShell: " + shell + Environment.NewLine +
                        "The Ataraxia GUI closed with an error (exit code " + child.ExitCode + ")." +
                        (details.Length == 0 ? "" : Environment.NewLine + Environment.NewLine + details));
                }
                return 0;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Ataraxia", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static string FindPowerShell()
    {
        string path = Environment.GetEnvironmentVariable("PATH") ?? "";
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string[] names = { "pwsh.exe", "powershell.exe" };
        foreach (string name in names)
        {
            foreach (string directory in path.Split(Path.PathSeparator))
            {
                if (String.IsNullOrWhiteSpace(directory)) continue;
                string candidate = Path.Combine(directory.Trim('"'), name);
                if (File.Exists(candidate)) return candidate;
            }
        }

        string windowsPowerShell = Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        return File.Exists(windowsPowerShell) ? windowsPowerShell : null;
    }

    private static string QuoteArgument(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0)
            return value;

        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char ch in value)
        {
            if (ch == '\\')
            {
                slashes++;
                continue;
            }
            if (ch == '"')
            {
                result.Append('\\', slashes * 2 + 1);
                result.Append('"');
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes);
            slashes = 0;
            result.Append(ch);
        }
        result.Append('\\', slashes * 2);
        result.Append('"');
        return result.ToString();
    }
}
