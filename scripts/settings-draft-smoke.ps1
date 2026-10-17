#Requires -Version 7.0
param(
    [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/settings-drafts'),
    [string]$UiaProbePath=(Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe')
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName;$UiaProbePath=(Get-Item -LiteralPath $UiaProbePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('draft-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'config')).FullName;$configPath=Join-Path $configDir 'config.json'
$helper=Join-Path $PSScriptRoot 'support/real-keys.cs';Add-Type -Path $helper
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PinSettingsForm {
 [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")]private static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]private static extern int GetClassNameW(IntPtr h,StringBuilder text,int count);
 [DllImport("user32.dll")]private static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out UIntPtr result);
 private static UIntPtr Query(IntPtr h,uint pid,int id,uint message,int value){uint owner;GetWindowThreadProcessId(h,out owner);var name=new StringBuilder(128);GetClassNameW(h,name,name.Capacity);if(owner!=pid||name.ToString()!="ScreenPin.Settings")throw new InvalidOperationException("Settings form ownership changed");UIntPtr result;if(SendMessageTimeoutW(GetDlgItem(h,id),message,new IntPtr(value),IntPtr.Zero,0x23,100,out result)==IntPtr.Zero)throw new InvalidOperationException("Settings form query timed out");return result;}
 public static bool Checked(IntPtr h,uint pid){return Query(h,pid,206,0xf0,0).ToUInt64()==1;}
 public static void Check(IntPtr h,uint pid,bool value){Query(h,pid,206,0xf1,value?1:0);}
 public static void Profile(IntPtr h,uint pid,int index){if(Query(h,pid,105,0x14e,index).ToUInt64()!=(ulong)index)throw new InvalidOperationException("Profile selection failed");}
}
'@
$report=[ordered]@{started_utc=[DateTime]::UtcNow.ToString('o');exe_path=$ExePath;exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;helper_sha256=(Get-FileHash -LiteralPath $helper).Hash;config_dir=$configDir;checks=@();snapshots=@();cycles=@();normal_exits=@();errors=@();passed=$false;scope='Owned GUI messages stage raw settings/check state and select views; real foreground hotkeys prove the currently effective mappings. Offline profile is private seeded JSON, not physical topology.';limitations=@('One local desktop/current DPI; settings entry is by native GUI messages, not keyboard navigation.','The autostart draft is checked only while uncommitted and cleared before any Save; no actual Run registration is changed.','Real I/O sharing failure affects only this private config. Recovery fixture is prepared while its instance is stopped.')}
$process=$null;$hostWindow=[IntPtr]::Zero;$settings=[IntPtr]::Zero;$lock=$null;$cycle=0
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-SD($value,[string]$message){if(-not $value){throw $message};$report.checks+=$message}
function Read-SD {Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json}
function Hash-SD {(Get-FileHash -LiteralPath $configPath).Hash}
function Status-SD {[PinRealKeys]::Text($settings,138)}
function Field-SD([int]$id){[PinRealKeys]::Text($settings,$id)}
function Wait-SD([scriptblock]$test,[string]$description){$watch=[Diagnostics.Stopwatch]::StartNew();do{[PinRealKeys]::AssertForeground();try{if(& $test){return}}catch{if($_.Exception.Message -notmatch 'Timed out reading own app result'){throw}};Start-Sleep -Milliseconds 10}while($watch.ElapsedMilliseconds -lt 6000);throw ('Timeout: '+$description+'; '+(Status-SD))}
function Confirm-SD {$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id);if(-not $owner -or $owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains('"'+$configDir+'"')){throw 'Private process identity changed'}}
function Command-SD([int]$id){Confirm-SD;[PinRealKeys]::Command($settings,$process.Id,$id);Wait-SD {(Status-SD) -notmatch '^正在处理'} ('owned GUI command '+$id)}
function Start-SD {
    Assert-SD ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) 'No existing Screen Pin instance'
    $script:hostWindow=[IntPtr]::Zero;$script:settings=[IntPtr]::Zero;$script:process=Start-Process -FilePath $ExePath -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    do{$hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);$windows=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id);if($hosts.Count -eq 1){$script:hostWindow=$hosts[0]};if($windows.Count -eq 1){$script:settings=$windows[0]};if($hostWindow -ne [IntPtr]::Zero -and $settings -ne [IntPtr]::Zero){try{if((Status-SD) -notin @('','正在处理…')){break}}catch{}};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline)
    Confirm-SD
}
function Stop-SD {if($null -eq $process){return};$process.Refresh();if($process.HasExited){return};Confirm-SD;if($hostWindow -eq [IntPtr]::Zero){$hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);if($hosts.Count -eq 1){$script:hostWindow=$hosts[0]}};[uint32]$owner=0;[PinRealKeys]::GetWindowThreadProcessId($hostWindow,[ref]$owner)|Out-Null;if($owner -eq $process.Id){[PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null};if(-not $process.WaitForExit(8000)){Confirm-SD;$process.Kill();$process.WaitForExit();throw 'Verified own app required forced cleanup'};Assert-SD ($process.ExitCode -eq 0) 'Owned test instance exited normally';$report.normal_exits+=@{pid=$process.Id;exit_code=$process.ExitCode};$script:process=$null}
function Draft-SD([string]$restore='Ctrl+Alt+F7',[string]$remember='Ctrl+Alt+F8',[bool]$autostart=$false){[PinRealKeys]::ControlText($settings,$process.Id,202,$restore);[PinRealKeys]::ControlText($settings,$process.Id,204,$remember);[PinSettingsForm]::Check($settings,$process.Id,$autostart)}
function Check-DraftSD([bool]$autostart=$false){return (Field-SD 202) -ceq 'Ctrl+Alt+F7' -and (Field-SD 204) -ceq 'Ctrl+Alt+F8' -and [PinSettingsForm]::Checked($settings,$process.Id) -eq $autostart}
function Registered-SD([int]$restore,[int]$remember){$text=Field-SD 208;Assert-SD ($text -match ('恢复 Ctrl\+Alt\+F'+$restore+'：已注册') -and $text -match ('记住 Ctrl\+Alt\+F'+$remember+'：已注册')) ('Effective registrations remain F'+$restore+'/F'+$remember)}
function Free-SD([int]$key){Assert-SD ([PinRealKeys]::Block($key)) ('Unassigned key F'+($key-0x6f)+' is available');[PinRealKeys]::Unblock($key)}
function Move-SD([int]$x,[int]$y){$expected=[PinRealKeys]::Move($x,$y,660,430);Wait-SD {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$expected) -le 2} 'owned displacement';return [PinRealKeys]::Frame()}
function Restore-SD($frame,[int]$key=0x78){$hash=Hash-SD;[PinRealKeys]::Chord($key);Wait-SD {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$frame) -le 2 -and (Status-SD) -match '^已恢复|^已符合预设'} 'real restore completion';Assert-SD ((Hash-SD) -eq $hash) 'Real restore does not write config'}
function Cycle-SD([int]$restore,[int]$remember,[string]$name){$script:cycle++;$target=Move-SD (140+$cycle*40) (160+$cycle*25);$revision=(Read-SD).revision;[PinRealKeys]::Chord($remember);Wait-SD {(Read-SD).revision -gt $revision -and (Status-SD) -match '^已记住'} 'actual remember mapping';$null=Move-SD 900 600;Restore-SD $target $restore;$report.cycles+=@{case=$name;restore_vk=$restore;remember_vk=$remember;edge_error_px=[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$target)}}
function Snapshot-SD([string]$name){$report.snapshots+=@{case=$name;restore=Field-SD 202;remember=Field-SD 204;autostart=[PinSettingsForm]::Checked($settings,$process.Id);registered=Field-SD 208;configuration=Read-SD;hash=Hash-SD;status=Status-SD}}
try{
    Assert-SD ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) 'Only isolated instances are used'
    $fixture=[PinRealKeys]::StartFixture()
    if([PinRealKeys]::GetForegroundWindow() -ne $fixture){$input=Join-Path $runDir 'focus-input.json';$output=Join-Path $runDir 'focus-output.json';ConvertTo-Json -InputObject @(@{handle=$fixture.ToInt64();id=0;page='activation'})|Set-Content -LiteralPath $input -Encoding utf8;& $UiaProbePath $input $output $PID --focus;if($LASTEXITCODE -ne 0){throw 'Owned public UIA focus failed'}}
    [PinRealKeys]::AssertForeground();Free-SD 0x76;Free-SD 0x77
    Start-SD;$revision=(Read-SD).revision;[PinRealKeys]::Chord(0x79);Wait-SD {(Read-SD).revision -gt $revision -and (Status-SD) -match '^已记住'} 'seed real capture';$frame=[PinRealKeys]::Frame();$seed=Read-SD;Stop-SD
    $seed.displays+=@(@{id='settings-draft-offline-display';name='Offline draft fixture';fingerprints=@('model:ffff:0000')});$seed.profiles+=@(@{id='settings-draft-offline-profile';name='Offline draft fixture';display_ids=@('settings-draft-offline-display');applications=@()})
    $text=$seed|ConvertTo-Json -Depth 24;[IO.File]::WriteAllText($configPath,$text);[IO.File]::WriteAllText((Join-Path $configDir 'config.backup.json'),$text)
    Start-SD;Command-SD 101;Draft-SD 'Ctrl+Alt+F7' 'Ctrl+Alt+F8' $true;Snapshot-SD 'draft-before-restore';$hash=Hash-SD
    $null=Move-SD 600 400;Restore-SD $frame;Snapshot-SD 'draft-after-restore'
    Assert-SD (Check-DraftSD $true) 'Real F9 preserves raw settings and unchecked-versus-checked autostart draft'
    Assert-SD (-not (Read-SD).settings.autostart -and (Read-SD).settings.restore.key -eq 0x78 -and (Hash-SD) -eq $hash) 'Draft checkbox and hotkeys do not commit themselves'
    Registered-SD 9 10;Free-SD 0x76;Free-SD 0x77
    [PinRealKeys]::Chord(0x79);Wait-SD {(Status-SD) -match '^位置未变化'} 'actual no-op remember'
    Assert-SD (Check-DraftSD $true) 'No-op F10 preserves the settings draft';Command-SD 109
    Assert-SD ((Check-DraftSD $true) -and (Hash-SD) -eq $hash) 'Explicit refresh keeps uncommitted settings without writing'
    Command-SD 100;[PinSettingsForm]::Profile($settings,$process.Id,1);[PinRealKeys]::Command($settings,$process.Id,65536+105)
    Assert-SD (Check-DraftSD $true) 'Viewing an offline profile preserves the global settings draft'
    [PinSettingsForm]::Profile($settings,$process.Id,0);[PinRealKeys]::Command($settings,$process.Id,65536+105);Command-SD 101
    Assert-SD ((Check-DraftSD $true) -and (Hash-SD) -eq $hash) 'Returning to the active profile keeps the same global draft'
    $frame=Move-SD 620 420;$revision=(Read-SD).revision;[PinRealKeys]::Chord(0x79);Wait-SD {(Read-SD).revision -gt $revision -and (Status-SD) -match '^已记住'} 'unrelated preset update'
    Assert-SD ((Check-DraftSD $true) -and -not (Read-SD).settings.autostart) 'Preset changes preserve the draft without enabling real autostart';Snapshot-SD 'after-unrelated-preset-update'
    Draft-SD 'Ctrl+Alt+F7' 'Ctrl+Alt+F7';$hash=Hash-SD;Command-SD 207
    Assert-SD ((Status-SD) -match '同一热键' -and (Hash-SD) -eq $hash) 'Duplicate draft keys are refused before any commit';Registered-SD 9 10
    Draft-SD;Assert-SD ([PinRealKeys]::Block(0x77)) 'Fixture occupies the proposed second key'
    try{Command-SD 207;Assert-SD ((Status-SD) -match 'F8 注册失败' -and (Check-DraftSD) -and (Hash-SD) -eq $hash) 'Registration failure retains raw input and old config';Free-SD 0x76;Registered-SD 9 10}finally{[PinRealKeys]::Unblock(0x77)}
    $lock=[IO.File]::Open($configPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{Command-SD 207;Assert-SD ((Status-SD) -match '无法替换配置' -and (Check-DraftSD) -and (Hash-SD) -eq $hash) 'Accepted save failure keeps retryable draft and exact primary bytes';Registered-SD 9 10;Free-SD 0x76;Free-SD 0x77;Snapshot-SD 'failed-save'}finally{$lock.Dispose();$lock=$null}
    $null=Move-SD 900 600;Restore-SD $frame
    Assert-SD (Check-DraftSD) 'Old actual hotkey still works after failure without erasing the failed draft'
    $null=Move-SD 900 600;$hash=Hash-SD;[PinRealKeys]::Schedule(0x8044,1200);Wait-SD {-not [PinRealKeys]::Responsive($fixture)} 'owned pause';[PinRealKeys]::Chord(0x78)
    Wait-SD {-not [PinRealKeys]::Enabled($settings,$process.Id,109) -and -not [PinRealKeys]::Enabled($settings,$process.Id,202) -and -not [PinRealKeys]::Enabled($settings,$process.Id,204) -and -not [PinRealKeys]::Enabled($settings,$process.Id,206) -and -not [PinRealKeys]::Enabled($settings,$process.Id,207)} 'all settings controls disabled during busy operation'
    [PinRealKeys]::Command($settings,$process.Id,207);Wait-SD {(Status-SD) -match '^正在处理上一项'} 'busy settings save refused'
    Wait-SD {[PinRealKeys]::Enabled($settings,$process.Id,207) -and (Status-SD) -match '^暂无法确认'} 'operation finishes unconfirmed'
    Assert-SD ((Check-DraftSD) -and (Hash-SD) -eq $hash) 'Busy failure preserves the draft without executing the rejected settings save'
    Wait-SD {[PinRealKeys]::Responsive($fixture) -and [PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$frame) -le 2} 'late original placement'
    Assert-SD ((Hash-SD) -eq $hash) 'Busy settings save was not queued';Registered-SD 9 10;Free-SD 0x76;Free-SD 0x77
    Command-SD 207;Assert-SD ((Status-SD) -eq '设置已保存' -and (Read-SD).settings.restore.key -eq 0x76 -and (Read-SD).settings.remember.key -eq 0x77 -and -not (Read-SD).settings.autostart) 'A new explicit retry commits exactly the requested hotkeys with autostart off';Registered-SD 7 8
    Free-SD 0x78;Free-SD 0x79;Cycle-SD 0x76 0x77 'committed draft';Snapshot-SD 'committed';$hash=Hash-SD;Stop-SD;Free-SD 0x76;Free-SD 0x77
    Start-SD;Assert-SD ((Check-DraftSD) -and (Hash-SD) -eq $hash) 'Restart reloads committed settings rather than a transient draft';Registered-SD 7 8;Cycle-SD 0x76 0x77 'restart';$backup=Read-SD;Stop-SD
    $backup.settings.restore.key=0x7a;$backup.settings.remember.key=0x7b;[IO.File]::WriteAllText((Join-Path $configDir 'config.backup.json'),($backup|ConvertTo-Json -Depth 24));[IO.File]::WriteAllText($configPath,'{ "schema_version": 1, "broken": ')
    Start-SD;Command-SD 101
    Assert-SD (-not [PinRealKeys]::Enabled($settings,$process.Id,202) -and -not [PinRealKeys]::Enabled($settings,$process.Id,204) -and -not [PinRealKeys]::Enabled($settings,$process.Id,206) -and -not [PinRealKeys]::Enabled($settings,$process.Id,207)) 'Protection mode disables editable settings fields and Save'
    Command-SD 211
    Assert-SD ((Field-SD 202) -eq 'Ctrl+Alt+F11' -and (Field-SD 204) -eq 'Ctrl+Alt+F12' -and -not [PinSettingsForm]::Checked($settings,$process.Id)) 'Recovery replaces the form with authoritative recovered settings';Registered-SD 11 12;Cycle-SD 0x7a 0x7b 'recovery';Snapshot-SD 'recovered';Stop-SD;Free-SD 0x7a;Free-SD 0x7b
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{if($lock){$lock.Dispose()};try{Stop-SD}catch{$report.errors+=('Cleanup: '+$_.Exception.Message)};try{[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)};$report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null);if(-not $report.startup_registry_unchanged){$report.errors+='Startup registration changed'};$report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report.passed=$report.errors.Count -eq 0 -and $report.normal_exits.Count -eq 4 -and $report.cycles.Count -eq 3;$report|ConvertTo-Json -Depth 24|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8;Write-Host ('Settings draft report: '+(Join-Path $runDir 'report.json'))}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
