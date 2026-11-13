// Alter.exe: starts Alter (Alter.ps1, next to this exe) in Windows PowerShell 5.1 without a console window.
// Build (C# 5, .NET Framework 4):
//   csc /target:winexe /win32icon:logo\alter.ico /out:Alter.exe src\AlterLauncher.cs
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Alter")]
[assembly: AssemblyProduct("Alter")]
[assembly: AssemblyDescription("Separate copies of any Windows app")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace AlterApp
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(dir, "Alter.ps1");
            if (!File.Exists(script))
            {
                MessageBox.Show(
                    "Alter.ps1 is missing.\n\nKeep Alter.exe in the same folder as Alter.ps1 and the fonts folder " +
                    "(extract the whole Alter.zip, then start Alter.exe from that folder).",
                    "Alter", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }

            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                                             @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell))
            {
                MessageBox.Show("Windows PowerShell 5.1 was not found at\n" + powershell +
                                "\n\nAlter needs Windows 10 or 11.", "Alter", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }

            ProcessStartInfo psi = new ProcessStartInfo(powershell,
                "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;          // no console window at all, not even a flash
            psi.WorkingDirectory = dir;
            psi.EnvironmentVariables["ALTER_EXE"] = Application.ExecutablePath;   // Alter points its Start Menu entry here

            try { Process.Start(psi); }
            catch (Exception ex)
            {
                MessageBox.Show("Could not start Alter:\n\n" + ex.Message, "Alter", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            return 0;
        }
    }
}
