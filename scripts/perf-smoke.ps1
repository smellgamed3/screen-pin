#Requires -Version 7.0
param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,
    [Parameter(Mandatory = $true)]
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'
$resolvedExe = (Resolve-Path -LiteralPath $ExePath).ProviderPath
if ([IO.Path]::GetExtension($resolvedExe) -ine '.exe') {
    throw 'ExePath must identify the Release Screen Pin executable.'
}
$resolvedOutput = [IO.Path]::GetFullPath($OutputDir)
[IO.Directory]::CreateDirectory($resolvedOutput) | Out-Null
$runName = 'perf-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$runDir = Join-Path $resolvedOutput $runName
$configDir = Join-Path $runDir 'config'
[IO.Directory]::CreateDirectory($configDir) | Out-Null
$reportPath = Join-Path $runDir 'report.json'

if (-not ('ScreenPinPerfNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class ScreenPinPerfNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hwnd, StringBuilder name, int capacity);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr address);

    public static IntPtr FindWindow(uint processId, string className) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hwnd, IntPtr data) {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner != processId) return true;
            var name = new StringBuilder(256);
            if (GetClassNameW(hwnd, name, name.Capacity) > 0 && name.ToString() == className) {
                found = hwnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool AnswersNull(IntPtr hwnd) {
        UIntPtr result;
        // SMTO_BLOCK | SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT, bounded to 50 ms.
        return SendMessageTimeoutW(hwnd, 0, IntPtr.Zero, IntPtr.Zero, 0x23, 50, out result) != IntPtr.Zero;
    }

    public static string[] CommandArgs(string commandLine) {
        int count;
        IntPtr arguments = CommandLineToArgvW(commandLine, out count);
        if (arguments == IntPtr.Zero) throw new InvalidOperationException("Cannot parse launched process command line.");
        try {
            var result = new string[count];
            for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(arguments, i * IntPtr.Size));
            return result;
        } finally { LocalFree(arguments); }
    }
}
'@
}

$exeFile = Get-Item -LiteralPath $resolvedExe
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
$report = [ordered]@{
    schema_version = 1
    scope = 'Release local resource/startup smoke only; this does not prove the complete performance or release acceptance gates.'
    started_utc = [DateTime]::UtcNow.ToString('o')
    executable = [ordered]@{
        path = $resolvedExe
        sha256 = (Get-FileHash -LiteralPath $resolvedExe -Algorithm SHA256).Hash.ToLowerInvariant()
        size_bytes = $exeFile.Length
        last_write_utc = $exeFile.LastWriteTimeUtc.ToString('o')
        file_version = $exeFile.VersionInfo.FileVersion
        product_version = $exeFile.VersionInfo.ProductVersion
        build_assertion = 'Caller supplies a freshly built Release executable; build profile is not inferred from the file name.'
    }
    environment = [ordered]@{
        os_caption = $os.Caption
        os_version = $os.Version
        os_build = $os.BuildNumber
        architecture = $os.OSArchitecture
        cpu = $cpu.Name
        logical_processors = [Environment]::ProcessorCount
        powershell = $PSVersionTable.PSVersion.ToString()
    }
    isolation = [ordered]@{
        config_dir = $configDir
        config_started_empty = $true
        arguments = @('--background', '--config-dir', $configDir)
        process_id = $null
        identity_verified = $false
        user_windows_moved = $false
        autostart_or_elevation_requested = $false
        artifacts_preserved = $true
    }
    startup = [ordered]@{
        definition = 'Elapsed from immediately before Start-Process to the same PID-owned ScreenPin.Host answering a bounded WM_NULL; polled every 20 ms. A message-loop readiness proxy, not proof of tray creation or hotkey registration.'
        scenario = 'Fresh isolated configuration, background launch; this is not the existing-config startup scenario or first visible UI usability test.'
        proxy_budget_ms = 1000
        elapsed_ms = $null
        host_found = $false
        message_loop_responded = $false
        proxy_within_budget = $false
    }
    idle = [ordered]@{
        definition = 'After five seconds of warm-up, measure process CPU time delta during at least 60 seconds without script commands or GUI interactions; sample private committed bytes once per second.'
        warmup_seconds = 5
        requested_seconds = 60
        elapsed_seconds = $null
        cpu_start_ms = $null
        cpu_end_ms = $null
        cpu_delta_ms = $null
        cpu_budget_ms = 300
        cpu_single_logical_core_percent = $null
        cpu_within_budget = $false
        private_start_bytes = $null
        private_end_bytes = $null
        private_max_bytes = $null
        private_budget_bytes = 50 * 1MB
        private_within_budget = $false
        settings_hidden_throughout_sample = $false
    }
    gui = [ordered]@{
        definition = 'Post SHOW_MESSAGE (WM_APP+1) only to the launched PID-owned host, wait for its visible ScreenPin.Settings and responsive message loop, then settle for two seconds.'
        visible_and_responsive = $false
        private_bytes = $null
        private_budget_bytes = 80 * 1MB
        private_within_budget = $false
    }
    shutdown = [ordered]@{
        definition = 'Post WM_COMMAND 403 to the PID-owned host and wait up to ten seconds for normal exit.'
        command_sent = $false
        normal_exit = $false
        exit_code = $null
        forced_cleanup = $false
        process_remaining = $false
    }
    limitations = @(
        'One isolated run does not establish repeated startup distributions, restore p95, cross-DPI behavior, or growth after 100 operations.',
        'The readiness proxy does not prove actual global hotkey availability or a visible Explorer notification-area icon.',
        'Opening the configuration window is an intentional test action; no other application window is moved.',
        'This script never requests auto-start or elevation and preserves its dedicated test configuration and raw report.'
    )
    errors = @()
    passed = $false
}

$process = $null
$hostWindow = [IntPtr]::Zero

function Confirm-PerfProcess {
    if ($null -eq $process) { throw 'No launched process is available.' }
    $process.Refresh()
    if ($process.HasExited) { throw 'The launched process exited before verification.' }
    $actual = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $process.Id)
    if ($null -eq $actual -or [string]::IsNullOrEmpty($actual.ExecutablePath) -or [string]::IsNullOrEmpty($actual.CommandLine)) {
        throw 'Cannot verify the launched process executable and command line; refusing to control any process.'
    }
    if (-not [string]::Equals([IO.Path]::GetFullPath($actual.ExecutablePath), $resolvedExe, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Launched PID executable differs from ExePath; refusing to control it.'
    }
    $arguments = [ScreenPinPerfNative]::CommandArgs($actual.CommandLine)
    $directoryIndex = [Array]::IndexOf($arguments, '--config-dir')
    if ($directoryIndex -lt 0 -or $directoryIndex + 1 -ge $arguments.Length -or
        -not [string]::Equals($arguments[$directoryIndex + 1], $configDir, [StringComparison]::OrdinalIgnoreCase) -or
        [Array]::IndexOf($arguments, '--background') -lt 0) {
        throw 'Launched PID does not have the exact isolated arguments; refusing to control it.'
    }
    $report.isolation.identity_verified = $true
}

function Confirm-PerfWindow([IntPtr]$Handle) {
    Confirm-PerfProcess
    [uint32]$owner = 0
    [ScreenPinPerfNative]::GetWindowThreadProcessId($Handle, [ref]$owner) | Out-Null
    if ($Handle -eq [IntPtr]::Zero -or $owner -ne $process.Id) {
        throw 'Window no longer belongs to the launched process; refusing to message it.'
    }
}

function Wait-PerfExit([int]$TimeoutMilliseconds) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $process.Refresh()
        if ($process.HasExited) { return $true }
        Start-Sleep -Milliseconds 50
    } while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    return $false
}

try {
    $startupWatch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $resolvedExe -ArgumentList '--background', '--config-dir', ('"' + $configDir + '"') -WindowStyle Hidden -PassThru
    $report.isolation.process_id = $process.Id
    while ($startupWatch.ElapsedMilliseconds -lt 10000) {
        $process.Refresh()
        if ($process.HasExited) { throw 'Screen Pin exited during startup.' }
        $hostWindow = [ScreenPinPerfNative]::FindWindow($process.Id, 'ScreenPin.Host')
        if ($hostWindow -ne [IntPtr]::Zero -and [ScreenPinPerfNative]::AnswersNull($hostWindow)) {
            $report.startup.elapsed_ms = $startupWatch.Elapsed.TotalMilliseconds
            $report.startup.host_found = $true
            $report.startup.message_loop_responded = $true
            break
        }
        Start-Sleep -Milliseconds 20
    }
    if (-not $report.startup.message_loop_responded) { throw 'Host message loop did not become responsive within ten seconds.' }
    Confirm-PerfWindow $hostWindow
    $report.startup.proxy_within_budget = $report.startup.elapsed_ms -le $report.startup.proxy_budget_ms
    Write-Host ('Startup readiness proxy: {0:N1} ms. Warming up for five seconds.' -f $report.startup.elapsed_ms)
    Start-Sleep -Seconds 5
    Confirm-PerfProcess
    $backgroundSettings = [ScreenPinPerfNative]::FindWindow($process.Id, 'ScreenPin.Settings')
    if ($backgroundSettings -ne [IntPtr]::Zero -and [ScreenPinPerfNative]::IsWindowVisible($backgroundSettings)) {
        throw 'Configuration UI is visible during the intended background test; refusing to label this tray-idle memory.'
    }
    $process.Refresh()
    $cpuStart = $process.TotalProcessorTime.TotalMilliseconds
    $privateStart = $process.PrivateMemorySize64
    $privateMaximum = $privateStart
    $idleWatch = [Diagnostics.Stopwatch]::StartNew()
    Write-Host 'Measuring idle CPU and private memory for 60 seconds; no window operations are being sent.'
    while ($idleWatch.Elapsed.TotalSeconds -lt 60) {
        Start-Sleep -Milliseconds 1000
        $process.Refresh()
        if ($process.HasExited) { throw 'Screen Pin exited during idle measurement.' }
        $backgroundSettings = [ScreenPinPerfNative]::FindWindow($process.Id, 'ScreenPin.Settings')
        if ($backgroundSettings -ne [IntPtr]::Zero -and [ScreenPinPerfNative]::IsWindowVisible($backgroundSettings)) {
            throw 'Configuration UI became visible during the idle interval; sample is not a valid tray-idle observation.'
        }
        $privateMaximum = [Math]::Max($privateMaximum, $process.PrivateMemorySize64)
    }
    $process.Refresh()
    $cpuEnd = $process.TotalProcessorTime.TotalMilliseconds
    $report.idle.elapsed_seconds = $idleWatch.Elapsed.TotalSeconds
    $report.idle.cpu_start_ms = $cpuStart
    $report.idle.cpu_end_ms = $cpuEnd
    $report.idle.cpu_delta_ms = $cpuEnd - $cpuStart
    $report.idle.cpu_single_logical_core_percent = 100 * ($cpuEnd - $cpuStart) / ($report.idle.elapsed_seconds * 1000)
    $report.idle.cpu_within_budget = $report.idle.cpu_delta_ms -le $report.idle.cpu_budget_ms
    $report.idle.private_start_bytes = $privateStart
    $report.idle.private_end_bytes = $process.PrivateMemorySize64
    $report.idle.private_max_bytes = $privateMaximum
    $report.idle.private_within_budget = $privateMaximum -le $report.idle.private_budget_bytes
    $report.idle.settings_hidden_throughout_sample = $true

    Confirm-PerfWindow $hostWindow
    if (-not [ScreenPinPerfNative]::PostMessageW($hostWindow, 0x8001, [IntPtr]::Zero, [IntPtr]::Zero)) {
        throw 'Could not post SHOW_MESSAGE to the isolated host.'
    }
    $guiWatch = [Diagnostics.Stopwatch]::StartNew()
    while ($guiWatch.ElapsedMilliseconds -lt 5000) {
        $settingsWindow = [ScreenPinPerfNative]::FindWindow($process.Id, 'ScreenPin.Settings')
        if ($settingsWindow -ne [IntPtr]::Zero -and [ScreenPinPerfNative]::IsWindowVisible($settingsWindow) -and
            [ScreenPinPerfNative]::AnswersNull($settingsWindow)) {
            Confirm-PerfWindow $settingsWindow
            $report.gui.visible_and_responsive = $true
            break
        }
        Start-Sleep -Milliseconds 50
    }
    if (-not $report.gui.visible_and_responsive) { throw 'Isolated configuration UI did not become visible and responsive.' }
    Start-Sleep -Seconds 2
    Confirm-PerfProcess
    $process.Refresh()
    $report.gui.private_bytes = $process.PrivateMemorySize64
    $report.gui.private_within_budget = $report.gui.private_bytes -le $report.gui.private_budget_bytes

    Confirm-PerfWindow $hostWindow
    $report.shutdown.command_sent = [ScreenPinPerfNative]::PostMessageW($hostWindow, 0x111, [IntPtr]403, [IntPtr]::Zero)
    if (-not $report.shutdown.command_sent) { throw 'Could not post the normal exit command.' }
    $report.shutdown.normal_exit = Wait-PerfExit 10000
    if (-not $report.shutdown.normal_exit) { throw 'Screen Pin did not exit normally within ten seconds.' }
    $report.shutdown.exit_code = $process.ExitCode
} catch {
    $report.errors += $_.Exception.Message
} finally {
    if ($null -ne $process) {
        $process.Refresh()
        if (-not $process.HasExited) {
            try {
                Confirm-PerfProcess
                $cleanupHost = [ScreenPinPerfNative]::FindWindow($process.Id, 'ScreenPin.Host')
                if ($cleanupHost -ne [IntPtr]::Zero) {
                    Confirm-PerfWindow $cleanupHost
                    [ScreenPinPerfNative]::PostMessageW($cleanupHost, 0x111, [IntPtr]403, [IntPtr]::Zero) | Out-Null
                }
                if (-not (Wait-PerfExit 3000)) {
                    Confirm-PerfProcess
                    Stop-Process -InputObject $process -Force
                    $report.shutdown.forced_cleanup = $true
                    Wait-PerfExit 3000 | Out-Null
                }
            } catch { $report.errors += ('Isolated process cleanup: ' + $_.Exception.Message) }
        }
        $process.Refresh()
        $report.shutdown.process_remaining = -not $process.HasExited
        if ($process.HasExited) { $report.shutdown.exit_code = $process.ExitCode }
    }
    $report.finished_utc = [DateTime]::UtcNow.ToString('o')
    $report.passed = $report.errors.Count -eq 0 -and $report.startup.proxy_within_budget -and
        $report.idle.cpu_within_budget -and $report.idle.private_within_budget -and
        $report.gui.visible_and_responsive -and $report.gui.private_within_budget -and
        $report.shutdown.normal_exit -and $report.shutdown.exit_code -eq 0 -and
        -not $report.shutdown.forced_cleanup -and -not $report.shutdown.process_remaining
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding utf8
    Write-Host ('Performance smoke report: ' + $reportPath)
}

if (-not $report.passed) { exit 1 }
