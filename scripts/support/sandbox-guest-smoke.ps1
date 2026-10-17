#Requires -Version 5.1
param([string]$InputDir='C:\ScreenPinInput',[string]$OutputDir='C:\ScreenPinOutput',[switch]$FunctionsOnly)
$ErrorActionPreference='Stop'
$expected=Get-Content -LiteralPath (Join-Path $InputDir 'expected.json') -Raw -Encoding utf8|ConvertFrom-Json
$report=[ordered]@{run_id=$expected.run_id;started_utc=[DateTime]::UtcNow.ToString('o');checks=@();startups=@();restores=@();normal_exits=@();errors=@();passed=$false;scope='Fresh Windows Sandbox desktop; original release ZIP, default guest configuration, owned native fixture, real foreground hotkeys and ordinary restart. No external runtime or development tool installation.';limitations=@('One virtual display/current guest DPI and the Sandbox account; does not prove physical mixed DPI, UAC handoff, Narrator, independent usability or a full Windows installation/reboot.')}
$process=$null;$hostWindow=[IntPtr]::Zero;$settings=[IntPtr]::Zero;$fixture=[IntPtr]::Zero;$oldDpi=[IntPtr]::Zero
$configDir=Join-Path $env:LOCALAPPDATA 'ScreenPin';$configPath=Join-Path $configDir 'config.json'
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-Guest($value,[string]$message){if(-not $value){throw $message};$report.checks+=$message}
function Wait-Guest([scriptblock]$test,[string]$name){$deadline=[DateTime]::UtcNow.AddSeconds(10);do{try{if(& $test){return}}catch{if($_.Exception.Message -notmatch 'Timed out reading own app result'){throw}};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline);throw ('Timeout: '+$name)}
function Frame-Guest {$r=[PinApplication+Rect]::new();if([PinApplication]::DwmGetWindowAttribute($fixture,9,[ref]$r,16) -ne 0){throw 'Own fixture DWM frame unavailable'};return $r}
function Error-Guest($a,$b){$value=0;foreach($edge in @('Left','Top','Right','Bottom')){$value=[Math]::Max($value,[Math]::Abs($a.$edge-$b.$edge))};return $value}
function Status-Guest {[PinRealKeys]::Text($settings,138)}
function Read-GuestConfig {
 # Observers must permit the application's atomic replacement of this file.
 $stream=[IO.File]::Open($configPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try{$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true);try{return ($reader.ReadToEnd()|ConvertFrom-Json)}finally{$reader.Dispose()}}finally{$stream.Dispose()}
}
function Command-Guest([int]$id){[PinRealKeys]::Command($settings,$process.Id,$id);Wait-Guest {(Status-Guest) -notmatch '^正在处理'} ('GUI '+$id)}
function Focus-Fixture {
 if([PinRealKeys]::GetForegroundWindow() -ne $fixture){
  [PinApplication]::SetForegroundWindow($fixture)|Out-Null
  if([PinRealKeys]::GetForegroundWindow() -ne $fixture){Add-Type -AssemblyName UIAutomationClient;$element=[System.Windows.Automation.AutomationElement]::FromHandle($fixture);if($element.Current.ProcessId -ne $PID){throw 'Own fixture UIA identity changed'};$element.SetFocus()}
 }
 [PinRealKeys]::AssertForeground()
}
function Move-Fixture([int]$x,[int]$y,[int]$width,[int]$height){Focus-Fixture;$before=Frame-Guest;if(-not [PinApplication]::SetWindowPos($fixture,[IntPtr]::Zero,$x,$y,$width,$height,0x4014)){throw 'Own fixture move failed'};Wait-Guest {(Error-Guest (Frame-Guest) $before) -gt 10} 'owned displacement';Start-Sleep -Milliseconds 80}
function New-GuestProcess([string]$arguments='',[switch]$Diagnostic) {
 $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$script:exePath;$info.Arguments=$arguments;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
 if($Diagnostic){$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)}
 $child=[Diagnostics.Process]::new();$child.StartInfo=$info;$child.Start()|Out-Null;return $child
}
function Start-GuestApp {
 $script:hostWindow=[IntPtr]::Zero;$script:settings=[IntPtr]::Zero
 $script:launchWatch=[Diagnostics.Stopwatch]::StartNew()
 $script:process=New-GuestProcess
 Wait-Guest {$h=@([PinRealKeys]::FindClass('ScreenPin.Host',$process.Id));$s=@([PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id));if($h.Count -eq 1){$script:hostWindow=$h[0]};if($s.Count -eq 1){$script:settings=$s[0]};return $hostWindow -ne [IntPtr]::Zero -and $settings -ne [IntPtr]::Zero -and [PinRealKeys]::Enabled($settings,$process.Id,207)} 'default startup'
 $report.startups+=@{pid=$process.Id;handles_ready_ms=$launchWatch.Elapsed.TotalMilliseconds;visible_at_handles_ready=[PinApplication]::IsWindowVisible($settings)}
 $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id);Assert-Guest ($owner.ExecutablePath -ieq $exePath) 'Guest process runs the extracted release executable'
}
function Stop-GuestApp {
 if($process -and -not $process.HasExited){$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id);if($owner.ExecutablePath -ine $exePath){throw 'Guest exit identity mismatch'};[uint32]$pidOwner=0;[PinRealKeys]::GetWindowThreadProcessId($hostWindow,[ref]$pidOwner)|Out-Null;if($pidOwner -ne $process.Id){throw 'Own host window identity mismatch'};[PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null;if(-not $process.WaitForExit(8000)){throw 'Normal guest exit timed out'};Assert-Guest ($process.ExitCode -eq 0) 'Guest release exited normally';$report.normal_exits+=@{pid=$process.Id;exit_code=$process.ExitCode}}
}
if($FunctionsOnly){return}
try{
 $os=Get-CimInstance Win32_OperatingSystem;$identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=[Security.Principal.WindowsPrincipal]::new($identity)
 $tools=@();foreach($name in @('cargo','rustc','cl','vswhere','dotnet','pwsh')){if(Get-Command $name -ErrorAction SilentlyContinue){$tools+=$name}}
 $windowsVersion=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
 $report['environment']=@{display_version=$windowsVersion.DisplayVersion;update_build_revision=$windowsVersion.UBR;logical_processors=[Environment]::ProcessorCount;visible_memory_kib=$os.TotalVisibleMemorySize;os=$os.Caption;build=$os.BuildNumber;version=$os.Version;architecture=$os.OSArchitecture;powershell=$PSVersionTable.PSVersion.ToString();culture=[Globalization.CultureInfo]::CurrentUICulture.Name;administrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);development_commands_found=$tools}
 Assert-Guest ($tools.Count -eq 0) 'No Rust/MSVC/.NET SDK or PowerShell 7 development command is available'
 Assert-Guest (-not (Test-Path -LiteralPath $configDir)) 'Default guest configuration directory is initially absent'
 foreach($entry in $expected.files.PSObject.Properties){Assert-Guest ((Get-FileHash -LiteralPath (Join-Path $InputDir $entry.Name)).Hash -eq $entry.Value) ('Read-only staged input matches host hash: '+$entry.Name)}
 $report['guest_script_sha256']=(Get-FileHash -LiteralPath $PSCommandPath).Hash
 $zip=Join-Path $InputDir 'ScreenPin.zip';Assert-Guest ((Get-FileHash -LiteralPath $zip).Hash -eq $expected.zip_sha256) 'Input is the original verified release ZIP'
 $localRoot=Join-Path $env:LOCALAPPDATA ('ScreenPin-Clean-'+$expected.run_id);$appDir=Join-Path $localRoot 'app';New-Item -ItemType Directory -Path $appDir -Force|Out-Null
 Expand-Archive -LiteralPath $zip -DestinationPath $appDir
 $files=@(Get-ChildItem -LiteralPath $appDir -File);Assert-Guest ($files.Count -eq 2 -and @(Get-ChildItem -LiteralPath $appDir -Directory).Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $appDir 'README.txt'))) 'ZIP contains only the executable and README'
 $script:exePath=(Get-Item -LiteralPath (Join-Path $appDir 'screen-pin.exe')).FullName
 $report['exe_sha256']=(Get-FileHash -LiteralPath $exePath).Hash;$report['zip_sha256']=(Get-FileHash -LiteralPath $zip).Hash
 Assert-Guest ($report.exe_sha256 -eq $expected.exe_sha256) 'Extracted executable hash matches the host release'
 $diagnosePath=Join-Path $OutputDir 'guest-diagnose.json';$diagnose=New-GuestProcess '--diagnose' -Diagnostic;$diagnosticOutput=$diagnose.StandardOutput.ReadToEndAsync();$diagnosticError=$diagnose.StandardError.ReadToEndAsync()
 if(-not $diagnose.WaitForExit(8000)){throw 'Guest release diagnostics timed out'}
 $report['diagnostic_exit_code']=$diagnose.ExitCode;[IO.File]::WriteAllText($diagnosePath,$diagnosticOutput.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false));$report['diagnostic_stderr']=$diagnosticError.GetAwaiter().GetResult()
 if($diagnose.ExitCode -ne 0){throw 'Guest release diagnostics failed'}
 $report['diagnostics']=Get-Content -LiteralPath $diagnosePath -Raw -Encoding utf8|ConvertFrom-Json
 Assert-Guest ($report.diagnostics.monitors.Count -gt 0) 'Guest public diagnostics record the actual virtual display bounds and work area'
 Add-Type -Path (Join-Path $InputDir 'real-keys.cs');Add-Type -Path (Join-Path $InputDir 'application-native.cs');Add-Type -AssemblyName System.Drawing
 $oldDpi=[PinApplication]::SetThreadDpiAwarenessContext([IntPtr](-4))
 Assert-Guest ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) 'No guest Screen Pin instance predates the test'
 Start-GuestApp
 Wait-Guest {[PinApplication]::IsWindowVisible($settings)} 'first default UI becomes visible'
 $report['first_visible_ms']=$launchWatch.Elapsed.TotalMilliseconds
 Assert-Guest ([PinApplication]::IsWindowVisible($settings)) 'First default launch automatically displays the configuration UI'
 Assert-Guest (Test-Path -LiteralPath $configPath) 'Default LOCALAPPDATA configuration is created in the guest profile'
 Wait-Guest {$script:initialKeyStatus=[PinRealKeys]::Text($settings,208);([regex]::Matches($initialKeyStatus,'已注册')).Count -eq 2} 'both default hotkeys report ready'
 Assert-Guest (([regex]::Matches($initialKeyStatus,'已注册')).Count -eq 2) 'Both default hotkeys are registered in the clean guest'
 $report['guest_dpi']=[PinApplication]::GetDpiForWindow($settings)
 $unexpected=@($process.Modules|Where-Object {$_.FileName -ine $exePath -and -not $_.FileName.StartsWith($env:WINDIR+'\',[StringComparison]::OrdinalIgnoreCase)}|ForEach-Object FileName)
 $report['non_windows_modules']=$unexpected;Assert-Guest ($unexpected.Count -eq 0) 'Running release loads no modules outside its executable and Windows directories'
 $fixture=[PinRealKeys]::StartFixture();Focus-Fixture;$title='Screen Pin clean guest '+$expected.run_id;[PinRealKeys]::FixtureTitle($title)
 $monitor=[PinApplication+Monitor]::new();$monitor.Size=[Runtime.InteropServices.Marshal]::SizeOf($monitor);if(-not [PinApplication]::GetMonitorInfoW([PinApplication]::MonitorFromWindow($fixture,2),[ref]$monitor)){throw 'Guest monitor unavailable'}
 $report['target_monitor']=@{bounds=$monitor.Bounds;work=$monitor.Work;device=$monitor.Device}
 $x=$monitor.Work.Left;$y=$monitor.Work.Top
 Move-Fixture ($x+50) ($y+70) 360 260;$guiBaseline=Frame-Guest;Command-Guest 109;[PinRealKeys]::SelectWindow($settings,$process.Id,$title);Command-Guest 111
 $config=Read-GuestConfig;Assert-Guest ($config.profiles[0].applications.Count -eq 1 -and $config.profiles[0].applications[0].default) 'GUI capture creates only the selected fixture application default'
 Move-Fixture ($x+200) ($y+180) 300 220;$hash=(Get-FileHash -LiteralPath $configPath).Hash;Command-Guest 112
 Wait-Guest {(Error-Guest (Frame-Guest) $guiBaseline) -le 2} 'GUI geometry restoration'
 Assert-Guest ((Get-FileHash -LiteralPath $configPath).Hash -eq $hash) 'GUI restore preserves saved configuration bytes'
 $report['gui_restore']=@{expected=$guiBaseline;actual=(Frame-Guest);edge_error_px=(Error-Guest (Frame-Guest) $guiBaseline)}
 Move-Fixture ($x+90) ($y+100) 380 280;$baseline=Frame-Guest;$revision=$config.revision
 [PinRealKeys]::Chord(0x79);Wait-Guest {$c=Read-GuestConfig;return $c.revision -gt $revision -and (Status-Guest) -match '^已记住'} 'actual F10 capture'
 $hash=(Get-FileHash -LiteralPath $configPath).Hash
 for($i=0;$i -lt 20;$i++){
  Move-Fixture ($x+220) ($y+190) 300 220;$watch=[Diagnostics.Stopwatch]::StartNew();[PinRealKeys]::Chord(0x78)
  Wait-Guest {(Error-Guest (Frame-Guest) $baseline) -le 2 -and (Status-Guest) -match '^已恢复|^已符合预设'} 'actual F9 restore'
  [PinRealKeys]::AssertForeground();$errorPx=Error-Guest (Frame-Guest) $baseline
  Assert-Guest ($errorPx -le 2 -and (Get-FileHash -LiteralPath $configPath).Hash -eq $hash) 'Actual guest restore verifies geometry without writing config or changing foreground'
  $report.restores+=@{cycle=$i+1;edge_error_px=$errorPx;elapsed_ms=$watch.Elapsed.TotalMilliseconds;foreground_preserved=$true;expected=$baseline;actual=(Frame-Guest)}
 }
 $r=[PinApplication+Rect]::new();[PinApplication]::GetWindowRect($settings,[ref]$r)|Out-Null;$bitmap=[Drawing.Bitmap]::new($r.Right-$r.Left,$r.Bottom-$r.Top);$graphics=[Drawing.Graphics]::FromImage($bitmap);$dc=$graphics.GetHdc();try{if(-not [PinApplication]::PrintWindow($settings,$dc,2)){throw 'Guest GUI capture failed'}}finally{$graphics.ReleaseHdc($dc)};$bitmap.Save((Join-Path $OutputDir 'guest-ui.png'),[Drawing.Imaging.ImageFormat]::Png);$graphics.Dispose();$bitmap.Dispose()
 Command-Guest 102;Assert-Guest ([PinRealKeys]::Text($settings,309) -match '应用后影响.*1 个预设') 'Guest association preview reports the actual saved scope'
 [PinApplication]::PostMessageW($settings,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null;Wait-Guest {-not [PinApplication]::IsWindowVisible($settings)} 'close hides UI'
 Assert-Guest (-not $process.HasExited -and [PinRealKeys]::Responsive($hostWindow)) 'Closing UI preserves the responsive guest host'
 $duplicate=New-GuestProcess;Assert-Guest ($duplicate.WaitForExit(8000) -and $duplicate.ExitCode -eq 0) 'Duplicate launch exits normally'
 Assert-Guest ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 1 -and [PinApplication]::IsWindowVisible($settings)) 'Duplicate launch opens the existing instance without a second host'
 Stop-GuestApp;Start-GuestApp
 Assert-Guest (-not [PinApplication]::IsWindowVisible($settings) -and (Get-FileHash -LiteralPath $configPath).Hash -eq $hash) 'Ordinary restart retains exact config bytes and starts in the tray'
 Move-Fixture ($x+220) ($y+190) 300 220;[PinRealKeys]::Chord(0x78);Wait-Guest {(Error-Guest (Frame-Guest) $baseline) -le 2 -and (Status-Guest) -match '^已恢复|^已符合预设'} 'persisted preset after restart'
 [PinRealKeys]::AssertForeground();$report['restart_restore']=@{expected=$baseline;actual=(Frame-Guest);edge_error_px=(Error-Guest (Frame-Guest) $baseline);foreground_preserved=$true}
 Assert-Guest ((Get-FileHash -LiteralPath $configPath).Hash -eq $hash) 'Real F9 after restart uses the preserved preset without rewriting'
 Stop-GuestApp
}catch{
 $report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace
 try{$report['failure_observation']=@{status=(Status-Guest);refresh_enabled=[PinRealKeys]::Enabled($settings,$process.Id,109);foreground=[PinRealKeys]::GetForegroundWindow().ToInt64();fixture=$fixture.ToInt64();frame=(Frame-Guest);config=(Read-GuestConfig)}}catch{$report['failure_observation_error']=$_.Exception.Message}
}
finally{
 try{if($process -and -not $process.HasExited){Stop-GuestApp}}catch{$report.errors+=('Exit: '+$_.Exception.Message)}
 try{if($fixture -ne [IntPtr]::Zero){[PinRealKeys]::StopFixture()}}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)}
 if($oldDpi -ne [IntPtr]::Zero){[PinApplication]::SetThreadDpiAwarenessContext($oldDpi)|Out-Null}
 $report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
 $report.passed=$report.errors.Count -eq 0 -and $report.normal_exits.Count -eq 2 -and $report.restores.Count -eq 20 -and $report.startup_registry_unchanged
 $report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutputDir 'guest-report.json') -Encoding utf8
}
if(-not $report.passed){exit 1}
