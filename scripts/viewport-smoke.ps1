#Requires -Version 7.0
param(
 [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
 [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/viewport')
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('viewport-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'config')).FullName;$configPath=Join-Path $configDir 'config.json'
$helper=Join-Path $PSScriptRoot 'support/real-keys.cs';Add-Type -Path $helper
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class PinViewport {
 public delegate bool EnumProc(IntPtr h,IntPtr data);
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]public struct Font{public int Height,Width,Escapement,Orientation,Weight;public byte Italic,Underline,StrikeOut,CharacterSet,OutPrecision,ClipPrecision,Quality,PitchAndFamily;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string Face;}
 public class Box{public int id,region;public Rect bounds,visible;}
 [DllImport("user32.dll")]public static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]private static extern bool GetClientRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]private static extern int MapWindowPoints(IntPtr a,IntPtr b,ref Rect r,uint count);
 [DllImport("user32.dll")]private static extern bool EnumChildWindows(IntPtr h,EnumProc p,IntPtr data);
 [DllImport("user32.dll")]private static extern IntPtr GetParent(IntPtr h);
 [DllImport("user32.dll")]private static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]private static extern int GetDlgCtrlID(IntPtr h);
 [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern bool SetWindowTextW(IntPtr h,string text);
 [DllImport("user32.dll")]private static extern int GetWindowRgn(IntPtr h,IntPtr region);
 [DllImport("gdi32.dll")]private static extern IntPtr CreateRectRgn(int a,int b,int c,int d);
 [DllImport("gdi32.dll")]private static extern int GetRgnBox(IntPtr region,out Rect r);
 [DllImport("gdi32.dll")]private static extern bool DeleteObject(IntPtr h);
 [DllImport("gdi32.dll",CharSet=CharSet.Unicode)]private static extern int GetObjectW(IntPtr h,int size,out Font font);
 [DllImport("user32.dll")]public static extern uint GetGuiResources(IntPtr process,uint flags);
 [DllImport("user32.dll")]public static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")]public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll")]public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll")]private static extern IntPtr SendMessageTimeoutW(IntPtr h,uint msg,IntPtr wp,IntPtr lp,uint flags,uint timeout,out UIntPtr result);
 public static void Message(IntPtr h,uint pid,uint message,int wp){uint owner;GetWindowThreadProcessId(h,out owner);if(owner!=pid)throw new InvalidOperationException("Viewport message owner mismatch");UIntPtr result;if(SendMessageTimeoutW(h,message,new IntPtr(wp),IntPtr.Zero,0x23,500,out result)==IntPtr.Zero)throw new InvalidOperationException("Own viewport message timed out");}
 public static void Title(IntPtr h,uint pid,string title){uint owner;GetWindowThreadProcessId(h,out owner);if(owner!=pid||!SetWindowTextW(h,title))throw new InvalidOperationException("Fixture title ownership mismatch");}
 public static Rect Bounds(IntPtr h){Rect r;if(!GetWindowRect(h,out r))throw new InvalidOperationException("Own control bounds unavailable");return r;}
 public static Rect Client(IntPtr h){Rect r;if(!GetClientRect(h,out r))throw new InvalidOperationException("Own client bounds unavailable");MapWindowPoints(h,IntPtr.Zero,ref r,2);return r;}
 public static Font ControlFont(IntPtr h){UIntPtr result;if(SendMessageTimeoutW(h,0x31,IntPtr.Zero,IntPtr.Zero,0x23,100,out result)==IntPtr.Zero)throw new InvalidOperationException("Font query timed out");Font font;if(GetObjectW(new IntPtr((long)result.ToUInt64()),Marshal.SizeOf(typeof(Font)),out font)==0)throw new InvalidOperationException("Font metadata unavailable");return font;}
 public static Box[] Content(IntPtr root){var boxes=new List<Box>();EnumChildWindows(root,delegate(IntPtr h,IntPtr data){if(GetParent(h)!=root||!IsWindowVisible(h))return true;int id=GetDlgCtrlID(h);if(id==100||id==101||id==102||id==136||id==137||id==138)return true;var r=Bounds(h);var visible=r;var region=CreateRectRgn(0,0,0,0);if(region==IntPtr.Zero)throw new InvalidOperationException("Region query allocation failed");int type;try{type=GetWindowRgn(h,region);if(type==1)visible=new Rect();else if(type!=0){Rect local;GetRgnBox(region,out local);visible=new Rect{Left=Math.Max(r.Left,r.Left+local.Left),Top=Math.Max(r.Top,r.Top+local.Top),Right=Math.Min(r.Right,r.Left+local.Right),Bottom=Math.Min(r.Bottom,r.Top+local.Bottom)};}}finally{DeleteObject(region);}boxes.Add(new Box{id=id,region=type,bounds=r,visible=visible});return true;},IntPtr.Zero);return boxes.ToArray();}
}
'@
$oldDpi=[PinViewport]::SetThreadDpiAwarenessContext([IntPtr](-4))
$report=[ordered]@{started_utc=[DateTime]::UtcNow.ToString('o');exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;helper_sha256=(Get-FileHash -LiteralPath $helper).Hash;checks=@();scenes=@();resources=@();screenshots=@();errors=@();normal_exit=$false;passed=$false;scope='Only owned GUI commands, native viewport/region/font queries, own window resizing and local setting-reload messages; no SendInput or global display/font/theme change.';limitations=@('Current physical display/current DPI only; does not prove real mixed-DPI, large system font, high contrast or Narrator.','Synthetic current-size resize and local reload are not physical topology or global setting tests.')}
$process=$null;$settings=[IntPtr]::Zero;$hostWindow=[IntPtr]::Zero
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-VP($value,[string]$message){if(-not $value){throw $message};$report.checks+=$message}
function Wait-VP([scriptblock]$condition,[string]$name){$deadline=[DateTime]::UtcNow.AddSeconds(8);do{try{if(& $condition){return}}catch{if($_.Exception.Message -notmatch 'Timed out reading own app result'){throw}};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline);throw ('Timeout: '+$name)}
function Command-VP([int]$id){[PinRealKeys]::Command($settings,$process.Id,$id);Wait-VP {[PinRealKeys]::Text($settings,138) -notmatch '^正在处理'} ('GUI command '+$id)}
function Chrome-VP {$rows=@();foreach($id in @(100,101,102,136,137,138)){$rows+=@{id=$id;rect=[PinViewport]::Bounds([PinViewport]::GetDlgItem($settings,$id))}};return $rows}
function Check-VP([string]$scene){
 $client=[PinViewport]::Client($settings);$chrome=Chrome-VP;$header=($chrome[0..2].rect.Bottom|Measure-Object -Maximum).Maximum;$footer=$chrome[3].rect.Top
 foreach($row in $chrome){$r=$row.rect;Assert-VP ($r.Left -ge $client.Left -and $r.Top -ge $client.Top -and $r.Right -le $client.Right -and $r.Bottom -le $client.Bottom) ($scene+': fixed control '+$row.id+' is fully inside the window')}
 $boxes=@([PinViewport]::Content($settings));$painted=@($boxes|Where-Object {$_.visible.Bottom -gt $_.visible.Top})
 Assert-VP ($painted.Count -gt 0) ($scene+': content remains visible')
 foreach($box in $painted){Assert-VP ($box.visible.Top -ge $header -and $box.visible.Bottom -le $footer) ($scene+': content '+$box.id+' cannot cover fixed navigation or feedback')}
 $report.scenes+=@{scene=$scene;client=$client;chrome=$chrome;content=$boxes}
 return ($chrome|ConvertTo-Json -Depth 6 -Compress)
}
function Image-VP([string]$name){$r=[PinViewport]::Bounds($settings);$bitmap=[Drawing.Bitmap]::new($r.Right-$r.Left,$r.Bottom-$r.Top);$g=[Drawing.Graphics]::FromImage($bitmap);$dc=$g.GetHdc();try{if(-not [PinViewport]::PrintWindow($settings,$dc,2)){throw 'Own screenshot rendering failed'}}finally{$g.ReleaseHdc($dc)};$path=Join-Path $runDir ($name+'.png');$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png);$g.Dispose();$bitmap.Dispose();$report.screenshots+=@{scene=$name;path=$path}}
try{
 Assert-VP ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) 'No existing Screen Pin instance'
 $exe=Get-Item -LiteralPath $ExePath;$process=Start-Process -FilePath $exe.FullName -ArgumentList '--show','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
 Wait-VP {$w=@([PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id));$h=@([PinRealKeys]::FindClass('ScreenPin.Host',$process.Id));if($h.Count -eq 1){$script:hostWindow=$h[0]};if($w.Count -eq 1){$script:settings=$w[0]};return $settings -ne [IntPtr]::Zero -and [PinRealKeys]::Enabled($settings,$process.Id,207)} 'owned startup'
 $fixture=[PinRealKeys]::StartFixture();$title='Screen Pin Viewport Fixture '+[Guid]::NewGuid().ToString('N');[PinViewport]::Title($fixture,$PID,$title)
 Command-VP 109;[PinRealKeys]::SelectWindow($settings,$process.Id,$title);Command-VP 111
 [PinViewport]::Message([PinViewport]::GetDlgItem($settings,117),$process.Id,0x186,0);Command-VP (65536+117)
 [PinRealKeys]::ControlText($settings,$process.Id,114,'Viewport');$configHash=(Get-FileHash -LiteralPath $configPath).Hash
 foreach($size in @(@(1100,800),@(720,440),@(900,600))){
  Assert-VP ([PinViewport]::SetWindowPos($settings,[IntPtr]::Zero,40,40,$size[0],$size[1],0x4014)) 'Resize only the owned settings window'
  foreach($page in @(100,101,102)){
   Command-VP $page;[PinViewport]::Message($settings,$process.Id,0x115,6);Start-Sleep -Milliseconds 30;$top=Check-VP ($size[0].ToString()+'x'+$size[1]+'-page-'+$page+'-top')
   [PinViewport]::Message($settings,$process.Id,0x115,7);Start-Sleep -Milliseconds 30;$bottom=Check-VP ($size[0].ToString()+'x'+$size[1]+'-page-'+$page+'-bottom')
   Assert-VP ($top -ceq $bottom) 'Scrolling changes content without moving navigation, Undo or recent result'
   if($size[0] -in @(1100,720)){Image-VP ($size[0].ToString()+'-page-'+$page+'-bottom')}
   $font=[PinViewport]::ControlFont([PinViewport]::GetDlgItem($settings,$page));Assert-VP ($font.Weight -ge 600) 'Current page has native semibold emphasis'
  }
 }
 $font=[PinViewport]::ControlFont([PinViewport]::GetDlgItem($settings,114));$report['body_font']=$font;$report['dpi']=[PinViewport]::GetDpiForWindow($settings)
 Assert-VP ([Math]::Abs($font.Height) -ge 14*$report.dpi/96) 'Body text is at least 14 logical pixels and retains the system font'
 Command-VP 100;[PinViewport]::Message($settings,$process.Id,0x115,7)
 for($i=0;$i -lt 44;$i++){[PinViewport]::Message($settings,$process.Id,0x115,6);[PinViewport]::Message($settings,$process.Id,0x115,7);[PinViewport]::Message($settings,$process.Id,0x1a,0);if($i -ge 4){$process.Refresh();$report.resources+=@{iteration=$i;gdi=[PinViewport]::GetGuiResources($process.Handle,0);user=[PinViewport]::GetGuiResources($process.Handle,1);private_bytes=$process.PrivateMemorySize64}}}
 $gdi=@($report.resources.gdi);Assert-VP ($gdi[0] -gt 0 -and ($gdi[-1] - $gdi[0]) -le 8) 'Forty warmed scroll and local font reload cycles have bounded GDI object growth'
 $null=Check-VP 'after-resource-cycles';Assert-VP ((Get-FileHash -LiteralPath $configPath).Hash -eq $configHash) 'Viewport, resize and local setting reload do not write config'
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{if($process -and -not $process.HasExited){try{$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id);if($owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains($configDir)){throw 'Owned exit identity mismatch'};[PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null;if(-not $process.WaitForExit(8000)){throw 'Normal owned exit timed out'};$report.normal_exit=$process.ExitCode -eq 0}catch{$report.errors+=('Cleanup: '+$_.Exception.Message)}};try{[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)};[PinViewport]::SetThreadDpiAwarenessContext($oldDpi)|Out-Null;$report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null);$report.passed=$report.errors.Count -eq 0 -and $report.normal_exit -and $report.startup_registry_unchanged -and $report.scenes.Count -eq 19;$report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8;Write-Host ('Viewport report: '+(Join-Path $runDir 'report.json'))}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
