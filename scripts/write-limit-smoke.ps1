#Requires -Version 7.0
param(
    [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/write-limits'),
    [string]$UiaProbePath=(Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe')
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName;$UiaProbePath=(Get-Item -LiteralPath $UiaProbePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('write-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'config')).FullName;$configPath=Join-Path $configDir 'config.json';$backupPath=Join-Path $configDir 'config.backup.json'
$helper=Join-Path $PSScriptRoot 'support/real-keys.cs';Add-Type -Path $helper
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PinWriteLimitSelect {
 [DllImport("user32.dll")]private static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")]private static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll",EntryPoint="SendMessageTimeoutW",CharSet=CharSet.Unicode)]private static extern IntPtr SendText(IntPtr h,uint m,IntPtr w,StringBuilder l,uint flags,uint timeout,out UIntPtr result);
 public static void SelectUnused(IntPtr settings,uint pid,string name){
  uint owner;GetWindowThreadProcessId(settings,out owner);if(owner!=pid)throw new InvalidOperationException("Preset selection owner changed");
  var list=GetDlgItem(settings,117);UIntPtr result;
  if(SendMessageTimeoutW(list,0x18b,IntPtr.Zero,IntPtr.Zero,0x23,100,out result)==IntPtr.Zero||result.ToUInt64()!=2)throw new InvalidOperationException("Expected exactly two private preset rows");
  var text=new StringBuilder(32768);if(SendText(list,0x189,new IntPtr(1),text,0x23,100,out result)==IntPtr.Zero||!text.ToString().Contains(name))throw new InvalidOperationException("The unused preset row was not verified");
  if(SendMessageTimeoutW(list,0x186,new IntPtr(1),IntPtr.Zero,0x23,100,out result)==IntPtr.Zero||result.ToUInt64()!=1)throw new InvalidOperationException("Unused preset selection failed");
 }
}
'@
$report=[ordered]@{started_utc=[DateTime]::UtcNow.ToString('o');exe_path=$ExePath;exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;helper_sha256=(Get-FileHash -LiteralPath $helper).Hash;config_dir=$configDir;checks=@();restores=@();snapshots=@();normal_exits=@();errors=@();passed=$false;scope='Private supported compact config near 8 MiB; real F10/F9 plus owned GUI rule creation, Undo and deletion. Synthetic inventory bytes and unused preset are seeded only while the instance is stopped; no physical topology claim.';limitations=@('Single local display/current DPI; owned GUI messages do not prove keyboard navigation.','No user app/config, actual Run registration or physical monitor settings are changed.')}
$process=$null;$hostWindow=[IntPtr]::Zero;$settings=[IntPtr]::Zero;$limit=8*1024*1024
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-WL($value,[string]$message){if(-not $value){throw $message};$report.checks+=$message}
function Read-WL {[PinRealKeys]::ReadConfig($configPath)|ConvertFrom-Json}
function Hash-WL([string]$path=$configPath){(Get-FileHash -LiteralPath $path).Hash}
function Status-WL {[PinRealKeys]::Text($settings,138)}
function Wait-WL([scriptblock]$condition,[string]$description){$watch=[Diagnostics.Stopwatch]::StartNew();do{[PinRealKeys]::AssertForeground();try{if(& $condition){return}}catch{if($_.Exception.Message -notmatch 'Timed out reading own app result'){throw}};Start-Sleep -Milliseconds 10}while($watch.ElapsedMilliseconds -lt 8000);throw ('Timeout: '+$description)}
function Confirm-WL {$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id);if(-not $owner -or $owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains('"'+$configDir+'"')){throw 'Private app identity changed'}}
function Command-WL([int]$id){Confirm-WL;[PinRealKeys]::Command($settings,$process.Id,$id);Wait-WL {(Status-WL) -notmatch '^正在处理'} ('owned GUI command '+$id)}
function Start-WL {
 Assert-WL ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) 'No existing Screen Pin instance'
 $script:hostWindow=[IntPtr]::Zero;$script:settings=[IntPtr]::Zero;$script:process=Start-Process -FilePath $ExePath -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
 Wait-WL {$h=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);$w=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id);if($h.Count -eq 1){$script:hostWindow=$h[0]};if($w.Count -eq 1){$script:settings=$w[0]};return $hostWindow -ne [IntPtr]::Zero -and $settings -ne [IntPtr]::Zero -and (Status-WL) -notin @('','正在处理…')} 'startup'
 Confirm-WL;Assert-WL ([PinRealKeys]::Enabled($settings,$process.Id,207)) 'Supported config starts in writable mode'
}
function Stop-WL {if($null -eq $process){return};$process.Refresh();if($process.HasExited){return};Confirm-WL;$h=@([PinRealKeys]::FindClass('ScreenPin.Host',$process.Id));if($h.Count -eq 1){[PinRealKeys]::PostMessageW($h[0],0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null};if(-not $process.WaitForExit(8000)){Confirm-WL;$process.Kill();$process.WaitForExit();throw 'Verified own app required forced cleanup'};Assert-WL ($process.ExitCode -eq 0) 'Owned instance exits normally';$report.normal_exits+=@{pid=$process.Id;exit_code=$process.ExitCode};$script:process=$null}
function Move-WL([int]$x,[int]$y){$frame=[PinRealKeys]::Move($x,$y,660,430);Wait-WL {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$frame) -le 2} 'fixture placement';return [PinRealKeys]::Frame()}
function Remember-WL {$revision=(Read-WL).revision;[PinRealKeys]::Chord(0x79);Wait-WL {(Status-WL) -match '^已记住' -and (Read-WL).revision -gt $revision} 'actual F10 persistence'}
function Restore-WL($frame,[string]$name){$hash=Hash-WL;$null=Move-WL 900 600;[PinRealKeys]::Chord(0x78);Wait-WL {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$frame) -le 2 -and (Status-WL) -match '^已恢复|^已符合预设'} 'actual F9 restore';Assert-WL ((Hash-WL) -eq $hash) ($name+': F9 does not write config');$report.restores+=@{case=$name;edge_error_px=[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$frame);foreground_preserved=$true;feedback=Status-WL}}
function Snapshot-WL([string]$name){$process.Refresh();$report.snapshots+=@{case=$name;bytes=(Get-Item -LiteralPath $configPath).Length;primary_hash=Hash-WL;backup_hash=Hash-WL $backupPath;status=Status-WL;private_bytes=$process.PrivateMemorySize64}}
try{
 Assert-WL ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) 'Only isolated instances are used'
 $fixture=[PinRealKeys]::StartFixture()
 if([PinRealKeys]::GetForegroundWindow() -ne $fixture){$input=Join-Path $runDir 'focus-input.json';$output=Join-Path $runDir 'focus-output.json';ConvertTo-Json -InputObject @(@{handle=$fixture.ToInt64();id=0;page='activation'})|Set-Content -LiteralPath $input -Encoding utf8;& $UiaProbePath $input $output $PID --focus;if($LASTEXITCODE -ne 0){throw 'Owned initial focus failed'}}
 [PinRealKeys]::AssertForeground();Start-WL;$original=Move-WL 140 160;Remember-WL;$seed=Read-WL;Stop-WL
 $fillerId='write-limit-inventory-'+[Guid]::NewGuid().ToString('N');$seed.displays+=@(@{id=$fillerId;name='Private size fixture';fingerprints=@('opaque:write-limit:')})
 $unusedName='Unused write-limit fixture '+[Guid]::NewGuid().ToString('N');$unusedId='exe:private-unused-write-limit-'+[Guid]::NewGuid().ToString('N')
 $unused=($seed.profiles[0].applications[0].default|ConvertTo-Json -Depth 12)|ConvertFrom-Json;$unused.id='unused-preset-'+[Guid]::NewGuid().ToString('N')
 $seed.profiles[0].applications+=@(@{app_id=$unusedId;app_name=$unusedName;default=$unused;rules=@()})
 $text=$seed|ConvertTo-Json -Depth 24 -Compress;$padding=$limit-128-[Text.Encoding]::UTF8.GetByteCount($text)
 if($padding -le 0){throw 'Unexpected private seed size'};$seed.displays[-1].fingerprints[0]+='x'*$padding
 $text=$seed|ConvertTo-Json -Depth 24 -Compress;[IO.File]::WriteAllText($configPath,$text);[IO.File]::WriteAllText($backupPath,$text)
 Assert-WL ((Get-Item -LiteralPath $configPath).Length -eq $limit-128) 'Private compact fixture is exactly 128 bytes below the read limit'
 Start-WL;Command-WL 109;[PinRealKeys]::SelectWindow($settings,$process.Id,'Screen Pin isolated real hotkey fixture')
 Assert-WL ((Get-Item -LiteralPath $configPath).Length -ge $limit-256) 'Startup retains the near-limit inventory fixture'
 $priorHash=Hash-WL;$updated=Move-WL 400 300;Remember-WL
 Assert-WL ((Get-Item -LiteralPath $configPath).Length -le $limit) 'Successful actual F10 writes a config that remains within the read limit'
 Assert-WL ((Hash-WL $backupPath) -eq $priorHash -and (Get-Item -LiteralPath $backupPath).Length -le $limit) 'Successful F10 keeps the exact supported previous primary as backup'
 Assert-WL ([PinRealKeys]::Enabled($settings,$process.Id,136)) 'Successful F10 creates an available Undo'
 Snapshot-WL 'supported-update';$saved=Read-WL;$mainHash=Hash-WL;$backupHash=Hash-WL $backupPath
 [PinRealKeys]::ControlText($settings,$process.Id,114,'isolated');Command-WL 115
 Assert-WL ((Status-WL) -match '配置超过 8 MiB.*未保存') 'Oversized GUI rule creation explicitly refuses persistence'
 Assert-WL ((Hash-WL) -eq $mainHash -and (Hash-WL $backupPath) -eq $backupHash) 'Rejected rule leaves primary and backup bytes unchanged'
 Assert-WL ((Read-WL).profiles[0].applications[0].rules.Count -eq 0 -and [PinRealKeys]::Enabled($settings,$process.Id,136) -and [PinRealKeys]::Enabled($settings,$process.Id,207)) 'Rejected rule publishes no rule and retains Undo and writable settings'
 Snapshot-WL 'rejected-rule';Restore-WL $updated 'after rejection'
 $before=[PinRealKeys]::Frame();Command-WL 136
 Assert-WL ((Status-WL) -match '^已撤销' -and [PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$before) -eq 0) 'Undo after the rejected rule restores the prior successful update without moving the window'
 Restore-WL $original 'after retained Undo'
 $beforeDeleteBytes=(Get-Item -LiteralPath $configPath).Length
 [PinWriteLimitSelect]::SelectUnused($settings,$process.Id,$unusedName);Command-WL (65536+117);Command-WL 133
 $unusedNow=@((Read-WL).profiles[0].applications|Where-Object app_id -eq $unusedId)
 Assert-WL (($unusedNow.Count -eq 0 -or ($null -eq $unusedNow[0].default -and $unusedNow[0].rules.Count -eq 0)) -and (Get-Item -LiteralPath $configPath).Length -lt $beforeDeleteBytes) 'Deleting the verified unused preset frees config capacity'
 Command-WL 109;[PinRealKeys]::SelectWindow($settings,$process.Id,'Screen Pin isolated real hotkey fixture');[PinRealKeys]::ControlText($settings,$process.Id,114,'isolated')
 $ruleFrame=Move-WL 520 350;Command-WL 115
 Assert-WL ((Status-WL) -match '^已创建标题规则' -and (Read-WL).profiles[0].applications[0].rules.Count -eq 1 -and (Get-Item -LiteralPath $configPath).Length -le $limit) 'Explicit retry succeeds after capacity is freed and keeps the persisted file supported'
 Restore-WL $ruleFrame 'retried title rule';Command-WL 136
 Assert-WL ((Read-WL).profiles[0].applications[0].rules.Count -eq 0) 'Undo removes only the successful retried rule'
 Restore-WL $original 'default after rule Undo';Snapshot-WL 'retry-and-undo';$restartHash=Hash-WL;Stop-WL
 Start-WL;Assert-WL ((Hash-WL) -eq $restartHash) 'Restart reads the near-limit committed file without rewriting or protection'
 Restore-WL $original 'restart';Stop-WL
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{try{Stop-WL}catch{$report.errors+=('Cleanup: '+$_.Exception.Message)};try{[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)};$report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null);if(-not $report.startup_registry_unchanged){$report.errors+='Run registration changed'};$report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report.passed=$report.errors.Count -eq 0 -and $report.normal_exits.Count -eq 3 -and $report.restores.Count -eq 5;$report|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8;Write-Host ('Write-limit report: '+(Join-Path $runDir 'report.json'))}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
