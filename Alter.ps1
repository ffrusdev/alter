<#
  Alter - run several independent copies of the same Windows app.

  Each instance gets:
    * its own launcher .exe (with its own name + icon) in %LOCALAPPDATA%\ParallWin\<Name>\
      (the folder keeps its original name so copies made before the rename keep working)
    * its own data folder (<Name>\data) so logins/settings stay separate
    * its own taskbar button (the launcher tags the app's windows with a unique AppUserModelID)
    * optional Desktop / Start Menu shortcuts

  Usage
    GUI:  double-click "Start Alter.cmd" (or use the Alter shortcut in the Start Menu)
    CLI:  .\Alter.ps1 -Name "Slack Work" -Target "C:\...\slack.exe" [-Icon pic.png] [-Mode Auto|Chromium|Firefox|Redirect|None]

  Requires Windows 10/11 with the built-in Windows PowerShell 5.1 (it compiles the launchers with the
  .NET Framework C# compiler that ships with Windows). Running it from PowerShell 7 re-launches it in 5.1.
#>
[CmdletBinding()]
param(
    [string]$Name,
    [string]$Target,
    [string]$Icon,
    [ValidateSet('Auto', 'Chromium', 'Firefox', 'Redirect', 'None')][string]$Mode = 'Auto',
    [string]$Arguments,
    [switch]$NoDesktopShortcut,
    [switch]$ListApps          # print the apps in the Start Menu with their Works / Might work / Won't work verdict
)
$ErrorActionPreference = 'Stop'

# The GUI runs with a hidden console, so show startup errors in a message box instead of losing them.
trap {
    $msg = $_.Exception.Message
    try {
        $ii = $_.InvocationInfo
        if ($ii -and $ii.ScriptLineNumber) { $msg += "`n`n(line $($ii.ScriptLineNumber): $($ii.Line.Trim()))" }
    }
    catch { }
    if ($Name -and $Target) { [Console]::Error.WriteLine("Alter: $msg"); exit 1 }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show("Alter hit an error:`n`n$msg", 'Alter', 'OK', 'Error')
    } catch { }
    exit 1
}

# --- PowerShell 7 can't compile .NET Framework exes; hand over to Windows PowerShell 5.1 -------------
if ($PSVersionTable.PSEdition -eq 'Core') {
    $pass = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath)
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v) { $pass += "-$k" } }
        else { $pass += "-$k"; $pass += [string]$v }
    }
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @pass
    exit $LASTEXITCODE
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root = Join-Path $env:LOCALAPPDATA 'ParallWin'
$StartMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Alter'
New-Item -ItemType Directory -Force -Path $Root | Out-Null

# Before the rename to Alter, the copies' Start Menu shortcuts lived in Programs\Parall-Win: move them once.
# (Only the shortcut files move; they still point at the same launchers, so nothing else changes.)
$OldStartMenuDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Parall-Win'
if (Test-Path -LiteralPath $OldStartMenuDir) {
    try {
        New-Item -ItemType Directory -Force -Path $StartMenuDir | Out-Null
        Get-ChildItem -LiteralPath $OldStartMenuDir -Filter *.lnk | ForEach-Object {
            Move-Item -LiteralPath $_.FullName -Destination (Join-Path $StartMenuDir $_.Name) -Force
        }
        Remove-Item -LiteralPath $OldStartMenuDir -Recurse -Force
    }
    catch { }
}

# =====================================================================================================
#  Launcher source (C# 5 - compiled once per instance into <Name>.exe)
# =====================================================================================================
$LauncherSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace ParallWin
{
    internal sealed class Config
    {
        public string Name = "Instance";
        public string Target = "";
        public string Args = "";
        public string Aumid = "ParallWin.Instance";
        public bool Taskbar = true;
        public List<KeyValuePair<string, string>> Env = new List<KeyValuePair<string, string>>();

        public static Config Load(string path)
        {
            Config c = new Config();
            foreach (string raw in File.ReadAllLines(path))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                string key = line.Substring(0, eq).Trim();
                string val = line.Substring(eq + 1);
                if (key.StartsWith("env:", StringComparison.OrdinalIgnoreCase))
                {
                    c.Env.Add(new KeyValuePair<string, string>(key.Substring(4), val));
                    continue;
                }
                switch (key.ToLowerInvariant())
                {
                    case "name": c.Name = val; break;
                    case "target": c.Target = val; break;
                    case "args": c.Args = val; break;
                    case "aumid": c.Aumid = val; break;
                    case "taskbar": c.Taskbar = val.Trim() == "1"; break;
                }
            }
            return c;
        }
    }

    internal static class Program
    {
        [STAThread]
        private static int Main(string[] argv)
        {
            string self = System.Reflection.Assembly.GetExecutingAssembly().Location;
            string dir = Path.GetDirectoryName(self);
            Config cfg;
            try { cfg = Config.Load(Path.Combine(dir, "config.txt")); }
            catch (Exception ex) { Fail("Could not read config.txt next to this launcher.\n\n" + ex.Message); return 1; }

            if (argv.Length >= 2 && argv[0] == "--shortcut")
            {
                try { Shell.CreateShortcut(argv[1], self, dir, cfg.Name, cfg.Aumid); return 0; }
                catch { return 2; }
            }

            try { return Run(cfg, dir, self, argv); }
            catch (Exception ex) { Fail(ex.Message); return 1; }
        }

        private static void Fail(string msg)
        {
            MessageBox.Show(msg, "Alter", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        private static string Expand(string s, string data)
        {
            if (string.IsNullOrEmpty(s)) return "";
            return Environment.ExpandEnvironmentVariables(s.Replace("{DATA}", data));
        }

        // Standard Windows (CommandLineToArgvW) quoting, so e.g. "C:\some dir\" survives intact.
        private static string Quote(string a)
        {
            if (a.Length > 0 && a.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) return a;
            StringBuilder sb = new StringBuilder("\"");
            int slashes = 0;
            foreach (char ch in a)
            {
                if (ch == '\\') { slashes++; continue; }
                if (ch == '"') sb.Append('\\', slashes * 2 + 1);
                else sb.Append('\\', slashes);
                slashes = 0;
                sb.Append(ch);
            }
            sb.Append('\\', slashes * 2);
            return sb.Append('"').ToString();
        }

        // Squirrel-installed apps (Discord, Slack, ...) live in ...\app-1.2.3\x.exe and move on update.
        // Always pick the newest app-* folder that still contains the exe.
        private static string ResolveTarget(string target)
        {
            string parent = Path.GetDirectoryName(target);
            if (parent == null) return target;
            if (!Path.GetFileName(parent).StartsWith("app-", StringComparison.OrdinalIgnoreCase)) return target;
            string root = Path.GetDirectoryName(parent);
            if (root == null || !Directory.Exists(root)) return target;
            string exeName = Path.GetFileName(target);
            string best = null;
            Version bestV = null;
            foreach (string d in Directory.GetDirectories(root, "app-*"))
            {
                Version v;
                if (!Version.TryParse(Path.GetFileName(d).Substring(4), out v)) continue;
                string candidate = Path.Combine(d, exeName);
                if (!File.Exists(candidate)) continue;
                if (bestV == null || v > bestV) { bestV = v; best = candidate; }
            }
            return best ?? target;
        }

        private static int Run(Config cfg, string dir, string self, string[] argv)
        {
            string data = Path.Combine(dir, "data");
            Directory.CreateDirectory(Path.Combine(data, "profile"));

            string target = ResolveTarget(Expand(cfg.Target, data));
            if (!File.Exists(target)) throw new FileNotFoundException("Target app not found:\n" + target);

            StringBuilder args = new StringBuilder(Expand(cfg.Args, data));
            foreach (string a in argv) args.Append(' ').Append(Quote(a));   // pass through files/URLs

            ProcessStartInfo psi = new ProcessStartInfo(target, args.ToString().Trim());
            psi.UseShellExecute = false;
            psi.WorkingDirectory = Path.GetDirectoryName(target);
            foreach (KeyValuePair<string, string> kv in cfg.Env)
            {
                string v = Expand(kv.Value, data);
                if (v.StartsWith(data, StringComparison.OrdinalIgnoreCase)) Directory.CreateDirectory(v);
                psi.EnvironmentVariables[kv.Key] = v;
            }

            Process p = Process.Start(psi);
            if (p == null || !cfg.Taskbar) return 0;
            TaskbarTagger.Watch(p.Id, cfg, self);
            return 0;
        }
    }

    // Keeps running (tiny, idle most of the time) while the app runs, giving each of its top-level
    // windows this instance's AppUserModelID so Windows shows it as its own taskbar button.
    internal static class TaskbarTagger
    {
        // Windows reuses process IDs quickly, so a PID alone does not identify a process. Both maps hold
        // pid -> parent pid, and an entry only stays valid while that PID still has the same parent.
        // Exited processes are dropped right away, so a recycled PID never keeps the launcher alive.
        private static bool Same(Dictionary<int, int> map, int pid, int parent)
        {
            int p;
            return map.TryGetValue(pid, out p) && p == parent;
        }

        public static void Watch(int rootPid, Config cfg, string self)
        {
            Dictionary<int, int> tree = new Dictionary<int, int>();       // the app's processes
            tree[rootPid] = Process.GetCurrentProcess().Id;
            Dictionary<int, int> foreign = new Dictionary<int, int>();    // processes seen outside the app
            HashSet<IntPtr> tagged = new HashSet<IntPtr>();
            DateTime start = DateTime.UtcNow;

            while (true)
            {
                Dictionary<int, int> procs = Native.SnapshotParents();
                Track(tree, foreign, procs);
                if (tree.Count == 0) return;

                List<IntPtr> dead = new List<IntPtr>();
                foreach (IntPtr h in tagged) { if (!Native.IsWindow(h)) dead.Add(h); }
                foreach (IntPtr h in dead) tagged.Remove(h);

                Native.EnumWindows(delegate(IntPtr h, IntPtr l)
                {
                    if (tagged.Contains(h)) return true;
                    if (!Native.IsWindowVisible(h)) return true;
                    if (Native.GetWindow(h, 4 /* GW_OWNER */) != IntPtr.Zero) return true;
                    uint wpid;
                    Native.GetWindowThreadProcessId(h, out wpid);
                    if (!tree.ContainsKey((int)wpid)) return true;
                    if (Shell.TagWindow(h, cfg, self)) tagged.Add(h);
                    return true;
                }, IntPtr.Zero);

                Thread.Sleep((DateTime.UtcNow - start).TotalSeconds < 30 ? 300 : 1500);
            }
        }

        // Updates the app's process tree from a fresh snapshot (pid -> parent pid).
        internal static void Track(Dictionary<int, int> tree, Dictionary<int, int> foreign, Dictionary<int, int> procs)
        {
            // 1. Forget PIDs that now belong to a different process (same PID, different parent).
            List<int> drop = new List<int>();
            foreach (KeyValuePair<int, int> kv in tree)
            {
                int parent;
                if (procs.TryGetValue(kv.Key, out parent) && parent != kv.Value) drop.Add(kv.Key);
            }
            foreach (int pid in drop) tree.Remove(pid);

            // 2. Adopt new children. Exited members still count as parents here, so a child whose
            //    parent has just quit (e.g. a Squirrel stub like slack.exe) is still found.
            bool grew = true;
            while (grew)
            {
                grew = false;
                foreach (KeyValuePair<int, int> kv in procs)
                {
                    if (tree.ContainsKey(kv.Key) || Same(foreign, kv.Key, kv.Value)) continue;
                    if (tree.ContainsKey(kv.Value)) { tree[kv.Key] = kv.Value; grew = true; }
                }
            }

            // 3. Drop exited processes; remember everything else as foreign so it is never adopted
            //    later just because its (long gone) parent's PID got reused by one of ours.
            drop.Clear();
            foreach (int pid in tree.Keys) { if (!procs.ContainsKey(pid)) drop.Add(pid); }
            foreach (int pid in drop) tree.Remove(pid);
            foreign.Clear();
            foreach (KeyValuePair<int, int> kv in procs) { if (!tree.ContainsKey(kv.Key)) foreign[kv.Key] = kv.Value; }
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;
        public PropertyKey(Guid g, uint p) { fmtid = g; pid = p; }
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    internal struct PropVariant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr ptr;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    internal class CShellLink { }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        void Resolve(IntPtr hwnd, uint fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    internal static class Shell
    {
        // PKEY_AppUserModel_*: 2 RelaunchCommand, 3 RelaunchIconResource, 4 RelaunchDisplayNameResource, 5 ID
        private static readonly Guid AppUserModelFmt = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

        private static void SetString(IPropertyStore ps, uint pid, string value)
        {
            PropertyKey key = new PropertyKey(AppUserModelFmt, pid);
            PropVariant pv = new PropVariant();
            pv.vt = 31; // VT_LPWSTR
            pv.ptr = Marshal.StringToCoTaskMemUni(value);
            try
            {
                int hr = ps.SetValue(ref key, ref pv);
                if (hr < 0) Marshal.ThrowExceptionForHR(hr);
            }
            finally { Marshal.FreeCoTaskMem(pv.ptr); }
        }

        public static bool TagWindow(IntPtr hwnd, Config cfg, string self)
        {
            IPropertyStore ps = null;
            Guid iid = typeof(IPropertyStore).GUID;
            try
            {
                if (Native.SHGetPropertyStoreForWindow(hwnd, ref iid, out ps) < 0 || ps == null) return false;
                SetString(ps, 2, "\"" + self + "\"");
                SetString(ps, 4, cfg.Name);
                SetString(ps, 3, self + ",0");
                SetString(ps, 5, cfg.Aumid);
                return true;
            }
            catch { return false; }
            finally { if (ps != null) Marshal.ReleaseComObject(ps); }
        }

        public static void CreateShortcut(string lnk, string exe, string dir, string name, string aumid)
        {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            try
            {
                link.SetPath(exe);
                link.SetWorkingDirectory(dir);
                link.SetIconLocation(exe, 0);
                link.SetDescription(name + " (Alter copy)");
                IPropertyStore ps = (IPropertyStore)link;
                SetString(ps, 5, aumid);
                int hr = ps.Commit();
                if (hr < 0) Marshal.ThrowExceptionForHR(hr);
                string folder = Path.GetDirectoryName(lnk);
                if (!string.IsNullOrEmpty(folder)) Directory.CreateDirectory(folder);
                ((IPersistFile)link).Save(lnk, true);
            }
            finally { Marshal.ReleaseComObject(link); }
        }
    }

    internal static class Native
    {
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("shell32.dll")]
        public static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ps);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PROCESSENTRY32W
        {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public IntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32W e);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32W e);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);

        public static Dictionary<int, int> SnapshotParents()
        {
            Dictionary<int, int> map = new Dictionary<int, int>();
            IntPtr snap = CreateToolhelp32Snapshot(2 /* TH32CS_SNAPPROCESS */, 0);
            if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return map;
            try
            {
                PROCESSENTRY32W e = new PROCESSENTRY32W();
                e.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                if (Process32FirstW(snap, ref e))
                {
                    do { map[(int)e.th32ProcessID] = (int)e.th32ParentProcessID; }
                    while (Process32NextW(snap, ref e));
                }
            }
            finally { CloseHandle(snap); }
            return map;
        }
    }
}
'@

# =====================================================================================================
#  App knowledge
# =====================================================================================================
$ChromiumNames = @('chrome', 'msedge', 'brave', 'vivaldi', 'opera', 'chromium', 'thorium',
    'code', 'code - insiders', 'codium', 'vscodium', 'cursor', 'windsurf',
    'slack', 'notion', 'obsidian', 'figma', 'postman', 'signal', 'element', 'mattermost', 'githubdesktop',
    'claude', 'claude-desktop')
$EditorNames = @('code', 'code - insiders', 'codium', 'vscodium', 'cursor', 'windsurf')
$FirefoxNames = @('firefox', 'thunderbird', 'librewolf', 'waterfox', 'floorp', 'zen')

$ModeHints = @{
    Chromium = 'Chromium browsers and Electron apps (Chrome, Edge, Brave, VS Code, Slack, Notion, Obsidian...). Each instance gets its own --user-data-dir, so logins and settings are separate.'
    Firefox  = 'Firefox family. Each instance gets its own profile folder, and -no-remote stops it handing off to the copy that is already open.'
    Redirect = 'Generic. Points APPDATA and LOCALAPPDATA at this instance''s folder. Works for many apps that keep settings there; apps with a hard single-instance lock will still refuse to open twice.'
    None     = 'No data separation - just a separate launcher, icon and taskbar button.'
}

function Get-BaseName([string]$exe) { [IO.Path]::GetFileNameWithoutExtension($exe).ToLowerInvariant() }

function Test-Electron([string]$exe) {
    $d = Split-Path -Parent $exe
    return (Test-Path -LiteralPath (Join-Path $d 'resources\app.asar')) -or
           (Test-Path -LiteralPath (Join-Path $d 'v8_context_snapshot.bin'))
}

function Get-AutoMode([string]$exe) {
    $b = Get-BaseName $exe
    if ($FirefoxNames -contains $b) { return 'Firefox' }
    if ($b -like 'discord*') { return 'Redirect' }
    if (($ChromiumNames -contains $b) -or (Test-Electron $exe)) { return 'Chromium' }
    return 'Redirect'
}

function Get-ModeDefaults([string]$mode, [string]$exe) {
    $b = Get-BaseName $exe
    $a = ''; $e = ''
    switch ($mode) {
        'Chromium' {
            $a = '--user-data-dir="{DATA}\profile"'
            if ($EditorNames -contains $b) { $a += ' --extensions-dir="{DATA}\extensions"' }
        }
        'Firefox'  { $a = '-profile "{DATA}\profile" -no-remote' }
        'Redirect' { $e = "APPDATA={DATA}\Roaming`r`nLOCALAPPDATA={DATA}\Local" }
    }
    if ($b -like 'discord*') { $a = ('--multi-instance ' + $a).Trim() }
    return [pscustomobject]@{ Args = $a; Env = $e }
}

# --- Microsoft Store (MSIX) apps ---------------------------------------------------------------------
# They can't be started from their install folder (C:\Program Files\WindowsApps\...), but many register
# launch aliases in %LOCALAPPDATA%\Microsoft\WindowsApps (e.g. claude-desktop.exe) that start them properly.
$AliasDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'

function Test-StoreAlias([string]$p) { [IO.Path]::GetDirectoryName($p) -ieq $AliasDir }
function Test-StoreInstallPath([string]$p) { ($p -match '\\WindowsApps\\') -and -not (Test-StoreAlias $p) }

# For a Store app path (launch alias or install-folder exe) returns:
#   Target = the launch alias to start (or $null if the app has none), Icon = the real exe (for its icon),
#   Name = the app's display name, Note = a message for the user.
# Returns $null for normal (non-Store) apps.
function Resolve-StoreApp([string]$path) {
    $isAlias = Test-StoreAlias $path
    if (-not $isAlias -and -not (Test-StoreInstallPath $path)) { return $null }

    $pkg = $null
    if ($isAlias) {
        # Each package keeps a copy of its aliases in a sub-folder named after its package family.
        $leaf = [IO.Path]::GetFileName($path)
        $fam = Get-ChildItem -LiteralPath $AliasDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $leaf) } | Select-Object -First 1
        if ($fam) { $pkg = Get-AppxPackage | Where-Object { $_.PackageFamilyName -eq $fam.Name } | Select-Object -First 1 }
        if (-not $pkg) { return [pscustomobject]@{ Target = $path; Icon = $null; Name = $null; Note = '' } }
    }
    else {
        $pkg = Get-AppxPackage | Where-Object {
            $_.InstallLocation -and $path.StartsWith($_.InstallLocation.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        if (-not $pkg) {
            return [pscustomobject]@{ Target = $null; Icon = $path; Name = $null
                Note = "This is a Microsoft Store app, which can't be started from its install folder. Install the regular desktop version of the app instead." }
        }
    }

    $xml = New-Object System.Xml.XmlDocument
    $xml.Load((Join-Path $pkg.InstallLocation 'AppxManifest.xml'))
    $name = $pkg.Name
    $dn = $xml.SelectSingleNode("//*[local-name()='Properties']/*[local-name()='DisplayName']")
    if ($dn -and $dn.InnerText -and $dn.InnerText -notlike 'ms-resource:*') { $name = $dn.InnerText }

    # Each alias runs the Executable of its <Extension>, or else of its <Application>.
    $aliases = @(foreach ($node in $xml.SelectNodes("//*[local-name()='ExecutionAlias']")) {
        $alias = $node.GetAttribute('Alias')
        if (-not $alias) { continue }
        $exe = $null; $p = $node.ParentNode
        while ($p -is [System.Xml.XmlElement]) {
            if ($p.GetAttribute('Executable')) { $exe = $p.GetAttribute('Executable'); break }
            $p = $p.ParentNode
        }
        $full = $null
        if ($exe) { $full = Join-Path $pkg.InstallLocation $exe }
        [pscustomobject]@{ Alias = $alias; Path = (Join-Path $AliasDir $alias); Exe = $full }
    })

    if ($isAlias) {
        $hit = $aliases | Where-Object { $_.Alias -ieq [IO.Path]::GetFileName($path) } | Select-Object -First 1
        $icon = $null
        if ($hit -and $hit.Exe -and (Test-Path -LiteralPath $hit.Exe)) { $icon = $hit.Exe }
        return [pscustomobject]@{ Target = $path; Icon = $icon; Name = $name; Note = '' }
    }

    # Picked the real exe: switch to the (shortest-named) alias that starts it.
    $hit = $aliases | Where-Object { $_.Exe -and ($_.Exe -ieq $path) -and (Test-Path -LiteralPath $_.Path) } |
        Sort-Object { $_.Alias.Length } | Select-Object -First 1
    if (-not $hit) {
        return [pscustomobject]@{ Target = $null; Icon = $path; Name = $name
            Note = "'$name' is a Microsoft Store app without a launch alias, so it can't be started directly. Install the regular desktop version of the app instead." }
    }
    return [pscustomobject]@{ Target = $hit.Path; Icon = $path; Name = $name; Note = "Store app: using its launch alias $($hit.Alias)." }
}

# =====================================================================================================
#  Instance storage
# =====================================================================================================
function Get-SafeName([string]$n) {
    $n = ([string]$n).Trim()
    if ($n -notmatch '^[A-Za-z0-9 _\-]{1,40}$') {
        throw 'Name must be 1-40 characters: letters, numbers, spaces, - or _.'
    }
    return $n
}

function Get-DesktopLink([string]$n) { Join-Path ([Environment]::GetFolderPath('Desktop')) "$n.lnk" }
function Get-StartLink([string]$n) { Join-Path $StartMenuDir "$n.lnk" }

function Get-Instances {
    Get-ChildItem -LiteralPath $Root -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'config.txt') } |
        Sort-Object Name | ForEach-Object { $_.Name }
}

function Read-Instance([string]$n) {
    $dir = Join-Path $Root $n
    $cfg = @{ Name = $n; Target = ''; Mode = 'Redirect'; Args = ''; Taskbar = $true; Env = @() }
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $dir 'config.txt'))) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $i = $line.IndexOf('='); $k = $line.Substring(0, $i).Trim(); $v = $line.Substring($i + 1)
        if ($k -like 'env:*') { $cfg.Env += $k.Substring(4) + '=' + $v; continue }
        switch ($k) {
            'target'  { $cfg.Target = $v }
            'mode'    { $cfg.Mode = $v }
            'args'    { $cfg.Args = $v }
            'taskbar' { $cfg.Taskbar = ($v.Trim() -eq '1') }
            'icon'    { $cfg.CustomIcon = ($v.Trim() -eq 'custom') }
        }
    }
    if (-not $cfg.ContainsKey('CustomIcon')) { $cfg.CustomIcon = $false }
    $cfg.Icon = Join-Path $dir 'icon.ico'
    $cfg.Desktop = Test-Path -LiteralPath (Get-DesktopLink $n)
    $cfg.StartMenu = Test-Path -LiteralPath (Get-StartLink $n)
    return $cfg
}

function Write-PngIco([System.Drawing.Image]$img, [string]$dst) {
    $size = [Math]::Min(256, [Math]::Max($img.Width, $img.Height))
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)
    $scale = [Math]::Min($size / $img.Width, $size / $img.Height)
    $w = [int]($img.Width * $scale); $h = [int]($img.Height * $scale)
    $g.DrawImage($img, [int](($size - $w) / 2), [int](($size - $h) / 2), $w, $h)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $png = $ms.ToArray()
    $dim = if ($size -ge 256) { 0 } else { $size }
    $bw = New-Object System.IO.BinaryWriter ([IO.File]::Create($dst))
    try {
        $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)          # ICONDIR
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([UInt16]1); $bw.Write([UInt16]32)
        $bw.Write([UInt32]$png.Length); $bw.Write([UInt32]22)                      # ICONDIRENTRY
        $bw.Write($png)
    }
    finally { $bw.Close() }
}

function Set-InstanceIcon([string]$src, [string]$target, [string]$dst) {
    if ($src -and (Test-Path -LiteralPath $src)) {
        $full = (Resolve-Path -LiteralPath $src).Path
        if ($full -ieq $dst) { return }                       # unchanged
        $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
        if ($ext -eq '.ico') { Copy-Item -LiteralPath $full -Destination $dst -Force; return }
        if ($ext -in '.png', '.jpg', '.jpeg', '.bmp', '.gif') {
            $img = [System.Drawing.Image]::FromFile($full)
            try { Write-PngIco $img $dst } finally { $img.Dispose() }
            return
        }
        $target = $full                                       # .exe/.dll: take its icon
    }
    # Store app launch aliases are empty placeholder files, so there may be no icon to take:
    # fall back to the standard program icon (pick a better one with the Icon box).
    try { $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($target) } catch { $ico = $null }
    if (-not $ico) { $ico = [System.Drawing.Icon]([System.Drawing.SystemIcons]::Application.Clone()) }
    $bmp = $ico.ToBitmap()
    try { Write-PngIco $bmp $dst } finally { $bmp.Dispose(); $ico.Dispose() }
}

function Build-Launcher([string]$dir, [string]$n) {
    $exe = Join-Path $dir "$n.exe"
    $ico = Join-Path $dir 'icon.ico'
    if (Test-Path -LiteralPath $exe) {
        try { [IO.File]::Open($exe, 'Open', 'ReadWrite', 'None').Close() }
        catch { throw "'$n' is still running. Close it, then save again." }
    }
    $cp = New-Object System.CodeDom.Compiler.CompilerParameters
    $cp.GenerateExecutable = $true
    $cp.GenerateInMemory = $false
    $cp.OutputAssembly = $exe
    foreach ($r in 'System.dll', 'System.Core.dll', 'System.Windows.Forms.dll') { [void]$cp.ReferencedAssemblies.Add($r) }
    $cp.CompilerOptions = "/target:winexe /optimize+ /win32icon:`"$ico`""
    $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
    $res = $provider.CompileAssemblyFromSource($cp, $LauncherSource)
    if ($res.Errors.HasErrors) {
        $msg = ($res.Errors | Where-Object { -not $_.IsWarning } | ForEach-Object { $_.ToString() }) -join "`n"
        throw "Launcher build failed:`n$msg"
    }
    return $exe
}

function New-InstanceShortcut([string]$exe, [string]$lnk) {
    $p = Start-Process -FilePath $exe -ArgumentList '--shortcut', "`"$lnk`"" -Wait -PassThru
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $lnk)) { throw "Could not create shortcut $lnk" }
}

function Save-Instance {
    param([string]$Name, [string]$Target, [string]$Icon, [string]$Mode, [string]$LaunchArgs,
          [string]$EnvText, [bool]$Taskbar = $true, [bool]$Desktop = $true, [bool]$StartMenu = $true)

    $Name = Get-SafeName $Name
    $Target = ([string]$Target).Trim('" ')
    if (-not (Test-Path -LiteralPath $Target) -or [IO.Path]::GetExtension($Target) -ne '.exe') {
        throw "Target must be an existing .exe file:`n$Target"
    }
    # Did the user pick their own icon? (Otherwise the app's own icon is used and Alter shows a letter tile.)
    $iconFile = Join-Path (Join-Path $Root $Name) 'icon.ico'
    $customIcon = $false
    if ($Icon -and (Test-Path -LiteralPath $Icon)) {
        if ((Resolve-Path -LiteralPath $Icon).Path -ieq $iconFile) {
            # Unchanged icon of an existing copy: keep what it was.
            try { $customIcon = (Read-Instance $Name).CustomIcon } catch { $customIcon = $true }
        }
        else { $customIcon = $true }
    }
    if ((Test-StoreAlias $Target) -or (Test-StoreInstallPath $Target)) {
        $store = $null
        try { $store = Resolve-StoreApp $Target } catch { }
        if (Test-StoreInstallPath $Target) {
            if (-not $store -or -not $store.Target) {
                $why = if ($store -and $store.Note) { $store.Note } else { "This is a Microsoft Store (MSIX) app, which can't be started from its install folder." }
                throw "$why`n`nIf it has a launch alias, pick that instead: look in`n$AliasDir`n(for example claude-desktop.exe for Claude)."
            }
            $Target = $store.Target
        }
        # Launch aliases are empty placeholder files: take the icon from the real program.
        if (-not $Icon -and $store -and $store.Icon) { $Icon = $store.Icon }
    }
    if (-not $Mode -or $Mode -eq 'Auto') { $Mode = Get-AutoMode $Target }

    $dir = Join-Path $Root $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'data') | Out-Null

    $aumid = 'ParallWin.' + ($Name -replace '[^A-Za-z0-9]', '')
    $lines = @(
        '# Alter copy. {DATA} = the data folder next to this file. Lines "env:KEY=VALUE" set environment variables.',
        "name=$Name", "target=$Target", "mode=$Mode", "args=$LaunchArgs", "aumid=$aumid", "taskbar=$([int]$Taskbar)",
        "icon=$(if ($customIcon) { 'custom' } else { 'app' })"
    )
    foreach ($l in ([string]$EnvText -split "`r?`n")) {
        $l = $l.Trim()
        if ($l -match '^[^=\s]+=') { $lines += "env:$l" }
    }
    [IO.File]::WriteAllLines((Join-Path $dir 'config.txt'), [string[]]$lines)

    Set-InstanceIcon $Icon $Target (Join-Path $dir 'icon.ico')
    $exe = Build-Launcher $dir $Name

    foreach ($pair in @(@($Desktop, (Get-DesktopLink $Name)), @($StartMenu, (Get-StartLink $Name)))) {
        if ($pair[0]) { New-InstanceShortcut $exe $pair[1] }
        elseif (Test-Path -LiteralPath $pair[1]) { Remove-Item -LiteralPath $pair[1] -Force }
    }
    return $exe
}

function Remove-Instance([string]$n) {
    $n = Get-SafeName $n
    $dir = Join-Path $Root $n
    $trash = $null
    if (Test-Path -LiteralPath $dir) {
        # Move the folder aside first. Windows refuses to move a folder while the launcher or the app
        # still has a file in it open, so a running instance is left completely intact
        # (instead of losing its shortcuts and half of its data).
        $trash = Join-Path $Root ('.trash\' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $trash) | Out-Null
        try { [IO.Directory]::Move($dir, $trash) }
        catch { throw "'$n' is still running, or a file in its folder is open. Close it, then delete again." }
    }
    foreach ($l in (Get-DesktopLink $n), (Get-StartLink $n)) {
        if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force }
    }
    if ($trash) { Remove-Item -LiteralPath $trash -Recurse -Force }
}

# Leftovers from a delete that was interrupted.
$TrashDir = Join-Path $Root '.trash'
if (Test-Path -LiteralPath $TrashDir) { Remove-Item -LiteralPath $TrashDir -Recurse -Force -ErrorAction SilentlyContinue }

# =====================================================================================================
#  Can this app be copied? (the badges in the app picker)
# =====================================================================================================
# Apps known to refuse a second copy, by program name. This is a best guess: Alter warns, it never blocks.
$LauncherReason = 'Game launchers only allow one copy at a time, and anti-cheat blocks second copies of games.'
$SyncReason = 'Sync apps only allow one copy per Windows account.'
$OfficeReason = 'Office apps share one running copy per Windows account.'
$NoCopyApps = @{
    'spotify' = 'Spotify only allows one copy running at a time.'
    'steam' = $LauncherReason; 'steamwebhelper' = $LauncherReason; 'epicgameslauncher' = $LauncherReason
    'battle.net' = $LauncherReason; 'battle.net launcher' = $LauncherReason; 'riotclientservices' = $LauncherReason
    'eadesktop' = $LauncherReason; 'origin' = $LauncherReason; 'upc' = $LauncherReason; 'ubisoftconnect' = $LauncherReason
    'galaxyclient' = $LauncherReason
    'onedrive' = $SyncReason; 'dropbox' = $SyncReason
    'winword' = $OfficeReason; 'excel' = $OfficeReason; 'powerpnt' = $OfficeReason; 'outlook' = $OfficeReason
    'onenote' = $OfficeReason; 'msaccess' = $OfficeReason; 'mspub' = $OfficeReason
}
$BrowserNames = @('chrome', 'msedge', 'brave', 'vivaldi', 'opera', 'chromium', 'thorium')

# Level ('works', 'maybe' or 'no') and a one-line reason, for the program that actually runs.
function Get-AppVerdict([string]$exe) {
    $b = Get-BaseName $exe
    if ($NoCopyApps.ContainsKey($b)) { return [pscustomobject]@{ Level = 'no'; Reason = $NoCopyApps[$b] } }
    if ($b -like 'discord*') {
        return [pscustomobject]@{ Level = 'works'; Reason = 'Discord: each copy gets its own settings folder and runs with --multi-instance.' }
    }
    $m = Get-AutoMode $exe
    if ($m -eq 'Firefox') { return [pscustomobject]@{ Level = 'works'; Reason = 'Firefox family: each copy gets its own profile.' } }
    if ($m -eq 'Chromium') {
        if ($BrowserNames -contains $b) { return [pscustomobject]@{ Level = 'works'; Reason = 'Chromium browser: each copy gets its own profile.' } }
        return [pscustomobject]@{ Level = 'works'; Reason = 'Electron app: each copy gets its own profile.' }
    }
    return [pscustomobject]@{ Level = 'maybe'; Reason = 'Not an app Alter knows: each copy gets its own settings folders. Most apps work; some refuse to open twice.' }
}

# Squirrel apps (Discord, Slack...) live in <root>\app-1.2.3\<exe>; pick the newest version folder.
function Find-SquirrelExe([string]$root, [string]$exeName) {
    $best = $null
    $bestV = $null
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue)) {
        $v = $null
        if (-not [version]::TryParse($d.Name.Substring(4), [ref]$v)) { continue }
        $c = Join-Path $d.FullName $exeName
        if (-not (Test-Path -LiteralPath $c)) { continue }
        if ($null -eq $bestV -or $v -gt $bestV) { $bestV = $v; $best = $c }
    }
    return $best
}

# Launch aliases of a Store package, with the app (Id) and real program each one starts.
function Get-PackageAliases($pkg) {
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load((Join-Path $pkg.InstallLocation 'AppxManifest.xml'))
    foreach ($node in $xml.SelectNodes("//*[local-name()='ExecutionAlias']")) {
        $alias = $node.GetAttribute('Alias')
        if (-not $alias) { continue }
        $exe = $null
        $appId = $null
        $p = $node.ParentNode
        while ($p -is [System.Xml.XmlElement]) {
            if (-not $exe -and $p.GetAttribute('Executable')) { $exe = $p.GetAttribute('Executable') }
            if ($p.LocalName -eq 'Application') { $appId = $p.GetAttribute('Id'); break }
            $p = $p.ParentNode
        }
        $full = $null
        if ($exe) { $full = Join-Path $pkg.InstallLocation $exe }
        [pscustomobject]@{ Alias = $alias; AppId = $appId; Path = (Join-Path $AliasDir $alias); Exe = $full }
    }
}

# The apps in the Start Menu: desktop apps through their shortcuts, Store apps through their launch aliases.
# Each one: Name, Target (what a copy would start), Real (the actual program, for its icon), Level, Reason.
function Get-InstalledApps {
    $list = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $winDir = $env:SystemRoot.TrimEnd('\') + '\'
    $shell = New-Object -ComObject WScript.Shell
    $menus = @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
               (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))
    foreach ($menu in $menus) {
        if (-not (Test-Path -LiteralPath $menu)) { continue }
        foreach ($lnk in @(Get-ChildItem -LiteralPath $menu -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
            if ($lnk.FullName -like '*\Programs\Alter\*' -or $lnk.Name -eq 'Alter.lnk') { continue }   # Alter and its own copies
            $label = [IO.Path]::GetFileNameWithoutExtension($lnk.Name)
            if ($label -match '(?i)uninstall|readme|read me|help|documentation|release notes|website|license|changelog|manual') { continue }
            $target = $null
            $lnkArgs = ''
            try {
                $sc = $shell.CreateShortcut($lnk.FullName)
                $target = [string]$sc.TargetPath
                $lnkArgs = [string]$sc.Arguments
            }
            catch { continue }
            if (-not $target -or [IO.Path]::GetExtension($target) -ne '.exe') { continue }
            # Squirrel apps start through Update.exe --processStart <app>.exe
            if ([IO.Path]::GetFileName($target) -eq 'Update.exe' -and $lnkArgs -match '--processStart\s+"?([^"\s]+)') {
                $target = Find-SquirrelExe (Split-Path -Parent $target) $Matches[1]
                if (-not $target) { continue }
            }
            if (-not (Test-Path -LiteralPath $target)) { continue }
            # Windows' own tools (Character Map, Disk Cleanup, consoles...) live in the Windows folder: leave them out.
            if ($target.StartsWith($winDir, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $key = $target.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $v = Get-AppVerdict $target
            $list.Add([pscustomobject]@{ Name = $label; Target = $target; Real = $target; Level = $v.Level; Reason = $v.Reason })
        }
    }
    # Microsoft Store apps (not the ones built into Windows)
    try {
        $pkgs = @{}
        foreach ($pk in @(Get-AppxPackage -ErrorAction SilentlyContinue)) {
            if (-not $pk.IsFramework -and [string]$pk.SignatureKind -ne 'System' -and $pk.InstallLocation) { $pkgs[$pk.PackageFamilyName] = $pk }
        }
        $aliasCache = @{}
        foreach ($sa in @(Get-StartApps -ErrorAction SilentlyContinue)) {
            $id = [string]$sa.AppID
            $bang = $id.IndexOf('!')
            if ($bang -lt 0) { continue }
            $pkg = $pkgs[$id.Substring(0, $bang)]
            if (-not $pkg) { continue }
            $appId = $id.Substring($bang + 1)
            $fam = $pkg.PackageFamilyName
            if (-not $aliasCache.ContainsKey($fam)) {
                $found = @()
                try { $found = @(Get-PackageAliases $pkg) } catch { }
                $aliasCache[$fam] = $found
            }
            $hits = @($aliasCache[$fam] | Where-Object { $_.AppId -eq $appId -and (Test-Path -LiteralPath $_.Path) } |
                Sort-Object { $_.Alias.Length })
            if ($hits.Count -gt 0) {
                $h = $hits[0]
                $key = $h.Path.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $real = $h.Path
                if ($h.Exe -and (Test-Path -LiteralPath $h.Exe)) { $real = $h.Exe }
                $v = Get-AppVerdict $real
                $list.Add([pscustomobject]@{ Name = [string]$sa.Name; Target = $h.Path; Real = $real; Level = $v.Level
                        Reason = 'Microsoft Store app, started through its launch alias. ' + $v.Reason })
            }
            else {
                $list.Add([pscustomobject]@{ Name = [string]$sa.Name; Target = ''; Real = ''; Level = 'no'
                        Reason = "Microsoft Store app without a launch alias: Windows doesn't let other programs start it with its own settings." })
            }
        }
    }
    catch { }
    # Works first, then Might work, then Won't work; alphabetical within each group.
    $rank = @{ works = 0; maybe = 1; no = 2 }
    return @($list | Sort-Object @{ Expression = { $rank[$_.Level] } }, @{ Expression = { $_.Name } })
}

# =====================================================================================================
#  CLI mode
# =====================================================================================================
if ($ListApps) {
    $apps = @(Get-InstalledApps)
    $labels = @{ works = 'Works'; maybe = 'Might work'; no = "Won't work" }
    $apps | Format-Table @{ n = 'Verdict'; e = { $labels[$_.Level] } }, Name, Target, Reason -AutoSize -Wrap |
        Out-String -Width 400 | Write-Host
    $nWorks = @($apps | Where-Object { $_.Level -eq 'works' }).Count
    $nMaybe = @($apps | Where-Object { $_.Level -eq 'maybe' }).Count
    $nNo = @($apps | Where-Object { $_.Level -eq 'no' }).Count
    Write-Host "$($apps.Count) apps: $nWorks work, $nMaybe might work, $nNo won't work."
    exit 0
}

if ($Name -and $Target) {
    if ($Mode -eq 'Auto') { $Mode = Get-AutoMode $Target }
    $d = Get-ModeDefaults $Mode $Target
    $a = if ($PSBoundParameters.ContainsKey('Arguments')) { $Arguments } else { $d.Args }
    $exe = Save-Instance -Name $Name -Target $Target -Icon $Icon -Mode $Mode -LaunchArgs $a -EnvText $d.Env `
        -Desktop (-not $NoDesktopShortcut) -StartMenu $true
    Write-Host "Created $Name ($Mode) -> $exe"
    exit 0
}

# =====================================================================================================
#  GUI (WPF; layout and colours from the Alter UI handoff)
# =====================================================================================================
# Alter's logo (multi-size .ico, made from logo\alter-logo.svg).
$AlterIconB64 = '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'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[System.Windows.Forms.Application]::EnableVisualStyles()     # modern look for the file dialogs / message boxes

if (-not ('AlterUi.CopyItem' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms, System.Core -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AlterUi
{
    // One card on the "Your copies" page. Running raises PropertyChanged so the card updates by itself.
    public class CopyItem : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        public string Name { get; set; }
        public string Exe { get; set; }
        public string Target { get; set; }
        public string Mode { get; set; }
        public string Mono { get; set; }
        public object Icon { get; set; }
        public bool HasIcon { get; set; }
        public bool IsAdd { get; set; }
        private bool running;
        public bool Running
        {
            get { return running; }
            set
            {
                if (running == value) return;
                running = value;
                PropertyChangedEventHandler h = PropertyChanged;
                if (h != null) h(this, new PropertyChangedEventArgs("Running"));
            }
        }
    }

    // One row in the app picker.
    public class AppEntry
    {
        public string Name { get; set; }
        public string Target { get; set; }
        public string Real { get; set; }
        public string Level { get; set; }
        public int Rank { get; set; }      // 0 works, 1 might work, 2 won't work (for sorting)
        public string Badge { get; set; }
        public string Reason { get; set; }
        public object Icon { get; set; }
    }

    public class EnvItem
    {
        public string Key { get; set; }
        public string Value { get; set; }
    }

    // Lets WinForms dialogs (file picker, message boxes) sit on top of the WPF window.
    public class Owner : System.Windows.Forms.IWin32Window
    {
        private readonly IntPtr handle;
        public Owner(IntPtr h) { handle = h; }
        public IntPtr Handle { get { return handle; } }
    }

    public static class AppId
    {
        // Gives the Alter window its own taskbar button and icon instead of grouping under PowerShell.
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
    }

    // Asks every visible window of the given processes to close, like clicking their X button.
    public static class WindowCloser
    {
        private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);

        public static int CloseWindowsOf(int[] pids)
        {
            HashSet<int> set = new HashSet<int>(pids);
            int count = 0;
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                if (set.Contains((int)pid) && IsWindowVisible(h))
                {
                    PostMessage(h, 0x0010 /* WM_CLOSE */, IntPtr.Zero, IntPtr.Zero);
                    count++;
                }
                return true;
            }, IntPtr.Zero);
            return count;
        }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;
        public PropertyKey(Guid g, uint p) { fmtid = g; pid = p; }
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    internal struct PropVariant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr ptr;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    internal class CShellLink { }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszName, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszDir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszArgs, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszIconPath, int cch, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        void Resolve(IntPtr hwnd, uint fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    // Start Menu shortcut for Alter itself, carrying the same app id as the window,
    // so pinning it to the taskbar and the running window share one button.
    public static class AppShortcut
    {
        public static void Create(string lnk, string exe, string args, string dir, string icon, string appId, string description)
        {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            try
            {
                link.SetPath(exe);
                link.SetArguments(args);
                link.SetWorkingDirectory(dir);
                link.SetIconLocation(icon, 0);
                link.SetDescription(description);
                IPropertyStore ps = (IPropertyStore)link;
                PropertyKey key = new PropertyKey(new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), 5);
                PropVariant pv = new PropVariant();
                pv.vt = 31; // VT_LPWSTR
                pv.ptr = Marshal.StringToCoTaskMemUni(appId);
                try
                {
                    int hr = ps.SetValue(ref key, ref pv);
                    if (hr < 0) Marshal.ThrowExceptionForHR(hr);
                    hr = ps.Commit();
                    if (hr < 0) Marshal.ThrowExceptionForHR(hr);
                }
                finally { Marshal.FreeCoTaskMem(pv.ptr); }
                ((System.Runtime.InteropServices.ComTypes.IPersistFile)link).Save(lnk, true);
            }
            finally { Marshal.ReleaseComObject(link); }
        }
    }

    public static class Dwm
    {
        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

        // Dark title bar (Windows 10 2004+ / 11), plus caption and border colours matching the window (Windows 11).
        public static void Dark(IntPtr hwnd, int captionBgr, int borderBgr)
        {
            int on = 1;
            if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) != 0) DwmSetWindowAttribute(hwnd, 19, ref on, 4);
            DwmSetWindowAttribute(hwnd, 35, ref captionBgr, 4);
            DwmSetWindowAttribute(hwnd, 34, ref borderBgr, 4);
        }
    }
}
'@
}

[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="Alter" Width="1280" Height="820" MinWidth="1000" MinHeight="620"
        WindowStartupLocation="CenterScreen" UseLayoutRounding="True"
        Background="#0B0B0B" Foreground="#F4F1EE"
        FontFamily="{DynamicResource FontUI}" FontSize="14">
  <Window.Resources>
    <!-- Fonts: replaced at start-up by the bundled Rubik / Inter / JetBrains Mono when the fonts folder is there -->
    <FontFamily x:Key="FontUI">Segoe UI</FontFamily>
    <FontFamily x:Key="FontDisplay">Segoe UI</FontFamily>
    <FontFamily x:Key="FontMono">Consolas</FontFamily>
    <sys:Double x:Key="CardWidth">300</sys:Double>

    <!-- The ALT letters, drawn as shapes (same geometry as the logo) -->
    <Geometry x:Key="AltA">F0 M41,176 V106 A26,26 0 0 1 67,80 H73 A26,26 0 0 1 99,106 V176 H78 V150 H62 V176 Z M62,104 H78 V128 H62 Z</Geometry>
    <Geometry x:Key="AltL">M116,80 H138 V154 H158 V176 H116 Z</Geometry>
    <Geometry x:Key="AltT">M156,80 H214 V102 H196 V176 H174 V102 H156 Z</Geometry>

    <!-- Buttons. Corner radius comes from Tag (default 12). Hover and press are overlays, so one template fits every colour. -->
    <ControlTemplate x:Key="BtnTemplate" TargetType="Button">
      <Grid>
        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="{TemplateBinding BorderThickness}"
                CornerRadius="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}"/>
        <Border x:Name="Hover" Background="#16FFFFFF" Visibility="Collapsed"
                CornerRadius="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}"/>
        <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"
                          VerticalAlignment="Center" RecognizesAccessKey="False"/>
      </Grid>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="Hover" Property="Visibility" Value="Visible"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter TargetName="Hover" Property="Background" Value="#22000000"/>
        </Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True">
          <Setter TargetName="Bd" Property="BorderBrush" Value="#FF8F7A"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter Property="Opacity" Value="0.45"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Template" Value="{StaticResource BtnTemplate}"/>
      <Setter Property="Tag" Value="12"/>
      <Setter Property="Height" Value="44"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#2A2A2A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="#F4F1EE"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    </Style>
    <Style x:Key="BtnSoft" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#1E1E1E"/>
      <Setter Property="Padding" Value="18,0"/>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#FF8F7A"/>
      <Setter Property="BorderBrush" Value="#FF8F7A"/>
      <Setter Property="Foreground" Value="#141414"/>
      <Setter Property="FontFamily" Value="{DynamicResource FontDisplay}"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="15"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="BorderBrush" Value="#6B3329"/>
      <Setter Property="Foreground" Value="#FF8F7A"/>
      <Setter Property="Padding" Value="18,0"/>
    </Style>
    <Style x:Key="BtnQuiet" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Tag" Value="10"/>
      <Setter Property="Foreground" Value="#A39E99"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <!-- "< Your copies" back link -->
    <Style x:Key="BtnLink" TargetType="Button">
      <Setter Property="Foreground" Value="#FF8F7A"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="Transparent" Padding="0,2">
              <ContentPresenter x:Name="Cp"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="#FFB3A5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Filter chips on the app picker. Tag="Selected" marks the active one. -->
    <Style x:Key="Chip" TargetType="Button">
      <Setter Property="Height" Value="32"/>
      <Setter Property="Margin" Value="0,0,8,6"/>
      <Setter Property="Foreground" Value="#C9C4BF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="16" Padding="14,0" Background="#161616" BorderBrush="#262626" BorderThickness="1">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#3A3A3A"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FFB3A5"/>
              </Trigger>
              <Trigger Property="Tag" Value="Selected">
                <Setter TargetName="Bd" Property="Background" Value="#2A1C19"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FF8F7A"/>
                <Setter Property="Foreground" Value="#F4F1EE"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Sidebar navigation. Tag="Selected" marks the current page. -->
    <Style x:Key="BtnNav" TargetType="Button">
      <Setter Property="Height" Value="44"/>
      <Setter Property="Foreground" Value="#C9C4BF"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="12" Padding="12,0">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Stretch"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1C1C1C"/>
              </Trigger>
              <Trigger Property="Tag" Value="Selected">
                <Setter TargetName="Bd" Property="Background" Value="#1E1E1E"/>
                <Setter Property="Foreground" Value="#F4F1EE"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Text inputs -->
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#0E0E0E"/>
      <Setter Property="Foreground" Value="#F4F1EE"/>
      <Setter Property="BorderBrush" Value="#2A2A2A"/>
      <Setter Property="CaretBrush" Value="#F4F1EE"/>
      <Setter Property="SelectionBrush" Value="#FF8F7A"/>
      <Setter Property="MinHeight" Value="44"/>
      <Setter Property="Padding" Value="14,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="12">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"
                            VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#3A3A3A"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FF8F7A"/>
              </Trigger>
              <Trigger Property="IsReadOnly" Value="True">
                <Setter Property="Foreground" Value="#A39E99"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="MonoBox" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="FontFamily" Value="{DynamicResource FontMono}"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>
    <!-- Search box text: no frame of its own (the frame is the surrounding border) -->
    <Style x:Key="BareBox" TargetType="TextBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#F4F1EE"/>
      <Setter Property="CaretBrush" Value="#F4F1EE"/>
      <Setter Property="SelectionBrush" Value="#FF8F7A"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="FieldLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="Foreground" Value="#C9C4BF"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{DynamicResource FontDisplay}"/>
      <Setter Property="FontWeight" Value="ExtraBold"/>
      <Setter Property="FontSize" Value="40"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{DynamicResource FontDisplay}"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Muted" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#A39E99"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#161616"/>
      <Setter Property="BorderBrush" Value="#242424"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="20"/>
      <Setter Property="Padding" Value="24"/>
    </Style>
    <!-- Numbered step badge in the New copy form -->
    <Style x:Key="StepBadge" TargetType="Border">
      <Setter Property="Width" Value="28"/>
      <Setter Property="Height" Value="28"/>
      <Setter Property="CornerRadius" Value="9"/>
      <Setter Property="Background" Value="#FF8F7A"/>
      <Setter Property="Margin" Value="0,0,12,0"/>
    </Style>
    <Style x:Key="StepNum" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="{DynamicResource FontDisplay}"/>
      <Setter Property="FontWeight" Value="ExtraBold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Foreground" Value="#141414"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <!-- Status and mode pills -->
    <Style x:Key="Pill" TargetType="Border">
      <Setter Property="Height" Value="26"/>
      <Setter Property="CornerRadius" Value="13"/>
      <Setter Property="Padding" Value="10,0"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Background" Value="#1E1E1E"/>
    </Style>

    <!-- On/off switch -->
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Track" Width="48" Height="28" CornerRadius="14" Background="#2E2E2E" Padding="3"
                    BorderThickness="1" BorderBrush="Transparent">
              <Ellipse x:Name="Knob" Width="22" Height="22" Fill="#A39E99" HorizontalAlignment="Left" Margin="-1"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#FF8F7A"/>
                <Setter TargetName="Knob" Property="Fill" Value="#141414"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Track" Property="BorderBrush" Value="#FFB3A5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Drop-down -->
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#F4F1EE"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="8" Padding="12,8" Margin="0,1">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1E1E1E"/>
              </Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#262626"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#F4F1EE"/>
      <Setter Property="Height" Value="44"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" Background="#0E0E0E" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="12">
                      <Path Data="M6,9 L12,15 L18,9" Stroke="#A39E99" StrokeThickness="2" StrokeStartLineCap="Round"
                            StrokeEndLineCap="Round" StrokeLineJoin="Round" Width="24" Height="24"
                            HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True">
                        <Setter TargetName="Bd" Property="BorderBrush" Value="#3A3A3A"/>
                      </Trigger>
                      <Trigger Property="IsChecked" Value="True">
                        <Setter TargetName="Bd" Property="BorderBrush" Value="#FF8F7A"/>
                      </Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter Content="{TemplateBinding SelectionBoxItem}" IsHitTestVisible="False"
                                Margin="14,0,40,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
              <Popup x:Name="PART_Popup" IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                <Border Background="#161616" BorderBrush="#2A2A2A" BorderThickness="1" CornerRadius="12" Padding="6"
                        Margin="0,6,0,0" MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                  <ScrollViewer MaxHeight="260"><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Slim scroll bars (vertical only; horizontal scrolling is turned off everywhere) -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border Background="#2E2E2E" CornerRadius="4" Margin="2"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Visibility" Value="Collapsed"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- Copy cards on "Your copies" -->
    <DataTemplate x:Key="CopyCard">
      <Grid>
        <!-- A copy -->
        <Border x:Name="Card" Background="#161616" BorderBrush="#242424" BorderThickness="1" CornerRadius="20" Padding="20">
          <DockPanel>
            <DockPanel DockPanel.Dock="Bottom" Margin="0,18,0,0">
              <Button x:Name="Details" DockPanel.Dock="Right" Style="{StaticResource Btn}" Width="44" Padding="0" Margin="8,0,0,0"
                      Uid="details" ToolTip="Details">
                <Path Data="M9,6 L15,12 L9,18" Stroke="#C9C4BF" StrokeThickness="2" StrokeStartLineCap="Round"
                      StrokeEndLineCap="Round" StrokeLineJoin="Round" Width="24" Height="24"/>
              </Button>
              <Button x:Name="Act" Style="{StaticResource BtnPrimary}" Uid="toggle" Content="Launch"
                      FontFamily="{DynamicResource FontUI}" FontWeight="SemiBold" FontSize="14"/>
            </DockPanel>
            <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,18,0,0">
              <Border x:Name="StatusPill" Style="{StaticResource Pill}" Background="#1E1E1E">
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="StatusDot" Width="6" Height="6" Fill="#A39E99" VerticalAlignment="Center" Margin="0,0,6,0"/>
                  <TextBlock x:Name="StatusText" Text="Stopped" FontSize="12" FontWeight="SemiBold" Foreground="#A39E99" VerticalAlignment="Center"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Pill}">
                <TextBlock Text="{Binding Mode}" FontSize="12" Foreground="#C9C4BF" VerticalAlignment="Center"/>
              </Border>
            </StackPanel>
            <DockPanel>
              <Border Width="56" Height="56" CornerRadius="15" Background="#0B0B0B" BorderBrush="#262626" BorderThickness="1"
                      Margin="0,0,14,0" VerticalAlignment="Top">
                <Grid>
                  <TextBlock x:Name="Mono" Text="{Binding Mono}" FontFamily="{DynamicResource FontDisplay}" FontWeight="ExtraBold"
                             FontSize="20" Foreground="#FF8F7A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <Image x:Name="Img" Source="{Binding Icon}" Width="32" Height="32" Visibility="Collapsed"
                         RenderOptions.BitmapScalingMode="HighQuality"/>
                </Grid>
              </Border>
              <StackPanel VerticalAlignment="Center">
                <Button Style="{StaticResource BtnLink}" Uid="details" Foreground="#F4F1EE" FontSize="18">
                  <TextBlock Text="{Binding Name}" FontFamily="{DynamicResource FontDisplay}" FontWeight="Bold"
                             TextTrimming="CharacterEllipsis"/>
                </Button>
                <TextBlock Text="{Binding Exe}" ToolTip="{Binding Target}" FontFamily="{DynamicResource FontMono}" FontSize="12"
                           Foreground="#A39E99" TextTrimming="CharacterEllipsis" Margin="0,4,0,0"/>
              </StackPanel>
            </DockPanel>
          </DockPanel>
        </Border>
        <!-- The "Copy another app" tile -->
        <Button x:Name="AddTile" Uid="add" Visibility="Collapsed" MinHeight="210" Cursor="Hand" FocusVisualStyle="{x:Null}">
          <Button.Template>
            <ControlTemplate TargetType="Button">
              <Grid Background="Transparent">
                <Rectangle x:Name="Dash" RadiusX="20" RadiusY="20" Stroke="#333333" StrokeThickness="1.5" StrokeDashArray="4 3"/>
                <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
                  <Border Width="48" Height="48" CornerRadius="14" Background="#161616" HorizontalAlignment="Center">
                    <Path x:Name="PlusPath" Data="M12,5 V19 M5,12 H19" Stroke="#A39E99"
                          StrokeThickness="2.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Width="24" Height="24"/>
                  </Border>
                  <TextBlock x:Name="Lbl" Text="Copy another app" FontWeight="Medium" Foreground="#A39E99" Margin="0,12,0,0"
                             HorizontalAlignment="Center"/>
                </StackPanel>
              </Grid>
              <ControlTemplate.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                  <Setter TargetName="Dash" Property="Stroke" Value="#FF8F7A"/>
                  <Setter TargetName="PlusPath" Property="Stroke" Value="#FF8F7A"/>
                  <Setter TargetName="Lbl" Property="Foreground" Value="#FF8F7A"/>
                </Trigger>
              </ControlTemplate.Triggers>
            </ControlTemplate>
          </Button.Template>
        </Button>
      </Grid>
      <DataTemplate.Triggers>
        <DataTrigger Binding="{Binding IsAdd}" Value="True">
          <Setter TargetName="Card" Property="Visibility" Value="Collapsed"/>
          <Setter TargetName="AddTile" Property="Visibility" Value="Visible"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding HasIcon}" Value="True">
          <Setter TargetName="Mono" Property="Visibility" Value="Collapsed"/>
          <Setter TargetName="Img" Property="Visibility" Value="Visible"/>
        </DataTrigger>
        <DataTrigger Binding="{Binding Running}" Value="True">
          <Setter TargetName="StatusPill" Property="Background" Value="#3A211C"/>
          <Setter TargetName="StatusDot" Property="Fill" Value="#FF8F7A"/>
          <Setter TargetName="StatusText" Property="Text" Value="Running"/>
          <Setter TargetName="StatusText" Property="Foreground" Value="#FF8F7A"/>
          <Setter TargetName="Act" Property="Content" Value="Stop"/>
          <Setter TargetName="Act" Property="Background" Value="Transparent"/>
          <Setter TargetName="Act" Property="BorderBrush" Value="#2A2A2A"/>
          <Setter TargetName="Act" Property="Foreground" Value="#F4F1EE"/>
        </DataTrigger>
        <Trigger SourceName="Card" Property="IsMouseOver" Value="True">
          <Setter TargetName="Card" Property="BorderBrush" Value="#3A3A3A"/>
        </Trigger>
      </DataTemplate.Triggers>
    </DataTemplate>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="260"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- ============================ Sidebar ============================ -->
    <Border Background="#111111" BorderBrush="#1C1C1C" BorderThickness="0,1,1,0">
      <DockPanel Margin="20,28,20,20">
        <StackPanel DockPanel.Dock="Top" Margin="8,0,8,28">
          <Viewbox Height="30" HorizontalAlignment="Left">
            <Canvas Width="190" Height="112">
              <Canvas.RenderTransform><TranslateTransform X="-33" Y="-72"/></Canvas.RenderTransform>
              <Path Data="{StaticResource AltA}" Fill="#FF8F7A" Stroke="#FF8F7A" StrokeThickness="7" StrokeLineJoin="Round"/>
              <Path Data="{StaticResource AltL}" Fill="#FF8F7A" Stroke="#FF8F7A" StrokeThickness="7" StrokeLineJoin="Round"/>
              <Path Data="{StaticResource AltT}" Fill="#FF8F7A" Stroke="#FF8F7A" StrokeThickness="7" StrokeLineJoin="Round"/>
            </Canvas>
          </Viewbox>
          <TextBlock Text="Separate copies of any app" Foreground="#A39E99" FontSize="13" Margin="0,10,0,0"/>
        </StackPanel>

        <StackPanel DockPanel.Dock="Bottom">
          <Border Background="#161616" BorderBrush="#222222" BorderThickness="1" CornerRadius="14" Padding="14" Margin="0,0,0,12">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="dotRunning" Width="8" Height="8" Fill="#4A4A4A" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <TextBlock x:Name="txtRunning" Text="No copies running" FontSize="13" Foreground="#C9C4BF"/>
            </StackPanel>
          </Border>
          <Button x:Name="btnNewSide" Style="{StaticResource BtnPrimary}" Height="48" Tag="14">
            <StackPanel Orientation="Horizontal">
              <Path Data="M12,5 V19 M5,12 H19" Stroke="#141414" StrokeThickness="3" StrokeStartLineCap="Round"
                    StrokeEndLineCap="Round" Width="24" Height="24" Margin="0,0,4,0">
                <Path.LayoutTransform><ScaleTransform ScaleX="0.67" ScaleY="0.67"/></Path.LayoutTransform>
              </Path>
              <TextBlock Text="New copy" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
        </StackPanel>

        <StackPanel>
          <Button x:Name="navCopies" Style="{StaticResource BtnNav}" Tag="Selected" Margin="0,0,0,4">
            <DockPanel>
              <Viewbox Width="18" Height="18" Margin="0,0,12,0" DockPanel.Dock="Left">
                <Canvas Width="24" Height="24">
                  <Rectangle Canvas.Left="3" Canvas.Top="3" Width="7" Height="7" RadiusX="2" RadiusY="2" Stroke="#FF8F7A" StrokeThickness="2"/>
                  <Rectangle Canvas.Left="14" Canvas.Top="3" Width="7" Height="7" RadiusX="2" RadiusY="2" Stroke="#FF8F7A" StrokeThickness="2"/>
                  <Rectangle Canvas.Left="3" Canvas.Top="14" Width="7" Height="7" RadiusX="2" RadiusY="2" Stroke="#FF8F7A" StrokeThickness="2"/>
                  <Rectangle Canvas.Left="14" Canvas.Top="14" Width="7" Height="7" RadiusX="2" RadiusY="2" Stroke="#FF8F7A" StrokeThickness="2"/>
                </Canvas>
              </Viewbox>
              <TextBlock x:Name="txtCount" DockPanel.Dock="Right" Text="0" FontSize="12" Foreground="#A39E99" VerticalAlignment="Center"/>
              <TextBlock Text="Copies" VerticalAlignment="Center"/>
            </DockPanel>
          </Button>
          <Button x:Name="navNew" Style="{StaticResource BtnNav}">
            <StackPanel Orientation="Horizontal">
              <Viewbox Width="18" Height="18" Margin="0,0,12,0">
                <Canvas Width="24" Height="24">
                  <Rectangle Canvas.Left="3" Canvas.Top="3" Width="18" Height="18" RadiusX="5" RadiusY="5"
                             Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="2"/>
                  <Path Data="M12,8 V16 M8,12 H16" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}"
                        StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                </Canvas>
              </Viewbox>
              <TextBlock Text="New copy" VerticalAlignment="Center"/>
            </StackPanel>
          </Button>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ============================ Content ============================ -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- ===== Your copies ===== -->
      <ScrollViewer x:Name="viewMain" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel Margin="40,36,40,48">
          <DockPanel Margin="0,0,0,28">
            <Border DockPanel.Dock="Right" VerticalAlignment="Bottom" Height="44" MinWidth="240" Padding="14,0"
                    CornerRadius="12" Background="#161616" BorderBrush="#262626" BorderThickness="1">
              <DockPanel>
                <Path DockPanel.Dock="Left" Data="M11,4 A7,7 0 1 1 10.99,4 Z M20,20 L16.5,16.5" Stroke="#A39E99" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" Width="24" Height="24" VerticalAlignment="Center" Margin="0,0,6,0">
                  <Path.LayoutTransform><ScaleTransform ScaleX="0.67" ScaleY="0.67"/></Path.LayoutTransform>
                </Path>
                <Grid>
                  <TextBox x:Name="txtSearch" Style="{StaticResource BareBox}" MinWidth="180"/>
                  <TextBlock x:Name="txtSearchHint" Text="Search copies" Foreground="#6F6A66" VerticalAlignment="Center" IsHitTestVisible="False"/>
                </Grid>
              </DockPanel>
            </Border>
            <StackPanel>
              <TextBlock Text="Your copies" Style="{StaticResource H1}"/>
              <TextBlock Text="Each copy runs on its own, with its own sign-in and settings." Style="{StaticResource Muted}" Margin="0,6,0,0"/>
            </StackPanel>
          </DockPanel>
          <ItemsControl x:Name="icCopies" ItemTemplate="{StaticResource CopyCard}" Margin="0,0,-16,0" Focusable="False">
            <ItemsControl.ItemsPanel>
              <ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate>
            </ItemsControl.ItemsPanel>
            <ItemsControl.ItemContainerStyle>
              <Style TargetType="ContentPresenter">
                <Setter Property="Width" Value="{DynamicResource CardWidth}"/>
                <Setter Property="Margin" Value="0,0,16,16"/>
              </Style>
            </ItemsControl.ItemContainerStyle>
          </ItemsControl>
        </StackPanel>
      </ScrollViewer>

      <!-- ===== New copy / Edit ===== -->
      <ScrollViewer x:Name="viewForm" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Visibility="Collapsed">
        <StackPanel Margin="40,36,40,48">
          <Button x:Name="btnFormBack" Style="{StaticResource BtnLink}">
            <StackPanel Orientation="Horizontal">
              <Path Data="M15,6 L9,12 L15,18" Stroke="#FF8F7A" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                    StrokeLineJoin="Round" Width="24" Height="24" VerticalAlignment="Center">
                <Path.LayoutTransform><ScaleTransform ScaleX="0.6" ScaleY="0.6"/></Path.LayoutTransform>
              </Path>
              <TextBlock x:Name="txtFormBack" Text="Your copies" VerticalAlignment="Center" Margin="4,0,0,0"/>
            </StackPanel>
          </Button>
          <TextBlock x:Name="txtFormTitle" Text="New copy" Style="{StaticResource H1}" Margin="0,6,0,0"/>
          <TextBlock x:Name="txtFormSub" Text="Pick an app to make a separate copy of it." Style="{StaticResource Muted}" Margin="0,6,0,28"/>

          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="24"/>
              <ColumnDefinition Width="300"/>
            </Grid.ColumnDefinitions>

            <StackPanel>
              <!-- 1. App -->
              <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                <StackPanel>
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,18">
                    <Border Style="{StaticResource StepBadge}"><TextBlock Text="1" Style="{StaticResource StepNum}"/></Border>
                    <TextBlock Text="App" Style="{StaticResource H2}"/>
                  </StackPanel>
                  <TextBlock Text="Name" Style="{StaticResource FieldLabel}"/>
                  <TextBox x:Name="txtName" Margin="0,0,0,18"/>
                  <TextBlock Text="App (.exe)" Style="{StaticResource FieldLabel}"/>
                  <DockPanel Margin="0,0,0,18">
                    <Button x:Name="btnTarget" DockPanel.Dock="Right" Style="{StaticResource BtnSoft}" Content="Browse" Margin="8,0,0,0"/>
                    <Grid>
                      <TextBox x:Name="txtTarget" Style="{StaticResource MonoBox}"/>
                      <TextBlock x:Name="hintTarget" Text="C:\Program Files\...\app.exe" FontFamily="{DynamicResource FontMono}" FontSize="13"
                                 Foreground="#5C5854" VerticalAlignment="Center" Margin="15,0,0,0" IsHitTestVisible="False"/>
                    </Grid>
                  </DockPanel>
                  <!-- Can this app be copied? Shown after picking an app. -->
                  <Border x:Name="verdictBox" CornerRadius="12" Padding="14,10" Margin="0,-8,0,18" Background="#1E1E1E" Visibility="Collapsed">
                    <DockPanel>
                      <Ellipse x:Name="dotVerdict" DockPanel.Dock="Left" Width="8" Height="8" Margin="0,5,10,0" VerticalAlignment="Top" Fill="#F2C46D"/>
                      <TextBlock x:Name="txtVerdict" FontSize="13" Foreground="#C9C4BF" TextWrapping="Wrap"/>
                    </DockPanel>
                  </Border>
                  <TextBlock Style="{StaticResource FieldLabel}">
                    <Run Text="Icon"/><Run Text=" - optional, uses the app's own if empty" Foreground="#A39E99" FontWeight="Normal"/>
                  </TextBlock>
                  <DockPanel>
                    <Button x:Name="btnIcon" DockPanel.Dock="Right" Style="{StaticResource BtnSoft}" Content="Browse" Margin="8,0,0,0"/>
                    <Grid>
                      <TextBox x:Name="txtIcon" Style="{StaticResource MonoBox}"/>
                      <TextBlock x:Name="hintIcon" Text=".ico or .png" FontFamily="{DynamicResource FontMono}" FontSize="13"
                                 Foreground="#5C5854" VerticalAlignment="Center" Margin="15,0,0,0" IsHitTestVisible="False"/>
                    </Grid>
                  </DockPanel>
                </StackPanel>
              </Border>

              <!-- 2. Isolation -->
              <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                <StackPanel>
                  <DockPanel Margin="0,0,0,18">
                    <Button x:Name="btnDefaults" DockPanel.Dock="Right" Style="{StaticResource BtnQuiet}" Content="Reset to defaults"/>
                    <StackPanel Orientation="Horizontal">
                      <Border Style="{StaticResource StepBadge}"><TextBlock Text="2" Style="{StaticResource StepNum}"/></Border>
                      <TextBlock Text="Isolation" Style="{StaticResource H2}"/>
                    </StackPanel>
                  </DockPanel>
                  <TextBlock Text="Mode" Style="{StaticResource FieldLabel}"/>
                  <ComboBox x:Name="cmbMode"/>
                  <Border Background="#1E1E1E" CornerRadius="12" Padding="14" Margin="0,8,0,18">
                    <DockPanel>
                      <Viewbox Width="18" Height="18" DockPanel.Dock="Left" VerticalAlignment="Top" Margin="0,1,12,0">
                        <Canvas Width="24" Height="24">
                          <Ellipse Canvas.Left="2" Canvas.Top="2" Width="20" Height="20" Stroke="#FF8F7A" StrokeThickness="2"/>
                          <Path Data="M12,11 V17" Stroke="#FF8F7A" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                          <Ellipse Canvas.Left="10.8" Canvas.Top="6.3" Width="2.4" Height="2.4" Fill="#FF8F7A"/>
                        </Canvas>
                      </Viewbox>
                      <TextBlock x:Name="txtHint" FontSize="13" LineHeight="20" Foreground="#C9C4BF" TextWrapping="Wrap"/>
                    </DockPanel>
                  </Border>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="12"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel>
                      <TextBlock Text="Arguments" Style="{StaticResource FieldLabel}"/>
                      <TextBox x:Name="txtArgs" Style="{StaticResource MonoBox}"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2">
                      <TextBlock Text="Environment" Style="{StaticResource FieldLabel}"/>
                      <Grid>
                        <TextBox x:Name="txtEnv" Style="{StaticResource MonoBox}" AcceptsReturn="True"
                                 TextWrapping="NoWrap" VerticalContentAlignment="Top" Padding="14,12" MaxHeight="140"
                                 VerticalScrollBarVisibility="Auto"/>
                        <TextBlock x:Name="hintEnv" Text="KEY=value, one per line" FontFamily="{DynamicResource FontMono}" FontSize="13"
                                   Foreground="#5C5854" Margin="15,13,0,0" IsHitTestVisible="False"/>
                      </Grid>
                    </StackPanel>
                  </Grid>
                </StackPanel>
              </Border>

              <!-- 3. Options -->
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
                    <Border Style="{StaticResource StepBadge}"><TextBlock Text="3" Style="{StaticResource StepNum}"/></Border>
                    <TextBlock Text="Options" Style="{StaticResource H2}"/>
                  </StackPanel>
                  <DockPanel MinHeight="56">
                    <CheckBox x:Name="chkTaskbar" DockPanel.Dock="Right" Style="{StaticResource Switch}" IsChecked="True" VerticalAlignment="Center"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="Own taskbar button" FontWeight="Medium"/>
                      <TextBlock Text="Shows this copy as its own button on the taskbar, separate from the original app." FontSize="13" Style="{StaticResource Muted}" Margin="0,2,16,0"/>
                    </StackPanel>
                  </DockPanel>
                  <DockPanel MinHeight="56">
                    <CheckBox x:Name="chkDesktop" DockPanel.Dock="Right" Style="{StaticResource Switch}" IsChecked="True" VerticalAlignment="Center"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="Desktop shortcut" FontWeight="Medium"/>
                      <TextBlock Text="Adds a shortcut that opens this copy directly." FontSize="13" Style="{StaticResource Muted}" Margin="0,2,16,0"/>
                    </StackPanel>
                  </DockPanel>
                  <DockPanel MinHeight="56">
                    <CheckBox x:Name="chkStart" DockPanel.Dock="Right" Style="{StaticResource Switch}" IsChecked="True" VerticalAlignment="Center"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="Start Menu shortcut" FontWeight="Medium"/>
                      <TextBlock Text="Adds this copy to the Start Menu, in the Alter folder." FontSize="13" Style="{StaticResource Muted}" Margin="0,2,16,0"/>
                    </StackPanel>
                  </DockPanel>
                  <DockPanel x:Name="rowOpen" MinHeight="56">
                    <CheckBox x:Name="chkOpen" DockPanel.Dock="Right" Style="{StaticResource Switch}" IsChecked="False" VerticalAlignment="Center"/>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="Open when created" FontWeight="Medium"/>
                      <TextBlock Text="Starts the copy as soon as it is ready." FontSize="13" Style="{StaticResource Muted}" Margin="0,2,16,0"/>
                    </StackPanel>
                  </DockPanel>
                </StackPanel>
              </Border>
            </StackPanel>

            <!-- Preview -->
            <StackPanel Grid.Column="2">
              <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                <StackPanel>
                  <TextBlock Text="PREVIEW" FontSize="12" FontWeight="SemiBold" Foreground="#A39E99" Margin="0,0,0,16"/>
                  <Border Width="112" Height="112" CornerRadius="28" Background="#141414" BorderBrush="#2A2A2A" BorderThickness="1"
                          HorizontalAlignment="Center">
                    <Grid>
                      <TextBlock x:Name="txtPrevMono" Text="ALT" FontFamily="{DynamicResource FontDisplay}" FontWeight="ExtraBold"
                                 FontSize="38" Foreground="#FF8F7A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      <Image x:Name="imgPrev" Width="64" Height="64" RenderOptions.BitmapScalingMode="HighQuality"/>
                    </Grid>
                  </Border>
                  <TextBlock x:Name="txtPrevName" Text="Untitled copy" FontFamily="{DynamicResource FontDisplay}" FontWeight="Bold"
                             FontSize="20" HorizontalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,16,0,4"/>
                  <TextBlock x:Name="txtPrevMode" Text="Redirect" FontSize="13" Foreground="#A39E99" HorizontalAlignment="Center"/>
                </StackPanel>
              </Border>
              <Button x:Name="btnSave" Style="{StaticResource BtnPrimary}" Height="52" Tag="14" FontSize="16" Content="Create copy" Margin="0,0,0,16"/>
              <Button x:Name="btnCancel" Style="{StaticResource Btn}" Tag="14" Content="Cancel"/>
              <TextBlock x:Name="txtFormStatus" Style="{StaticResource Muted}" FontSize="13" Margin="2,14,0,0"/>
            </StackPanel>
          </Grid>
        </StackPanel>
      </ScrollViewer>

      <!-- ===== Copy detail ===== -->
      <ScrollViewer x:Name="viewDetail" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Visibility="Collapsed">
        <StackPanel Margin="40,36,40,48">
          <Button x:Name="btnDetailBack" Style="{StaticResource BtnLink}" Margin="0,0,0,24">
            <StackPanel Orientation="Horizontal">
              <Path Data="M15,6 L9,12 L15,18" Stroke="#FF8F7A" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                    StrokeLineJoin="Round" Width="24" Height="24" VerticalAlignment="Center">
                <Path.LayoutTransform><ScaleTransform ScaleX="0.6" ScaleY="0.6"/></Path.LayoutTransform>
              </Path>
              <TextBlock Text="Your copies" VerticalAlignment="Center" Margin="4,0,0,0"/>
            </StackPanel>
          </Button>

          <!-- Hero -->
          <Border Style="{StaticResource Card}" CornerRadius="24" Padding="28" Margin="0,0,0,24">
            <DockPanel>
              <Border Width="96" Height="96" CornerRadius="26" Background="#0B0B0B" BorderBrush="#2A2A2A" BorderThickness="1"
                      Margin="0,0,24,0" DockPanel.Dock="Left">
                <Grid>
                  <TextBlock x:Name="txtDetMono" FontFamily="{DynamicResource FontDisplay}" FontWeight="ExtraBold" FontSize="32"
                             Foreground="#FF8F7A" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <Image x:Name="imgDet" Width="56" Height="56" RenderOptions.BitmapScalingMode="HighQuality"/>
                </Grid>
              </Border>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="btnDetFolder" Style="{StaticResource Btn}" Margin="0,0,8,0">
                  <StackPanel Orientation="Horizontal">
                    <Path Data="M3,7 A2,2 0 0 1 5,5 H9 L11,7 H19 A2,2 0 0 1 21,9 V17 A2,2 0 0 1 19,19 H5 A2,2 0 0 1 3,17 Z"
                          Stroke="#F4F1EE" StrokeThickness="2" StrokeLineJoin="Round" Width="24" Height="24" VerticalAlignment="Center" Margin="0,0,6,0">
                      <Path.LayoutTransform><ScaleTransform ScaleX="0.7" ScaleY="0.7"/></Path.LayoutTransform>
                    </Path>
                    <TextBlock Text="Open folder" VerticalAlignment="Center"/>
                  </StackPanel>
                </Button>
                <Button x:Name="btnDetEdit" Style="{StaticResource Btn}" Content="Edit" Margin="0,0,8,0"/>
                <Button x:Name="btnDetToggle" Style="{StaticResource BtnPrimary}" MinWidth="112" Padding="20,0" Content="Launch"/>
              </StackPanel>
              <StackPanel VerticalAlignment="Center" Margin="0,0,16,0">
                <TextBlock x:Name="txtDetName" Style="{StaticResource H1}" FontSize="36"/>
                <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                  <Border x:Name="pillDet" Style="{StaticResource Pill}">
                    <StackPanel Orientation="Horizontal">
                      <Ellipse x:Name="dotDet" Width="6" Height="6" Fill="#A39E99" VerticalAlignment="Center" Margin="0,0,6,0"/>
                      <TextBlock x:Name="txtDetStatus" Text="Stopped" FontSize="12" FontWeight="SemiBold" Foreground="#A39E99" VerticalAlignment="Center"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource Pill}">
                    <TextBlock x:Name="txtDetMode" FontSize="12" Foreground="#C9C4BF" VerticalAlignment="Center"/>
                  </Border>
                </StackPanel>
              </StackPanel>
            </DockPanel>
          </Border>

          <Grid Margin="0,0,0,24">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="16"/>
              <ColumnDefinition Width="320"/>
            </Grid.ColumnDefinitions>
            <!-- Details -->
            <Border Style="{StaticResource Card}" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock Text="Details" Style="{StaticResource H2}" Margin="0,0,0,12"/>
                <Border BorderBrush="#222222" BorderThickness="0,0,0,1" Padding="0,12">
                  <DockPanel>
                    <TextBlock Text="Source app" Width="140" Foreground="#A39E99" DockPanel.Dock="Left"/>
                    <TextBlock x:Name="txtDetSource" FontFamily="{DynamicResource FontMono}" FontSize="13" TextWrapping="Wrap"/>
                  </DockPanel>
                </Border>
                <Border BorderBrush="#222222" BorderThickness="0,0,0,1" Padding="0,12">
                  <DockPanel>
                    <TextBlock Text="Data folder" Width="140" Foreground="#A39E99" DockPanel.Dock="Left"/>
                    <TextBlock x:Name="txtDetData" FontFamily="{DynamicResource FontMono}" FontSize="13" TextWrapping="Wrap"/>
                  </DockPanel>
                </Border>
                <Border BorderBrush="#222222" BorderThickness="0,0,0,1" Padding="0,12">
                  <DockPanel>
                    <TextBlock Text="Arguments" Width="140" Foreground="#A39E99" DockPanel.Dock="Left"/>
                    <TextBlock x:Name="txtDetArgs" FontFamily="{DynamicResource FontMono}" FontSize="13" TextWrapping="Wrap"/>
                  </DockPanel>
                </Border>
                <Border Padding="0,12,0,0">
                  <DockPanel>
                    <TextBlock Text="Isolation" Width="140" Foreground="#A39E99" DockPanel.Dock="Left"/>
                    <TextBlock x:Name="txtDetIso" TextWrapping="Wrap"/>
                  </DockPanel>
                </Border>
              </StackPanel>
            </Border>
            <!-- Environment -->
            <Border Grid.Column="2" Style="{StaticResource Card}" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock Text="Environment" Style="{StaticResource H2}" Margin="0,0,0,12"/>
                <TextBlock x:Name="txtDetNoEnv" Text="No extra environment variables." Style="{StaticResource Muted}" FontSize="13"/>
                <ItemsControl x:Name="icEnv" Focusable="False">
                  <ItemsControl.ItemTemplate>
                    <DataTemplate>
                      <Border Background="#0E0E0E" BorderBrush="#222222" BorderThickness="1" CornerRadius="12" Padding="14" Margin="0,0,0,12">
                        <StackPanel>
                          <TextBlock Text="{Binding Key}" FontFamily="{DynamicResource FontMono}" FontSize="12" Foreground="#FF8F7A"/>
                          <TextBlock Text="{Binding Value}" FontFamily="{DynamicResource FontMono}" FontSize="12" Foreground="#C9C4BF"
                                     TextWrapping="Wrap" Margin="0,6,0,0"/>
                        </StackPanel>
                      </Border>
                    </DataTemplate>
                  </ItemsControl.ItemTemplate>
                </ItemsControl>
              </StackPanel>
            </Border>
          </Grid>

          <!-- Danger -->
          <Border CornerRadius="20" BorderBrush="#4A2620" BorderThickness="1" Padding="24,20">
            <DockPanel>
              <Button x:Name="btnDetDelete" DockPanel.Dock="Right" Style="{StaticResource BtnDanger}" Content="Delete copy" VerticalAlignment="Center"/>
              <StackPanel VerticalAlignment="Center" Margin="0,0,16,0">
                <TextBlock Text="Delete this copy" Style="{StaticResource H2}" FontSize="16"/>
                <TextBlock Text="Removes the copy, its shortcuts and its data folder (sign-ins, settings). The original app is not touched."
                           Style="{StaticResource Muted}" FontSize="13" Margin="0,4,0,0"/>
              </StackPanel>
            </DockPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>

      <!-- ===== App picker (Browse) ===== -->
      <Grid x:Name="viewPicker" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <StackPanel Margin="40,36,40,16">
          <Button x:Name="btnPickerBack" Style="{StaticResource BtnLink}">
            <StackPanel Orientation="Horizontal">
              <Path Data="M15,6 L9,12 L15,18" Stroke="#FF8F7A" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                    StrokeLineJoin="Round" Width="24" Height="24" VerticalAlignment="Center">
                <Path.LayoutTransform><ScaleTransform ScaleX="0.6" ScaleY="0.6"/></Path.LayoutTransform>
              </Path>
              <TextBlock Text="Back to the form" VerticalAlignment="Center" Margin="4,0,0,0"/>
            </StackPanel>
          </Button>
          <TextBlock Text="Pick an app" Style="{StaticResource H1}" Margin="0,6,0,0"/>
          <TextBlock Text="Apps from your Start Menu. The badge shows how well each one can be copied." Style="{StaticResource Muted}" Margin="0,6,0,20"/>
          <DockPanel>
            <Button x:Name="btnOtherExe" DockPanel.Dock="Right" Style="{StaticResource BtnSoft}" Content="Other .exe..." Margin="8,0,0,0"/>
            <Border Height="44" Padding="14,0" CornerRadius="12" Background="#161616" BorderBrush="#262626" BorderThickness="1">
              <DockPanel>
                <Path DockPanel.Dock="Left" Data="M11,4 A7,7 0 1 1 10.99,4 Z M20,20 L16.5,16.5" Stroke="#A39E99" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" Width="24" Height="24" VerticalAlignment="Center" Margin="0,0,6,0">
                  <Path.LayoutTransform><ScaleTransform ScaleX="0.67" ScaleY="0.67"/></Path.LayoutTransform>
                </Path>
                <Grid>
                  <TextBox x:Name="txtPickSearch" Style="{StaticResource BareBox}"/>
                  <TextBlock x:Name="txtPickHint" Text="Search apps" Foreground="#6F6A66" VerticalAlignment="Center" IsHitTestVisible="False"/>
                </Grid>
              </DockPanel>
            </Border>
          </DockPanel>
          <DockPanel Margin="0,14,0,0">
            <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Top" Margin="12,0,0,0">
              <TextBlock Text="Sort by" Foreground="#A39E99" FontSize="13" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <ComboBox x:Name="cmbPickSort" Width="170" Height="36"/>
            </StackPanel>
            <WrapPanel x:Name="pnlChips" VerticalAlignment="Center">
              <Button x:Name="chipAll" Uid="all" Style="{StaticResource Chip}" Tag="Selected" Content="All"/>
              <Button x:Name="chipWorks" Uid="works" Style="{StaticResource Chip}" Content="Works"/>
              <Button x:Name="chipMaybe" Uid="maybe" Style="{StaticResource Chip}" Content="Might work"/>
              <Button x:Name="chipNo" Uid="no" Style="{StaticResource Chip}" Content="Won't work"/>
            </WrapPanel>
          </DockPanel>
          <TextBlock x:Name="txtPickInfo" Style="{StaticResource Muted}" FontSize="13" Margin="2,8,0,0"/>
        </StackPanel>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <ItemsControl x:Name="icApps" Margin="40,0,40,32" Focusable="False">
            <ItemsControl.ItemTemplate>
              <DataTemplate>
                <Button Uid="pick" Cursor="Hand" Margin="0,0,0,8" FocusVisualStyle="{x:Null}" ToolTip="{Binding Target}">
                  <Button.Template>
                    <ControlTemplate TargetType="Button">
                      <Border x:Name="Bd" Background="#161616" BorderBrush="#242424" BorderThickness="1" CornerRadius="14" Padding="14,12">
                        <ContentPresenter/>
                      </Border>
                      <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                          <Setter TargetName="Bd" Property="BorderBrush" Value="#3A3A3A"/>
                          <Setter TargetName="Bd" Property="Background" Value="#1A1A1A"/>
                        </Trigger>
                      </ControlTemplate.Triggers>
                    </ControlTemplate>
                  </Button.Template>
                  <DockPanel>
                    <Border Width="40" Height="40" CornerRadius="11" Background="#0B0B0B" BorderBrush="#262626" BorderThickness="1"
                            Margin="0,0,14,0" DockPanel.Dock="Left">
                      <Image Source="{Binding Icon}" Width="26" Height="26" RenderOptions.BitmapScalingMode="HighQuality"/>
                    </Border>
                    <Border x:Name="BadgeBd" DockPanel.Dock="Right" Height="26" CornerRadius="13" Padding="10,0" Margin="12,0,0,0"
                            VerticalAlignment="Center" Background="#2A2418">
                      <StackPanel Orientation="Horizontal">
                        <Ellipse x:Name="BadgeDot" Width="6" Height="6" Fill="#F2C46D" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <TextBlock x:Name="BadgeText" Text="{Binding Badge}" FontSize="12" FontWeight="SemiBold" Foreground="#F2C46D"
                                   VerticalAlignment="Center"/>
                      </StackPanel>
                    </Border>
                    <StackPanel VerticalAlignment="Center">
                      <TextBlock Text="{Binding Name}" FontFamily="{DynamicResource FontDisplay}" FontWeight="Bold" FontSize="15"
                                 Foreground="#F4F1EE" TextTrimming="CharacterEllipsis"/>
                      <TextBlock Text="{Binding Reason}" FontSize="12" Foreground="#A39E99" TextWrapping="Wrap" Margin="0,2,0,0"/>
                    </StackPanel>
                  </DockPanel>
                </Button>
                <DataTemplate.Triggers>
                  <DataTrigger Binding="{Binding Level}" Value="works">
                    <Setter TargetName="BadgeBd" Property="Background" Value="#1A2A1F"/>
                    <Setter TargetName="BadgeDot" Property="Fill" Value="#7FD49B"/>
                    <Setter TargetName="BadgeText" Property="Foreground" Value="#7FD49B"/>
                  </DataTrigger>
                  <DataTrigger Binding="{Binding Level}" Value="no">
                    <Setter TargetName="BadgeBd" Property="Background" Value="#33201D"/>
                    <Setter TargetName="BadgeDot" Property="Fill" Value="#FF8A80"/>
                    <Setter TargetName="BadgeText" Property="Foreground" Value="#FF8A80"/>
                  </DataTrigger>
                </DataTemplate.Triggers>
              </DataTemplate>
            </ItemsControl.ItemTemplate>
          </ItemsControl>
        </ScrollViewer>
      </Grid>

      <!-- Status line, shared by all pages -->
      <TextBlock x:Name="txtStatus" Grid.Row="1" Foreground="#A39E99" FontSize="13" TextWrapping="Wrap" Margin="40,0,40,14"/>
    </Grid>
  </Grid>
</Window>
'@

$win = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $Xaml))
foreach ($n in 'dotRunning', 'txtRunning', 'btnNewSide', 'navCopies', 'navNew', 'txtCount',
               'viewMain', 'txtSearch', 'txtSearchHint', 'icCopies',
               'viewForm', 'btnFormBack', 'txtFormBack', 'txtFormTitle', 'txtFormSub', 'txtName', 'txtTarget', 'hintTarget',
               'verdictBox', 'dotVerdict', 'txtVerdict',
               'viewPicker', 'btnPickerBack', 'btnOtherExe', 'txtPickSearch', 'txtPickHint', 'txtPickInfo', 'icApps',
               'cmbPickSort', 'pnlChips', 'chipAll', 'chipWorks', 'chipMaybe', 'chipNo',
               'btnTarget', 'txtIcon', 'hintIcon', 'btnIcon', 'btnDefaults', 'cmbMode', 'txtHint', 'txtArgs', 'txtEnv', 'hintEnv',
               'chkTaskbar', 'chkDesktop', 'chkStart', 'chkOpen', 'rowOpen',
               'txtPrevMono', 'imgPrev', 'txtPrevName', 'txtPrevMode', 'btnSave', 'btnCancel', 'txtFormStatus',
               'viewDetail', 'btnDetailBack', 'txtDetMono', 'imgDet', 'txtDetName', 'pillDet', 'dotDet', 'txtDetStatus', 'txtDetMode',
               'btnDetFolder', 'btnDetEdit', 'btnDetToggle', 'txtDetSource', 'txtDetData', 'txtDetArgs', 'txtDetIso',
               'txtDetNoEnv', 'icEnv', 'btnDetDelete', 'txtStatus') {
    Set-Variable -Name $n -Value $win.FindName($n) -Scope Script
}
foreach ($m in 'Chromium', 'Firefox', 'Redirect', 'None') { [void]$cmbMode.Items.Add($m) }

$script:loading = $false
$script:detail = $null       # copy shown on the detail page
$script:editing = $null      # copy being edited (null = new copy)
$script:owner = $null
$script:items = $null

# Short descriptions for the detail page; the form shows the longer $ModeHints.
$ModeShort = @{
    Chromium = 'Own --user-data-dir, so sign-ins and settings stay separate'
    Firefox  = 'Own profile folder, started with -no-remote'
    Redirect = 'APPDATA and LOCALAPPDATA point at the data folder'
    None     = 'No data separation, only a separate launcher and taskbar button'
}
$Dot = [string][char]0x00B7

# --- fonts -----------------------------------------------------------------------------------------------
# Rubik (headings, buttons, monograms), Inter (text) and JetBrains Mono (paths) ship in the fonts folder.
$FontDir = Join-Path $PSScriptRoot 'fonts'
if (Test-Path -LiteralPath (Join-Path $FontDir 'Inter-Regular.ttf')) {
    try {
        $base = [Uri]::new($FontDir.TrimEnd('\') + '\')
        $win.Resources['FontUI'] = [System.Windows.Media.FontFamily]::new($base, './#Inter, Segoe UI')
        $win.Resources['FontDisplay'] = [System.Windows.Media.FontFamily]::new($base, './#Rubik, Segoe UI')
        $win.Resources['FontMono'] = [System.Windows.Media.FontFamily]::new($base, './#JetBrains Mono, Consolas')
    }
    catch { }
}

# --- helpers ---------------------------------------------------------------------------------------------
function Set-Status([string]$t) { $txtStatus.Text = $t }

function Show-Error([string]$m) {
    if ($script:owner) { [void][System.Windows.Forms.MessageBox]::Show($script:owner, $m, 'Alter', 'OK', 'Error') }
    else { [void][System.Windows.Forms.MessageBox]::Show($m, 'Alter', 'OK', 'Error') }
}

function Confirm-Box([string]$m) {
    $r = [System.Windows.Forms.MessageBox]::Show($script:owner, $m, 'Alter', 'YesNo', 'Warning')
    return ($r -eq 'Yes')
}

function Show-Busy {
    # Let WPF draw the status text before a slow, blocking step.
    $win.Dispatcher.Invoke([Action]{ }, [System.Windows.Threading.DispatcherPriority]::Background)
}

# "Claude 2" -> CL2, "Slack Client" -> SC, "Discord" -> DIS
function Get-Monogram([string]$n) {
    $words = @((([string]$n) -replace '[^A-Za-z0-9 ]', ' ').Trim() -split '\s+' | Where-Object { $_ })
    if ($words.Count -eq 0) { return 'ALT' }
    if ($words.Count -eq 1) { $m = $words[0].Substring(0, [Math]::Min(3, $words[0].Length)) }
    elseif ($words.Count -eq 2 -and $words[1] -match '^\d+$') {
        $m = $words[0].Substring(0, [Math]::Min(2, $words[0].Length)) + $words[1].Substring(0, [Math]::Min(1, $words[1].Length))
    }
    else { $m = -join @($words | Select-Object -First 3 | ForEach-Object { $_.Substring(0, 1) }) }
    return $m.ToUpperInvariant()
}

# Image file (.ico/.png/...) or program (.exe) -> WPF image, or $null.
function Get-ImageSource([string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    try {
        if ([IO.Path]::GetExtension($path) -in '.exe', '.dll') {
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($path)
            try {
                $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle,
                    [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
            } finally { $ico.Dispose() }
        }
        else {
            # Read into memory so the file is never left locked (it gets replaced on save / moved on delete).
            $ms = New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path))
            $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create($ms,
                [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $src = $dec.Frames | Sort-Object { $_.PixelWidth } -Descending | Select-Object -First 1
        }
        if ($src -and $src.CanFreeze) { $src.Freeze() }
        return $src
    }
    catch { return $null }
}

function Test-InstanceRunning([string]$n) {
    # The launcher stays open while the app runs (with "Own taskbar button" on).
    $exe = Join-Path (Join-Path $Root $n) "$n.exe"
    foreach ($p in @(Get-Process -Name $n -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $p.Path } catch { }
        if (-not $path -or ($path -ieq $exe)) { return $true }
    }
    # Chromium browsers keep this file only while that profile is open.
    return (Test-Path -LiteralPath (Join-Path $Root "$n\data\profile\lockfile"))
}

# Every process that belongs to a copy: its launcher, anything started with its data folder, and their children.
function Get-CopyProcessIds([string]$n) {
    $dir = (Join-Path $Root $n) + '\'
    $exe = Join-Path (Join-Path $Root $n) "$n.exe"
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, ExecutablePath, CommandLine)
    $ids = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($p in $all) {
        if (($p.ExecutablePath -and $p.ExecutablePath -ieq $exe) -or
            ($p.CommandLine -and $p.CommandLine.IndexOf($dir, [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
            [void]$ids.Add([int]$p.ProcessId)
        }
    }
    $grew = $true
    while ($grew) {
        $grew = $false
        foreach ($p in $all) {
            if (-not $ids.Contains([int]$p.ProcessId) -and $ids.Contains([int]$p.ParentProcessId)) {
                [void]$ids.Add([int]$p.ProcessId); $grew = $true
            }
        }
    }
    [void]$ids.Remove($PID)
    return , ([int[]]@($ids))
}

function Find-CopyItem([string]$n) {
    if (-not $script:items) { return $null }
    foreach ($it in $script:items) { if (-not $it.IsAdd -and $it.Name -eq $n) { return $it } }
    return $null
}

# --- copies list -----------------------------------------------------------------------------------------
function New-CopyItem([string]$n) {
    $it = [AlterUi.CopyItem]::new()
    $it.Name = $n
    $it.Mono = Get-Monogram $n
    try {
        $c = Read-Instance $n
        $it.Target = $c.Target
        $it.Exe = Split-Path -Leaf $c.Target
        $parent = Split-Path -Leaf (Split-Path -Parent $c.Target)
        if ($parent) { $it.Exe = "$parent\$($it.Exe)" }
        $it.Mode = $c.Mode
        if ($c.CustomIcon) {
            $src = Get-ImageSource $c.Icon
            if ($src) { $it.Icon = $src.psobject.BaseObject; $it.HasIcon = $true }
        }
    }
    catch { $it.Exe = 'config.txt unreadable'; $it.Mode = '?' }
    $it.Running = Test-InstanceRunning $n
    return $it
}

function Update-CardWidth {
    $w = $icCopies.ActualWidth
    if ($w -le 0) { return }
    $cols = [Math]::Max(1, [Math]::Floor($w / (280 + 16)))
    $win.Resources['CardWidth'] = [double]([Math]::Floor($w / $cols) - 16)
}

function Refresh-List {
    # Real objects only (::new, .psobject.BaseObject): WPF must see the CopyItem itself, not PowerShell's
    # wrapper around it, or bindings and the live Running updates don't work.
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @(Get-Instances)) { $list.Add((New-CopyItem $n).psobject.BaseObject) }
    $add = [AlterUi.CopyItem]::new()
    $add.IsAdd = $true
    $list.Add($add)
    $script:items = $list
    $icCopies.ItemsSource = $list
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($list)
    $view.Filter = [Predicate[object]] {
        param($o)
        $q = $txtSearch.Text.Trim()
        return ($o.IsAdd -or -not $q -or $o.Name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    $txtCount.Text = [string]($list.Count - 1)
    Update-Running
}

function Update-Running {
    # Written in the plainest form on purpose: Windows PowerShell 5.1 failed here with
    # "Argument types do not match" when this loop used $n++ inside a nested if.
    $n = 0
    $all = $script:items
    if ($null -ne $all) {
        foreach ($item in $all) {
            if ($null -eq $item) { continue }
            if ($item.IsAdd) { continue }
            $isOn = [bool](Test-InstanceRunning $item.Name)
            $item.Running = $isOn
            if ($isOn) { $n = $n + 1 }
        }
    }
    if ($n -eq 0) { $txtRunning.Text = 'No copies running' }
    elseif ($n -eq 1) { $txtRunning.Text = '1 copy running' }
    else { $txtRunning.Text = [string]$n + ' copies running' }
    $dotColor = '#4A4A4A'
    if ($n -gt 0) { $dotColor = '#FF8F7A' }
    $dotRunning.Fill = Get-Brush $dotColor
    if ($script:detail) { Update-DetailStatus }
}

function Get-Brush([string]$hex) { return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }

# --- pages -----------------------------------------------------------------------------------------------
function Show-Page([string]$page) {
    $viewMain.Visibility = if ($page -eq 'main') { 'Visible' } else { 'Collapsed' }
    $viewForm.Visibility = if ($page -eq 'form') { 'Visible' } else { 'Collapsed' }
    $viewDetail.Visibility = if ($page -eq 'detail') { 'Visible' } else { 'Collapsed' }
    $viewPicker.Visibility = if ($page -eq 'picker') { 'Visible' } else { 'Collapsed' }
    $newPage = (($page -eq 'form' -or $page -eq 'picker') -and -not $script:editing)
    if ($newPage) { $navCopies.Tag = $null; $navNew.Tag = 'Selected' }
    else { $navCopies.Tag = 'Selected'; $navNew.Tag = $null }
    if ($page -ne 'detail') { $script:detail = $null }
    Set-Status ''
}

function Show-Main {
    Show-Page 'main'
    Refresh-List
}

function Update-DetailStatus {
    $it = Find-CopyItem $script:detail
    $on = [bool]($it -and $it.Running)
    # Plain if/else on purpose: Windows PowerShell 5.1 can fail on "$x = if ... else ..." with mixed types.
    if ($on) {
        $txtDetStatus.Text = 'Running'; $fg = '#FF8F7A'; $pill = '#3A211C'
        $btnDetToggle.Content = 'Stop'; $bg = '#1E1E1E'; $border = '#2A2A2A'; $text = '#F4F1EE'
    }
    else {
        $txtDetStatus.Text = 'Stopped'; $fg = '#A39E99'; $pill = '#1E1E1E'
        $btnDetToggle.Content = 'Launch'; $bg = '#FF8F7A'; $border = '#FF8F7A'; $text = '#141414'
    }
    $txtDetStatus.Foreground = Get-Brush $fg
    $dotDet.Fill = Get-Brush $fg
    $pillDet.Background = Get-Brush $pill
    $btnDetToggle.Background = Get-Brush $bg
    $btnDetToggle.BorderBrush = Get-Brush $border
    $btnDetToggle.Foreground = Get-Brush $text
}

function Show-Detail([string]$n) {
    $c = Read-Instance $n
    Show-Page 'detail'
    $script:detail = $n
    if (-not (Find-CopyItem $n)) { Refresh-List }
    $data = Join-Path (Join-Path $Root $n) 'data'
    $txtDetName.Text = $n
    $txtDetMono.Text = Get-Monogram $n
    $imgDet.Source = $null
    if ($c.CustomIcon) { $imgDet.Source = Get-ImageSource $c.Icon }
    $txtDetMono.Visibility = if ($imgDet.Source) { 'Collapsed' } else { 'Visible' }
    $txtDetMode.Text = $c.Mode
    $txtDetSource.Text = $c.Target
    $txtDetData.Text = $data
    if ($c.Args) { $txtDetArgs.Text = $c.Args.Replace('{DATA}', $data); $txtDetArgs.Foreground = Get-Brush '#F4F1EE' }
    else { $txtDetArgs.Text = 'None'; $txtDetArgs.Foreground = Get-Brush '#A39E99' }
    $short = $ModeShort[$c.Mode]
    if ($short) { $txtDetIso.Text = [string]$c.Mode + ' - ' + $short } else { $txtDetIso.Text = [string]$c.Mode }
    $envList = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @($c.Env)) {
        $i = $e.IndexOf('=')
        if ($i -le 0) { continue }
        $ei = [AlterUi.EnvItem]::new()
        $ei.Key = $e.Substring(0, $i)
        $ei.Value = $e.Substring($i + 1).Replace('{DATA}', $data)
        $envList.Add($ei)
    }
    $icEnv.ItemsSource = $envList
    $txtDetNoEnv.Visibility = if ($envList.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $viewDetail.ScrollToTop()
    Update-DetailStatus
}

function Update-Hint {
    $m = [string]$cmbMode.SelectedItem
    $txtHint.Text = $ModeHints[$m]
    Update-Preview
}

function Update-Preview {
    $n = $txtName.Text.Trim()
    if ($n) { $txtPrevName.Text = $n } else { $txtPrevName.Text = 'Untitled copy' }
    $txtPrevMono.Text = Get-Monogram $n
    $src = $null
    if ($txtIcon.Text.Trim()) { $src = Get-ImageSource $txtIcon.Text.Trim() }
    $imgPrev.Source = $src
    $txtPrevMono.Visibility = if ($src) { 'Collapsed' } else { 'Visible' }
    $m = [string]$cmbMode.SelectedItem
    if ($m -eq 'None') { $txtPrevMode.Text = 'None ' + $Dot + ' shared data' }
    else { $txtPrevMode.Text = $m + ' ' + $Dot + ' own data folder' }
    $hintTarget.Visibility = if ($txtTarget.Text) { 'Collapsed' } else { 'Visible' }
    $hintIcon.Visibility = if ($txtIcon.Text) { 'Collapsed' } else { 'Visible' }
    $hintEnv.Visibility = if ($txtEnv.Text) { 'Collapsed' } else { 'Visible' }
}

function Apply-Defaults {
    if (-not $txtTarget.Text) { return }
    $d = Get-ModeDefaults ([string]$cmbMode.SelectedItem) $txtTarget.Text
    $txtArgs.Text = $d.Args
    $txtEnv.Text = $d.Env
}

function Show-Form([string]$n) {
    $script:loading = $true
    $script:editing = $null
    if ($n) {
        $c = Read-Instance $n
        $script:editing = $n
        $txtName.Text = $n; $txtName.IsReadOnly = $true
        $txtName.ToolTip = 'A copy keeps its name. To use another name, create a new copy.'
        $txtTarget.Text = $c.Target
        $txtIcon.Text = ''
        if ($c.CustomIcon) { $txtIcon.Text = [string]$c.Icon }
        if ($cmbMode.Items.Contains($c.Mode)) { $cmbMode.SelectedItem = $c.Mode } else { $cmbMode.SelectedItem = 'None' }
        $txtArgs.Text = $c.Args; $txtEnv.Text = ($c.Env -join "`r`n")
        $chkTaskbar.IsChecked = $c.Taskbar; $chkDesktop.IsChecked = $c.Desktop; $chkStart.IsChecked = $c.StartMenu
        $txtFormTitle.Text = "Edit $n"
        $txtFormSub.Text = 'Change how this copy starts. Saving rebuilds its launcher.'
        $txtFormBack.Text = $n
        $btnSave.Content = 'Save changes'
        $rowOpen.Visibility = 'Collapsed'
    }
    else {
        $txtName.Text = ''; $txtName.IsReadOnly = $false; $txtName.ToolTip = $null
        $txtTarget.Text = ''; $txtIcon.Text = ''; $txtArgs.Text = ''; $txtEnv.Text = ''
        $cmbMode.SelectedItem = 'Redirect'
        $chkTaskbar.IsChecked = $true; $chkDesktop.IsChecked = $true; $chkStart.IsChecked = $true; $chkOpen.IsChecked = $false
        $txtFormTitle.Text = 'New copy'
        $txtFormSub.Text = 'Pick an app to make a separate copy of it.'
        $txtFormBack.Text = 'Your copies'
        $btnSave.Content = 'Create copy'
        $rowOpen.Visibility = 'Visible'
    }
    $txtFormStatus.Text = ''
    $verdictBox.Visibility = 'Collapsed'
    $script:loading = $false
    Show-Page 'form'
    Update-Hint
    $viewForm.ScrollToTop()
    if (-not $n) { $txtName.Focus() | Out-Null }
}

function Close-Form {
    if ($script:editing) { Show-Detail $script:editing } else { Show-Main }
}

# --- actions ---------------------------------------------------------------------------------------------
function Start-Copy([string]$n) {
    $exe = Join-Path (Join-Path $Root $n) "$n.exe"
    if (-not (Test-Path -LiteralPath $exe)) { throw "The launcher for '$n' is missing. Open the copy, click Edit, then Save changes to rebuild it." }
    Start-Process -FilePath $exe
    Set-Status "Launched '$n'."
}

function Stop-Copy([string]$n) {
    $ids = Get-CopyProcessIds $n
    if ($ids.Count -eq 0) { Set-Status "'$n' isn't running."; Update-Running; return }
    $closed = [AlterUi.WindowCloser]::CloseWindowsOf($ids)
    Set-Status "Closing '$n'..."
    # Give the app a few seconds to close by itself, then offer to force it (some apps hide in the tray instead).
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(4)
    $t.Tag = $n
    $t.Add_Tick({
        param($sender, $e)
        $sender.Stop()
        try {
            $name = [string]$sender.Tag
            $left = Get-CopyProcessIds $name
            if ($left.Count -eq 0) { Set-Status "Stopped '$name'."; Update-Running; return }
            if (Confirm-Box "'$name' is still running in the background (some apps keep running in the system tray when their window closes).`n`nForce it to close? Anything unsaved in it may be lost.") {
                foreach ($id in $left) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
                Set-Status "Stopped '$name'."
            }
            else { Set-Status "'$name' is still running." }
            Update-Running
        }
        catch { Show-Error $_.Exception.Message }
    })
    $t.Start()
}

function Switch-Copy([string]$n) {
    $it = Find-CopyItem $n
    if ($it -and $it.Running) { Stop-Copy $n } else { Start-Copy $n; Update-Running }
}

function Save-Form {
    $win.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $txtFormStatus.Text = 'Building the launcher...'
        Show-Busy
        $exe = Save-Instance -Name $txtName.Text -Target $txtTarget.Text -Icon $txtIcon.Text.Trim() `
            -Mode ([string]$cmbMode.SelectedItem) -LaunchArgs $txtArgs.Text -EnvText $txtEnv.Text `
            -Taskbar ([bool]$chkTaskbar.IsChecked) -Desktop ([bool]$chkDesktop.IsChecked) -StartMenu ([bool]$chkStart.IsChecked)
        $n = Get-SafeName $txtName.Text
        $created = -not $script:editing
        $open = ($created -and [bool]$chkOpen.IsChecked)
        $script:editing = $null
        Refresh-List
        Show-Detail $n
        if ($open) { Start-Process -FilePath $exe }
        if ($created) { Set-Status "Created '$n'." } else { Set-Status "Saved '$n'." }
    }
    catch { $txtFormStatus.Text = 'Not saved.'; Show-Error $_.Exception.Message }
    finally { $win.Cursor = $null }
}

# --- events ----------------------------------------------------------------------------------------------
# Every handler catches its own errors: an uncaught one would reach the script's trap and close the window.
$navCopies.Add_Click({ try { $script:editing = $null; Show-Main } catch { Show-Error $_.Exception.Message } })
$navNew.Add_Click({ try { Show-Form $null } catch { Show-Error $_.Exception.Message } })
$btnNewSide.Add_Click({ try { Show-Form $null } catch { Show-Error $_.Exception.Message } })
$btnDetailBack.Add_Click({ try { Show-Main } catch { Show-Error $_.Exception.Message } })
$btnFormBack.Add_Click({ try { Close-Form } catch { Show-Error $_.Exception.Message } })
$btnCancel.Add_Click({ try { Close-Form } catch { Show-Error $_.Exception.Message } })

# Buttons inside the copy cards: Uid says which one, DataContext says which copy.
$icCopies.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($sender, $e)
    try {
        $b = $e.OriginalSource
        if (-not ($b -is [System.Windows.Controls.Button])) { return }
        $it = $b.DataContext
        switch ($b.Uid) {
            'add'     { Show-Form $null }
            'details' { Show-Detail $it.Name }
            'toggle'  { Switch-Copy $it.Name }
        }
    }
    catch { Show-Error $_.Exception.Message }
})
$icCopies.Add_SizeChanged({ try { Update-CardWidth } catch { } })

$txtSearch.Add_TextChanged({
    try {
        $txtSearchHint.Visibility = if ($txtSearch.Text) { 'Collapsed' } else { 'Visible' }
        if ($script:items) { [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:items).Refresh() }
    }
    catch { }
})

$cmbMode.Add_SelectionChanged({
    try {
        Update-Hint
        if (-not $script:loading) { Apply-Defaults }
    }
    catch { Show-Error $_.Exception.Message }
})
foreach ($tb in $txtName, $txtTarget, $txtIcon, $txtEnv) { $tb.Add_TextChanged({ try { if (-not $script:loading) { Update-Preview } } catch { } }) }
$btnDefaults.Add_Click({ try { Apply-Defaults } catch { Show-Error $_.Exception.Message } })

# --- picking the app ------------------------------------------------------------------------------------
function Get-BadgeLabel([string]$level) {
    if ($level -eq 'works') { return 'Works' }
    if ($level -eq 'no') { return "Won't work" }
    return 'Might work'
}

# The "can this app be copied?" line under the App field.
function Show-Verdict([string]$level, [string]$reason) {
    $fg = '#F2C46D'; $bg = '#2A2418'
    if ($level -eq 'works') { $fg = '#7FD49B'; $bg = '#1A2A1F' }
    if ($level -eq 'no') { $fg = '#FF8A80'; $bg = '#33201D' }
    $dotVerdict.Fill = Get-Brush $fg
    $verdictBox.Background = Get-Brush $bg
    $txtVerdict.Text = (Get-BadgeLabel $level) + ': ' + $reason
    $verdictBox.Visibility = 'Visible'
}

# Fills the form for an app: target, suggested name, isolation mode, arguments, and the verdict.
function Use-AppPath([string]$path, [string]$displayName) {
    if ([IO.Path]::GetExtension($path) -ieq '.lnk') {
        $path = (New-Object -ComObject WScript.Shell).CreateShortcut($path).TargetPath
    }
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { throw "File not found:`n$path" }

    $store = $null
    try { $store = Resolve-StoreApp $path } catch { }
    if ($store -and -not $store.Target) { throw $store.Note }
    $target = $path
    $real = $path                       # the actual program, for the name, isolation mode and verdict
    if ($store) {
        $target = $store.Target
        if ($store.Icon) { $real = $store.Icon }
    }
    $script:loading = $true
    $txtTarget.Text = $target
    if (-not $txtName.Text -and -not $script:editing) {
        $desc = $displayName
        if (-not $desc -and $store -and $store.Name) { $desc = $store.Name }
        if (-not $desc) { try { $desc = [Diagnostics.FileVersionInfo]::GetVersionInfo($real).FileDescription } catch { } }
        if (-not $desc) { $desc = [IO.Path]::GetFileNameWithoutExtension($real) }
        $desc = ($desc -replace '[^A-Za-z0-9 _\-]', '').Trim()
        if ($desc.Length -gt 38) { $desc = $desc.Substring(0, 38).Trim() }   # names are max 40 chars
        $txtName.Text = "$desc 2"
    }
    $cmbMode.SelectedItem = Get-AutoMode $real
    $script:loading = $false
    Update-Hint
    Apply-Defaults
    $v = Get-AppVerdict $real
    $reason = $v.Reason
    if ($store) { $reason = 'Microsoft Store app, started through its launch alias. ' + $reason }
    Show-Verdict $v.Level $reason
    $txtFormStatus.Text = "Detected isolation: $($cmbMode.SelectedItem)."
}

# Chip labels with counts, and how many apps the list shows right now.
function Update-PickerInfo {
    $all = @($script:apps)
    $works = @($all | Where-Object { $_.Level -eq 'works' }).Count
    $maybe = @($all | Where-Object { $_.Level -eq 'maybe' }).Count
    $no = @($all | Where-Object { $_.Level -eq 'no' }).Count
    $chipAll.Content = 'All (' + $all.Count + ')'
    $chipWorks.Content = 'Works (' + $works + ')'
    $chipMaybe.Content = 'Might work (' + $maybe + ')'
    $chipNo.Content = "Won't work (" + $no + ')'
    $shown = 0
    if ($script:apps) { $shown = @([System.Windows.Data.CollectionViewSource]::GetDefaultView($script:apps)).Count }
    $txtPickInfo.Text = 'Showing ' + $shown + ' of ' + $all.Count + ' apps. Not listed? Use Other .exe.'
}

# Sort by: Works first (verdict, then name), Name (A-Z), Name (Z-A).
function Set-PickSort {
    if (-not $script:apps) { return }
    $pv = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:apps)
    $up = [System.ComponentModel.ListSortDirection]::Ascending
    $down = [System.ComponentModel.ListSortDirection]::Descending
    $pv.SortDescriptions.Clear()
    $i = $cmbPickSort.SelectedIndex
    if ($i -eq 1) { $pv.SortDescriptions.Add([System.ComponentModel.SortDescription]::new('Name', $up)) }
    elseif ($i -eq 2) { $pv.SortDescriptions.Add([System.ComponentModel.SortDescription]::new('Name', $down)) }
    else {
        $pv.SortDescriptions.Add([System.ComponentModel.SortDescription]::new('Rank', $up))
        $pv.SortDescriptions.Add([System.ComponentModel.SortDescription]::new('Name', $up))
    }
}

# Filter chips: all, works, maybe or no.
function Set-PickLevel([string]$level) {
    $script:pickLevel = $level
    foreach ($c in $chipAll, $chipWorks, $chipMaybe, $chipNo) {
        if ($c.Uid -eq $level) { $c.Tag = 'Selected' } else { $c.Tag = $null }
    }
    if ($script:apps) { [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:apps).Refresh() }
    Update-PickerInfo
}

# Browse: a list of the installed apps with their verdicts (built once, then kept).
function Show-Picker {
    Show-Page 'picker'
    if (-not $script:apps) {
        $txtPickInfo.Text = 'Finding your apps...'
        $win.Cursor = [System.Windows.Input.Cursors]::Wait
        Show-Busy
        try {
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($a in @(Get-InstalledApps)) {
                $entry = [AlterUi.AppEntry]::new()
                $entry.Name = [string]$a.Name
                $entry.Target = [string]$a.Target
                $entry.Real = [string]$a.Real
                $entry.Level = [string]$a.Level
                $entry.Rank = 1
                if ($entry.Level -eq 'works') { $entry.Rank = 0 }
                if ($entry.Level -eq 'no') { $entry.Rank = 2 }
                $entry.Badge = Get-BadgeLabel ([string]$a.Level)
                $entry.Reason = [string]$a.Reason
                if ($a.Real) {
                    $src = Get-ImageSource ([string]$a.Real)
                    if ($src) { $entry.Icon = $src.psobject.BaseObject }
                }
                $list.Add($entry)
            }
            $script:apps = $list
            $icApps.ItemsSource = $list
            $pv = [System.Windows.Data.CollectionViewSource]::GetDefaultView($list)
            $pv.Filter = [Predicate[object]] {
                param($o)
                $q = $txtPickSearch.Text.Trim()
                $levelOk = ($script:pickLevel -eq 'all' -or $o.Level -eq $script:pickLevel)
                return ($levelOk -and (-not $q -or $o.Name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0))
            }
            Set-PickSort
        }
        finally { $win.Cursor = $null }
    }
    Update-PickerInfo
    $txtPickSearch.Text = ''
    $txtPickSearch.Focus() | Out-Null
}

$btnTarget.Add_Click({ try { Show-Picker } catch { $win.Cursor = $null; Show-Error $_.Exception.Message } })
$btnPickerBack.Add_Click({ try { Show-Page 'form' } catch { Show-Error $_.Exception.Message } })

$txtPickSearch.Add_TextChanged({
    try {
        if ($txtPickSearch.Text) { $txtPickHint.Visibility = 'Collapsed' } else { $txtPickHint.Visibility = 'Visible' }
        if ($script:apps) { [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:apps).Refresh() }
        Update-PickerInfo
    }
    catch { }
})

$script:pickLevel = 'all'
foreach ($s in 'Works first', 'Name (A-Z)', 'Name (Z-A)') { [void]$cmbPickSort.Items.Add($s) }
$cmbPickSort.SelectedIndex = 0
$cmbPickSort.Add_SelectionChanged({ try { Set-PickSort; Update-PickerInfo } catch { } })
$pnlChips.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($sender, $e)
    try {
        $b = $e.OriginalSource
        if ($b -is [System.Windows.Controls.Button]) { Set-PickLevel $b.Uid }
    }
    catch { }
})

# A row in the picker: use that app (apps that won't work get a warning first, but are allowed).
$icApps.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
    param($sender, $e)
    try {
        $b = $e.OriginalSource
        if (-not ($b -is [System.Windows.Controls.Button]) -or $b.Uid -ne 'pick') { return }
        $app = $b.DataContext
        if (-not $app.Target) { Show-Error ("$($app.Name) can't be copied.`n`n" + $app.Reason); return }
        if ($app.Level -eq 'no') {
            if (-not (Confirm-Box ("$($app.Name) probably won't work as a copy:`n`n" + $app.Reason + "`n`nUse it anyway?"))) { return }
        }
        Show-Page 'form'
        Use-AppPath $app.Target $app.Name
    }
    catch { $script:loading = $false; Show-Error $_.Exception.Message }
})

# Other .exe...: the normal file picker, for apps that aren't in the Start Menu.
$btnOtherExe.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Applications (*.exe)|*.exe'
        $dlg.Title = 'Pick the app to make a copy of'
        # Store app launch aliases fail the dialog's own checks ("The file cannot be accessed by the
        # system"), so turn those off and check the choice here instead.
        $dlg.CheckFileExists = $false
        $dlg.ValidateNames = $false
        $dlg.DereferenceLinks = $false
        if ($dlg.ShowDialog($script:owner) -ne 'OK') { return }
        Show-Page 'form'
        Use-AppPath $dlg.FileName ''
    }
    catch { $script:loading = $false; Show-Error $_.Exception.Message }
})

$btnIcon.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Icons and images (*.png;*.ico;*.jpg;*.exe)|*.png;*.ico;*.jpg;*.jpeg;*.bmp;*.exe|All files|*.*'
        if ($dlg.ShowDialog($script:owner) -eq 'OK') { $txtIcon.Text = $dlg.FileName; Update-Preview }
    }
    catch { Show-Error $_.Exception.Message }
})

$btnSave.Add_Click({ try { Save-Form } catch { Show-Error $_.Exception.Message } })

$btnDetToggle.Add_Click({ try { if ($script:detail) { Switch-Copy $script:detail } } catch { Show-Error $_.Exception.Message } })
$btnDetEdit.Add_Click({ try { if ($script:detail) { Show-Form $script:detail } } catch { Show-Error $_.Exception.Message } })
$btnDetFolder.Add_Click({
    try {
        $d = $Root
        if ($script:detail -and (Test-Path -LiteralPath (Join-Path $Root $script:detail))) { $d = Join-Path $Root $script:detail }
        Start-Process explorer.exe -ArgumentList "`"$d`""
    }
    catch { Show-Error $_.Exception.Message }
})
$btnDetDelete.Add_Click({
    try {
        $n = $script:detail
        if (-not $n) { return }
        if (-not (Confirm-Box "Delete '$n'?`n`nThis removes its launcher, shortcuts AND its data folder (sign-ins, settings). The original app is not touched.")) { return }
        try { Remove-Instance $n }
        catch { Show-Error ("Couldn't delete (is it still running? Stop it first.)`n`n" + $_.Exception.Message); return }
        Show-Main
        Set-Status "Deleted '$n'."
    }
    catch { Show-Error $_.Exception.Message }
})

$win.Add_SourceInitialized({
    try {
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
        $script:owner = New-Object AlterUi.Owner $h
        [AlterUi.Dwm]::Dark($h, 0x000B0B0B, 0x001C1C1C)
    }
    catch { }
})

# Refresh the running state every 2 seconds.
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({ try { Update-Running } catch { } })
$win.Add_Closed({ $timer.Stop() })

# --- Alter's own logo and Start Menu shortcut -----------------------------------------------------------
$AlterIcon = Join-Path $Root 'alter.ico'
$AlterIconBytes = [Convert]::FromBase64String($AlterIconB64)
try {
    $have = $null
    if (Test-Path -LiteralPath $AlterIcon) { $have = [IO.File]::ReadAllBytes($AlterIcon) }
    if (-not $have -or $have.Length -ne $AlterIconBytes.Length) { [IO.File]::WriteAllBytes($AlterIcon, $AlterIconBytes) }
}
catch { }
try {
    $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object IO.MemoryStream (, $AlterIconBytes)),
        [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
}
catch { }
try { [void][AlterUi.AppId]::SetCurrentProcessExplicitAppUserModelID('Alter.App') } catch { }
try {
    $alterLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Alter.lnk'
    if ($env:ALTER_EXE -and (Test-Path -LiteralPath $env:ALTER_EXE)) {
        # Started from Alter.exe: the Start Menu entry opens Alter.exe (no console window).
        [AlterUi.AppShortcut]::Create($alterLnk, $env:ALTER_EXE, '', (Split-Path -Parent $env:ALTER_EXE),
            $env:ALTER_EXE, 'Alter.App', 'Alter - separate copies of any app')
    }
    elseif ($PSCommandPath) {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        [AlterUi.AppShortcut]::Create($alterLnk, $psExe,
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`"",
            (Split-Path -Parent $PSCommandPath), $AlterIcon, 'Alter.App', 'Alter - separate copies of any app')
    }
}
catch { }

# Open at the designed size, but never larger than the screen.
$work = [System.Windows.SystemParameters]::WorkArea
$win.Width = [Math]::Max($win.MinWidth, [Math]::Min(1280, $work.Width - 24))
$win.Height = [Math]::Max($win.MinHeight, [Math]::Min(820, $work.Height - 24))

Show-Main
$timer.Start()
[void]$win.ShowDialog()
