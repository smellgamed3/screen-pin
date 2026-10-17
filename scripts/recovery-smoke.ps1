#Requires -Version 7.0
param(
    [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/recovery')
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('recovery-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$helperPath=Join-Path $PSScriptRoot 'support/real-keys.cs'
Add-Type -Path $helperPath
$report=[ordered]@{
    started_utc=[DateTime]::UtcNow.ToString('o');exe_path=$ExePath;exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash
    script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;helper_sha256=(Get-FileHash -LiteralPath $helperPath).Hash
    scope='Bounded native GUI commands, no keyboard/mouse input; only fresh isolated configuration directories and owned dialogs.'
    passed_checks=@();cases=@();normal_exits=@();errors=@();passed=$false
    limitations=@('Does not cover every disk/ACL failure, real Narrator, keyboard confirmation navigation, or unsupported old-format migration.','Explicit reset creates a new configuration only inside this test run; no daily configuration or Run setting is edited.')
}
$process=$null;$settings=[IntPtr]::Zero;$hostWindow=[IntPtr]::Zero;$configDir='';$configPath='';$dialog=[IntPtr]::Zero
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-Recovery($condition,[string]$message){if(-not $condition){throw $message};$report.passed_checks+=$message}
function Wait-Recovery([scriptblock]$condition,[string]$description){$watch=[Diagnostics.Stopwatch]::StartNew();do{if(& $condition){return};Start-Sleep -Milliseconds 20}while($watch.ElapsedMilliseconds -lt 6000);throw ('Timeout: '+$description)}
function Hash-Recovery([string]$path){(Get-FileHash -LiteralPath $path).Hash}
function Status-Recovery {[PinRealKeys]::Text($settings,138)}
function Confirm-RecoveryOwner {
    $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
    if(-not $owner -or $owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains('"'+$configDir+'"')){throw 'Isolated process/configuration ownership mismatch'}
}
function Start-Recovery([string]$name,[string]$primary,[string]$backup=''){
    $script:configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir $name)).FullName
    $script:configPath=Join-Path $configDir 'config.json'
    [IO.File]::WriteAllText($configPath,$primary)
    if($backup){[IO.File]::WriteAllText((Join-Path $configDir 'config.backup.json'),$backup)}
    $script:process=Start-Process -FilePath $ExePath -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    $script:settings=[IntPtr]::Zero;$script:hostWindow=[IntPtr]::Zero
    Wait-Recovery {
        $hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);$windows=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id)
        if($hosts.Length -eq 1 -and $windows.Length -eq 1 -and [PinRealKeys]::Responsive($hosts[0]) -and [PinRealKeys]::Text($windows[0],138) -notin @('','正在处理…')){$script:hostWindow=$hosts[0];$script:settings=$windows[0];return $true};return $false
    } 'protected startup'
    Confirm-RecoveryOwner
    [PinRealKeys]::Command($settings,$process.Id,101)
    Assert-Recovery (-not [PinRealKeys]::Enabled($settings,$process.Id,207) -and [PinRealKeys]::Enabled($settings,$process.Id,211) -and [PinRealKeys]::Enabled($settings,$process.Id,213)) ($name+': protection disables normal saves and exposes recovery/reset')
}
function Stop-Recovery {
    if($null -eq $process){return};$process.Refresh();if($process.HasExited){return}
    Confirm-RecoveryOwner
    $ownedDialog=[PinRealKeys]::FindDialog($process.Id,'新建配置')
    if($ownedDialog -ne [IntPtr]::Zero){[PinRealKeys]::DialogButton($ownedDialog,$process.Id,'新建配置',7)}
    [uint32]$owner=0;[PinRealKeys]::GetWindowThreadProcessId($hostWindow,[ref]$owner)|Out-Null
    if($owner -ne $process.Id){throw 'Exit host ownership mismatch'}
    if(-not [PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)){throw 'Normal exit post failed'}
    if(-not $process.WaitForExit(8000)){Confirm-RecoveryOwner;$process.Kill();$process.WaitForExit();throw 'Own process was forcibly cleaned up after normal exit timeout'}
    Assert-Recovery ($process.ExitCode -eq 0) 'Owned application exited normally'
    $report.normal_exits+=@{pid=$process.Id;exit_code=$process.ExitCode};$script:process=$null
}
function Attempt-Recovery([string]$errorPattern){
    $before=Hash-Recovery $configPath;$backupPath=Join-Path $configDir 'config.backup.json'
    $backupBefore=if(Test-Path -LiteralPath $backupPath){Hash-Recovery $backupPath}else{$null}
    [PinRealKeys]::Command($settings,$process.Id,211)
    Wait-Recovery {(Status-Recovery) -ne '正在处理…'} 'failed backup recovery result'
    Assert-Recovery ((Status-Recovery) -match $errorPattern) ('Recovery failure is explicit: '+$errorPattern)
    Assert-Recovery ((Hash-Recovery $configPath) -eq $before -and -not [PinRealKeys]::Enabled($settings,$process.Id,207)) 'Failed recovery preserves primary bytes and protected mode'
    if($backupBefore){Assert-Recovery ((Hash-Recovery $backupPath) -eq $backupBefore) 'Failed recovery preserves existing backup bytes'}
    $report.cases+=@{directory=$configDir;primary_hash=$before;backup_hash=$backupBefore;status=Status-Recovery}
}
function Open-ResetDialog {
    Confirm-RecoveryOwner
    if(-not [PinRealKeys]::PostMessageW($settings,0x111,[IntPtr]213,[IntPtr]::Zero)){throw 'Reset dialog post failed'}
    Wait-Recovery {$script:dialog=[PinRealKeys]::FindDialog($process.Id,'新建配置');$script:dialog -ne [IntPtr]::Zero} 'explicit reset confirmation'
    Assert-Recovery ([PinRealKeys]::DefaultButton($dialog,$process.Id,'新建配置') -eq 7) 'Reset confirmation defaults to No'
    Assert-Recovery ([PinRealKeys]::Text($dialog,65535) -match '保留.*原件' -and [PinRealKeys]::Text($dialog,65535) -match '原有预设不会自动导入') 'Reset confirmation explains original preservation and empty presets'
}
$empty=@{schema_version=1;revision=0;settings=@{restore=@{modifiers=3;key=120};remember=@{modifiers=3;key=121};autostart=$false};displays=@();profiles=@()}|ConvertTo-Json -Depth 9
$future='{"schema_version":999,"future_field":"must remain"}'
try{
    if([PinRealKeys]::FindClass('ScreenPin.Host',0).Length){throw 'Existing Screen Pin instance detected; no user data changed'}
    Start-Recovery 'truncated-no-backup' '{"schema_version":1,'
    Assert-Recovery ((Status-Recovery) -match 'JSON 损坏') 'Truncated JSON is diagnosed'
    Attempt-Recovery '无法读取'
    Stop-Recovery

    Start-Recovery 'future-invalid-backup' $future '{broken'
    Assert-Recovery ((Status-Recovery) -match '不支持的配置格式版本 999') 'Future format is diagnosed without downgrade'
    Attempt-Recovery 'JSON 损坏'
    $before=Hash-Recovery $configPath
    Open-ResetDialog
    [PinRealKeys]::DialogButton($dialog,$process.Id,'新建配置',7)
    Wait-Recovery {[PinRealKeys]::FindDialog($process.Id,'新建配置') -eq [IntPtr]::Zero} 'reset cancellation'
    Assert-Recovery ((Hash-Recovery $configPath) -eq $before -and -not [PinRealKeys]::Enabled($settings,$process.Id,207)) 'Cancelling explicit reset retains future bytes and protected mode'
    Open-ResetDialog
    [PinRealKeys]::DialogButton($dialog,$process.Id,'新建配置',6)
    Wait-Recovery {(Status-Recovery) -match '^已明确建立新配置'} 'explicit reset completion'
    $fresh=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
    Assert-Recovery ($fresh.schema_version -eq 1 -and $fresh.profiles.Count -eq 1 -and $fresh.profiles[0].applications.Count -eq 0) 'Confirmed reset creates an empty current-display profile'
    $preserved=@(Get-ChildItem -LiteralPath $configDir -Filter 'config.preserved-*.json')
    Assert-Recovery ($preserved.Count -eq 1 -and (Hash-Recovery $preserved[0].FullName) -eq $before) 'Confirmed reset separately preserves exact future-format original'
    Assert-Recovery ([PinRealKeys]::Enabled($settings,$process.Id,207) -and -not [PinRealKeys]::Enabled($settings,$process.Id,211)) 'Confirmed reset returns to normal editable mode'
    Stop-Recovery

    $invalid=$empty|ConvertFrom-Json;$invalid|Add-Member -NotePropertyName unexpected -NotePropertyValue 'keep'
    Start-Recovery 'invalid-fields-future-backup' ($invalid|ConvertTo-Json -Depth 9) $future
    Assert-Recovery ((Status-Recovery) -match '配置字段无效') 'Unknown current-schema fields are diagnosed'
    Attempt-Recovery '不支持的配置格式版本 999'
    Stop-Recovery

    Start-Recovery 'replacement-blocked' '{truncated' $empty
    $before=Hash-Recovery $configPath;$backupBefore=Hash-Recovery (Join-Path $configDir 'config.backup.json')
    $lock=[IO.File]::Open($configPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{Attempt-Recovery '无法替换配置'}finally{$lock.Dispose()}
    Assert-Recovery ((Hash-Recovery (Join-Path $configDir 'config.backup.json')) -eq $backupBefore) 'Failed replacement leaves the valid backup intact'
    [PinRealKeys]::Command($settings,$process.Id,211)
    Wait-Recovery {(Status-Recovery) -match '^已恢复有效备份'} 'retry after releasing test file lock'
    Assert-Recovery ([PinRealKeys]::Enabled($settings,$process.Id,207)) 'Recovery can be retried successfully after the file lock is released'
    $preserved=@(Get-ChildItem -LiteralPath $configDir -Filter 'config.preserved-*.json')
    Assert-Recovery ($preserved.Count -eq 2 -and @($preserved|Where-Object {(Hash-Recovery $_.FullName) -ne $before}).Count -eq 0) 'Both recovery attempts retain exact damaged originals'
    Stop-Recovery
}catch{$report.errors+=$_.Exception.Message}
finally{
    try{Stop-Recovery}catch{$report.errors+=('Cleanup: '+$_.Exception.Message)}
    $report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
    if(-not $report.startup_registry_unchanged){$report.errors+='User Run registry unexpectedly changed'}
    $report['finished_utc']=[DateTime]::UtcNow.ToString('o')
    $report.passed=$report.errors.Count -eq 0 -and $report.cases.Count -eq 4 -and $report.normal_exits.Count -eq 4
    $report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8
    Write-Host ('Recovery smoke report: '+(Join-Path $runDir 'report.json'))
}
if(-not $report.passed){exit 1}
