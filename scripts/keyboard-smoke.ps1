#Requires -Version 7.0
param(
    [string]$ExePath = (Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '../artifacts/keyboard'),
    [string]$UiaProbePath = (Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe'),
    [switch]$WaitForForeground
)
$ErrorActionPreference = 'Stop'
$ExePath = (Get-Item -LiteralPath $ExePath).FullName
$UiaProbePath = (Get-Item -LiteralPath $UiaProbePath).FullName
$runDir = Join-Path ([IO.Path]::GetFullPath($OutputDir)) ('keyboard-' + [Guid]::NewGuid().ToString('N'))
$configDir = (New-Item -ItemType Directory -Path (Join-Path $runDir 'config') -Force).FullName
$configPath = Join-Path $configDir 'config.json'
$reportPath = Join-Path $runDir 'report.json'
$fixtureTitle = 'Screen Pin Keyboard Fixture ' + [Guid]::NewGuid().ToString('N')
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class PinKeyboard {
 public delegate bool EnumProc(IntPtr h,IntPtr d);
 private delegate IntPtr Procedure(IntPtr h,uint m,IntPtr w,IntPtr l);
 [StructLayout(LayoutKind.Sequential)] public struct Rect {public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential)] private struct GuiInfo {public uint size,flags;public IntPtr active,focus,capture,menuOwner,moveSize,caret;public Rect caretRect;}
 [StructLayout(LayoutKind.Sequential)] private struct Key {public ushort key,scan;public uint flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Sequential)] private struct Mouse {public int x,y;public uint data,flags,time;public UIntPtr extra;}
 [StructLayout(LayoutKind.Explicit)] private struct InputData {[FieldOffset(0)]public Key key;[FieldOffset(0)]public Mouse mouse;}
 [StructLayout(LayoutKind.Sequential)] private struct Input {public uint type;public InputData data;}
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] private struct Class {public uint style;public IntPtr procedure;public int classExtra,windowExtra;public IntPtr instance,icon,cursor,background;public string menu,name;}
 [StructLayout(LayoutKind.Sequential)] private struct Message {public IntPtr h;public uint m;public UIntPtr w;public IntPtr l;public uint time;public int x,y;public uint extra;}
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p,IntPtr d);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassNameW(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")] private static extern int GetDlgCtrlID(IntPtr h);
 [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint thread,ref GuiInfo info);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
 [DllImport("user32.dll",SetLastError=true)] private static extern uint SendInput(uint n,Input[] input,int size);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,StringBuilder l);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] private static extern int MapWindowPoints(IntPtr from,IntPtr to,ref Rect r,uint count);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll")] private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern ushort RegisterClassW(ref Class c);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern IntPtr CreateWindowExW(uint ex,string c,string title,uint style,int x,int y,int width,int height,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr param);
 [DllImport("user32.dll")] private static extern IntPtr DefWindowProcW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr h);
 [DllImport("user32.dll")] private static extern void PostQuitMessage(int code);
 [DllImport("user32.dll")] private static extern int GetMessageW(out Message m,IntPtr h,uint first,uint last);
 [DllImport("user32.dll")] private static extern bool TranslateMessage(ref Message m);
 [DllImport("user32.dll")] private static extern IntPtr DispatchMessageW(ref Message m);
 [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h,int command);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] private static extern IntPtr GetModuleHandleW(string value);
 private static readonly Procedure proc=WindowProc;
 private static readonly ManualResetEventSlim ready=new ManualResetEventSlim(false);
 private static Thread fixtureThread;
 private static string fixtureFailure;
 public static IntPtr Fixture,UI;public static uint AppPid;
 private static IntPtr WindowProc(IntPtr h,uint m,IntPtr w,IntPtr l){if(m==0x10){DestroyWindow(h);return IntPtr.Zero;}if(m==2){PostQuitMessage(0);return IntPtr.Zero;}return DefWindowProcW(h,m,w,l);}
 public static void StartFixture(string title){fixtureThread=new Thread(delegate(){try{SetThreadDpiAwarenessContext(new IntPtr(-4));var name="ScreenPin.KeyboardFixture."+Guid.NewGuid().ToString("N");var instance=GetModuleHandleW(null);var c=new Class{procedure=Marshal.GetFunctionPointerForDelegate(proc),instance=instance,name=name};if(RegisterClassW(ref c)==0)throw new Exception("Fixture class creation failed");Fixture=CreateWindowExW(0,name,title,0x00cf0000,100,120,740,520,IntPtr.Zero,IntPtr.Zero,instance,IntPtr.Zero);if(Fixture==IntPtr.Zero)throw new Exception("Fixture window creation failed");ShowWindow(Fixture,4);ready.Set();Message m;while(GetMessageW(out m,IntPtr.Zero,0,0)>0){TranslateMessage(ref m);DispatchMessageW(ref m);}}catch(Exception e){fixtureFailure=e.ToString();ready.Set();}});fixtureThread.IsBackground=true;fixtureThread.Start();if(!ready.Wait(3000))throw new Exception("Fixture startup timed out");if(fixtureFailure!=null)throw new Exception(fixtureFailure);}
 public static void StopFixture(){if(Fixture!=IntPtr.Zero)PostMessageW(Fixture,0x10,IntPtr.Zero,IntPtr.Zero);if(fixtureThread!=null&&!fixtureThread.Join(2000))throw new Exception("Fixture did not exit");}
 public static IntPtr[] Find(string name,uint pid){var result=new List<IntPtr>();EnumWindows(delegate(IntPtr h,IntPtr d){uint owner;GetWindowThreadProcessId(h,out owner);var b=new StringBuilder(256);GetClassNameW(h,b,b.Capacity);if((pid==0||owner==pid)&&b.ToString()==name)result.Add(h);return true;},IntPtr.Zero);return result.ToArray();}
 public static string ForegroundDescription(){var h=GetForegroundWindow();uint owner;GetWindowThreadProcessId(h,out owner);var name=new StringBuilder(256);var title=new StringBuilder(256);GetClassNameW(h,name,name.Capacity);GetWindowTextW(h,title,title.Capacity);return "HWND="+h+" PID="+owner+" class="+name+" title="+title;}
 public static bool LayoutReady(){Rect r;return IsWindowVisible(UI)&&GetWindowRect(GetDlgItem(UI,100),out r)&&r.Right-r.Left>50&&r.Bottom-r.Top>10;}
 public static void AssertUI(){uint owner;GetWindowThreadProcessId(UI,out owner);if(UI==IntPtr.Zero||owner!=AppPid||GetForegroundWindow()!=UI||!IsWindowVisible(UI))throw new Exception("Foreground left the owned settings window; keyboard input cancelled; "+ForegroundDescription());}
 private static Input KeyInput(ushort code,bool up,bool unicode){return new Input{type=1,data=new InputData{key=new Key{key=unicode?(ushort)0:code,scan=unicode?code:(ushort)0,flags=(up?2u:0u)|(unicode?4u:0u)}}};}
 private static void Send(Input[] input){if(SendInput((uint)input.Length,input,Marshal.SizeOf(typeof(Input)))!=input.Length)throw new Exception("SendInput accepted an incomplete sequence");}
 public static void Press(ushort key,ushort modifier){AssertUI();if((GetAsyncKeyState(key)&0x8000)!=0||(modifier!=0&&(GetAsyncKeyState(modifier)&0x8000)!=0))throw new Exception("A test key is already held; input cancelled");var inputs=new List<Input>();if(modifier!=0)inputs.Add(KeyInput(modifier,false,false));inputs.Add(KeyInput(key,false,false));inputs.Add(KeyInput(key,true,false));if(modifier!=0)inputs.Add(KeyInput(modifier,true,false));Send(inputs.ToArray());}
 public static void Type(string value){AssertUI();foreach(char c in value){AssertUI();Send(new[]{KeyInput(c,false,true),KeyInput(c,true,true)});}}
 public static int FocusId(){uint owner;var thread=GetWindowThreadProcessId(UI,out owner);var info=new GuiInfo{size=(uint)Marshal.SizeOf(typeof(GuiInfo))};if(!GetGUIThreadInfo(thread,ref info))throw new Exception("Cannot inspect own UI focus");return GetDlgCtrlID(info.focus);}
 [DllImport("user32.dll")] private static extern int GetWindowRgn(IntPtr h,IntPtr region);
 [DllImport("gdi32.dll")] private static extern IntPtr CreateRectRgn(int a,int b,int c,int d);
 [DllImport("gdi32.dll")] private static extern int GetRgnBox(IntPtr region,out Rect box);
 [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr h);
 public static bool FocusFullyVisible(){
  var previous=SetThreadDpiAwarenessContext(new IntPtr(-4));
  try{
   int id=FocusId();var control=GetDlgItem(UI,id);Rect child,client;
   if(control==IntPtr.Zero||!GetWindowRect(control,out child)||!GetClientRect(UI,out client))return false;
   MapWindowPoints(UI,IntPtr.Zero,ref client,2);
   if(child.Left<client.Left||child.Top<client.Top||child.Right>client.Right||child.Bottom>client.Bottom)return false;
   if(id!=100&&id!=101&&id!=102&&id!=136&&id!=138){
    Rect nav,undo;if(!GetWindowRect(GetDlgItem(UI,100),out nav)||!GetWindowRect(GetDlgItem(UI,136),out undo)||child.Top<nav.Bottom||child.Bottom>undo.Top)return false;
   }
   var region=CreateRectRgn(0,0,0,0);if(region==IntPtr.Zero)return false;
   try{int type=GetWindowRgn(control,region);if(type==0)return true;Rect box;GetRgnBox(region,out box);return type!=1&&box.Left<=0&&box.Top<=0&&box.Right>=child.Right-child.Left&&box.Bottom>=child.Bottom-child.Top;}
   finally{DeleteObject(region);}
  }finally{SetThreadDpiAwarenessContext(previous);}
 }
 public static string Text(int id){var text=new StringBuilder(32768);SendMessageW(GetDlgItem(UI,id),0x0d,new IntPtr(text.Capacity),text);return text.ToString();}
 public static int FindListIndex(int id,string value){var list=GetDlgItem(UI,id);for(int i=0;i<10000;i++){var text=new StringBuilder(32768);var length=SendMessageW(list,0x189,new IntPtr(i),text).ToInt64();if(length<0)return -1;if(text.ToString().Contains(value))return i;}return -1;}
}
'@
$report = [ordered]@{script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;focus_visibility_scope='Client bounds, fixed navigation/feedback and native control region; actual Tab and Shift+Tab.';executed=[DateTimeOffset]::Now.ToString('o');executable=$ExePath;exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;configuration=$configDir;input_method='Initial public UIA focus action when needed; subsequent application actions use SendInput Tab, Shift+Tab, Space, arrow keys and Unicode text.';passed_checks=@();uia=@();tab_focus=@();errors=@();normal_exit=$false;passed=$false;limitations=@('Single desktop at current DPI; UIA names are structural evidence, not a Narrator listening test.','Tray keyboard-only exit and migration/deletion confirmation are not covered.','Fixture creation and cleanup use APIs; application actions use keyboard input.')}
$process=$null;$hostWindow=[IntPtr]::Zero
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-Keyboard($condition,[string]$message){if(-not $condition){throw $message};$report.passed_checks+= $message}
function Wait-Keyboard([scriptblock]$condition,[string]$description){$deadline=[DateTime]::UtcNow.AddSeconds(6);do{[PinKeyboard]::AssertUI();if(& $condition){return};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline);throw ('Timeout: '+$description+'; result: '+[PinKeyboard]::Text(138))}
function Press-Keyboard([int]$key,[int]$modifier=0){[PinKeyboard]::Press([ushort]$key,[ushort]$modifier);Start-Sleep -Milliseconds 60;[PinKeyboard]::AssertUI()}
function Config-Keyboard {Get-Content -Raw -LiteralPath $configPath|ConvertFrom-Json}
function Select-Keyboard([int]$id,[int]$index){Assert-Keyboard ([PinKeyboard]::FocusId() -eq $id) ('Keyboard focus is on list '+$id);Press-Keyboard 0x24;for($i=0;$i -lt $index;$i++){Press-Keyboard 0x28}}
function Tab-ToKeyboard([int]$id){for($step=0;$step -lt 60;$step++){if([PinKeyboard]::FocusId() -eq $id){return};Press-Keyboard 9};throw ('Tab could not reach control '+$id)}
function Names-Keyboard([int[]]$ids,[string]$page){
 $rows=@();foreach($id in $ids){$control=[PinKeyboard]::GetDlgItem([PinKeyboard]::UI,$id);if([PinKeyboard]::IsWindowVisible($control)){$rows+=@{page=$page;id=$id;handle=$control.ToInt64()}}}
 $inputPath=Join-Path $runDir ($page+'-uia-input.json');$outputPath=Join-Path $runDir ($page+'-uia-output.json')
 ConvertTo-Json -InputObject @($rows) -Depth 5|Set-Content -LiteralPath $inputPath -Encoding utf8
 $reader=Start-Process -FilePath $UiaProbePath -ArgumentList ('"'+$inputPath+'"'),('"'+$outputPath+'"'),$process.Id -WindowStyle Hidden -PassThru
 if(-not $reader.WaitForExit(15000)){ $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$reader.Id);if($owner.ExecutablePath -eq $UiaProbePath -and $owner.CommandLine.Contains($inputPath)){$reader.Kill();$reader.WaitForExit()};throw 'Native UIA reader timed out' }
 if($reader.ExitCode -ne 0){throw 'Isolated native UIA reader failed'}
 $report.uia+= @(Get-Content -Raw -LiteralPath $outputPath|ConvertFrom-Json)
}
function Tabs-Keyboard([string]$page){
 $expected=@($report.uia|Where-Object {$_.page -eq $page -and [PinKeyboard]::IsWindowVisible([PinKeyboard]::GetDlgItem([PinKeyboard]::UI,$_.id)) -and [PinKeyboard]::IsWindowEnabled([PinKeyboard]::GetDlgItem([PinKeyboard]::UI,$_.id))}|ForEach-Object id|Sort-Object -Unique)
 foreach($reverse in @($false,$true)){
  $visited=@()
  for($step=0;$step -lt 60;$step++){Press-Keyboard 9 $(if($reverse){0x10}else{0});$id=[PinKeyboard]::FocusId();if($visited -contains $id){break};$visited+=$id;$visible=[PinKeyboard]::FocusFullyVisible();$report.tab_focus+= [ordered]@{page=$page;id=$id;reverse=$reverse;fully_visible=$visible};Assert-Keyboard $visible ('Tab focus '+$id+' is fully visible on '+$page)}
  $missing=@($expected|Where-Object {$_ -notin $visited})
  Assert-Keyboard ($missing.Count -eq 0 -and $visited.Count -ge 5) ('Tab cycle reaches every enabled control on '+$page+'; reverse='+$reverse+'; missing='+($missing -join ','))
 }
}
function Exit-KeyboardApp {if($process -and -not $process.HasExited){$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id);if(-not $owner -or $owner.ExecutablePath -ne $ExePath -or -not $owner.CommandLine.Contains($configDir)){throw 'Cleanup ownership mismatch'};if($hostWindow -ne [IntPtr]::Zero){[PinKeyboard]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null};if(-not $process.WaitForExit(8000)){throw 'Own app did not exit normally'};$report.normal_exit=$process.ExitCode -eq 0}}
try {
 Assert-Keyboard ([PinKeyboard]::Find('ScreenPin.Host',0).Count -eq 0) 'No existing Screen Pin instance competes for hotkeys'
 [PinKeyboard]::StartFixture($fixtureTitle)
 $process=Start-Process -FilePath $ExePath -ArgumentList '--show','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
 $deadline=[DateTime]::UtcNow.AddSeconds(8)
 do{$uis=[PinKeyboard]::Find('ScreenPin.Settings',$process.Id);$hosts=[PinKeyboard]::Find('ScreenPin.Host',$process.Id);if($uis.Count -eq 1 -and $hosts.Count -eq 1){[PinKeyboard]::UI=$uis[0];$hostWindow=$hosts[0];break};Start-Sleep -Milliseconds 30}while([DateTime]::UtcNow -lt $deadline)
 [PinKeyboard]::AppPid=$process.Id
 $deadline=[DateTime]::UtcNow.AddSeconds(8)
 do {if([PinKeyboard]::LayoutReady() -and [PinKeyboard]::Text(138) -notin @('','正在处理…')){break};Start-Sleep -Milliseconds 30}while([DateTime]::UtcNow -lt $deadline)
 Names-Keyboard @(100,101,102,105,108,109,111,112,114,115,117,138) 'initial'
 [PinKeyboard]::SetForegroundWindow([PinKeyboard]::UI)|Out-Null
 Start-Sleep -Milliseconds 100
 if([PinKeyboard]::GetForegroundWindow() -ne [PinKeyboard]::UI){
  $focusInput=Join-Path $runDir 'focus-input.json';$focusOutput=Join-Path $runDir 'focus-output.json'
  ConvertTo-Json -InputObject @(@{page='activation';id=100;handle=[PinKeyboard]::GetDlgItem([PinKeyboard]::UI,100).ToInt64()})|Set-Content -LiteralPath $focusInput -Encoding utf8
  & $UiaProbePath $focusInput $focusOutput $process.Id --focus
  $report['uia_initial_focus_result']=$LASTEXITCODE
  [PinKeyboard]::SetForegroundWindow([PinKeyboard]::UI)|Out-Null
  Start-Sleep -Milliseconds 100
 }
 if($WaitForForeground -and [PinKeyboard]::GetForegroundWindow() -ne [PinKeyboard]::UI){
  Write-Host ('Waiting up to 120 seconds for the user to activate Screen Pin settings; PID '+$process.Id+'. No input is sent while waiting.')
  $deadline=[DateTime]::UtcNow.AddSeconds(120)
  while([PinKeyboard]::GetForegroundWindow() -ne [PinKeyboard]::UI -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
 }
 Wait-Keyboard { [PinKeyboard]::Text(138) -notin @('','正在处理…') } 'first refresh'
 Tab-ToKeyboard 108
 $index=[PinKeyboard]::FindListIndex(108,$fixtureTitle)
 Assert-Keyboard ($index -ge 0) 'Owned fixture is present in the window list'
 Select-Keyboard 108 $index
 Tab-ToKeyboard 111;Press-Keyboard 0x20
 Wait-Keyboard { (Config-Keyboard).profiles[0].applications.Count -eq 1 -and [PinKeyboard]::Text(138) -match '已记住' } 'keyboard remember'
 $original=(Config-Keyboard).profiles[0].applications[0].default.placement|ConvertTo-Json -Depth 10 -Compress
 Assert-Keyboard $true 'Tab and Space capture the selected application default'
 Tab-ToKeyboard 117;Select-Keyboard 117 0
 Wait-Keyboard {[PinKeyboard]::IsWindowVisible([PinKeyboard]::GetDlgItem([PinKeyboard]::UI,132))} 'selected preset editor'
 Names-Keyboard @(100,101,102,105,108,109,111,112,114,115,117,120,122,124,126,128,129,131,132,133,134,135,136,138,140) 'main'
 Tab-ToKeyboard 122;Assert-Keyboard ([PinKeyboard]::FocusId() -eq 122) 'Tab focuses the position editor'
 Press-Keyboard 0x41 0x11;[PinKeyboard]::Type('12.5')
 $revision=(Config-Keyboard).revision
 Tab-ToKeyboard 132;Press-Keyboard 0x20
 Wait-Keyboard {(Config-Keyboard).revision -gt $revision -and [PinKeyboard]::Text(138) -match '已保存预设'} 'keyboard percentage save'
 Assert-Keyboard ((Config-Keyboard).profiles[0].applications[0].default.placement.rect.x -eq 0.125) 'Keyboard text editing persists the intended percentage'
 Tab-ToKeyboard 136;Press-Keyboard 0x20;Wait-Keyboard { [PinKeyboard]::Text(138) -match '已撤销' } 'keyboard undo'
 Assert-Keyboard (((Config-Keyboard).profiles[0].applications[0].default.placement|ConvertTo-Json -Depth 10 -Compress) -eq $original) 'Keyboard undo restores the previous complete placement'
 foreach($keyword in @('Keyboard','Fixture')){Tab-ToKeyboard 114;Press-Keyboard 0x41 0x11;[PinKeyboard]::Type($keyword);$revision=(Config-Keyboard).revision;Tab-ToKeyboard 115;Press-Keyboard 0x20;Wait-Keyboard {(Config-Keyboard).revision -gt $revision -and [PinKeyboard]::Text(138) -match '已创建标题规则'} 'keyboard rule capture'}
 Tab-ToKeyboard 117;Select-Keyboard 117 ([PinKeyboard]::FindListIndex(117,'Fixture'))
 Tab-ToKeyboard 134;Press-Keyboard 0x20;Wait-Keyboard {(Config-Keyboard).profiles[0].applications[0].rules[0].keyword -eq 'Fixture'} 'keyboard reorder up'
 Tab-ToKeyboard 135;Press-Keyboard 0x20;Wait-Keyboard {(Config-Keyboard).profiles[0].applications[0].rules[1].keyword -eq 'Fixture'} 'keyboard reorder down'
 Assert-Keyboard $true 'Keyboard creates and reorders title rules in both directions'
 Tabs-Keyboard 'main'
 Tab-ToKeyboard 101;Press-Keyboard 0x20
 Wait-Keyboard {[PinKeyboard]::IsWindowVisible([PinKeyboard]::GetDlgItem([PinKeyboard]::UI,202))} 'settings page'
 Names-Keyboard @(100,101,102,202,204,206,207,210,211,213,136,138) 'settings'
 Tab-ToKeyboard 202;Assert-Keyboard ([PinKeyboard]::FocusId() -eq 202) 'Tab focuses the restore-hotkey setting'
 Tabs-Keyboard 'settings'
 Tab-ToKeyboard 102;Press-Keyboard 0x20
 Wait-Keyboard {[PinKeyboard]::IsWindowVisible([PinKeyboard]::GetDlgItem([PinKeyboard]::UI,302))} 'association page'
 Names-Keyboard @(100,101,102,302,303,305,307,308,309,310,312,136,138) 'association'
 Tabs-Keyboard 'association'
 foreach($item in $report.uia){
  $expectedRole=if($item.id -in @(105,120,302,305,307)){50003}elseif($item.id -in @(108,117)){50008}elseif($item.id -in @(129,206)){50002}elseif($item.id -in @(114,122,124,126,128,131,138,202,204,210,309)){50004}else{50000}
  Assert-Keyboard (-not [string]::IsNullOrWhiteSpace($item.name) -and $item.type -eq $expectedRole) ('Native UIA control '+$item.id+' exposes a name and native role on '+$item.page)
 }
 $startupAfter=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
 Assert-Keyboard ($startupBefore -ceq $startupAfter) 'Keyboard inspection leaves real startup registration unchanged'
 [PinKeyboard]::Press(0x73,0x12)
 $deadline=[DateTime]::UtcNow.AddSeconds(3);while([PinKeyboard]::IsWindowVisible([PinKeyboard]::UI) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 30}
 Assert-Keyboard (-not [PinKeyboard]::IsWindowVisible([PinKeyboard]::UI) -and -not $process.HasExited) 'Alt+F4 hides the settings window and retains the tray process'
} catch { $report.errors+=$_.Exception.Message;$report['focus_on_failure']=[PinKeyboard]::FocusId() }
finally {try {Exit-KeyboardApp}catch{$report.errors+=('App cleanup: '+$_.Exception.Message)};try{[PinKeyboard]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)};$report.passed=$report.errors.Count -eq 0 -and $report.normal_exit;$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $reportPath -Encoding utf8;Write-Host ('Keyboard report: '+$reportPath)}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
