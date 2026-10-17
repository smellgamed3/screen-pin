#Requires -Version 5.1
param([string]$InputDir='C:\ScreenPinInput',[string]$OutputDir='C:\ScreenPinOutput')
$ErrorActionPreference='Stop'
$expected=Get-Content -LiteralPath (Join-Path $InputDir 'expected.json') -Raw -Encoding utf8|ConvertFrom-Json
$report=[ordered]@{run_id=$expected.run_id;started_utc=[DateTime]::UtcNow.ToString('o');checks=@();startups=@();restores=@();normal_exits=@();errors=@();passed=$false;scope='Actual guest-only Explorer restart and Run enable/path repair/disable. OS reboot and login are not tested.'}
$guestAllowed=$false;$lease=$null;$duplicateVerifier=$false;$process=$null;$fixture=[IntPtr]::Zero;$oldDpi=[IntPtr]::Zero

function Write-Life($path,$value){$value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $path -Encoding utf8}
try{
 $computer=Get-CimInstance Win32_ComputerSystem;$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 $environment=@{computer=$env:COMPUTERNAME;user=$identity.Name;manufacturer=$computer.Manufacturer;model=$computer.Model;boot_utc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o');administrator=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
 $report['environment']=$environment
 # Do not execute these lifecycle actions from a host session or an ordinary VM account.
 $guestAllowed=$expected.mode -eq 'lifecycle' -and $InputDir -eq 'C:\ScreenPinInput' -and $OutputDir -eq 'C:\ScreenPinOutput' -and $identity.Name.EndsWith('\WDAGUtilityAccount',[StringComparison]::OrdinalIgnoreCase) -and $computer.Manufacturer -eq 'Microsoft Corporation' -and $computer.Model -eq 'Virtual Machine' -and $env:COMPUTERNAME -ne $expected.host_computer_name
 if(-not $guestAllowed){throw 'Guest-only lifecycle guard rejected this environment'}
 try{$lease=[IO.File]::Open((Join-Path $OutputDir 'lifecycle.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{$duplicateVerifier=$true;exit 0}
 $initialReport=$report
 . (Join-Path $InputDir 'sandbox-guest-smoke.ps1') -InputDir $InputDir -OutputDir $OutputDir -FunctionsOnly
 $report=$initialReport;$guestAllowed=$true
 foreach($entry in $expected.files.PSObject.Properties){Assert-Guest ((Get-FileHash -LiteralPath (Join-Path $InputDir $entry.Name)).Hash -eq $entry.Value) ('Lifecycle input hash matches: '+$entry.Name)}
 $report['guest_script_sha256']=(Get-FileHash -LiteralPath $PSCommandPath).Hash;$report['exe_sha256']=$expected.exe_sha256;$report['zip_sha256']=(Get-FileHash -LiteralPath (Join-Path $InputDir 'ScreenPin.zip')).Hash
 Assert-Guest ($report.zip_sha256 -eq $expected.zip_sha256) 'Lifecycle uses the original release ZIP'
 Add-Type -Path (Join-Path $InputDir 'real-keys.cs');Add-Type -Path (Join-Path $InputDir 'application-native.cs')
 Add-Type @'
using System;using System.Runtime.InteropServices;
public static class PinGuestLife {
 [StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential)]private struct IconId{public uint size;public IntPtr window;public uint id;public Guid guid;}
 [DllImport("shell32.dll")]private static extern int Shell_NotifyIconGetRect(ref IconId id,out Rect rect);
 [DllImport("user32.dll")]public static extern IntPtr GetShellWindow();
 public static int Tray(IntPtr window,out Rect rect){var id=new IconId{size=(uint)Marshal.SizeOf(typeof(IconId)),window=window,id=1};return Shell_NotifyIconGetRect(ref id,out rect);}
 [DllImport("user32.dll")]public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 public static uint ShellPid(){uint pid;GetWindowThreadProcessId(GetShellWindow(),out pid);return pid;}
}
'@
 $oldDpi=[PinApplication]::SetThreadDpiAwarenessContext([IntPtr](-4))
 function Wait-Life([scriptblock]$test,[string]$name,[int]$seconds=60){$end=[DateTime]::UtcNow.AddSeconds($seconds);do{try{if(& $test){return}}catch{if($_.Exception.Message -notmatch 'Timed out reading own app result'){throw}};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $end);throw ('Lifecycle timeout: '+$name)}
 function Ready-Life {Wait-Life {([regex]::Matches([PinRealKeys]::Text($settings,208),'已注册')).Count -eq 2 -and [PinRealKeys]::Enabled($settings,$process.Id,207)} 'hotkeys and operation slot ready'}
 function Tray-Life {$r=[PinGuestLife+Rect]::new();$hr=[PinGuestLife]::Tray($hostWindow,[ref]$r);return @{hresult=$hr;rect=$r}}
 function Set-Autostart([bool]$enabled){Command-Guest 101;[PinApplication]::SendMessageW([PinApplication]::GetDlgItem($settings,206),0xf1,[IntPtr][int]$enabled,[IntPtr]::Zero)|Out-Null;Command-Guest 207;Wait-Life {$c=Get-Content -LiteralPath $configPath -Raw -Encoding utf8|ConvertFrom-Json;return $c.settings.autostart -eq $enabled} 'saved autostart choice'}
 function Restore-Life($placement,[string]$name){
  $focusEnd=[DateTime]::UtcNow.AddSeconds(10);$focusError=$null;do{try{Focus-Fixture;$focusError=$null;break}catch{$focusError=$_;Start-Sleep -Milliseconds 200}}while([DateTime]::UtcNow -lt $focusEnd);if($focusError){throw $focusError};$m=[PinApplication+Monitor]::new();$m.Size=[Runtime.InteropServices.Marshal]::SizeOf($m);if(-not [PinApplication]::GetMonitorInfoW([PinApplication]::MonitorFromWindow($fixture,2),[ref]$m)){throw 'Guest work area unavailable'}
  $w=$m.Work.Right-$m.Work.Left;$h=$m.Work.Bottom-$m.Work.Top;$wanted=[PinApplication+Rect]::new();$wanted.Left=$m.Work.Left+[Math]::Round($placement.rect.x*$w);$wanted.Top=$m.Work.Top+[Math]::Round($placement.rect.y*$h);$wanted.Right=$wanted.Left+[Math]::Round($placement.rect.width*$w);$wanted.Bottom=$wanted.Top+[Math]::Round($placement.rect.height*$h)
  Move-Fixture ($m.Work.Left+220) ($m.Work.Top+190) 300 220;$hash=(Get-FileHash -LiteralPath $configPath).Hash;[PinRealKeys]::Chord(0x78)
  Wait-Life {(Error-Guest (Frame-Guest) $wanted) -le 2 -and (Status-Guest) -match '^已恢复|^已符合预设'} $name 10
  [PinRealKeys]::AssertForeground();Assert-Guest ((Get-FileHash -LiteralPath $configPath).Hash -eq $hash) 'Lifecycle hotkey restore does not rewrite configuration'
  $report.restores+=@{scene=$name;expected=$wanted;actual=(Frame-Guest);edge_error_px=(Error-Guest (Frame-Guest) $wanted);foreground_preserved=$true;work_area=$m.Work}
 }

  $report['phase']='before-reboot';Assert-Guest (-not (Test-Path -LiteralPath $configDir)) 'Fresh lifecycle guest starts without application config'
  $appDir=Join-Path $env:LOCALAPPDATA ('ScreenPin-Life-'+$expected.run_id+'\app');New-Item -ItemType Directory -Path $appDir -Force|Out-Null;Expand-Archive -LiteralPath (Join-Path $InputDir 'ScreenPin.zip') -DestinationPath $appDir
  $script:exePath=(Get-Item -LiteralPath (Join-Path $appDir 'screen-pin.exe')).FullName;$report.exe_sha256=(Get-FileHash -LiteralPath $exePath).Hash;Assert-Guest ((Get-FileHash -LiteralPath $exePath).Hash -eq $expected.exe_sha256) 'Lifecycle extracted executable matches release'
  Start-GuestApp;Ready-Life
  Assert-Guest ($startupBefore -eq $null) 'Guest autostart is initially absent'
  $fixture=[PinRealKeys]::StartFixture();Focus-Fixture;[PinRealKeys]::FixtureTitle('Screen Pin lifecycle '+$expected.run_id);Move-Fixture 90 100 380 280
  [PinRealKeys]::Chord(0x79);Wait-Life {(Test-Path -LiteralPath $configPath) -and (Status-Guest) -match '^已记住'} 'seed real F10 capture' 10
  $c=Get-Content -LiteralPath $configPath -Raw -Encoding utf8|ConvertFrom-Json;$placement=$c.profiles[0].applications[0].default.placement
  Wait-Life {$tray=Tray-Life;$tray.hresult -eq 0 -and $tray.rect.Right -gt $tray.rect.Left -and $tray.rect.Bottom -gt $tray.rect.Top} 'initial tray icon rectangle';$trayBefore=Tray-Life;$appPidBefore=$process.Id;$configHash=(Get-FileHash -LiteralPath $configPath).Hash
  $shellPid=[PinGuestLife]::ShellPid();$shellProcess=Get-Process -Id $shellPid;$shellOwner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$shellPid)
  Assert-Guest ($shellOwner.ExecutablePath -ieq (Join-Path $env:WINDIR 'explorer.exe') -and $shellProcess.SessionId -eq (Get-Process -Id $PID).SessionId) 'Only the current guarded guest shell is selected for restart'
  $shellProcess.Kill();if(-not $shellProcess.WaitForExit(8000)){throw 'Own guest Explorer did not exit'}
  Wait-Life {[PinGuestLife]::ShellPid() -gt 0 -and [PinGuestLife]::ShellPid() -ne $shellPid} 'new actual Explorer process'
  Wait-Life {$tray=Tray-Life;$tray.hresult -eq 0 -and $tray.rect.Right -gt $tray.rect.Left -and $tray.rect.Bottom -gt $tray.rect.Top} 'tray icon recreated in new Explorer';Ready-Life
  $report['explorer_restart']=@{old_pid=$shellPid;new_pid=[PinGuestLife]::ShellPid();app_pid_before=$appPidBefore;app_pid_after=$process.Id;tray_before=$trayBefore;tray_after=(Tray-Life)}
  Assert-Guest (-not $process.HasExited -and $process.Id -eq $appPidBefore -and (Get-FileHash -LiteralPath $configPath).Hash -eq $configHash) 'Actual guest Explorer restart preserves the app and exact config bytes'
  Restore-Life $placement 'after-explorer-restart'
  Set-Autostart $true;$runValue=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
  Assert-Guest ($runValue -and $runValue.Contains($exePath) -and $runValue.Contains('--background')) 'GUI enabling autostart writes the actual guest Run command'
  Stop-GuestApp
  $moved=Join-Path (Split-Path -Parent $appDir) 'moved-app';New-Item -ItemType Directory -Path $moved|Out-Null;Copy-Item -LiteralPath (Join-Path $appDir 'screen-pin.exe') -Destination (Join-Path $moved 'screen-pin.exe')
  $script:exePath=(Get-Item -LiteralPath (Join-Path $moved 'screen-pin.exe')).FullName;Start-GuestApp;Ready-Life
  Assert-Guest ([PinRealKeys]::Text($settings,214) -match '开机启动项与当前程序路径不一致') 'Launching the same app from a new path exposes the real startup path mismatch'
  $beforeRepair=(Get-FileHash -LiteralPath $configPath).Hash;Set-Autostart $true;$repaired=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
  Assert-Guest ($repaired.Contains($exePath) -and $repaired -ne $runValue -and (Get-FileHash -LiteralPath $configPath).Hash -eq $beforeRepair) 'Explicit path repair updates Run without rewriting unchanged app settings'
  Set-Autostart $false;Assert-Guest ($null -eq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)) 'GUI disabling autostart removes the actual guest Run entry'
  Stop-GuestApp;$report['phase']='completed-without-reboot';$report['reboot_verified']=$false

}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{
 if($guestAllowed -and -not $duplicateVerifier){try{if($process -and -not $process.HasExited){Stop-GuestApp}}catch{$report.errors+=('App cleanup: '+$_.Exception.Message)};try{if($fixture -ne [IntPtr]::Zero){[PinRealKeys]::StopFixture()}}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)}}
 if($oldDpi -ne [IntPtr]::Zero){[PinApplication]::SetThreadDpiAwarenessContext($oldDpi)|Out-Null}
 if($lease){$lease.Dispose()}
 if(-not $duplicateVerifier){$report.passed=$report.errors.Count -eq 0 -and $report.phase -eq 'completed-without-reboot' -and $report.restores.Count -eq 1;$report['finished_utc']=[DateTime]::UtcNow.ToString('o');Write-Life (Join-Path $OutputDir 'guest-report.json') $report}
}
if(-not $duplicateVerifier -and -not $report.passed){exit 1}
