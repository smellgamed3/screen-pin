#Requires -Version 7.0
param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [ValidateRange(20, 500)][int]$Cycles = 100
)
$ErrorActionPreference = 'Stop'
$resolvedExe = (Resolve-Path -LiteralPath $ExePath).ProviderPath
$runDir = Join-Path ([IO.Path]::GetFullPath($OutputDir)) ('hotkey-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$configDir = Join-Path $runDir 'config'
[IO.Directory]::CreateDirectory($configDir) | Out-Null
$configPath = Join-Path $configDir 'config.json'
$reportPath = Join-Path $runDir 'report.json'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class PinRealKeys {
 public delegate bool EnumProc(IntPtr h,IntPtr d);
 private delegate IntPtr WndProc(IntPtr h,uint m,IntPtr w,IntPtr l);
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct WindowClass { public uint style;public IntPtr proc;public int classExtra,windowExtra;public IntPtr instance,icon,cursor,background;public string menu,name; }
 [StructLayout(LayoutKind.Sequential)] private struct Message {public IntPtr h;public uint m;public UIntPtr w;public IntPtr l;public uint time;public int x,y;public uint extra;}
 [StructLayout(LayoutKind.Sequential)] private struct Keyboard {public ushort key,scan;public uint flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Sequential)] private struct Mouse {public int x,y;public uint data,flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Explicit)] private struct InputData {[FieldOffset(0)]public Keyboard keyboard;[FieldOffset(0)]public Mouse mouse;}
 [StructLayout(LayoutKind.Sequential)] private struct Input {public uint type;public InputData data;}
 [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo {public uint size;public Rect bounds,work;public uint flags;}
 [DllImport("user32.dll")]private static extern bool EnumWindows(EnumProc callback,IntPtr d);
 [DllImport("user32.dll")]public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern int GetClassNameW(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]private static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")]private static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")]private static extern short GetAsyncKeyState(int key);
 [DllImport("user32.dll",SetLastError=true)]private static extern uint SendInput(uint n,Input[] inputs,int size);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern ushort RegisterClassW(ref WindowClass c);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)]private static extern IntPtr CreateWindowExW(uint ex,string c,string t,uint style,int x,int y,int w,int h,IntPtr p,IntPtr menu,IntPtr instance,IntPtr param);
 [DllImport("user32.dll")]private static extern IntPtr DefWindowProcW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")]private static extern bool DestroyWindow(IntPtr h);
 [DllImport("user32.dll")]private static extern void PostQuitMessage(int code);
 [DllImport("user32.dll")]private static extern int GetMessageW(out Message m,IntPtr h,uint first,uint last);
 [DllImport("user32.dll")]private static extern bool TranslateMessage(ref Message m);
 [DllImport("user32.dll")]private static extern IntPtr DispatchMessageW(ref Message m);
 [DllImport("user32.dll")]private static extern bool ShowWindow(IntPtr h,int command);
 [DllImport("user32.dll")]public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll",SetLastError=true)]private static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode,SetLastError=true)]private static extern IntPtr SendText(IntPtr h,uint m,IntPtr w,StringBuilder l,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll")]private static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")]private static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]private static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
 [DllImport("dwmapi.dll")]private static extern int DwmGetWindowAttribute(IntPtr h,int attribute,out Rect value,int size);
 [DllImport("user32.dll")]private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll")]private static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")]private static extern IntPtr MonitorFromWindow(IntPtr h,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern bool GetMonitorInfoW(IntPtr h,ref MonitorInfo info);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]private static extern IntPtr GetModuleHandleW(string name);
 private static Thread fixtureThread;
 private static readonly ManualResetEventSlim ready=new ManualResetEventSlim(false);
 private static readonly WndProc procedure=WindowProcedure;
 private static string failure;
 private static string fixtureClass;
 private static bool held;
 public static IntPtr Fixture;
 private static IntPtr WindowProcedure(IntPtr h,uint m,IntPtr w,IntPtr l){if(m==0x10){DestroyWindow(h);return IntPtr.Zero;}if(m==2){PostQuitMessage(0);return IntPtr.Zero;}return DefWindowProcW(h,m,w,l);}
 public static IntPtr StartFixture(){
  fixtureClass="ScreenPin.RealHotkeyFixture."+Guid.NewGuid().ToString("N");
  fixtureThread=new Thread(delegate(){try{
   SetThreadDpiAwarenessContext(new IntPtr(-4));
   var instance=GetModuleHandleW(null);
   var c=new WindowClass{proc=Marshal.GetFunctionPointerForDelegate(procedure),instance=instance,name=fixtureClass};
   if(RegisterClassW(ref c)==0)throw new InvalidOperationException("Fixture RegisterClassW failed");
   Fixture=CreateWindowExW(0,fixtureClass,"Screen Pin isolated real hotkey fixture",0x00cf0000,140,140,720,480,IntPtr.Zero,IntPtr.Zero,instance,IntPtr.Zero);
   if(Fixture==IntPtr.Zero)throw new InvalidOperationException("Fixture CreateWindowExW failed");
   ShowWindow(Fixture,1);ShowWindow(Fixture,5);SetForegroundWindow(Fixture);ready.Set();
   Message message;while(GetMessageW(out message,IntPtr.Zero,0,0)>0){TranslateMessage(ref message);DispatchMessageW(ref message);}
  }catch(Exception e){failure=e.ToString();ready.Set();}});
  fixtureThread.IsBackground=true;fixtureThread.Start();
  if(!ready.Wait(3000))throw new InvalidOperationException("Fixture UI thread startup timed out");
  if(failure!=null)throw new InvalidOperationException(failure);
  return Fixture;
 }
 public static void StopFixture(){ReleaseHeldKeys();if(Fixture!=IntPtr.Zero&&IsWindow(Fixture))PostMessageW(Fixture,0x10,IntPtr.Zero,IntPtr.Zero);if(fixtureThread!=null)fixtureThread.Join(2000);}
 public static void AssertForeground(){
  uint owner;GetWindowThreadProcessId(Fixture,out owner);
  var name=new StringBuilder(256);GetClassNameW(Fixture,name,name.Capacity);
  if(Fixture==IntPtr.Zero||!IsWindow(Fixture)||owner!=(uint)System.Diagnostics.Process.GetCurrentProcess().Id||name.ToString()!=fixtureClass||GetForegroundWindow()!=Fixture)
   throw new InvalidOperationException("Foreground is not the owned fixture; input cancelled without refocusing or bypassing Windows foreground policy.");
 }
 private static Input Key(ushort key,bool up){return new Input{type=1,data=new InputData{keyboard=new Keyboard{key=key,flags=up?2u:0u}}};}
 private static void Send(Input[] inputs){if(SendInput((uint)inputs.Length,inputs,Marshal.SizeOf(typeof(Input)))!=inputs.Length)throw new InvalidOperationException("SendInput did not accept the complete owned-fixture sequence");}
 private static void CheckReleased(){foreach(int key in new[]{0x11,0x12,0x78,0x79})if((GetAsyncKeyState(key)&0x8000)!=0)throw new InvalidOperationException("A test modifier/function key is physically held; input cancelled.");}
 public static void Chord(ushort functionKey){AssertForeground();CheckReleased();try{Send(new[]{Key(0x11,false),Key(0x12,false),Key(functionKey,false),Key(functionKey,true),Key(0x12,true),Key(0x11,true)});}catch{Send(new[]{Key(functionKey,true),Key(0x12,true),Key(0x11,true)});throw;}AssertForeground();}
 public static void BeginHold(){AssertForeground();CheckReleased();held=true;Send(new[]{Key(0x11,false),Key(0x12,false),Key(0x79,false)});AssertForeground();}
 public static void RepeatHeld(){AssertForeground();if(!held)throw new InvalidOperationException("No test hold is active");Send(new[]{Key(0x79,false)});AssertForeground();}
 public static void EndHold(){AssertForeground();ReleaseHeldKeys();AssertForeground();}
 public static void ReleaseHeldKeys(){if(held){held=false;Send(new[]{Key(0x79,true),Key(0x12,true),Key(0x11,true)});}}
 public static IntPtr[] FindClass(string c,uint processId){var result=new List<IntPtr>();EnumWindows(delegate(IntPtr h,IntPtr d){uint owner;GetWindowThreadProcessId(h,out owner);if(processId==0||owner==processId){var n=new StringBuilder(256);GetClassNameW(h,n,n.Capacity);if(n.ToString()==c)result.Add(h);}return true;},IntPtr.Zero);return result.ToArray();}
 public static bool Responsive(IntPtr h){UIntPtr result;return SendMessageTimeoutW(h,0,IntPtr.Zero,IntPtr.Zero,0x23,50,out result)!=IntPtr.Zero;}
 public static string Text(IntPtr ui,int id){var b=new StringBuilder(32768);UIntPtr result;if(SendText(GetDlgItem(ui,id),0x0d,new IntPtr(b.Capacity),b,0x23,50,out result)==IntPtr.Zero)throw new InvalidOperationException("Timed out reading own app result");return b.ToString();}
 public static Rect Frame(){Rect r;if(DwmGetWindowAttribute(Fixture,9,out r,Marshal.SizeOf(typeof(Rect)))!=0)throw new InvalidOperationException("Cannot read fixture DWM frame");return r;}
 public static Rect Work(){var info=new MonitorInfo{size=(uint)Marshal.SizeOf(typeof(MonitorInfo))};if(!GetMonitorInfoW(MonitorFromWindow(Fixture,2),ref info))throw new InvalidOperationException("Cannot read fixture work area");return info.work;}
 public static uint FixtureDpi(){return GetDpiForWindow(Fixture);}
 public static Rect Move(int x,int y,int width,int height){AssertForeground();var old=SetThreadDpiAwarenessContext(new IntPtr(-4));try{Rect outer;GetWindowRect(Fixture,out outer);var visible=Frame();var expected=new Rect{Left=x+visible.Left-outer.Left,Top=y+visible.Top-outer.Top,Right=x+width-(outer.Right-visible.Right),Bottom=y+height-(outer.Bottom-visible.Bottom)};if(!SetWindowPos(Fixture,IntPtr.Zero,x,y,width,height,0x4214))throw new InvalidOperationException("Cannot move owned fixture");return expected;}finally{if(old!=IntPtr.Zero)SetThreadDpiAwarenessContext(old);}}
 public static int EdgeError(Rect a,Rect b){return Math.Max(Math.Max(Math.Abs(a.Left-b.Left),Math.Abs(a.Top-b.Top)),Math.Max(Math.Abs(a.Right-b.Right),Math.Abs(a.Bottom-b.Bottom)));}
}
'@

$report = [ordered]@{
    schema_version = 1
    started_utc = [DateTime]::UtcNow.ToString('o')
    scope = 'Real SendInput Ctrl+Alt+F10/F9 end-to-end on only the newly created fixture in a fresh isolated configuration; no WM_HOTKEY messages are injected.'
    exe_path = $resolvedExe
    exe_sha256 = (Get-FileHash -LiteralPath $resolvedExe -Algorithm SHA256).Hash.ToLowerInvariant()
    script_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    os_version = [Environment]::OSVersion.Version.ToString()
    config_dir = $configDir
    requested_cycles = $Cycles
    completed_cycles = 0
    input_method = 'SendInput keyboard sequences with foreground/ownership checks immediately before and after each sequence; no AttachThreadInput, injected Alt workaround, or foreground-policy bypass.'
    latency_definition = 'Stopwatch immediately before the validated SendInput wrapper until first polled DWM visible rectangle within two physical pixels; polls every five milliseconds. Includes desktop scheduling and test polling overhead.'
    restore_samples_ms = @()
    restore_p95_ms = $null
    completion_feedback_samples_ms = @()
    completion_feedback_p95_ms = $null
    completion_feedback_definition = 'Same stopwatch as visible-frame latency, continued until hidden configuration result text explicitly reports restored/already-correct; previous F10 persisted-success feedback has already been observed, so an old restore result cannot satisfy this wait.'
    successful_completion_feedback_cycles = 0
    last_success_result = $null
    max_edge_error_px = 0
    unconfigured_restore_verified = $false
    no_change_update_verified = $false
    long_hold_norepeat_verified = $false
    long_hold_definition = 'Hold Ctrl+Alt+F10, wait for the first persisted update, move only the fixture while keys remain down, then send 25 further F10 key-down events without key-up. One final update, unchanged saved placement, and unchanged success result establish suppression of repeated down events.'
    foreground_preserved = $false
    process_id = $null
    private_start_bytes = $null
    private_after_cycles_bytes = $null
    private_growth_bytes = $null
    cpu_delta_ms = $null
    normal_exit = $false
    exit_code = $null
    forced_cleanup = $false
    errors = @()
    passed = $false
    limitations = @('One local desktop/display configuration and one synthetic standard Win32 fixture; does not validate real app compatibility, cross-DPI/multi-monitor p95, UAC, hardware typematic delivery, independent usability, or clean-machine installation.', 'Counter CPU/private-memory deltas are observations, not a leak proof or absolute CPU-instruction counts.', 'Foreground cannot be atomically locked together with Windows input dispatch; any observed mismatch aborts the run immediately, with only injected held-key releases permitted during emergency cleanup.')
}
$process = $null
$hostWindow = [IntPtr]::Zero
$settingsWindow = [IntPtr]::Zero

function Confirm-KeyProcess {
    $process.Refresh()
    if ($process.HasExited) { throw 'Isolated app exited unexpectedly.' }
    $actual = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $process.Id)
    if (-not $actual -or $actual.ExecutablePath -ine $resolvedExe -or
        -not $actual.CommandLine.Contains('"' + $configDir + '"') -or -not $actual.CommandLine.Contains('--background')) {
        throw 'Isolated executable/arguments no longer match; refusing process control.'
    }
}
function Key-Config { try { return Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } catch { return $null } }
function Key-Status { return [PinRealKeys]::Text($settingsWindow, 138) }
function Wait-Key([scriptblock]$Condition, [string]$Description, [int]$Timeout = 4000) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        [PinRealKeys]::AssertForeground()
        if (& $Condition) { [PinRealKeys]::AssertForeground(); return }
        Start-Sleep -Milliseconds 5
    } while ($watch.ElapsedMilliseconds -lt $Timeout)
    throw ('Timed out: ' + $Description + '; app status: ' + (Key-Status))
}
function Move-KeyFixture([int]$X,[int]$Y,[int]$Width,[int]$Height) {
    $expected = [PinRealKeys]::Move($X,$Y,$Width,$Height)
    Wait-Key { [PinRealKeys]::EdgeError([PinRealKeys]::Frame(), $expected) -le 2 } 'owned fixture position'
    Start-Sleep -Milliseconds 25
    [PinRealKeys]::AssertForeground()
    return [PinRealKeys]::Frame()
}
function Stop-KeyApp {
    if ($null -eq $process) { return }
    $process.Refresh()
    if ($process.HasExited) { return }
    Confirm-KeyProcess
    [uint32]$owner = 0
    [PinRealKeys]::GetWindowThreadProcessId($hostWindow,[ref]$owner) | Out-Null
    if ($owner -ne $process.Id) { throw 'Exit host no longer belongs to the isolated process.' }
    if (-not [PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)) { throw 'Could not post normal exit.' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do { $process.Refresh();if($process.HasExited){$report.normal_exit=$true;$report.exit_code=$process.ExitCode;return};Start-Sleep -Milliseconds 30 } while($watch.ElapsedMilliseconds -lt 8000)
    Confirm-KeyProcess
    Stop-Process -InputObject $process -Force
    $report.forced_cleanup=$true
    throw 'Normal exit timed out; only the verified isolated process was forcibly cleaned up.'
}

try {
    if ([PinRealKeys]::FindClass('ScreenPin.Host',0).Length -ne 0) { throw 'An existing Screen Pin instance owns global hotkeys; no process was terminated and no input was sent.' }
    $process=Start-Process -FilePath $resolvedExe -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    $report.process_id=$process.Id
    $startup=[Diagnostics.Stopwatch]::StartNew()
    do {
        $hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id)
        $settings=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id)
        if($hosts.Length -eq 1 -and $settings.Length -eq 1 -and [PinRealKeys]::Responsive($hosts[0])){$hostWindow=$hosts[0];$settingsWindow=$settings[0];break}
        Start-Sleep -Milliseconds 20
    } while($startup.ElapsedMilliseconds -lt 8000)
    if($hostWindow -eq [IntPtr]::Zero){throw 'Own host/settings message loop not ready.'}
    Confirm-KeyProcess
    $keyStatus=[PinRealKeys]::Text($settingsWindow,208)
    if(([regex]::Matches($keyStatus,'已注册')).Count -ne 2 -or $keyStatus -match '未注册|不可用|失败|冲突'){throw ('Global hotkeys are not both available: '+$keyStatus)}
    $fixture=[PinRealKeys]::StartFixture()
    Start-Sleep -Milliseconds 120
    [PinRealKeys]::AssertForeground()
    $work=[PinRealKeys]::Work()
    $report.fixture_work_area=$work
    $report.fixture_dpi=[PinRealKeys]::FixtureDpi()
    $workWidth=$work.Right-$work.Left;$workHeight=$work.Bottom-$work.Top
    $width=[Math]::Min(760,[int]($workWidth*0.6));$height=[Math]::Min(520,[int]($workHeight*0.6))
    $first=Move-KeyFixture ($work.Left+80) ($work.Top+90) $width $height
    $initial=Key-Config
    [PinRealKeys]::Chord(0x78)
    Wait-Key { (Key-Status) -match '尚未配置' } 'unconfigured F9 feedback'
    $after=Key-Config
    if($after.revision -ne $initial.revision -or [PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$first) -gt 2){throw 'Unconfigured F9 changed configuration or moved the fixture.'}
    $report.unconfigured_restore_verified=$true
    $process.Refresh();$report.private_start_bytes=$process.PrivateMemorySize64;$cpuStart=$process.TotalProcessorTime.TotalMilliseconds
    $samples=[Collections.Generic.List[double]]::new()
    $completionSamples=[Collections.Generic.List[double]]::new()
    $runWatch=[Diagnostics.Stopwatch]::StartNew();$lastProgress=0
    for($cycle=0;$cycle -lt $Cycles;$cycle++){
        $target=Move-KeyFixture ($work.Left+80+($cycle%5)*19) ($work.Top+90+($cycle%3)*17) ($width+($cycle%2)*12) ($height+($cycle%4)*8)
        $before=Key-Config
        [PinRealKeys]::Chord(0x79)
        Wait-Key { $current=Key-Config; $current -and $current.revision -gt $before.revision -and (Key-Status) -match '已记住' } 'F10 persisted capture'
        $saved=Key-Config
        if($saved.profiles[0].applications.Count -ne 1 -or -not $saved.profiles[0].applications[0].default){throw 'F10 did not create/update only the fixture application default.'}
        $displaced=Move-KeyFixture ($work.Left+[int]($workWidth*0.45)) ($work.Top+[int]($workHeight*0.35)) ([Math]::Max(300,$width-90)) ([Math]::Max(250,$height-70))
        if([PinRealKeys]::EdgeError($displaced,$target) -le 2){throw 'Fixture displacement did not establish a real restore test.'}
        $latency=[Diagnostics.Stopwatch]::StartNew()
        [PinRealKeys]::Chord(0x78)
        Wait-Key { [PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$target) -le 2 } 'real F9 restored DWM frame'
        $samples.Add($latency.Elapsed.TotalMilliseconds)
        Wait-Key { (Key-Status) -match '^已恢复|^已符合预设' } 'F9 completion feedback'
        $completionSamples.Add($latency.Elapsed.TotalMilliseconds)
        $report.successful_completion_feedback_cycles=$cycle+1
        $report.last_success_result=Key-Status
        $report.restore_samples_ms=$samples.ToArray()
        $report.completion_feedback_samples_ms=$completionSamples.ToArray()
        $report.max_edge_error_px=[Math]::Max($report.max_edge_error_px,[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$target))
        $report.completed_cycles=$cycle+1
        if($runWatch.Elapsed.TotalSeconds-$lastProgress -ge 20){Write-Host ('Real SendInput cycles complete: '+($cycle+1)+'/'+$Cycles);$lastProgress=$runWatch.Elapsed.TotalSeconds}
    }
    $process.Refresh();$report.private_after_cycles_bytes=$process.PrivateMemorySize64;$report.private_growth_bytes=$process.PrivateMemorySize64-$report.private_start_bytes;$report.cpu_delta_ms=$process.TotalProcessorTime.TotalMilliseconds-$cpuStart
    $report.restore_samples_ms=$samples.ToArray();$sorted=@($samples.ToArray()|Sort-Object);$report.restore_p95_ms=$sorted[[Math]::Ceiling($sorted.Length*0.95)-1]
    $sortedCompletion=@($completionSamples.ToArray()|Sort-Object);$report.completion_feedback_p95_ms=$sortedCompletion[[Math]::Ceiling($sortedCompletion.Length*0.95)-1]
    $before=Key-Config
    [PinRealKeys]::Chord(0x79)
    Wait-Key { (Key-Status) -match '位置未变化' } 'unchanged F10 feedback'
    $report.no_change_update_verified=(Key-Config).revision -eq $before.revision
    if(-not $report.no_change_update_verified){throw 'Identical F10 changed the persisted revision.'}

    $holdTarget=Move-KeyFixture ($work.Left+110) ($work.Top+125) ($width+25) ($height+20)
    $before=Key-Config
    [PinRealKeys]::BeginHold()
    try {
        Wait-Key { $current=Key-Config;$current -and $current.revision -gt $before.revision -and (Key-Status) -match '已记住' } 'initial held F10 capture'
        $firstHold=Key-Config;$firstHoldJson=$firstHold.profiles[0].applications[0].default|ConvertTo-Json -Depth 10 -Compress
        $holdStatus=Key-Status
        $null=Move-KeyFixture ($work.Left+300) ($work.Top+220) ($width-60) ($height-40)
        for($repeat=0;$repeat -lt 25;$repeat++){[PinRealKeys]::RepeatHeld();Start-Sleep -Milliseconds 40;[PinRealKeys]::AssertForeground()}
    } finally { [PinRealKeys]::ReleaseHeldKeys() }
    Start-Sleep -Milliseconds 120
    [PinRealKeys]::AssertForeground()
    $lastHold=Key-Config;$lastHoldJson=$lastHold.profiles[0].applications[0].default|ConvertTo-Json -Depth 10 -Compress
    $report.long_hold_norepeat_verified=$lastHold.revision -eq $firstHold.revision -and $lastHoldJson -eq $firstHoldJson -and (Key-Status) -eq $holdStatus
    if(-not $report.long_hold_norepeat_verified){throw 'Repeated held F10 events were not suppressed.'}
    [PinRealKeys]::Chord(0x78)
    Wait-Key { [PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$holdTarget) -le 2 } 'restore initial held capture after ignored repeats'
    $report.foreground_preserved=$true
    $report.final_config_autostart=(Key-Config).settings.autostart
    if($report.final_config_autostart){throw 'Isolated configuration unexpectedly enabled auto-start.'}
    Stop-KeyApp
} catch {$report.errors += $_.Exception.Message}
finally {
    try {[PinRealKeys]::ReleaseHeldKeys();[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)}
    try {Stop-KeyApp}catch{$report.errors+=('App cleanup: '+$_.Exception.Message)}
    $report.finished_utc=[DateTime]::UtcNow.ToString('o')
    $report.passed=$report.errors.Count -eq 0 -and $report.completed_cycles -eq $Cycles -and $report.successful_completion_feedback_cycles -eq $Cycles -and $report.restore_p95_ms -le 300 -and $report.completion_feedback_p95_ms -le 300 -and $report.max_edge_error_px -le 2 -and $report.unconfigured_restore_verified -and $report.no_change_update_verified -and $report.long_hold_norepeat_verified -and $report.foreground_preserved -and $report.normal_exit -and $report.exit_code -eq 0 -and -not $report.forced_cleanup
    $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $reportPath -Encoding utf8
    Write-Host ('Hotkey smoke report: '+$reportPath)
}
if(-not $report.passed){exit 1}
