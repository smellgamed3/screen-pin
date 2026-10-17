#Requires -Version 7.0
param(
 [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
 [string]$FixturePath=(Join-Path $PSScriptRoot '../target/debug/desktop_probe.exe'),
 [string]$UiaProbePath=(Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe'),
 [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/backend'),
 [ValidateRange(20,2000)][int]$Cycles=300,
 [ValidateRange(0,600)][int]$IdleSeconds=60
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName
$FixturePath=(Get-Item -LiteralPath $FixturePath).FullName
$UiaProbePath=(Get-Item -LiteralPath $UiaProbePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('backend-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'config')).FullName
$configPath=Join-Path $configDir 'config.json'
# Distinct test hotkeys let this background-only suite coexist with a foreground
# keyboard check. The script sends command messages only to its own settings HWND.
@{schema_version=1;revision=0;settings=@{restore=@{modifiers=7;key=134};remember=@{modifiers=7;key=135};autostart=$false};displays=@();profiles=@()}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $configPath -Encoding utf8
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PinBackend {
 public delegate bool EnumProc(IntPtr h,IntPtr d);
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")]public static extern bool EnumWindows(EnumProc p,IntPtr d);
 [DllImport("user32.dll")]public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern int GetClassNameW(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll")]public static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")]public static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]public static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")]public static extern IntPtr SendMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll",EntryPoint="SendMessageW",CharSet=CharSet.Unicode)]public static extern IntPtr SendText(IntPtr h,uint m,IntPtr w,StringBuilder l);
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("dwmapi.dll")]private static extern int DwmGetWindowAttribute(IntPtr h,uint attr,out Rect r,uint size);
 [DllImport("user32.dll",SetLastError=true)]private static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out UIntPtr result);
 public static bool Responsive(IntPtr h,uint timeout){UIntPtr result;return SendMessageTimeoutW(h,0,IntPtr.Zero,IntPtr.Zero,0x23,timeout,out result)!=IntPtr.Zero;}
 public static Rect Frame(IntPtr h){Rect r;if(DwmGetWindowAttribute(h,9,out r,16)!=0)throw new Exception("Cannot read fixture visible bounds");return r;}
 public static int Error(Rect a,Rect b){return Math.Max(Math.Max(Math.Abs(a.Left-b.Left),Math.Abs(a.Top-b.Top)),Math.Max(Math.Abs(a.Right-b.Right),Math.Abs(a.Bottom-b.Bottom)));}
 public static IntPtr Find(string cls,uint pid){IntPtr found=IntPtr.Zero;EnumWindows(delegate(IntPtr h,IntPtr d){uint owner;GetWindowThreadProcessId(h,out owner);if(owner==pid){var b=new StringBuilder(256);GetClassNameW(h,b,b.Capacity);if(b.ToString()==cls){found=h;return false;}}return true;},IntPtr.Zero);return found;}
}
'@
$process=$null;$fixture=$null;$ui=[IntPtr]::Zero;$hostWindow=[IntPtr]::Zero;$target=[IntPtr]::Zero
$title='ScreenPinBackendFixture-'+[Guid]::NewGuid().ToString('N')
$report=[ordered]@{executed=[DateTimeOffset]::Now.ToString('o');exe=$ExePath;exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;config=$configDir;scope='Hidden native shell command messages on a PID-owned fixture; no keyboard/mouse input and no pre-existing user window is moved.';cycles=$Cycles;completed=0;memory=@();idle=@{};freeze=@{};constraints=@{};uia=@();checks=@();errors=@();normal_exit=$false;fixture_normal_exit=$false;passed=$false;limitations=@('Single display/current DPI; synthetic fixture and shell-command path, not input latency or real application compatibility.','Memory sample points demonstrate only this bounded run, not an infinite leak proof.','Injected freeze intentionally allows queued asynchronous moves to arrive later; saved presets must stay unchanged.')}
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-Backend($condition,[string]$message){if(-not $condition){throw $message};$report.checks+=$message}
function Wait-Backend([scriptblock]$test,[string]$description,[int]$timeout=6000){$watch=[Diagnostics.Stopwatch]::StartNew();do{if(& $test){return};Start-Sleep -Milliseconds 10}while($watch.ElapsedMilliseconds -lt $timeout);throw ('Timeout: '+$description)}
function Config-Backend {Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json}
function Text-Backend([int]$id){$b=[Text.StringBuilder]::new(32768);[PinBackend]::SendText([PinBackend]::GetDlgItem($ui,$id),0x0d,[IntPtr]$b.Capacity,$b)|Out-Null;$b.ToString()}
function Command-Backend([int]$id){[PinBackend]::SendMessageW($ui,0x111,[IntPtr]$id,[IntPtr]::Zero)|Out-Null;Wait-Backend {(Text-Backend 138) -ne '正在处理…'} ('command '+$id)}
function Select-Backend([int]$id,[int]$index){$list=[PinBackend]::GetDlgItem($ui,$id);[PinBackend]::SendMessageW($list,0x186,[IntPtr]$index,[IntPtr]::Zero)|Out-Null;[PinBackend]::SendMessageW($ui,0x111,[IntPtr](65536+$id),$list)|Out-Null}
function Memory-Backend([int]$cycle){$process.Refresh();$report.memory+=@{cycle=$cycle;private_bytes=$process.PrivateMemorySize64;cpu_ms=$process.TotalProcessorTime.TotalMilliseconds}}
function Owner-Backend($p,[string]$path,[string]$marker){$p.Refresh();$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.Id);if($p.HasExited -or -not $owner -or $owner.ExecutablePath -ne $path -or -not $owner.CommandLine.Contains($marker)){throw 'Owned process identity changed; refusing commands'} }
function Uia-Backend([string]$page,[int[]]$ids){$input=Join-Path $runDir ($page+'-input.json');$output=Join-Path $runDir ($page+'-uia.json');$rows=@($ids|ForEach-Object {@{id=$_;page=$page;handle=[PinBackend]::GetDlgItem($ui,$_).ToInt64()}});ConvertTo-Json -InputObject $rows -Depth 5|Set-Content -LiteralPath $input -Encoding utf8;& $UiaProbePath $input $output $process.Id;if($LASTEXITCODE -ne 0){throw 'Native accessibility probe failed'};$report.uia+=@(Get-Content -Raw -LiteralPath $output|ConvertFrom-Json)}
try {
 $fixture=Start-Process -FilePath $FixturePath -ArgumentList '--fixture','--title',('"'+$title+'"') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $runDir 'fixture-stdout.txt') -PassThru
 Wait-Backend {$script:target=[PinBackend]::Find('ScreenPinDesktopProbeFixture',$fixture.Id);$target -ne [IntPtr]::Zero} 'fixture creation'
 $process=Start-Process -FilePath $ExePath -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
 Wait-Backend {$script:ui=[PinBackend]::Find('ScreenPin.Settings',$process.Id);$script:hostWindow=[PinBackend]::Find('ScreenPin.Host',$process.Id);$ui -ne [IntPtr]::Zero -and (Text-Backend 138) -notin @('','正在处理…')} 'background shell'
 Owner-Backend $process $ExePath $configDir;Owner-Backend $fixture $FixturePath $title
 $list=[PinBackend]::GetDlgItem($ui,108);$index=-1
 for($i=0;$i -lt 10000;$i++){$b=[Text.StringBuilder]::new(32768);$n=[PinBackend]::SendText($list,0x189,[IntPtr]$i,$b).ToInt64();if($n -lt 0){break};if($b.ToString().Contains($title)){$index=$i;break}}
 Assert-Backend ($index -ge 0) 'The owned fixture appears in the shell list'
 Select-Backend 108 $index
 [PinBackend]::SetWindowPos($target,[IntPtr]::Zero,130,150,700,500,0x4014)|Out-Null
 Start-Sleep -Milliseconds 80
 Command-Backend 111
 Assert-Backend ((Text-Backend 138) -match '已记住') 'Initial fixture placement is persisted'
 $baseline=[PinBackend]::Frame($target)
 Select-Backend 117 0
 Uia-Backend 'main' @(105,108,114,117,120,122,124,126,128,131,138)
 Command-Backend 101;Uia-Backend 'settings' @(202,204,210)
 Command-Backend 102;Uia-Backend 'association' @(302,305,307,309)
 foreach($entry in $report.uia){
  $expectedType=if($entry.id -in @(105,120,302,305,307)){50003}elseif($entry.id -in @(108,117)){50008}else{50004}
  Assert-Backend (-not [string]::IsNullOrWhiteSpace($entry.name) -and $entry.type -eq $expectedType) ('Native UIA exposes a named control with the expected role: '+$entry.id)
 }
 Assert-Backend (($report.uia|Where-Object id -eq 309).name -match '关联预览') 'Association preview exposes its own meaningful accessible name'
 Command-Backend 100
 $revision=(Config-Backend).revision
 [PinBackend]::SetWindowPos($target,[IntPtr]::Zero,600,300,450,300,0x4014)|Out-Null
 Wait-Backend {[PinBackend]::Error([PinBackend]::Frame($target),$baseline) -gt 20} 'actual fixture displacement'
 [PinBackend]::PostMessageW($target,0x802a,[IntPtr]1200,[IntPtr]::Zero)|Out-Null
 Wait-Backend {-not [PinBackend]::Responsive($target,20)} 'confirmed fixture message-pump freeze'
 $watch=[Diagnostics.Stopwatch]::StartNew();$responses=0
 [PinBackend]::PostMessageW($ui,0x111,[IntPtr]112,[IntPtr]::Zero)|Out-Null
 Wait-Backend {-not [PinBackend]::IsWindowEnabled([PinBackend]::GetDlgItem($ui,109))} 'restore occupies the operation slot'
 [PinBackend]::SendMessageW($ui,0x111,[IntPtr]111,[IntPtr]::Zero)|Out-Null
 $busyRefusal=(Text-Backend 138) -match '正在处理上一项'
 do {Assert-Backend ([PinBackend]::Responsive($hostWindow,50) -and [PinBackend]::Responsive($ui,50)) 'Host and settings respond while the target is frozen';$responses++;Start-Sleep -Milliseconds 10;$status=Text-Backend 138}while(-not [PinBackend]::IsWindowEnabled([PinBackend]::GetDlgItem($ui,109)) -and $watch.ElapsedMilliseconds -lt 2500)
 $report.freeze=@{elapsed_ms=$watch.Elapsed.TotalMilliseconds;status=$status;host_response_samples=$responses;busy_refusal_observed=$busyRefusal;revision_unchanged=((Config-Backend).revision -eq $revision)}
 Assert-Backend ($watch.ElapsedMilliseconds -lt 2000 -and $status -match '暂无法确认|暂时无响应|未确认') 'Frozen target receives an honest bounded result within two seconds'
 Assert-Backend ($report.freeze.revision_unchanged) 'Frozen target does not overwrite the saved preset'
 Assert-Backend $busyRefusal 'An overlapping shell command is refused rather than queued'
 Wait-Backend {[PinBackend]::Responsive($target,20)} 'fixture becomes responsive after its injected delay'
 Command-Backend 112
 Assert-Backend ((Text-Backend 138) -match '已恢复|已符合') 'Shell accepts another restore after the frozen-target result'
 [PinBackend]::SendMessageW($target,0x802b,[IntPtr]1000,[IntPtr]650)|Out-Null
 [PinBackend]::SetWindowPos($target,[IntPtr]::Zero,600,300,1100,700,0x4014)|Out-Null
 Start-Sleep -Milliseconds 50
 $watch.Restart();Command-Backend 112
 $report.constraints=@{elapsed_ms=$watch.Elapsed.TotalMilliseconds;status=(Text-Backend 138);revision_unchanged=((Config-Backend).revision -eq $revision)}
 Assert-Backend ($report.constraints.status -match '受限' -and $report.constraints.revision_unchanged) 'An enforced minimum size is reported as constrained without changing the preset'
 [PinBackend]::SendMessageW($target,0x802b,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
 Command-Backend 112
 Assert-Backend ([PinBackend]::Error([PinBackend]::Frame($target),$baseline) -le 2) 'Exact restore works again after fixture constraints are removed'
 Memory-Backend 0
 for($cycle=1;$cycle -le $Cycles;$cycle++){
  [PinBackend]::SetWindowPos($target,[IntPtr]::Zero,(130+($cycle%4)*17),(150+($cycle%3)*19),(700+($cycle%2)*12),(500+($cycle%5)*8),0x4014)|Out-Null
  Start-Sleep -Milliseconds 15
  Command-Backend 111
  if((Text-Backend 138) -notmatch '已记住'){throw 'Stress remember did not report persistence'}
  $saved=[PinBackend]::Frame($target)
  [PinBackend]::SetWindowPos($target,[IntPtr]::Zero,650,350,450,300,0x4014)|Out-Null
  Command-Backend 112
  if((Text-Backend 138) -notmatch '已恢复|已符合' -or [PinBackend]::Error([PinBackend]::Frame($target),$saved) -gt 2){throw 'Stress restore failed its visible-frame check'}
  $report.completed=$cycle
  if($cycle%25 -eq 0){Memory-Backend $cycle;Write-Host ('Background cycles '+$cycle+'/'+$Cycles)}
 }
 Memory-Backend $Cycles
 $process.Refresh();$cpu=$process.TotalProcessorTime.TotalMilliseconds;$watch.Restart()
 while($watch.Elapsed.TotalSeconds -lt $IdleSeconds){Start-Sleep -Seconds 1}
 $process.Refresh();$report.idle=@{seconds=$watch.Elapsed.TotalSeconds;cpu_delta_ms=$process.TotalProcessorTime.TotalMilliseconds-$cpu;private_bytes=$process.PrivateMemorySize64}
 Assert-Backend (($report.memory|Where-Object {$_.private_bytes -gt 50MB}).Count -eq 0) 'All observed post-operation private-memory samples stay within 50 MiB'
 Assert-Backend ($startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)) 'Real user startup registration remains unchanged'
} catch {$report.errors+=$_.Exception.Message}
finally {
 if($process -and -not $process.HasExited){try{Owner-Backend $process $ExePath $configDir;[PinBackend]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null;$report.normal_exit=$process.WaitForExit(8000) -and $process.ExitCode -eq 0}catch{$report.errors+=('App cleanup: '+$_.Exception.Message)}}
 if($fixture -and -not $fixture.HasExited){try{Owner-Backend $fixture $FixturePath $title;[PinBackend]::PostMessageW($target,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null;$report.fixture_normal_exit=$fixture.WaitForExit(8000) -and $fixture.ExitCode -eq 0}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)}}
 $report.passed=$report.errors.Count -eq 0 -and $report.completed -eq $Cycles -and $report.normal_exit -and $report.fixture_normal_exit
 $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8
 Write-Host ('Background report: '+(Join-Path $runDir 'report.json'))
}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
