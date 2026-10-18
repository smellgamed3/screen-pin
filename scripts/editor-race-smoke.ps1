#Requires -Version 7.0
param(
    [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/editor-races'),
    [string]$UiaProbePath=(Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe')
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName;$UiaProbePath=(Get-Item -LiteralPath $UiaProbePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('editor-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'config')).FullName;$configPath=Join-Path $configDir 'config.json'
$helper=Join-Path $PSScriptRoot 'support/real-keys.cs';Add-Type -Path $helper
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PinEditorSelect {
 [DllImport("user32.dll")]private static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")]private static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out UIntPtr result);
 public static void Select(IntPtr settings,uint pid,int index){uint owner;GetWindowThreadProcessId(settings,out owner);if(owner!=pid)throw new InvalidOperationException("Editor selection ownership changed");UIntPtr result;if(SendMessageTimeoutW(GetDlgItem(settings,117),0x186,new IntPtr(index),IntPtr.Zero,0x23,100,out result)==IntPtr.Zero||result.ToUInt64()!=(ulong)index)throw new InvalidOperationException("Preset selection failed");}
}
'@
$report=[ordered]@{started_utc=[DateTime]::UtcNow.ToString('o');exe_path=$ExePath;exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;helper_sha256=(Get-FileHash -LiteralPath $helper).Hash;config_dir=$configDir;checks=@();snapshots=@();errors=@();normal_exit=$false;passed=$false;scope='Private form drafts are prepared/read with owned GUI messages, then real foreground F9/F10 exercise refresh/update interleavings. A private fixture pause proves busy overlap; no WM_HOTKEY injection.';limitations=@('One ordinary standard fixture at current DPI; not physical hotplug, OS numeric HWND reuse or all real application timing.','Form text/selection and Save/Undo/Refresh use GUI messages, not keyboard navigation.','No manual external JSON editing or process-crash/disk interruption simulation.')}
$process=$null;$hostWindow=[IntPtr]::Zero;$settings=[IntPtr]::Zero
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-ER($condition,[string]$message){if(-not $condition){throw $message};$report.checks+=$message}
function Read-ER {[PinRealKeys]::ReadConfig($configPath)|ConvertFrom-Json}
function Hash-ER {(Get-FileHash -LiteralPath $configPath).Hash}
function Status-ER {[PinRealKeys]::Text($settings,138)}
function Text-ER([int]$id){[PinRealKeys]::Text($settings,$id)}
function Copy-ER($value){return $value|ConvertTo-Json -Depth 20|ConvertFrom-Json}
function Wait-ER([scriptblock]$condition,[string]$description){$watch=[Diagnostics.Stopwatch]::StartNew();do{[PinRealKeys]::AssertForeground();try{if(& $condition){return}}catch{if($_.Exception.Message -notmatch 'Timed out reading own app result'){throw}};Start-Sleep -Milliseconds 5}while($watch.ElapsedMilliseconds -lt 6000);throw ('Timeout: '+$description+'; '+(Status-ER))}
function Confirm-ER {$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id);if(-not $owner -or $owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains('"'+$configDir+'"')){throw 'Private test process identity changed'}}
function Command-ER([int]$id){Confirm-ER;[PinRealKeys]::Command($settings,$process.Id,$id);Wait-ER {(Status-ER) -notmatch '^正在处理'} ('GUI command '+$id)}
function Select-ER([int]$index){Confirm-ER;[PinEditorSelect]::Select($settings,$process.Id,$index);[PinRealKeys]::Command($settings,$process.Id,65536+117)}
function Draft-ER([string]$x,[string]$keyword=''){[PinRealKeys]::ControlText($settings,$process.Id,122,$x);if($keyword){[PinRealKeys]::ControlText($settings,$process.Id,131,$keyword)}}
function Move-ER([int]$x,[int]$y){$expected=[PinRealKeys]::Move($x,$y,660,430);Wait-ER {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$expected) -le 2} 'fixture displacement';return [PinRealKeys]::Frame()}
function Remember-ER {$revision=(Read-ER).revision;[PinRealKeys]::Chord(0x79);Wait-ER {(Read-ER).revision -gt $revision -and (Status-ER) -match '^已记住'} 'real F10 persistent update'}
function Restore-ER($frame){$hash=Hash-ER;[PinRealKeys]::Chord(0x78);Wait-ER {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$frame) -le 2 -and (Status-ER) -match '^已恢复|^已符合预设'} 'real F9 restore';Assert-ER ((Hash-ER) -eq $hash) 'Real F9 preserves configuration hash'}
function Snapshot-ER([string]$name){$report.snapshots+=@{case=$name;configuration=Read-ER;hash=Hash-ER;x=Text-ER 122;keyword=Text-ER 131;status=Status-ER}}
function Stop-ER {if($null -eq $process){return};$process.Refresh();if($process.HasExited){return};Confirm-ER;if($hostWindow -eq [IntPtr]::Zero){$hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);if($hosts.Count -eq 1){$script:hostWindow=$hosts[0]}};[uint32]$owner=0;[PinRealKeys]::GetWindowThreadProcessId($hostWindow,[ref]$owner)|Out-Null;if($owner -eq $process.Id){[PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null};if(-not $process.WaitForExit(8000)){Confirm-ER;$process.Kill();$process.WaitForExit();throw 'Verified own app required forced cleanup'};$report.normal_exit=$process.ExitCode -eq 0;$script:process=$null}
try{
    Assert-ER ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) 'No existing Screen Pin instance'
    $process=Start-Process -FilePath $ExePath -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    do{$hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);$windows=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id);if($hosts.Count -eq 1){$hostWindow=$hosts[0]};if($windows.Count -eq 1){$settings=$windows[0]};if($hostWindow -ne [IntPtr]::Zero -and $settings -ne [IntPtr]::Zero){try{if((Status-ER) -notin @('','正在处理…')){break}}catch{}};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline)
    Confirm-ER;$fixture=[PinRealKeys]::StartFixture()
    if([PinRealKeys]::GetForegroundWindow() -ne $fixture){$inputPath=Join-Path $runDir 'focus-input.json';$outputPath=Join-Path $runDir 'focus-output.json';ConvertTo-Json -InputObject @(@{handle=$fixture.ToInt64();id=0;page='activation'})|Set-Content -LiteralPath $inputPath -Encoding utf8;& $UiaProbePath $inputPath $outputPath $PID --focus;if($LASTEXITCODE -ne 0){throw 'Owned initial focus failed'}}
    [PinRealKeys]::AssertForeground();Remember-ER;$defaultFrame=[PinRealKeys]::Frame()
    Command-ER 109;[PinRealKeys]::SelectWindow($settings,$process.Id,'Screen Pin isolated real hotkey fixture');[PinRealKeys]::ControlText($settings,$process.Id,114,'Special');Command-ER 115
    Select-ER 1;Draft-ER '12.5';Snapshot-ER 'draft-before-restore';$hash=Hash-ER
    $null=Move-ER 500 420;Restore-ER $defaultFrame
    Snapshot-ER 'draft-after-restore'
    Assert-ER ((Text-ER 122) -ceq '12.5') 'Read-only real F9 preserves the unsaved preset draft'
    [PinRealKeys]::Chord(0x79);Wait-ER {(Status-ER) -match '^位置未变化'} 'real no-op F10'
    Assert-ER ((Text-ER 122) -ceq '12.5' -and (Hash-ER) -eq $hash) 'No-op real F10 preserves the draft and configuration'

    $before=Read-ER;[PinRealKeys]::FixtureTitle('Screen Pin editor race Special');$ruleFrame=Move-ER 620 400;Remember-ER
    Assert-ER ((Text-ER 122) -ceq '12.5' -and ((Read-ER).profiles[0].applications[0].default|ConvertTo-Json -Depth 12 -Compress) -eq ($before.profiles[0].applications[0].default|ConvertTo-Json -Depth 12 -Compress)) 'Another preset update preserves the unsaved default draft and stored default'
    $updatedRule=Copy-ER (Read-ER).profiles[0].applications[0].rules[0];Command-ER 132
    Assert-ER ((Status-ER) -match '^已保存预设' -and (Read-ER).profiles[0].applications[0].default.placement.rect.x -eq 0.125 -and ((Read-ER).profiles[0].applications[0].rules[0]|ConvertTo-Json -Depth 12 -Compress) -eq ($updatedRule|ConvertTo-Json -Depth 12 -Compress)) 'Rebased draft saves only its own target and preserves the other hotkey update'
    Command-ER 136
    Assert-ER (((Read-ER).profiles[0].applications[0].default|Select-Object id,placement|ConvertTo-Json -Depth 12 -Compress) -eq ($before.profiles[0].applications[0].default|Select-Object id,placement|ConvertTo-Json -Depth 12 -Compress) -and ((Read-ER).profiles[0].applications[0].rules[0]|ConvertTo-Json -Depth 12 -Compress) -eq ($updatedRule|ConvertTo-Json -Depth 12 -Compress)) 'Undo reverses the draft save while retaining the independent hotkey change'
    Snapshot-ER 'unrelated-update-save-undo'

    Select-ER 0;Draft-ER '25' 'Special-draft';$ruleFrame=Move-ER 700 450;Remember-ER;Snapshot-ER 'conflicting-hotkey-update'
    Assert-ER ((Text-ER 122) -ceq '25' -and (Text-ER 131) -ceq 'Special-draft' -and (Status-ER) -match '未保存[\s\S]*刷新') 'Same-target hotkey update retains old draft and explicitly reports its conflict'
    $hash=Hash-ER;$backupHash=(Get-FileHash -LiteralPath (Join-Path $configDir 'config.backup.json')).Hash;Command-ER 132
    Assert-ER ((Status-ER) -match '已改变|已更新' -and (Status-ER) -notmatch '^已保存' -and (Hash-ER) -eq $hash -and (Get-FileHash -LiteralPath (Join-Path $configDir 'config.backup.json')).Hash -eq $backupHash -and (Text-ER 122) -ceq '25' -and (Text-ER 131) -ceq 'Special-draft') 'Stale form save is rejected without replacing current config, backup or draft'
    $null=Move-ER 900 600;Restore-ER $ruleFrame
    Assert-ER ((Text-ER 122) -ceq '25' -and (Text-ER 131) -ceq 'Special-draft') 'Read-only restore does not clear an already-conflicted draft'
    Command-ER 109
    Assert-ER ((Text-ER 131) -ceq 'Special' -and (Text-ER 122) -cne '25') 'Explicit Refresh discards the draft and reloads the current preset'
    Command-ER 132
    Assert-ER ((Status-ER) -match '^无变化' -and (Hash-ER) -eq $hash) 'The reloaded current form can be saved as a no-op'

    Draft-ER '33.3' 'Special-staged';$null=Move-ER 900 600;$hash=Hash-ER
    [PinRealKeys]::Schedule(0x8044,1200);Wait-ER {-not [PinRealKeys]::Responsive($fixture)} 'confirmed fixture pause'
    [PinRealKeys]::Chord(0x78);Wait-ER {-not [PinRealKeys]::Enabled($settings,$process.Id,109)} 'restore is busy'
    Wait-ER {-not [PinRealKeys]::Enabled($settings,$process.Id,132) -and -not [PinRealKeys]::Enabled($settings,$process.Id,122) -and -not [PinRealKeys]::Enabled($settings,$process.Id,131)} 'editing controls finish disabling'
    Assert-ER (-not [PinRealKeys]::Enabled($settings,$process.Id,132) -and -not [PinRealKeys]::Enabled($settings,$process.Id,122) -and -not [PinRealKeys]::Enabled($settings,$process.Id,131)) 'Busy restore disables actual preset editing and saving controls'
    [PinRealKeys]::Command($settings,$process.Id,132);Wait-ER {(Status-ER) -match '^正在处理上一项'} 'forced busy Save refusal'
    Wait-ER {[PinRealKeys]::Enabled($settings,$process.Id,109) -and (Status-ER) -notmatch '^正在处理'} 'restore releases slot'
    Assert-ER ((Text-ER 122) -ceq '33.3' -and (Text-ER 131) -ceq 'Special-staged' -and (Hash-ER) -eq $hash -and (Status-ER) -match '^暂无法确认') 'Unconfirmed restore retains the draft and does not execute the rejected Save'
    Wait-ER {[PinRealKeys]::Responsive($fixture) -and [PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$ruleFrame) -le 2} 'late placement resumes on the original target'
    Assert-ER ((Hash-ER) -eq $hash) 'Rejected busy save was not queued for later execution';Snapshot-ER 'busy-edit-rejection'
    Command-ER 132
    Assert-ER ((Status-ER) -match '^已保存预设' -and (Read-ER).profiles[0].applications[0].rules[0].keyword -ceq 'Special-staged' -and [Math]::Abs((Read-ER).profiles[0].applications[0].rules[0].preset.placement.rect.x-0.333) -lt 1e-12) 'A fresh explicit Save can commit the retained valid draft after the slot is free'
    Snapshot-ER 'final-explicit-save'
    Stop-ER
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{try{Stop-ER}catch{$report.errors+=('App cleanup: '+$_.Exception.Message)};try{[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)};$report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null);if(-not $report.startup_registry_unchanged){$report.errors+='Startup registration changed'};$report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report.passed=$report.errors.Count -eq 0 -and $report.normal_exit;$report|ConvertTo-Json -Depth 24|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8;Write-Host ('Editor race report: '+(Join-Path $runDir 'report.json'))}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
