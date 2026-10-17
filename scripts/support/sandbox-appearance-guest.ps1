#Requires -Version 5.1
param([string]$InputDir='C:\ScreenPinInput',[string]$OutputDir='C:\ScreenPinOutput')
$ErrorActionPreference='Stop'
$expected=Get-Content -LiteralPath (Join-Path $InputDir 'expected.json') -Raw -Encoding utf8|ConvertFrom-Json
$report=[ordered]@{run_id=$expected.run_id;started_utc=[DateTime]::UtcNow.ToString('o');checks=@();startups=@();restores=@();normal_exits=@();scenes=@();focus=@();screenshots=@();text_metrics=@();errors=@();passed=$false;scope='Fresh isolated Sandbox only: actual system message-font and high-contrast changes, native bounds, owned foreground keyboard traversal and actual hotkeys. No host system setting changes; no Narrator or mixed-DPI claim.'}
$guestAllowed=$false;$savedMetrics=$null;$savedContrast=$null;$savedTheme=$null;$process=$null;$fixture=[IntPtr]::Zero;$oldDpi=[IntPtr]::Zero
try{
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$computer=Get-CimInstance Win32_ComputerSystem
 $guestAllowed=$expected.mode -eq 'appearance' -and $InputDir -eq 'C:\ScreenPinInput' -and $OutputDir -eq 'C:\ScreenPinOutput' -and $identity.Name.EndsWith('\WDAGUtilityAccount',[StringComparison]::OrdinalIgnoreCase) -and $computer.Manufacturer -eq 'Microsoft Corporation' -and $computer.Model -eq 'Virtual Machine' -and $env:COMPUTERNAME -ne $expected.host_computer_name
 if(-not $guestAllowed){throw 'Appearance guest-only guard rejected this environment'}
 $initialReport=$report
 . (Join-Path $InputDir 'sandbox-guest-smoke.ps1') -InputDir $InputDir -OutputDir $OutputDir -FunctionsOnly
 $report=$initialReport
 foreach($entry in $expected.files.PSObject.Properties){Assert-Guest ((Get-FileHash -LiteralPath (Join-Path $InputDir $entry.Name)).Hash -eq $entry.Value) ('Appearance input hash matches: '+$entry.Name)}
 $report['guest_script_sha256']=(Get-FileHash -LiteralPath $PSCommandPath).Hash;$report['zip_sha256']=(Get-FileHash -LiteralPath (Join-Path $InputDir 'ScreenPin.zip')).Hash
 Assert-Guest ($report.zip_sha256 -eq $expected.zip_sha256) 'Appearance uses the original release ZIP'
 foreach($name in @('real-keys.cs','application-native.cs','viewport-native.cs','desktop-keyboard.cs','guest-appearance.cs')){Add-Type -Path (Join-Path $InputDir $name)}
 Add-Type -AssemblyName System.Drawing;Add-Type -AssemblyName UIAutomationClient
 $oldDpi=[PinApplication]::SetThreadDpiAwarenessContext([IntPtr](-4))
 $savedTheme=[Environment]::ExpandEnvironmentVariables((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes').CurrentTheme);$report['initial_theme']=$savedTheme;$savedMetrics=[PinGuestAppearance]::ReadMetrics();$savedContrast=[PinGuestAppearance]::ReadContrast()
 $savedColors=@([PinGuestAppearance]::GetSysColor(5),[PinGuestAppearance]::GetSysColor(8),[PinGuestAppearance]::GetSysColor(15),[PinGuestAppearance]::GetSysColor(18));$report['initial_colors']=$savedColors;$report['initial_metrics']=$savedMetrics;$report['initial_contrast']=$savedContrast;$report['environment']=@{os=(Get-CimInstance Win32_OperatingSystem).Caption;build=[Environment]::OSVersion.Version.ToString();user=$identity.Name;computer=$env:COMPUTERNAME}
 $appDir=Join-Path $env:LOCALAPPDATA ('ScreenPin-Appearance-'+$expected.run_id);New-Item -ItemType Directory -Path $appDir|Out-Null;Expand-Archive -LiteralPath (Join-Path $InputDir 'ScreenPin.zip') -DestinationPath $appDir
 $script:exePath=(Get-Item -LiteralPath (Join-Path $appDir 'screen-pin.exe')).FullName;$report['exe_sha256']=(Get-FileHash -LiteralPath $exePath).Hash
 Assert-Guest ($report.exe_sha256 -eq $expected.exe_sha256) 'Appearance executable matches release'
 Start-GuestApp;Wait-Guest {[PinApplication]::IsWindowVisible($settings)} 'first appearance UI'
 $fixture=[PinRealKeys]::StartFixture();Focus-Fixture;[PinRealKeys]::FixtureTitle('Screen Pin appearance '+$expected.run_id);Move-Fixture 80 90 380 280
 [PinRealKeys]::Chord(0x79);Wait-Guest {(Status-Guest) -match '^已记住'} 'initial actual capture';$baseline=Frame-Guest;Command-Guest 109;[PinRealKeys]::SelectWindow($settings,$process.Id,('Screen Pin appearance '+$expected.run_id));[PinViewport]::Message([PinViewport]::GetDlgItem($settings,117),$process.Id,0x186,0);Command-Guest (65536+117);$configHash=(Get-FileHash -LiteralPath $configPath).Hash
 function Focus-Fixture {[PinGuestAppearance]::Activate($fixture,$PID);[PinRealKeys]::AssertForeground()}
 function Focus-Appearance {
  [PinApplication]::ShowWindow($settings,9)|Out-Null
  [PinGuestAppearance]::Activate($settings,$process.Id)
  [PinDesktopKeyboard]::AssertForeground($settings,$process.Id)
 }
 function Wait-Theme([uint32]$background,[uint32]$foreground){
  $deadline=[DateTime]::UtcNow.AddSeconds(45)
  do{
   $palette=@{window=[PinGuestAppearance]::GetSysColor(5);text=[PinGuestAppearance]::GetSysColor(8);contrast=[PinGuestAppearance]::ReadContrast();current_theme=(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes').CurrentTheme;utc=[DateTime]::UtcNow.ToString('o')}
   $palette|ConvertTo-Json -Depth 4|Set-Content (Join-Path $OutputDir 'theme-progress.json') -Encoding utf8
   if($palette.window -eq $background -and $palette.text -eq $foreground){return};Start-Sleep -Milliseconds 500
  }while([DateTime]::UtcNow -lt $deadline)
  Image-Appearance 'unconfirmed-theme-palette'
  $probe="Add-Type -Path C:\ScreenPinInput\guest-appearance.cs;@{window=[PinGuestAppearance]::GetSysColor(5);text=[PinGuestAppearance]::GetSysColor(8);contrast=[PinGuestAppearance]::ReadContrast()}|ConvertTo-Json -Depth 4|Set-Content C:\ScreenPinOutput\fresh-palette.json -Encoding utf8"
  $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe';$info.Arguments='-NoProfile -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe));$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$child=[Diagnostics.Process]::new();$child.StartInfo=$info;$child.Start()|Out-Null;$child.WaitForExit(8000)|Out-Null
  $report['unconfirmed_theme_palette']=$palette;throw 'Actual theme palette was not confirmed within 45 seconds'
 }
 function Image-Appearance([string]$name){
  $r=[PinViewport]::Bounds($settings);$bitmap=[Drawing.Bitmap]::new($r.Right-$r.Left,$r.Bottom-$r.Top,[Drawing.Imaging.PixelFormat]::Format24bppRgb);$g=[Drawing.Graphics]::FromImage($bitmap);$dc=$g.GetHdc()
  try{if(-not [PinViewport]::PrintWindow($settings,$dc,2)){throw 'Appearance screenshot failed'}}finally{$g.ReleaseHdc($dc)}
  try{$path=Join-Path $OutputDir ($name+'.png');$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png);$report.screenshots+=@{scene=$name;path=$path}}finally{$g.Dispose();$bitmap.Dispose()}
 }
 function Check-Appearance([string]$name){
  $deadline=[DateTime]::UtcNow.AddSeconds(2);$attempts=0;$watch=[Diagnostics.Stopwatch]::StartNew()
  do{
   $client=[PinViewport]::Client($settings);$chrome=@();foreach($id in @(100,101,102,136,137,138)){$r=[PinViewport]::Bounds([PinViewport]::GetDlgItem($settings,$id));$chrome+=@{id=$id;rect=$r}}
   $header=($chrome[0..2].rect.Bottom|Measure-Object -Maximum).Maximum;$footer=$chrome[3].rect.Top;$content=@([PinViewport]::Content($settings));$painted=@($content|Where-Object {$_.visible.Bottom -gt $_.visible.Top})
   $invalid=@($chrome|Where-Object {$_.rect.Left -lt $client.Left -or $_.rect.Top -lt $client.Top -or $_.rect.Right -gt $client.Right -or $_.rect.Bottom -gt $client.Bottom}).Count+@($painted|Where-Object {$_.visible.Top -lt $header -or $_.visible.Bottom -gt $footer}).Count
   $attempts++;if($invalid -eq 0 -and $painted.Count -gt 0){break};Start-Sleep -Milliseconds 20
  }while([DateTime]::UtcNow -lt $deadline)
  foreach($row in $chrome){$r=$row.rect;Assert-Guest ($r.Left -ge $client.Left -and $r.Top -ge $client.Top -and $r.Right -le $client.Right -and $r.Bottom -le $client.Bottom) ($name+': fixed control '+$row.id+' fits')}
  Assert-Guest ($painted.Count -gt 0) ($name+': content visible')
  foreach($box in $painted){Assert-Guest ($box.visible.Top -ge $header -and $box.visible.Bottom -le $footer) ($name+': content '+$box.id+' respects fixed areas')}
  $report.scenes+=@{scene=$name;client=$client;chrome=$chrome;content=$content;settle_attempts=$attempts;settle_ms=$watch.Elapsed.TotalMilliseconds}
 }
 function Keyboard-Appearance([string]$name){
  Focus-Appearance;$wanted=@([PinViewport]::TabIds($settings));$seen=@{};foreach($reverse in @($false,$true)){
   for($i=0;$i -le $wanted.Count;$i++){
    $before=[PinDesktopKeyboard]::FocusId($settings,$process.Id);[PinDesktopKeyboard]::Press($settings,$process.Id,9,$(if($reverse){16}else{0}));Wait-Guest {[PinDesktopKeyboard]::FocusId($settings,$process.Id) -ne $before} 'appearance Tab focus';Start-Sleep -Milliseconds 30
    $id=[PinDesktopKeyboard]::FocusId($settings,$process.Id);$r=[PinViewport]::Bounds([PinViewport]::GetDlgItem($settings,$id));$client=[PinViewport]::Client($settings)
    $box=@([PinViewport]::Content($settings)|Where-Object {$_.id -eq $id});$complete=$r.Left -ge $client.Left -and $r.Top -ge $client.Top -and $r.Right -le $client.Right -and $r.Bottom -le $client.Bottom
    if($box.Count -eq 1){$v=$box[0].visible;$complete=$complete -and $v.Left -eq $r.Left -and $v.Top -eq $r.Top -and $v.Right -eq $r.Right -and $v.Bottom -eq $r.Bottom}
    $report.focus+=@{scene=$name;id=$id;reverse=$reverse;fully_visible=$complete;bounds=$r};Assert-Guest $complete ($name+': focused '+$id+' fully visible');$seen[$id]=$true
   }
  }
  foreach($id in $wanted){Assert-Guest ($seen.ContainsKey($id)) ($name+': enabled Tab stop '+$id+' reached')}
 }
 foreach($mode in @('default','large-font','large-font-high-contrast')){
  @{mode=$mode;phase='before-system-change';utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $OutputDir 'guest-progress.json') -Encoding utf8
  if($mode -ne 'default'){$metrics=[PinGuestAppearance]::ReadMetrics();$messageFont=$metrics.Message;$messageFont.Height=-24;$metrics.Message=$messageFont;[PinGuestAppearance]::ApplyMetrics($metrics);Assert-Guest ([PinGuestAppearance]::ReadMetrics().Message.Height -eq -24) 'Actual guest system message font is 24 px'}
  if($mode -eq 'large-font-high-contrast'){
   $theme=Join-Path $env:WINDIR 'Resources\Ease of Access Themes\hcblack.theme';if(-not (Test-Path -LiteralPath $theme)){throw 'Built-in black high-contrast theme is absent'}
   $themeText=Get-Content -LiteralPath $theme -Raw
   $palette=@{};foreach($name in @('Window','WindowText')){$match=[regex]::Match($themeText,'(?m)^'+$name+'=(\d+)\s+(\d+)\s+(\d+)\s*$');if(-not $match.Success){throw ('Built-in contrast theme does not define '+$name)};$palette[$name]=[uint32]([int]$match.Groups[1].Value+([int]$match.Groups[2].Value -shl 8)+([int]$match.Groups[3].Value -shl 16))}
   $report['contrast_theme']=@{path=$theme;sha256=(Get-FileHash -LiteralPath $theme).Hash;expected_palette=$palette};Start-Process -FilePath $theme|Out-Null
   Wait-Theme $palette.Window $palette.WindowText;Assert-Guest (([PinGuestAppearance]::ReadContrast().Flags -band 1) -eq 1) 'Actual contrast mode enabled with a verified palette'
   $metrics=[PinGuestAppearance]::ReadMetrics();$messageFont=$metrics.Message;$messageFont.Height=-24;$metrics.Message=$messageFont;[PinGuestAppearance]::ApplyMetrics($metrics);Start-Sleep -Milliseconds 800
  }
  @{mode=$mode;phase='after-system-change';system_font=[PinGuestAppearance]::ReadMetrics().Message;app_font=[PinViewport]::ControlFont([PinViewport]::GetDlgItem($settings,114));utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content (Join-Path $OutputDir 'guest-progress.json') -Encoding utf8
  try{Wait-Guest {[Math]::Abs([PinViewport]::ControlFont([PinViewport]::GetDlgItem($settings,114)).Height) -ge $(if($mode -eq 'default'){14}else{24})} 'app follows actual system font'}catch{
   $report['font_failure_before_message']=@{system=[PinGuestAppearance]::ReadMetrics();app=[PinViewport]::ControlFont([PinViewport]::GetDlgItem($settings,114))}
   [PinViewport]::Message($settings,$process.Id,0x1a,0);Start-Sleep -Milliseconds 100
   $report['font_failure_after_local_message']=[PinViewport]::ControlFont([PinViewport]::GetDlgItem($settings,114));throw
  }
  $report[$mode]=@{metrics=[PinGuestAppearance]::ReadMetrics();contrast=[PinGuestAppearance]::ReadContrast();control_font=[PinViewport]::ControlFont([PinViewport]::GetDlgItem($settings,114));dpi=[PinViewport]::GetDpiForWindow($settings);colors=@{button_face=[PinGuestAppearance]::GetSysColor(15);button_text=[PinGuestAppearance]::GetSysColor(18);window=[PinGuestAppearance]::GetSysColor(5);window_text=[PinGuestAppearance]::GetSysColor(8);highlight=[PinGuestAppearance]::GetSysColor(13)}}
  foreach($size in @(@(1100,800),@(720,440))){
   [PinViewport]::SetWindowPos($settings,[IntPtr]::Zero,40,40,$size[0],$size[1],0x4014)|Out-Null
   foreach($page in @(100,101,102)){
    Command-Guest $page;$name=$mode+'-'+$size[0]+'-page-'+$page
    $labels=if($page -eq 100){@(104,136)}elseif($page -eq 101){@(201,203,136)}else{@(136)}
    foreach($id in $labels){$h=[PinViewport]::GetDlgItem($settings,$id);$text=[PinRealKeys]::Text($settings,$id);$r=[PinViewport]::Bounds($h);$measured=[PinGuestAppearance]::TextWidth($h,$text);$report.text_metrics+=@{scene=$name;id=$id;text=$text;measured_width_px=$measured;available_width_px=$r.Right-$r.Left;overflow=$measured -gt ($r.Right-$r.Left)}}
    [PinViewport]::Message($settings,$process.Id,0x115,6);Check-Appearance ($name+'-top');Image-Appearance ($name+'-top')
    [PinViewport]::Message($settings,$process.Id,0x115,7);Check-Appearance ($name+'-bottom')
    if($size[0] -eq 720){Keyboard-Appearance $name}
   }
  }
  Focus-Fixture;Move-Fixture 220 190 300 220;[PinRealKeys]::Chord(0x78);Wait-Guest {(Error-Guest (Frame-Guest) $baseline) -le 2 -and (Status-Guest) -match '^已恢复|^已符合预设'} 'appearance real hotkey restore';[PinRealKeys]::AssertForeground()
  $report.restores+=@{mode=$mode;expected=$baseline;actual=(Frame-Guest);edge_error_px=(Error-Guest (Frame-Guest) $baseline)}
  Assert-Guest ((Get-FileHash -LiteralPath $configPath).Hash -eq $configHash) 'Appearance and keyboard navigation preserve configuration bytes'
 }
 Stop-GuestApp
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{
 if($guestAllowed){
  try{if($savedTheme -and (Test-Path -LiteralPath $savedTheme)){Start-Process -FilePath $savedTheme|Out-Null;Wait-Theme $savedColors[0] $savedColors[1]};if($savedContrast){[PinGuestAppearance]::ApplyContrast($savedContrast)};if($savedMetrics){[PinGuestAppearance]::ApplyMetrics($savedMetrics)};$report['restored_metrics']=[PinGuestAppearance]::ReadMetrics();$report['restored_contrast']=[PinGuestAppearance]::ReadContrast();$report['restored_colors']=@([PinGuestAppearance]::GetSysColor(5),[PinGuestAppearance]::GetSysColor(8),[PinGuestAppearance]::GetSysColor(15),[PinGuestAppearance]::GetSysColor(18));$report['guest_settings_restored']=($report.restored_metrics|ConvertTo-Json -Depth 6 -Compress) -ceq ($savedMetrics|ConvertTo-Json -Depth 6 -Compress) -and $report.restored_contrast.Flags -eq $savedContrast.Flags -and ($report.restored_colors -join ',') -eq ($savedColors -join ',');$report['contrast_scheme_name_restored']=$report.restored_contrast.Scheme -ceq $savedContrast.Scheme}catch{$report.errors+=('Guest appearance restoration: '+$_.Exception.Message)}
  try{if($process -and -not $process.HasExited){Stop-GuestApp}}catch{$report.errors+=('App cleanup: '+$_.Exception.Message)}
  try{if($fixture -ne [IntPtr]::Zero){[PinRealKeys]::StopFixture()}}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)}
 }
 if($oldDpi -ne [IntPtr]::Zero){[PinApplication]::SetThreadDpiAwarenessContext($oldDpi)|Out-Null}
 $report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
 $report['functional_checks_passed']=$report.errors.Count -eq 0 -and $report.restores.Count -eq 3 -and $report.normal_exits.Count -eq 1 -and $report.guest_settings_restored -and $report.startup_registry_unchanged
 $report['readability_passed']=$report.text_metrics.Count -eq 36 -and @($report.text_metrics|Where-Object overflow).Count -eq 0;$report.passed=$report.functional_checks_passed -and $report.readability_passed;if(-not $report.readability_passed){$report.errors+='Readability gate: one-row label or Undo text is wider than its actual control'}
 $report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $OutputDir 'guest-report.json') -Encoding utf8
}
if(-not $report.passed){exit 1}
