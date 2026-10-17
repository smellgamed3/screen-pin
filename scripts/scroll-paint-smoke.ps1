#Requires -Version 7.0
param(
 [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
 [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/scroll-paint'),
 [string]$UiaProbePath=(Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe')
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName;$UiaProbePath=(Get-Item -LiteralPath $UiaProbePath).FullName
$root=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('paint-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$configDir=(New-Item -ItemType Directory -Path (Join-Path $root 'config')).FullName;$configPath=Join-Path $configDir 'config.json'
$helper=Join-Path $PSScriptRoot 'support/real-keys.cs';$native=Join-Path $PSScriptRoot 'support/application-native.cs'
Add-Type -AssemblyName System.Drawing;Add-Type -Path $helper;Add-Type -Path $native
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class PinScrollPaint {
 [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern bool SetWindowTextW(IntPtr h,string title);
 public static void Title(IntPtr h,uint pid,string title){uint owner;GetWindowThreadProcessId(h,out owner);if(owner!=pid||!SetWindowTextW(h,title))throw new InvalidOperationException("Own fixture title identity mismatch");}
 [DllImport("user32.dll")]public static extern bool RedrawWindow(IntPtr h,IntPtr rect,IntPtr region,uint flags);
 [DllImport("user32.dll")]public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
'@
$oldDpi=[PinScrollPaint]::SetThreadDpiAwarenessContext([IntPtr](-4))
$report=[ordered]@{started_utc=[DateTime]::UtcNow.ToString('o');exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;helper_sha256=(Get-FileHash -LiteralPath $helper).Hash;native_helper_sha256=(Get-FileHash -LiteralPath $native).Hash;checks=@();scenes=@();errors=@();normal_exit=$false;passed=$false;scope='Direct desktop pixel captures limited to the owned association preview; compares settled scrolling with an explicit full repaint. Owned GUI messages and public UIA focus of the first tab only, no SendInput or global setting change.';limitations=@('One physical display/current 96 DPI. This test does not prove mixed DPI, high contrast, Narrator or independent usability.','Exact pixels are compared within one focused instance and one unchanged control, not against a machine-specific golden image.')}
$process=$null;$hostWindow=[IntPtr]::Zero;$settings=[IntPtr]::Zero
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-SP($value,[string]$message){if(-not $value){throw $message};$report.checks+=$message}
function Wait-SP([scriptblock]$test,[string]$description){$deadline=[DateTime]::UtcNow.AddSeconds(8);do{try{if(& $test){return}}catch{if($_.Exception.Message -notmatch 'Timed out reading own app result'){throw}};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline);throw ('Timeout: '+$description)}
function Command-SP([int]$id){[PinRealKeys]::Command($settings,$process.Id,$id);Wait-SP {[PinRealKeys]::Text($settings,138) -notmatch '^正在处理'} ('GUI command '+$id)}
function Guard-SP {
 [uint32]$owner=0;[PinRealKeys]::GetWindowThreadProcessId($settings,[ref]$owner)|Out-Null
 if($process.HasExited -or $owner -ne $process.Id -or [PinApplication]::GetForegroundWindow() -ne $settings){throw 'Own foreground changed; desktop capture cancelled'}
}
function Capture-SP([string]$name){
 Guard-SP;$rect=[PinApplication+Rect]::new();if(-not [PinApplication]::GetWindowRect([PinApplication]::GetDlgItem($settings,309),[ref]$rect)){throw 'Own preview bounds unavailable'}
 # Exclude the border and scrollbar; this rectangle contains only owned text/background.
 $bitmap=[Drawing.Bitmap]::new($rect.Right-$rect.Left-28,$rect.Bottom-$rect.Top-8);$g=[Drawing.Graphics]::FromImage($bitmap)
 try{$g.CopyFromScreen($rect.Left+4,$rect.Top+4,0,0,$bitmap.Size);Guard-SP;$path=Join-Path $root ($name+'.png');$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png);return [pscustomobject]@{path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash;rect=$rect}}finally{$g.Dispose();$bitmap.Dispose()}
}
try{
 Assert-SP ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) 'No existing Screen Pin instance'
 $process=Start-Process -FilePath $ExePath -ArgumentList '--show','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
 Wait-SP {$w=@([PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id));$h=@([PinRealKeys]::FindClass('ScreenPin.Host',$process.Id));if($h.Count -eq 1){$script:hostWindow=$h[0]};if($w.Count -eq 1){$script:settings=$w[0]};return $settings -ne [IntPtr]::Zero -and [PinRealKeys]::Enabled($settings,$process.Id,207)} 'owned startup'
 $fixture=[PinRealKeys]::StartFixture();$title='Screen Pin paint fixture '+[Guid]::NewGuid().ToString('N');[PinScrollPaint]::Title($fixture,$PID,$title);Command-SP 109;[PinRealKeys]::SelectWindow($settings,$process.Id,$title);Command-SP 111
 $inputPath=Join-Path $root 'focus-input.json';$outputPath=Join-Path $root 'focus-output.json'
 ConvertTo-Json -InputObject @(@{handle=[PinApplication]::GetDlgItem($settings,100).ToInt64();id=100;page='activation'})|Set-Content -LiteralPath $inputPath -Encoding utf8
 & $UiaProbePath $inputPath $outputPath $process.Id --focus;if($LASTEXITCODE -ne 0){throw 'Owned first-tab UIA focus failed'}
 Guard-SP;Command-SP 102;Start-Sleep -Milliseconds 200;$configHash=(Get-FileHash -LiteralPath $configPath).Hash
 for($i=0;$i -lt 5;$i++){
  foreach($position in @(@('top',6),@('bottom',7))){
   Guard-SP;[PinApplication]::SendMessageW($settings,0x115,[IntPtr]$position[1],[IntPtr]::Zero)|Out-Null;Start-Sleep -Milliseconds 180
   $text=[PinRealKeys]::Text($settings,309);Assert-SP ($text -match '应用后影响.*1 个预设') 'Owned preview contains its actual saved scope'
   $before=Capture-SP ($i.ToString()+'-'+$position[0]+'-settled')
   Assert-SP ([PinScrollPaint]::RedrawWindow($settings,[IntPtr]::Zero,[IntPtr]::Zero,0x185)) 'Explicit comparison repaint succeeds';Start-Sleep -Milliseconds 100
   $after=Capture-SP ($i.ToString()+'-'+$position[0]+'-repainted')
   $report.scenes+=@{iteration=$i;position=$position[0];before=$before;after=$after;text_unchanged=$text -ceq [PinRealKeys]::Text($settings,309)}
   Assert-SP ($before.sha256 -eq $after.sha256) 'Settled scroll pixels already match a complete repaint'
  }
 }
 Assert-SP ((Get-FileHash -LiteralPath $configPath).Hash -eq $configHash) 'Scrolling and painting do not write config'
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{
 if($process -and -not $process.HasExited){try{$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id);if($owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains($configDir)){throw 'Owned exit identity mismatch'};[PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null;if(-not $process.WaitForExit(8000)){throw 'Owned normal exit timed out'};$report.normal_exit=$process.ExitCode -eq 0}catch{$report.errors+=('Cleanup: '+$_.Exception.Message)}}
 try{[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)};[PinScrollPaint]::SetThreadDpiAwarenessContext($oldDpi)|Out-Null
 $report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null);$report.passed=$report.errors.Count -eq 0 -and $report.normal_exit -and $report.startup_registry_unchanged -and $report.scenes.Count -eq 10;$report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $root 'report.json') -Encoding utf8;Write-Output ('Scroll paint report: '+(Join-Path $root 'report.json'))
}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
