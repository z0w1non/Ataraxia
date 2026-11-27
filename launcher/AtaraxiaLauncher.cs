using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class AtaraxiaLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        string errorLogPath = null;
        var childErrors = new StringBuilder();
        var childOutput = new StringBuilder();
        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            errorLogPath = CreateErrorLogPath(false);
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
            start.EnvironmentVariables["ATARAXIA_ERROR_LOG_PATH"] = errorLogPath;
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
                child.OutputDataReceived += (sender, eventArgs) =>
                {
                    if (eventArgs.Data != null) childOutput.AppendLine(eventArgs.Data);
                };
                child.BeginErrorReadLine();
                child.BeginOutputReadLine();
                child.WaitForExit();
                if (child.ExitCode != 0)
                {
                    child.WaitForExit();
                    string details = childErrors.ToString().Trim();
                    string standardOutput = childOutput.ToString().Trim();
                    if (standardOutput.Length > 0)
                        details += (details.Length == 0 ? "" : Environment.NewLine + Environment.NewLine) + "PowerShell output:" + Environment.NewLine + standardOutput;
                    string logContents = "=== Ataraxia GUI process failure ===" + Environment.NewLine +
                        "Timestamp (UTC): " + DateTime.UtcNow.ToString("o") + Environment.NewLine +
                        "PowerShell: " + shell + Environment.NewLine +
                        "Exit code: " + child.ExitCode + Environment.NewLine + Environment.NewLine +
                        "--- Standard Output ---" + Environment.NewLine + childOutput + Environment.NewLine +
                        "--- Standard Error ---" + Environment.NewLine + childErrors;
                    errorLogPath = WriteErrorLog(errorLogPath, logContents);
                    if (errorLogPath != null) start.EnvironmentVariables["ATARAXIA_ERROR_LOG_PATH"] = errorLogPath;
                    throw new InvalidOperationException("PowerShell: " + shell + Environment.NewLine +
                        "The Ataraxia GUI closed with an error (exit code " + child.ExitCode + ")." +
                        Environment.NewLine + "Log file: " + (errorLogPath ?? "Could not create a log file.") +
                        (details.Length == 0 ? "" : Environment.NewLine + Environment.NewLine + details));
                }
                return 0;
            }
        }
        catch (Exception ex)
        {
            string logEntry = "=== Ataraxia launcher exception ===" + Environment.NewLine +
                "Timestamp (UTC): " + DateTime.UtcNow.ToString("o") + Environment.NewLine +
                ex.ToString() + Environment.NewLine +
                "--- Captured PowerShell Standard Output ---" + Environment.NewLine + childOutput + Environment.NewLine +
                "--- Captured PowerShell Standard Error ---" + Environment.NewLine + childErrors + Environment.NewLine;
            errorLogPath = WriteErrorLog(errorLogPath, logEntry);
            if (errorLogPath != null)
            {
                try
                {
                    File.AppendAllText(errorLogPath, "--- Launcher Exception ---" + Environment.NewLine + ex.ToString() + Environment.NewLine,
                        new UTF8Encoding(false));
                }
                catch (Exception) { }
            }
            return 1;
        }
    }

    private static string CreateErrorLogPath(bool useTemporaryDirectory)
    {
        string baseDirectory = useTemporaryDirectory
            ? Path.GetTempPath()
            : Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (String.IsNullOrWhiteSpace(baseDirectory)) baseDirectory = Path.GetTempPath();
        string logDirectory = Path.Combine(baseDirectory, "Ataraxia", "logs");
        string fileName = "gui-startup-" + DateTime.UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + Guid.NewGuid().ToString("N") + ".log";
        return Path.Combine(logDirectory, fileName);
    }

    private static string WriteErrorLog(string preferredPath, string contents)
    {
        var candidates = new List<string>();
        if (!String.IsNullOrWhiteSpace(preferredPath)) candidates.Add(preferredPath);
        string localPath = CreateErrorLogPath(false);
        if (!candidates.Contains(localPath)) candidates.Add(localPath);
        string temporaryPath = CreateErrorLogPath(true);
        if (!candidates.Contains(temporaryPath)) candidates.Add(temporaryPath);

        foreach (string candidate in candidates)
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(candidate));
                File.AppendAllText(candidate, contents + Environment.NewLine + Environment.NewLine, new UTF8Encoding(false));
                return candidate;
            }
            catch (Exception)
            {
                // Continue to the next per-user or temporary fallback location.
            }
        }
        return null;
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
