#Requires -Version 7.0
param(
    [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/dialog-keyboard'),
    [string]$UiaProbePath=(Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe')
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName
$UiaProbePath=(Get-Item -LiteralPath $UiaProbePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('dialog-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$helpers=@((Join-Path $PSScriptRoot 'support/real-keys.cs'),(Join-Path $PSScriptRoot 'support/desktop-keyboard.cs'))
foreach($helper in $helpers){Add-Type -Path $helper}
$report=[ordered]@{started_utc=[DateTime]::UtcNow.ToString('o');exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;helpers=@($helpers|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}});checks=@();dialogs=@();cases=@();normal_exits=@();errors=@();passed=$false;scope='Native messages prepare isolated fixtures and selected windows. After public UIA focus of the first settings tab, Tab/Shift+Tab/Space/Enter/Escape are real SendInput; no confirmation button messages are used for test actions.';limitations=@('Current desktop/DPI; UIA names do not prove spoken Narrator output.','Ambiguous display identity is seeded in private JSON, not physical hotplug/multi-monitor validation.','Migration starts with a synthetic old application identity in private JSON; not an actual application upgrade.')}
$process=$null;$settings=[IntPtr]::Zero;$hostWindow=[IntPtr]::Zero;$dialog=[IntPtr]::Zero;$dialogTitle='';$configDir='';$configPath=''
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-DK($condition,[string]$message){if(-not $condition){throw $message};$report.checks+=$message}
function Wait-DK([scriptblock]$condition,[string]$description){$watch=[Diagnostics.Stopwatch]::StartNew();do{try{if(& $condition){return}}catch{if($_.Exception.Message -notmatch 'Timed out reading own app result'){throw};$report['transient_status_reads']=1+$report.transient_status_reads};Start-Sleep -Milliseconds 15}while($watch.ElapsedMilliseconds -lt 6000);throw ('Timeout: '+$description)}
function Read-DK {Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json}
function Hash-DK {(Get-FileHash -LiteralPath $configPath).Hash}
function Status-DK {[PinRealKeys]::Text($settings,138)}
function Copy-DK($value){return $value|ConvertTo-Json -Depth 24|ConvertFrom-Json}
function Confirm-DK {$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id);if(-not $owner -or $owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains('"'+$configDir+'"')){throw 'Owned app/config identity changed'}}
function Start-DK([string]$name,[string]$seed=''){
    Assert-DK ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) ($name+': no existing instance competes for hotkeys')
    $script:configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir $name)).FullName;$script:configPath=Join-Path $configDir 'config.json'
    if($seed){[IO.File]::WriteAllText($configPath,$seed)}
    $script:settings=[IntPtr]::Zero;$script:hostWindow=[IntPtr]::Zero
    $script:process=Start-Process -FilePath $ExePath -ArgumentList '--show','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    Wait-DK {$hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);$windows=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id);if($hosts.Count -eq 1){$script:hostWindow=$hosts[0]};if($windows.Count -eq 1){$script:settings=$windows[0]};if($hostWindow -ne [IntPtr]::Zero -and $settings -ne [IntPtr]::Zero){try{return (Status-DK) -notin @('','正在处理…')}catch{}};return $false} 'settings ready'
    Confirm-DK
}
function Stop-DK {
    if($null -eq $process){return};$process.Refresh();if($process.HasExited){return};Confirm-DK
    foreach($title in @('迁移应用预设','新环境','新建配置')){$h=[PinRealKeys]::FindDialog($process.Id,$title);if($h -ne [IntPtr]::Zero){[PinRealKeys]::DialogButton($h,$process.Id,$title,7)}}
    if($hostWindow -eq [IntPtr]::Zero){$hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);if($hosts.Count -eq 1){$script:hostWindow=$hosts[0]}}
    if([PinDesktopKeyboard]::Owner($hostWindow) -eq $process.Id){[PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null}
    if(-not $process.WaitForExit(8000)){Confirm-DK;$process.Kill();$process.WaitForExit();throw 'Verified own app required forced cleanup'}
    Assert-DK ($process.ExitCode -eq 0) 'Owned dialog test instance exited normally';$report.normal_exits+=@{pid=$process.Id;exit_code=$process.ExitCode};$script:process=$null
}
function Focus-DK {
    $inputPath=Join-Path $configDir 'focus-input.json';$outputPath=Join-Path $configDir 'focus-output.json'
    ConvertTo-Json -InputObject @(@{handle=[PinDesktopKeyboard]::GetDlgItem($settings,100).ToInt64();id=100;page='activation'})|Set-Content -LiteralPath $inputPath -Encoding utf8
    & $UiaProbePath $inputPath $outputPath $process.Id --focus
    if($LASTEXITCODE -ne 0){throw 'Settings initial public UIA focus failed'}
    Wait-DK {[PinDesktopKeyboard]::GetForegroundWindow() -eq $settings} 'owned settings foreground'
}
function Press-DK([int]$key,[int]$modifier=0){[PinDesktopKeyboard]::Press($settings,$process.Id,$key,$modifier);Start-Sleep -Milliseconds 35;[PinDesktopKeyboard]::AssertForeground($settings,$process.Id)}
function Tab-DK([int]$id){for($i=0;$i -lt 65;$i++){[PinDesktopKeyboard]::AssertForeground($settings,$process.Id);if([PinDesktopKeyboard]::FocusId($settings,$process.Id) -eq $id){return};Press-DK 9};throw ('Tab cannot reach '+$id)}
function Page-DK([int]$id,[int]$visible){Tab-DK $id;Press-DK 0x20;Wait-DK {[PinDesktopKeyboard]::IsWindowVisible([PinDesktopKeyboard]::GetDlgItem($settings,$visible))} 'selected page'}
function Assert-DialogDK {
    [PinDesktopKeyboard]::AssertForeground($dialog,$process.Id)
    if([PinRealKeys]::FindDialog($process.Id,$dialogTitle) -ne $dialog -or [PinDesktopKeyboard]::GetAncestor($dialog,3) -ne $settings){throw 'Confirmation dialog identity/owner changed'}
}
function Open-DialogDK([int]$button,[string]$title,[string]$descriptionPattern){
    Tab-DK $button;Assert-DK ([PinRealKeys]::Enabled($settings,$process.Id,$button)) ($title+': keyboard trigger is enabled')
    [PinDesktopKeyboard]::Press($settings,$process.Id,0x20,0)
    $script:dialogTitle=$title
    Wait-DK {$script:dialog=[PinRealKeys]::FindDialog($process.Id,$title);$dialog -ne [IntPtr]::Zero -and [PinDesktopKeyboard]::GetForegroundWindow() -eq $dialog} 'keyboard opens owned confirmation'
    Assert-DialogDK
    Assert-DK ([PinRealKeys]::DefaultButton($dialog,$process.Id,$title) -eq 7 -and [PinDesktopKeyboard]::FocusId($dialog,$process.Id) -eq 7) ($title+': No is both the default and actual keyboard focus')
    $description=[PinRealKeys]::Text($dialog,65535)
    Assert-DK ($description -match $descriptionPattern) ($title+': scope and consequences are present')
    $uiaInput=Join-Path $configDir ('dialog-uia-'+$report.dialogs.Count+'-input.json');$uiaOutput=$uiaInput.Replace('-input.json','-output.json')
    $controls=@();foreach($id in @(6,7)){$controls+=@{handle=[PinDesktopKeyboard]::GetDlgItem($dialog,$id).ToInt64();id=$id;page=$title}}
    ConvertTo-Json -InputObject @($controls)|Set-Content -LiteralPath $uiaInput -Encoding utf8
    & $UiaProbePath $uiaInput $uiaOutput $process.Id
    if($LASTEXITCODE -ne 0){throw 'Native confirmation UIA reader failed'}
    $buttons=@(Get-Content -LiteralPath $uiaOutput -Raw|ConvertFrom-Json)
    $report['last_button_samples']=$buttons
    foreach($sample in $buttons){Assert-DK (-not [string]::IsNullOrWhiteSpace($sample.name) -and $sample.type -eq 50000) ($title+': button '+$sample.id+' exposes a name and button role')}
    $report.dialogs+=@{title=$title;description=$description;buttons=$buttons;default=7;focus=7}
}
function Press-DialogDK([int]$key,[int]$modifier=0){Assert-DialogDK;[PinDesktopKeyboard]::Press($dialog,$process.Id,$key,$modifier);Start-Sleep -Milliseconds 35}
function Closed-DialogDK([int]$trigger){Wait-DK {-not [PinDesktopKeyboard]::IsWindow($dialog) -and [PinDesktopKeyboard]::GetForegroundWindow() -eq $settings} 'confirmation closes back to settings';$report['focus_after_cancel']=[PinDesktopKeyboard]::FocusId($settings,$process.Id);Wait-DK {[PinDesktopKeyboard]::AssertForeground($settings,$process.Id);[PinDesktopKeyboard]::FocusId($settings,$process.Id) -eq $trigger} 'confirmation restores trigger focus';Assert-DK $true ($dialogTitle+': focus returns to the original trigger')}
function Cancel-DialogDK([int]$button,[string]$title,[string]$pattern){
    $before=Hash-DK
    Open-DialogDK $button $title $pattern
    Press-DialogDK 9;Assert-DK ([PinDesktopKeyboard]::FocusId($dialog,$process.Id) -eq 6) ($title+': Tab reaches Yes')
    Press-DialogDK 9 0x10;Assert-DK ([PinDesktopKeyboard]::FocusId($dialog,$process.Id) -eq 7) ($title+': Shift+Tab returns to No')
    Press-DialogDK 0x0d;Closed-DialogDK $button
    Assert-DK ((Hash-DK) -eq $before) ($title+': Enter on default No preserves exact config bytes')
    Open-DialogDK $button $title $pattern
    # Native MB_YESNO deliberately has no Cancel result: Escape leaves it open.
    # Verify that safe behavior, then select the focused No to dismiss it.
    Press-DialogDK 0x1b;Assert-DialogDK
    Assert-DK ((Hash-DK) -eq $before -and [PinDesktopKeyboard]::FocusId($dialog,$process.Id) -eq 7) ($title+': Escape leaves Yes/No open without committing or changing No focus')
    Press-DialogDK 0x0d;Closed-DialogDK $button
    Assert-DK ((Hash-DK) -eq $before) ($title+': No remains usable after Escape and preserves exact config bytes')
}
function Accept-DialogDK([int]$button,[string]$title,[string]$pattern){Open-DialogDK $button $title $pattern;Press-DialogDK 9;Assert-DK ([PinDesktopKeyboard]::FocusId($dialog,$process.Id) -eq 6) ($title+': explicit Yes has actual focus');Press-DialogDK 0x0d;Wait-DK {-not [PinDesktopKeyboard]::IsWindow($dialog) -and (Status-DK) -notmatch '^正在处理'} 'explicit keyboard Yes finishes'}
function AppContent-DK($app){$copy=Copy-DK $app;$copy.app_id='identity';$copy.app_name='name';if($copy.default){$copy.default.revision=0};foreach($rule in $copy.rules){$rule.preset.revision=0};return $copy|ConvertTo-Json -Depth 20 -Compress}
try{
    $null=[PinRealKeys]::StartFixture()
    Start-DK 'seed'
    [PinRealKeys]::Command($settings,$process.Id,109);Wait-DK {(Status-DK) -notmatch '^正在处理'} 'seed refresh'
    [PinRealKeys]::SelectWindow($settings,$process.Id,'Screen Pin isolated real hotkey fixture')
    [PinRealKeys]::Command($settings,$process.Id,111);Wait-DK {(Status-DK) -match '^已记住'} 'seed default capture'
    foreach($keyword in @('Dialog','fixture')){[PinRealKeys]::ControlText($settings,$process.Id,114,$keyword);[PinRealKeys]::Command($settings,$process.Id,115);Wait-DK {(Status-DK) -match '^已创建标题规则'} 'seed title rule'}
    $seed=Read-DK;Assert-DK ($seed.profiles[0].applications[0].rules.Count -eq 2) 'Seed has a real captured default and two title rules';Stop-DK

    $migration=Copy-DK $seed;$oldApp=$migration.profiles[0].applications[0];$oldApp.app_id='exe:c:\screen-pin-dialog-fixture\old.exe';$oldApp.app_name='Old dialog fixture'
    Start-DK 'migration' ($migration|ConvertTo-Json -Depth 24)
    [PinRealKeys]::SelectWindow($settings,$process.Id,'Screen Pin isolated real hotkey fixture')
    # Select a source preset with Home; migration applies to the whole app.
    Focus-DK;Tab-DK 117;Press-DK 0x24
    $before=Read-DK
    Cancel-DialogDK 140 '迁移应用预设' '全部 2 条标题规则[\s\S]*新应用：'
    Accept-DialogDK 140 '迁移应用预设' '全部 2 条标题规则[\s\S]*新应用：'
    $after=Read-DK;$app=$after.profiles[0].applications[0]
    Assert-DK ($app.app_id -eq $seed.profiles[0].applications[0].app_id -and (AppContent-DK $app) -eq (AppContent-DK $before.profiles[0].applications[0]) -and $after.revision -gt $before.revision -and (Status-DK) -match '^已将') 'Keyboard-confirmed migration changes application identity and preserves default, all rule IDs, order and placements'
    $report.cases+=@{case='migration';before=$before;after=$after;status=Status-DK};Stop-DK

    $ambiguous=Copy-DK $seed;$duplicate=Copy-DK $ambiguous.displays[0];$duplicate.id='dialog-display-'+[Guid]::NewGuid().ToString('N');$ambiguous.displays+=@($duplicate)
    $profile=Copy-DK $ambiguous.profiles[0];$profile.id='dialog-profile-'+[Guid]::NewGuid().ToString('N');$profile.name='Dialog ambiguous old profile';$profile.display_ids=@($duplicate.id);$profile.applications=@();$ambiguous.profiles+=@($profile)
    Start-DK 'environment' ($ambiguous|ConvertTo-Json -Depth 24)
    Focus-DK;Page-DK 102 312
    $before=Read-DK
    Cancel-DialogDK 312 '新环境' '空方案[\s\S]*已有方案和预设继续保留'
    Accept-DialogDK 312 '新环境' '空方案[\s\S]*已有方案和预设继续保留'
    $after=Read-DK
    Assert-DK ($after.profiles.Count -eq 3 -and $after.displays.Count -eq 3 -and $after.profiles[2].applications.Count -eq 0 -and ($after.profiles[0..1]|ConvertTo-Json -Depth 20 -Compress) -eq ($before.profiles|ConvertTo-Json -Depth 20 -Compress) -and ($after.displays[0..1]|ConvertTo-Json -Depth 20 -Compress) -eq ($before.displays|ConvertTo-Json -Depth 20 -Compress) -and (Status-DK) -match '^已建立') 'Keyboard-confirmed new environment adds an empty profile and preserves both old profiles and display records'
    $report.cases+=@{case='environment';before=$before;after=$after;status=Status-DK};Stop-DK

    $corrupt='{ "schema_version": 1, "keyboard-test": '
    Start-DK 'reset' $corrupt
    Focus-DK;Page-DK 101 213
    Assert-DK (-not [PinRealKeys]::Enabled($settings,$process.Id,207)) 'Corrupt private configuration starts in protected mode'
    Cancel-DialogDK 213 '新建配置' '保留[\s\S]*原件[\s\S]*原有预设不会自动导入'
    $corruptHash=Hash-DK
    Accept-DialogDK 213 '新建配置' '保留[\s\S]*原件[\s\S]*原有预设不会自动导入'
    $after=Read-DK;$preserved=@(Get-ChildItem -LiteralPath $configDir -Filter 'config.preserved-*.json' -File)
    Assert-DK ($after.schema_version -eq 1 -and $after.profiles.Count -eq 1 -and $after.profiles[0].applications.Count -eq 0 -and [PinRealKeys]::Enabled($settings,$process.Id,207) -and $preserved.Count -eq 1 -and (Get-FileHash -LiteralPath $preserved[0].FullName).Hash -eq $corruptHash -and (Status-DK) -match '^已明确建立') 'Keyboard-confirmed reset preserves exact corrupt original and creates an editable empty configuration'
    $report.cases+=@{case='reset';original_hash=$corruptHash;preserved=$preserved[0].FullName;after=$after;status=Status-DK};Stop-DK
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace;$report['failure_foreground_class']=[PinDesktopKeyboard]::Class([PinDesktopKeyboard]::GetForegroundWindow())}
finally{
    try{Stop-DK}catch{$report.errors+=('App cleanup: '+$_.Exception.Message)}
    try{[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)}
    $report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
    if(-not $report.startup_registry_unchanged){$report.errors+='Startup registration changed'}
    $report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report.passed=$report.errors.Count -eq 0 -and $report.cases.Count -eq 3 -and $report.normal_exits.Count -eq 4
    $report|ConvertTo-Json -Depth 24|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8
    Write-Host ('Dialog keyboard report: '+(Join-Path $runDir 'report.json'))
}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
