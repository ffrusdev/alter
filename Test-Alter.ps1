<#
  Test-Alter.ps1 - checks that Alter works on this PC (steps 1-5 of the test plan).

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Alter.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Alter.ps1 -Cleanup

  It only creates/removes the test copies "Test Browser" and "Test App" (in %LOCALAPPDATA%\ParallWin and
  their Alter shortcuts). It never touches the original apps or your real profiles, and it never
  closes anything: it asks you to close the test window yourself. Everything is logged to
  Test-Alter.log next to this script.
#>
param([switch]$Cleanup)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Main = Join-Path $Here 'Alter.ps1'
$PS51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Root = Join-Path $env:LOCALAPPDATA 'ParallWin'
$StartDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Alter'
$TestNames = @('Test Browser', 'Test App')
$script:Failures = 0

function Pass([string]$m) { Write-Host "  PASS  $m" -ForegroundColor Green }
function Fail([string]$m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:Failures++ }
function Info([string]$m) { Write-Host "        $m" }
function Step([string]$m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }
function Check([bool]$ok, [string]$m) { if ($ok) { Pass $m } else { Fail $m } }

function Remove-TestCopy([string]$n) {
    # Same steps as Remove-Instance in Alter.ps1, limited to the test names.
    if ($TestNames -notcontains $n) { throw "Refusing to remove '$n' (not a test copy)." }
    $dir = Join-Path $Root $n
    if (Test-Path -LiteralPath $dir) {
        $trash = Join-Path $Root ('.trash\' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $trash) | Out-Null
        try { [IO.Directory]::Move($dir, $trash) }
        catch { Fail "'$n' is still running - close its window and run -Cleanup again."; return }
        Remove-Item -LiteralPath $trash -Recurse -Force
    }
    foreach ($l in (Join-Path ([Environment]::GetFolderPath('Desktop')) "$n.lnk"), (Join-Path $StartDir "$n.lnk")) {
        if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force }
    }
    Pass "Removed test copy '$n'"
}

function Get-ProcsUnder([string]$exe) {
    @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $exe) })
}

function First-Existing([string[]]$paths) {
    foreach ($p in $paths) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

function Find-Newest([string]$root, [string]$exeName) {
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    $best = Get-ChildItem -LiteralPath $root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $exeName) } |
        Sort-Object { try { [version]$_.Name.Substring(4) } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
    if ($best) { return (Join-Path $best.FullName $exeName) }
    return $null
}

function Test-Copy([string]$n, [string]$target, [string]$kind) {
    Step "Create '$n' from $target"
    $out = & $PS51 -NoProfile -ExecutionPolicy Bypass -File $Main -Name $n -Target $target -NoDesktopShortcut 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Info "$_" }
    Check ($code -eq 0) "CLI exit code is 0 (was $code)"

    $dir = Join-Path $Root $n
    $exe = Join-Path $dir "$n.exe"
    foreach ($f in 'config.txt', 'icon.ico', "$n.exe") { Check (Test-Path -LiteralPath (Join-Path $dir $f)) "$f exists" }
    Check (Test-Path -LiteralPath (Join-Path $StartDir "$n.lnk")) "Start Menu shortcut Programs\Alter\$n.lnk exists"
    Check (-not (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) "$n.lnk"))) 'No Desktop shortcut (-NoDesktopShortcut)'
    if (-not (Test-Path -LiteralPath $exe)) { Fail 'Launcher missing - skipping launch test'; return }
    Info 'config.txt:'
    Get-Content -LiteralPath (Join-Path $dir 'config.txt') | ForEach-Object { Info "  $_" }

    $prof = Join-Path $dir 'data\profile'
    $targetName = [IO.Path]::GetFileName($target)
    Step "Launch '$n'"
    Start-Process -FilePath $exe
    Start-Sleep -Seconds 8

    $launchers = @(Get-ProcsUnder $exe)
    Check ($launchers.Count -ge 1) "Launcher '$n.exe' is still running in the background ($($launchers.Count) process)"

    $app = @(Get-CimInstance Win32_Process -Filter "Name='$targetName'" -ErrorAction SilentlyContinue)
    if ($kind -eq 'Chromium') {
        $mine = @($app | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($prof, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        Check ($mine.Count -ge 1) "$targetName runs with --user-data-dir under $prof ($($mine.Count) processes)"
        $main = $mine | Where-Object { $_.CommandLine -notmatch '--type=' } | Select-Object -First 1
        if ($main) { Info "Main process $($main.ProcessId): $($main.CommandLine)" }
    }
    else {
        Check ($app.Count -ge 1) "$targetName is running"
        $roaming = Join-Path $dir 'data\Roaming'
        $used = (Test-Path -LiteralPath $roaming) -and @(Get-ChildItem -LiteralPath $roaming -Force -ErrorAction SilentlyContinue).Count -gt 0
        Check $used "App wrote its settings into the copy's own folder ($roaming)"
    }

    Write-Host ""
    Write-Host "  >> Look at the taskbar: does '$n' have its OWN button, separate from your normal $targetName?" -ForegroundColor Yellow
    $ans = Read-Host '     Type y or n'
    Check ($ans -match '^\s*y') "Own taskbar button (your answer: $ans)"

    Write-Host "  >> Now close ONLY the '$n' window(s) (not your normal one), then press Enter." -ForegroundColor Yellow
    [void](Read-Host)
    $deadline = (Get-Date).AddSeconds(30)
    while (@(Get-ProcsUnder $exe).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    Check (@(Get-ProcsUnder $exe).Count -eq 0) "Launcher exited after the app closed"
    if (@(Get-ProcsUnder $exe).Count -gt 0) {
        $left = @(Get-CimInstance Win32_Process -Filter "Name='$targetName'" | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($prof, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        Info "Processes still using the test profile: $($left.Count) (some apps keep running in the tray - quit it from there)"
    }
}

Start-Transcript -LiteralPath (Join-Path $Here 'Test-Alter.log') -Force | Out-Null
try {
    if ($Cleanup) {
        Step 'Cleanup'
        foreach ($n in $TestNames) { Remove-TestCopy $n }
        return
    }

    Step '1. Environment'
    Info "Windows: $([Environment]::OSVersion.VersionString), 64-bit OS: $([Environment]::Is64BitOperatingSystem)"
    Info "This shell: PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Check (Test-Path -LiteralPath $PS51) "Windows PowerShell exists at $PS51"
    if (Test-Path -LiteralPath $PS51) {
        $v = & $PS51 -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
        Check ($v -like '5.1*') "Windows PowerShell version is 5.1 ($v)"
    }
    $csc64 = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $csc32 = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    Check ((Test-Path -LiteralPath $csc64) -or (Test-Path -LiteralPath $csc32)) ".NET Framework 4 C# compiler exists ($csc64)"
    $rel = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
    Info ".NET Framework 4.x release key: $rel (528040+ = 4.8)"

    Step '2. Compile the launcher (same as Build-Launcher, run inside Windows PowerShell 5.1)'
    $compile = @'
$ErrorActionPreference = 'Stop'
$t = [IO.File]::ReadAllText($args[0])
$m = [regex]::Match($t, "\`$LauncherSource = @'\r?\n(.*?)\r?\n'@", 'Singleline')
if (-not $m.Success) { 'NO-SOURCE'; exit 2 }
$out = Join-Path $env:TEMP 'Alter-compile-test.exe'
$cp = New-Object System.CodeDom.Compiler.CompilerParameters
$cp.GenerateExecutable = $true; $cp.GenerateInMemory = $false; $cp.OutputAssembly = $out
foreach ($r in 'System.dll', 'System.Core.dll', 'System.Windows.Forms.dll') { [void]$cp.ReferencedAssemblies.Add($r) }
$cp.CompilerOptions = '/target:winexe /optimize+'
$res = (New-Object Microsoft.CSharp.CSharpCodeProvider).CompileAssemblyFromSource($cp, $m.Groups[1].Value)
$res.Errors | ForEach-Object { $_.ToString() }
if ($res.Errors.HasErrors) { exit 1 }
Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
'COMPILED'
'@
    $tmp = Join-Path $env:TEMP 'Alter-compile-test.ps1'
    [IO.File]::WriteAllText($tmp, $compile)
    $res = & $PS51 -NoProfile -ExecutionPolicy Bypass -File $tmp $Main 2>&1
    $code = $LASTEXITCODE
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    $res | ForEach-Object { Info "$_" }
    Check ($code -eq 0) 'Launcher source compiles with CSharpCodeProvider'
    if ($code -ne 0) { throw 'Stopping: the launcher does not compile. Send me Test-Alter.log.' }

    Step '3-4. Browser copy'
    $browser = First-Existing @(
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'))
    if ($browser) { Test-Copy 'Test Browser' $browser 'Chromium' } else { Fail 'Neither Chrome nor Edge found' }

    Step '5. Second app (VS Code, Discord or Slack)'
    $vscode = First-Existing @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'))
    $discord = Find-Newest (Join-Path $env:LOCALAPPDATA 'Discord') 'Discord.exe'
    $slack = First-Existing @((Join-Path $env:LOCALAPPDATA 'slack\slack.exe'), (Join-Path $env:ProgramFiles 'Slack\slack.exe'))
    if ($vscode) { Test-Copy 'Test App' $vscode 'Chromium' }
    elseif ($slack) { Test-Copy 'Test App' $slack 'Chromium' }
    elseif ($discord) { Test-Copy 'Test App' $discord 'Redirect' }
    else { Info 'None of VS Code, Discord or Slack found - skipped.' }
}
catch { Fail $_.Exception.Message }
finally {
    Write-Host ""
    if ($script:Failures -eq 0) { Write-Host 'All checks passed.' -ForegroundColor Green }
    else { Write-Host "$($script:Failures) check(s) failed." -ForegroundColor Red }
    Stop-Transcript | Out-Null
    Write-Host "Log: $(Join-Path $Here 'Test-Alter.log')"
}
