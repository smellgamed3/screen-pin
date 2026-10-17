#Requires -Version 7.0
param(
 [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
 [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/list-widths')
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('list-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'config')).FullName;$configPath=Join-Path $configDir 'config.json'
$helper=Join-Path $PSScriptRoot 'support/real-keys.cs';Add-Type -Path $helper
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PinListWidth {
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential)]public struct Size{public int Width,Height;}
 public class Sample{public int id,count,max_pixels,extent,font_height;public long font;}
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]public struct Font{public int Height,Width,Escapement,Orientation,Weight;public byte Italic,Underline,StrikeOut,CharacterSet,OutPrecision,ClipPrecision,Quality,PitchAndFamily;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string Face;}
 [DllImport("user32.dll")]private static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",SetLastError=true)]private static extern IntPtr SendScale(IntPtr h,uint msg,IntPtr wp,ref Rect rect,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll")]private static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern bool SetWindowTextW(IntPtr h,string title);
 [DllImport("user32.dll")]private static extern IntPtr GetDC(IntPtr h);
 [DllImport("user32.dll")]private static extern int ReleaseDC(IntPtr h,IntPtr dc);
 [DllImport("gdi32.dll",CharSet=CharSet.Unicode)]private static extern IntPtr CreateFontIndirectW(ref Font font);
 [DllImport("gdi32.dll")]private static extern bool DeleteObject(IntPtr h);
 [DllImport("gdi32.dll")]private static extern IntPtr SelectObject(IntPtr dc,IntPtr h);
 [DllImport("gdi32.dll",CharSet=CharSet.Unicode)]private static extern bool GetTextExtentPoint32W(IntPtr dc,string text,int length,out Size size);
 [DllImport("gdi32.dll",CharSet=CharSet.Unicode)]private static extern int GetObjectW(IntPtr h,int bytes,out Font font);
 [DllImport("user32.dll")]private static extern IntPtr SendMessageTimeoutW(IntPtr h,uint msg,IntPtr wp,IntPtr lp,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="SendMessageTimeoutW")]private static extern IntPtr SendText(IntPtr h,uint msg,IntPtr wp,StringBuilder text,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll")]public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll")]public static extern uint GetGuiResources(IntPtr process,uint flags);
 private static void Owner(IntPtr h,uint pid){uint owner;GetWindowThreadProcessId(h,out owner);if(owner!=pid)throw new InvalidOperationException("List query/message ownership mismatch");}
 private static long Query(IntPtr h,uint pid,uint message,int wp){Owner(h,pid);UIntPtr result;if(SendMessageTimeoutW(h,message,new IntPtr(wp),IntPtr.Zero,0x23,500,out result)==IntPtr.Zero)throw new InvalidOperationException("Own list query timed out");return (long)result.ToUInt64();}
 public static void Title(IntPtr h,uint pid,string title){Owner(h,pid);if(!SetWindowTextW(h,title))throw new InvalidOperationException("Own fixture title change failed");}
 public static void Scale(IntPtr h,uint pid,int dpi){Owner(h,pid);Rect r;if(!GetWindowRect(h,out r))throw new InvalidOperationException("Own scale bounds unavailable");UIntPtr result;if(SendScale(h,0x2e0,new IntPtr(dpi|(dpi<<16)),ref r,0x23,500,out result)==IntPtr.Zero)throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(),"Own scale handler message failed");}
 public static void First(IntPtr h,uint pid){Owner(h,pid);if(Query(GetDlgItem(h,117),pid,0x186,0)!=0)throw new InvalidOperationException("Own first preset selection failed");}
 public static Sample Read(IntPtr root,uint pid,int id){Owner(root,pid);var h=GetDlgItem(root,id);Owner(h,pid);var result=new Sample{id=id,count=(int)Query(h,pid,0x18b,0),extent=(int)Query(h,pid,0x193,0),font=Query(h,pid,0x31,0)};var fontHandle=new IntPtr(result.font);Font font;if(fontHandle==IntPtr.Zero||GetObjectW(fontHandle,Marshal.SizeOf(typeof(Font)),out font)==0)throw new InvalidOperationException("Own list font unavailable");result.font_height=font.Height;var localFont=CreateFontIndirectW(ref font);if(localFont==IntPtr.Zero)throw new InvalidOperationException("Local copy of list font unavailable");var dc=GetDC(h);if(dc==IntPtr.Zero){DeleteObject(localFont);throw new InvalidOperationException("List measurement DC unavailable");}var old=SelectObject(dc,localFont);if(old==IntPtr.Zero||old==new IntPtr(-1)){ReleaseDC(h,dc);DeleteObject(localFont);throw new InvalidOperationException("Local font selection failed");}try{for(int i=0;i<result.count;i++){int length=(int)Query(h,pid,0x18a,i);if(length<0||length>32768)throw new InvalidOperationException("List item length invalid");var text=new StringBuilder(length+1);UIntPtr copied;if(SendText(h,0x189,new IntPtr(i),text,0x23,500,out copied)==IntPtr.Zero)throw new InvalidOperationException("List item read timed out");Size size;if(!GetTextExtentPoint32W(dc,text.ToString(),text.Length,out size))throw new InvalidOperationException("Native list text measurement failed");result.max_pixels=Math.Max(result.max_pixels,size.Width);}}finally{SelectObject(dc,old);ReleaseDC(h,dc);DeleteObject(localFont);}return result;}
}
'@
$previousDpi=[PinListWidth]::SetThreadDpiAwarenessContext([IntPtr](-4))
$report=[ordered]@{started_utc=[DateTime]::UtcNow.ToString('o');exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;helper_sha256=(Get-FileHash -LiteralPath $helper).Hash;checks=@();samples=@();resources=@();errors=@();normal_exit=$false;passed=$false;scope='Owned native GUI commands and GDI measurements of actual list text using a checked local copy of the actual LOGFONT; local WM_DPICHANGED handler exercise only. No SendInput, global display/font/theme/startup change, or user-window modification.';limitations=@('Current physical single display at 96 DPI. Local scale messages do not prove physical DPI transitions, mixed DPI, user-selected fonts or Narrator.','Window list is measured without saving any other window titles to the report.')}
$process=$null;$hostWindow=[IntPtr]::Zero;$settings=[IntPtr]::Zero
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-LW($value,[string]$message){if(-not $value){throw $message};$report.checks+=$message}
function Wait-LW([scriptblock]$test,[string]$description){$deadline=[DateTime]::UtcNow.AddSeconds(8);do{try{if(& $test){return}}catch{if($_.Exception.Message -notmatch 'Timed out reading own app result'){throw}};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline);throw ('Timeout: '+$description)}
function Command-LW([int]$id){[PinRealKeys]::Command($settings,$process.Id,$id);Wait-LW {[PinRealKeys]::Text($settings,138) -notmatch '^正在处理'} ('GUI command '+$id)}
function Sample-LW([int]$id,[string]$scene){$s=[PinListWidth]::Read($settings,$process.Id,$id);$report.samples+=@{scene=$scene;measurement=$s};Assert-LW ($s.extent -ge $s.max_pixels+4) ($scene+': scroll extent '+$s.extent+' covers measured text '+$s.max_pixels+' plus padding');Assert-LW ($s.extent -le $s.max_pixels+64) ($scene+': scroll extent shrinks to current content');return $s}
try{
 Assert-LW ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) 'No existing Screen Pin instance'
 $process=Start-Process -FilePath $ExePath -ArgumentList '--show','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
 Wait-LW {$w=@([PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id));$h=@([PinRealKeys]::FindClass('ScreenPin.Host',$process.Id));if($h.Count -eq 1){$script:hostWindow=$h[0]};if($w.Count -eq 1){$script:settings=$w[0]};return $settings -ne [IntPtr]::Zero -and [PinRealKeys]::Enabled($settings,$process.Id,207)} 'owned startup'
 $fixture=[PinRealKeys]::StartFixture();$prefix='Screen Pin List Width '+[Guid]::NewGuid().ToString('N')+' ';$wide=$prefix+('W'*512)+' 终点';[PinListWidth]::Title($fixture,$PID,$wide)
 Command-LW 109;$null=Sample-LW 108 'wide-title-96'
 [PinRealKeys]::SelectWindow($settings,$process.Id,$prefix);Command-LW 111
 [PinRealKeys]::ControlText($settings,$process.Id,114,('W'*160));Command-LW 115
 $null=Sample-LW 117 'wide-rule-96';$configHash=(Get-FileHash -LiteralPath $configPath).Hash
 foreach($dpi in @(144,192,96)){
  [PinListWidth]::Scale($settings,$process.Id,$dpi)
  $a=Sample-LW 108 ('wide-title-handler-'+$dpi);$b=Sample-LW 117 ('wide-rule-handler-'+$dpi)
  Assert-LW ([Math]::Abs($a.font_height) -eq [Math]::Round(14*$dpi/96)) 'Local scale handler actually changes the font used for measurement'
 }
 Assert-LW ((Get-FileHash -LiteralPath $configPath).Hash -eq $configHash) 'Local scale changes do not write config'
 for($i=0;$i -lt 24;$i++){[PinListWidth]::Scale($settings,$process.Id,144);[PinListWidth]::Scale($settings,$process.Id,96);if($i -ge 4){$report.resources+=@{iteration=$i;gdi=[PinListWidth]::GetGuiResources($process.Handle,0);user=[PinListWidth]::GetGuiResources($process.Handle,1)}}}
 Assert-LW (($report.resources[-1].gdi-$report.resources[0].gdi) -le 8) 'Twenty warmed local scale cycles have bounded GDI growth'
 Assert-LW ((Get-FileHash -LiteralPath $configPath).Hash -eq $configHash) 'Scale/resource cycles do not write config'
 $short=$prefix+'中文 iii';[PinListWidth]::Title($fixture,$PID,$short);Command-LW 109;$null=Sample-LW 108 'short-title-after-refresh'
 [PinRealKeys]::SelectWindow($settings,$process.Id,$prefix)
 [PinRealKeys]::ControlText($settings,$process.Id,114,'中文');Command-LW 115
 $null=Sample-LW 117 'wide-and-short-rules'
 # Select the first (wide) rule explicitly, then remove only that private record.
 [PinListWidth]::First($settings,$process.Id);Command-LW (65536+117);Command-LW 133
 $null=Sample-LW 117 'short-rules-after-delete'
 $c=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json;Assert-LW ($c.profiles[0].applications[0].rules.Count -eq 1 -and $c.profiles[0].applications[0].rules[0].keyword -eq '中文') 'Only the owned long rule was deleted; short rule remains'
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{
 if($process -and -not $process.HasExited){try{$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id);if($owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains($configDir)){throw 'Owned exit identity mismatch'};[PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null;if(-not $process.WaitForExit(8000)){throw 'Owned normal exit timed out'};$report.normal_exit=$process.ExitCode -eq 0}catch{$report.errors+=('Cleanup: '+$_.Exception.Message)}}
 try{[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)};[PinListWidth]::SetThreadDpiAwarenessContext($previousDpi)|Out-Null
 $report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null);$report.passed=$report.errors.Count -eq 0 -and $report.normal_exit -and $report.startup_registry_unchanged;$report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8;Write-Host ('List width report: '+(Join-Path $runDir 'report.json'))
}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
