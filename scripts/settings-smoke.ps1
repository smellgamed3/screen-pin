#Requires -Version 7.0
param(
    [string]$ExePath = (Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '../artifacts/settings'),
    [string]$UiaProbePath = (Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe'),
    [switch]$StorageFaults
)
$ErrorActionPreference = 'Stop'
$ExePath = (Get-Item -LiteralPath $ExePath).FullName
$UiaProbePath = (Get-Item -LiteralPath $UiaProbePath).FullName
$runDir = [IO.Path]::GetFullPath((Join-Path $OutputDir ('settings-' + [Guid]::NewGuid().ToString('N'))))
$configDir = (New-Item -ItemType Directory -Path (Join-Path $runDir 'config') -Force).FullName
$configPath = Join-Path $configDir 'config.json'
$helperPath = Join-Path $PSScriptRoot 'support/real-keys.cs'
Add-Type -Path $helperPath
$report = [ordered]@{
    started_utc=[DateTime]::UtcNow.ToString('o'); exe_path=$ExePath
    exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash
    script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash
    helper_sha256=(Get-FileHash -LiteralPath $helperPath).Hash
    config_dir=$configDir; storage_faults_requested=$StorageFaults.IsPresent;storage_faults=@();passed_checks=@(); real_input_cycles=@(); normal_exits=@(); errors=@(); passed=$false;metadata_reads=@();metadata_read_timeouts=0
    scope='Settings controls are edited with bounded native messages to the owned hidden GUI. Each accepted or retained mapping is exercised with real SendInput on the new fixture; no WM_HOTKEY injection.'
    limitations=@('Single local desktop/DPI and synthetic fixture; settings form editing is programmatic, not a keyboard navigation test.','Persistence failure uses a sharing lock on only the fresh test config; not every storage fault is covered.','Startup conflict is a controlled independent registration on the fixture thread, not an unrelated third-party application.')
}
$process=$null; $settings=[IntPtr]::Zero; $hostWindow=[IntPtr]::Zero; $sequence=0
$storageBlockers=[Collections.Generic.List[string]]::new()
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-Settings($condition,[string]$message){if(-not $condition){throw $message};$report.passed_checks+=$message}
function Read-Settings {[PinRealKeys]::ReadConfig($configPath)|ConvertFrom-Json}
function Hash-Settings {(Get-FileHash -LiteralPath $configPath).Hash}
function Read-SettingsText([int]$id){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{
        try{
            $value=[PinRealKeys]::Text($settings,$id)
            $report.metadata_reads+=@{id=$id;elapsed_ms=$watch.Elapsed.TotalMilliseconds}
            return $value
        }catch{if($_.Exception.Message -notmatch 'Timed out reading own app result'){throw};$report.metadata_read_timeouts++}
        Start-Sleep -Milliseconds 15
    }while($watch.ElapsedMilliseconds -lt 1000)
    throw ('Settings control '+$id+' did not answer within the metadata read budget')
}
function Status-Settings {Read-SettingsText 138}
function Wait-Settings([scriptblock]$condition,[string]$description){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{[PinRealKeys]::AssertForeground();if(& $condition){return};Start-Sleep -Milliseconds 15}while($watch.ElapsedMilliseconds -lt 6000)
    throw ('Timeout: '+$description+'; '+(Status-Settings))
}
function Confirm-SettingsOwner {
    $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
    if(-not $owner -or $owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains('"'+$configDir+'"')){throw 'Isolated process/configuration ownership mismatch'}
}
function Start-SettingsApp {
    $script:process=Start-Process -FilePath $ExePath -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    $script:settings=[IntPtr]::Zero; $script:hostWindow=[IntPtr]::Zero
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{
        $hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);$windows=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id)
        if($hosts.Length -eq 1 -and $windows.Length -eq 1 -and [PinRealKeys]::Responsive($hosts[0]) -and [PinRealKeys]::Text($windows[0],138) -notin @('','正在处理…')){$script:hostWindow=$hosts[0];$script:settings=$windows[0];break}
        Start-Sleep -Milliseconds 20
    }while($watch.ElapsedMilliseconds -lt 8000)
    if($settings -eq [IntPtr]::Zero){throw 'Own app did not become ready'}
    Confirm-SettingsOwner
}
function Stop-SettingsApp {
    if($null -eq $process){return};$process.Refresh();if($process.HasExited){return}
    Confirm-SettingsOwner
    [uint32]$owner=0;[PinRealKeys]::GetWindowThreadProcessId($hostWindow,[ref]$owner)|Out-Null
    if($owner -ne $process.Id){throw 'Exit host ownership mismatch'}
    if(-not [PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)){throw 'Normal exit request failed'}
    if(-not $process.WaitForExit(8000)){Confirm-SettingsOwner;$process.Kill();$process.WaitForExit();throw 'Own app failed normal exit and was forcibly cleaned up'}
    Assert-Settings ($process.ExitCode -eq 0) 'Owned application exited normally'
    $report.normal_exits+=@{pid=$process.Id;exit_code=$process.ExitCode}
    $script:process=$null
}
function Edit-Settings([int]$restore,[int]$remember){
    [PinRealKeys]::AssertForeground();Confirm-SettingsOwner
    [PinRealKeys]::Command($settings,$process.Id,101)
    [PinRealKeys]::ControlText($settings,$process.Id,202,('Ctrl+Alt+F'+($restore-0x6f)))
    [PinRealKeys]::ControlText($settings,$process.Id,204,('Ctrl+Alt+F'+($remember-0x6f)))
    [PinRealKeys]::Command($settings,$process.Id,207)
    Wait-Settings {(Status-Settings) -ne '正在处理…'} 'settings save completion'
}
function Assert-Registered([int]$restore,[int]$remember){
    $status=(Read-SettingsText 208)
    Assert-Settings ($status -match ('恢复 Ctrl\+Alt\+F'+($restore-0x6f)+'：已注册') -and $status -match ('记住 Ctrl\+Alt\+F'+($remember-0x6f)+'：已注册')) ('Actual registered mapping is F'+($restore-0x6f)+'/F'+($remember-0x6f))
}
function Assert-Released([int]$key){
    $blocked=[PinRealKeys]::Block([ushort]$key)
    Assert-Settings $blocked ('Unused Ctrl+Alt+F'+($key-0x6f)+' is released')
    [PinRealKeys]::Unblock([ushort]$key)
}
function Exercise-Settings([int]$restore,[int]$remember,[string]$scenario){
    $script:sequence++
    [PinRealKeys]::AssertForeground();$work=[PinRealKeys]::Work()
    $expected=[PinRealKeys]::Move(($work.Left+90+$sequence*7),($work.Top+100+$sequence*5),710,490)
    Wait-Settings {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$expected) -le 2} 'fixture initial placement'
    $target=[PinRealKeys]::Frame();$before=Read-Settings
    [PinRealKeys]::Chord([ushort]$remember)
    Wait-Settings {(Read-Settings).revision -gt $before.revision -and (Status-Settings) -match '^已记住'} 'real remember persisted'
    $savedHash=Hash-Settings
    $displaced=[PinRealKeys]::Move(($work.Left+500),($work.Top+360),420,320)
    Wait-Settings {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$displaced) -le 2} 'fixture displacement'
    Assert-Settings ([PinRealKeys]::EdgeError($target,[PinRealKeys]::Frame()) -gt 2) ($scenario+': target displaced')
    [PinRealKeys]::Chord([ushort]$restore)
    Wait-Settings {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$target) -le 2 -and (Status-Settings) -match '^已恢复|^已符合预设'} 'real restore confirmed'
    $errorPx=[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$target)
    Assert-Settings ($errorPx -le 2 -and (Hash-Settings) -eq $savedHash) ($scenario+': real hotkeys capture and restore without restore writes')
    $report.real_input_cycles+=@{scenario=$scenario;restore_vk=$restore;remember_vk=$remember;edge_error_px=$errorPx}
}
function Block-Storage([string]$kind){
    Confirm-SettingsOwner
    if($storageBlockers.Count){throw 'Previous storage blockers are still present'}
    # Collision directories fail actual create_new/copy calls inside only this
    # run's config. No ACLs, disk settings, or production fault hooks are changed.
    foreach($index in 0..127){
        $name=switch($kind){'backup-temp'{"config.backup.tmp-$($process.Id)-$index"};'primary-temp'{"config.tmp-$($process.Id)-$index"};'preserve'{"config.preserved-$($process.Id)-$index.json"};default{throw 'Unknown storage blocker kind'}}
        $path=[IO.Path]::GetFullPath((Join-Path $configDir $name))
        if(-not $path.StartsWith($configDir+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $path)){throw 'Storage blocker must be a fresh child of the owned config directory'}
        New-Item -ItemType Directory -Path $path|Out-Null;$storageBlockers.Add($path)
    }
}
function Clear-Storage {
    foreach($path in $storageBlockers){
        $resolved=[IO.Path]::GetFullPath($path)
        if(-not $resolved.StartsWith($configDir+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $resolved -PathType Container) -or @(Get-ChildItem -LiteralPath $resolved -Force).Count){throw 'Refusing removal of an unexpected/nonempty storage blocker'}
        Remove-Item -LiteralPath $resolved
    }
    $storageBlockers.Clear()
}
try{
    if([PinRealKeys]::FindClass('ScreenPin.Host',0).Length){throw 'An existing Screen Pin instance owns global hotkeys; no changes or input made'}
    Start-SettingsApp
    $fixture=[PinRealKeys]::StartFixture();Start-Sleep -Milliseconds 100
    if([PinRealKeys]::GetForegroundWindow() -ne $fixture){
        $inputPath=Join-Path $runDir 'focus-input.json';$outputPath=Join-Path $runDir 'focus-output.json'
        ConvertTo-Json -InputObject @(@{handle=$fixture.ToInt64();id=0;page='activation'})|Set-Content -LiteralPath $inputPath -Encoding utf8
        & $UiaProbePath $inputPath $outputPath $PID --focus
        if($LASTEXITCODE -ne 0){throw 'Initial public UIA fixture focus failed'}
    }
    [PinRealKeys]::AssertForeground()
    Assert-Registered 0x78 0x79
    Exercise-Settings 0x78 0x79 'baseline'

    if($StorageFaults){
        $initialPlacement=(Read-Settings).profiles[0].applications[0].default.placement|ConvertTo-Json -Depth 8 -Compress
        $initialFrame=[PinRealKeys]::Frame()
        $before=Hash-Settings;$backupBefore=(Get-FileHash -LiteralPath (Join-Path $configDir 'config.backup.json')).Hash
        $undoBefore=(Read-SettingsText 144)
        Block-Storage 'backup-temp'
        try{
            Edit-Settings 0x7a 0x7b
            Assert-Settings ((Status-Settings) -match '^无法写入临时配置' -and (Hash-Settings) -eq $before -and (Get-FileHash -LiteralPath (Join-Path $configDir 'config.backup.json')).Hash -eq $backupBefore) 'Backup temporary creation failure preserves primary and backup bytes'
            Assert-Settings ((Read-SettingsText 144) -ceq $undoBefore) 'Backup temporary creation failure retains the visible prior undo entry'
            Assert-Registered 0x78 0x79;Assert-Released 0x7a;Assert-Released 0x7b
            $report.storage_faults+=@{kind='backup-temp';status=Status-Settings;primary_hash=$before;backup_hash=$backupBefore;undo_label=$undoBefore}
        }finally{Clear-Storage}
        Edit-Settings 0x7a 0x7b
        Assert-Settings ((Status-Settings) -eq '设置已保存') 'Settings save succeeds after clearing the backup temporary blocker'
        Exercise-Settings 0x7a 0x7b 'after backup temporary failure retry'
        Edit-Settings 0x78 0x79

        $before=Hash-Settings;$undoBefore=(Read-SettingsText 144);$savedFrame=[PinRealKeys]::Frame()
        $null=[PinRealKeys]::Move(580,380,490,360)
        Block-Storage 'primary-temp'
        try{
            [PinRealKeys]::Chord(0x79)
            Wait-Settings {(Status-Settings) -match '^无法写入临时配置'} 'primary temporary creation failure'
            Assert-Settings ((Hash-Settings) -eq $before -and (Get-FileHash -LiteralPath (Join-Path $configDir 'config.backup.json')).Hash -eq $before) 'Primary temporary creation failure retains primary and promotes only the prior valid config to backup'
            Assert-Settings ((Read-SettingsText 144) -ceq $undoBefore) 'Failed real remember retains the visible prior undo entry'
            [PinRealKeys]::Chord(0x78)
            Wait-Settings {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$savedFrame) -le 2 -and (Status-Settings) -match '^已恢复|^已符合预设'} 'runtime still restores the old placement after failed remember'
            Assert-Settings ((Hash-Settings) -eq $before) 'Old runtime placement remains authoritative after failed real remember'
            $report.storage_faults+=@{kind='primary-temp';failure='无法写入临时配置';primary_hash=$before;backup_hash=(Get-FileHash -LiteralPath (Join-Path $configDir 'config.backup.json')).Hash;restored_old_edge_error_px=[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$savedFrame);undo_label=$undoBefore}
        }finally{Clear-Storage}
        [PinRealKeys]::Command($settings,$process.Id,136)
        Wait-Settings {(Status-Settings) -match '^已撤销'} 'undo preceding successful change after failed remember'
        Assert-Settings (((Read-Settings).profiles[0].applications[0].default.placement|ConvertTo-Json -Depth 8 -Compress) -ceq $initialPlacement) 'After failed remember, actual undo restores the preceding successful update to its older placement'
        $undoHash=Hash-Settings
        [PinRealKeys]::Chord(0x78)
        Wait-Settings {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$initialFrame) -le 2 -and (Status-Settings) -match '^已恢复|^已符合预设'} 'real restore after preserved undo'
        Assert-Settings ((Hash-Settings) -eq $undoHash) 'Restoring the preserved undo result makes no extra configuration write'
        $faultTrace=$report.storage_faults[-1];$faultTrace['actual_undo_restored_older_placement']=$true;$faultTrace['post_undo_restore_error_px']=[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$initialFrame)
        Exercise-Settings 0x78 0x79 'after primary temporary failure retry'
    }

    $before=Hash-Settings
    Edit-Settings 0x7a 0x7a
    Assert-Settings ((Status-Settings) -match '不能使用同一热键' -and (Hash-Settings) -eq $before) 'Duplicate action hotkey rejected without configuration writes'
    Assert-Registered 0x78 0x79
    Exercise-Settings 0x78 0x79 'after duplicate refusal'

    Assert-Settings ([PinRealKeys]::Block(0x7b)) 'Independent fixture registration reserves proposed second hotkey F12'
    try{
        $before=Hash-Settings
        Edit-Settings 0x7a 0x7b
        Assert-Settings ((Status-Settings) -match 'F12 注册失败' -and (Hash-Settings) -eq $before) 'External registration conflict preserves configuration'
        Assert-Registered 0x78 0x79
        Assert-Released 0x7a
        Exercise-Settings 0x78 0x79 'after second registration failure'
    }finally{[PinRealKeys]::Unblock(0x7b)}

    Edit-Settings 0x79 0x78
    Assert-Settings ((Status-Settings) -eq '设置已保存') 'Existing action hotkeys can be swapped'
    Assert-Registered 0x79 0x78
    Exercise-Settings 0x79 0x78 'swapped actions'

    Edit-Settings 0x7a 0x7b
    Assert-Settings ((Status-Settings) -eq '设置已保存') 'Custom F11/F12 mapping is persisted'
    Assert-Registered 0x7a 0x7b
    Assert-Released 0x78;Assert-Released 0x79
    Exercise-Settings 0x7a 0x7b 'custom mapping'

    $before=Hash-Settings
    $lock=[IO.File]::Open($configPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        Edit-Settings 0x78 0x79
        Assert-Settings ((Status-Settings) -match '无法替换配置' -and (Hash-Settings) -eq $before) 'Save sharing violation retains exact primary bytes and reports failure'
        Assert-Registered 0x7a 0x7b
        Assert-Released 0x78;Assert-Released 0x79
    }finally{$lock.Dispose()}
    Assert-Settings ((Get-Content -LiteralPath (Join-Path $configDir 'config.backup.json') -Raw|ConvertFrom-Json).settings.restore.key -eq 0x7a) 'Last valid backup retains actual prior mapping after failed primary replacement'
    Exercise-Settings 0x7a 0x7b 'after persistence failure'

    $before=Hash-Settings
    Stop-SettingsApp
    Assert-Released 0x7a;Assert-Released 0x7b
    Start-SettingsApp
    Assert-Settings ((Hash-Settings) -eq $before) 'Ordinary same-config restart preserves exact persisted configuration'
    Assert-Registered 0x7a 0x7b
    Assert-Settings ([PinRealKeys]::Text($settings,202) -eq 'Ctrl+Alt+F11' -and [PinRealKeys]::Text($settings,204) -eq 'Ctrl+Alt+F12') 'Restarted settings form displays the persisted custom mapping'
    Exercise-Settings 0x7a 0x7b 'after ordinary restart'

    Stop-SettingsApp
    Assert-Settings ([PinRealKeys]::Block(0x7a)) 'Independent fixture registration occupies configured restore key during restart'
    try{
        $before=Hash-Settings
        Start-SettingsApp
        $status=(Read-SettingsText 208)
        Assert-Settings ($status -match '恢复 Ctrl\+Alt\+F11：不可用' -and $status -match '记住 Ctrl\+Alt\+F12：已注册' -and (Hash-Settings) -eq $before) 'Startup conflict is honestly shown without silently rewriting saved bindings'
        Edit-Settings 0x78 0x7b
        Assert-Settings ((Status-Settings) -eq '设置已保存') 'Settings can repair the unavailable startup binding'
        Assert-Registered 0x78 0x7b
        Exercise-Settings 0x78 0x7b 'after startup conflict repair'
    }finally{[PinRealKeys]::Unblock(0x7a)}
    Stop-SettingsApp
    Assert-Released 0x78;Assert-Released 0x7b

    $validBytes=[IO.File]::ReadAllBytes($configPath)
    [IO.File]::WriteAllBytes((Join-Path $configDir 'config.backup.json'),$validBytes)
    $damagedBytes=[Text.Encoding]::UTF8.GetBytes('{"schema_version":1,"interrupted":')
    [IO.File]::WriteAllBytes($configPath,$damagedBytes)
    $damagedHash=Hash-Settings
    Start-SettingsApp
    Assert-Settings ((Hash-Settings) -eq $damagedHash -and -not [PinRealKeys]::Enabled($settings,$process.Id,207) -and [PinRealKeys]::Enabled($settings,$process.Id,211)) 'Damaged primary is byte-preserved with editing disabled and recovery enabled'
    [PinRealKeys]::Command($settings,$process.Id,211)
    Wait-Settings {(Status-Settings) -match '^已恢复有效备份'} 'backup recovery completion'
    Assert-Settings ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($validBytes)) 'Recovery restores the exact valid backup when topology is unchanged'
    $preserved=@(Get-ChildItem -LiteralPath $configDir -Filter 'config.preserved-*.json')
    Assert-Settings ($preserved.Count -eq 1 -and (Get-FileHash -LiteralPath $preserved[0].FullName).Hash -eq $damagedHash) 'Recovery separately preserves the damaged original bytes'
    Assert-Settings ([PinRealKeys]::Enabled($settings,$process.Id,207) -and -not [PinRealKeys]::Enabled($settings,$process.Id,211)) 'Successful recovery re-enables configuration editing'
    Assert-Registered 0x78 0x7b
    Exercise-Settings 0x78 0x7b 'after backup recovery'
    Assert-Released 0x79
    Stop-SettingsApp

    $validBytes=[IO.File]::ReadAllBytes($configPath)
    [IO.File]::WriteAllBytes((Join-Path $configDir 'config.backup.json'),$validBytes)
    [IO.File]::WriteAllBytes($configPath,$damagedBytes)
    Assert-Settings ([PinRealKeys]::Block(0x7b)) 'Independent fixture registration occupies a key in the recoverable backup'
    try{
        Start-SettingsApp
        [PinRealKeys]::Command($settings,$process.Id,211)
        Wait-Settings {(Status-Settings) -match '^已恢复有效备份'} 'recovery with registration conflict'
        $status=(Read-SettingsText 208)
        Assert-Settings ($status -match '恢复 Ctrl\+Alt\+F9：已注册' -and $status -match '记住 Ctrl\+Alt\+F12：不可用' -and (Status-Settings) -match 'F12 注册失败') 'Recovery describes persisted keys and warns about the externally unavailable binding'
        Assert-Settings ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($validBytes)) 'Recovery conflict does not silently change the backup settings'
        Assert-Released 0x79
        Edit-Settings 0x78 0x7a
        Assert-Settings ((Status-Settings) -eq '设置已保存') 'Recovered unavailable binding can be repaired without restarting'
        Assert-Registered 0x78 0x7a
        Exercise-Settings 0x78 0x7a 'after recovery conflict repair'
    }finally{[PinRealKeys]::Unblock(0x7b)}
    Stop-SettingsApp

    if($StorageFaults){
        $validBytes=[IO.File]::ReadAllBytes($configPath)
        [IO.File]::WriteAllBytes((Join-Path $configDir 'config.backup.json'),$validBytes)
        [IO.File]::WriteAllBytes($configPath,$damagedBytes)
        $damagedHash=Hash-Settings;$backupBefore=(Get-FileHash -LiteralPath (Join-Path $configDir 'config.backup.json')).Hash
        Start-SettingsApp
        Block-Storage 'preserve'
        try{
            [PinRealKeys]::Command($settings,$process.Id,211)
            Wait-Settings {(Status-Settings) -match '^无法保留原配置'} 'preservation-copy failure'
            Assert-Settings ((Hash-Settings) -eq $damagedHash -and (Get-FileHash -LiteralPath (Join-Path $configDir 'config.backup.json')).Hash -eq $backupBefore -and -not [PinRealKeys]::Enabled($settings,$process.Id,207) -and [PinRealKeys]::Enabled($settings,$process.Id,211)) 'Failed original preservation retains primary/backup bytes and protected recovery mode'
            $report.storage_faults+=@{kind='preserve';status=Status-Settings;primary_hash=$damagedHash;backup_hash=$backupBefore}
        }finally{Clear-Storage}
        [PinRealKeys]::Command($settings,$process.Id,211)
        Wait-Settings {(Status-Settings) -match '^已恢复有效备份'} 'recovery retry after preservation blocker removal'
        Assert-Settings ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($validBytes)) 'Recovery retry restores the exact previously valid config'
        Assert-Registered 0x78 0x7a
        Exercise-Settings 0x78 0x7a 'after preservation failure retry'
        Stop-SettingsApp

        $validBytes=[IO.File]::ReadAllBytes($configPath)
        [IO.File]::WriteAllBytes((Join-Path $configDir 'config.backup.json'),$validBytes)
        [IO.File]::WriteAllBytes($configPath,$damagedBytes)
        Start-SettingsApp
        $history=@()
        foreach($index in 0..1){
            $path=Join-Path $configDir ("config.preserved-$($process.Id)-$index.json")
            $bytes=[Text.Encoding]::UTF8.GetBytes('Older original '+$index)
            $file=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
            try{$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}
            $history+=@{path=$path;hash=(Get-FileHash -LiteralPath $path).Hash}
        }
        [PinRealKeys]::Command($settings,$process.Id,211)
        Wait-Settings {(Status-Settings) -match '^已恢复有效备份'} 'recovery skips reused PID/counter filenames'
        Assert-Settings (@($history|Where-Object {(Get-FileHash -LiteralPath $_.path).Hash -ne $_.hash}).Count -eq 0) 'Recovery leaves both older colliding preserved originals byte-identical'
        $newPreserved=Join-Path $configDir ("config.preserved-$($process.Id)-2.json")
        Assert-Settings ((Get-FileHash -LiteralPath $newPreserved).Hash -eq $damagedHash) 'Recovery uses the next unused filename for the new damaged original'
        Assert-Settings ([Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -eq [Convert]::ToBase64String($validBytes)) 'Filename collision handling still restores the exact valid configuration'
        $report.storage_faults+=@{kind='preserve-collision';older_files=$history;new_preserved=$newPreserved;status=Status-Settings}
        Exercise-Settings 0x78 0x7a 'after preserved filename collision'
        Stop-SettingsApp
    }
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{
    try{Clear-Storage}catch{$report.errors+=('Storage blocker cleanup: '+$_.Exception.Message)}
    try{Stop-SettingsApp}catch{$report.errors+=('App cleanup: '+$_.Exception.Message)}
    try{[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)}
    $startupAfter=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
    $report['startup_registry_unchanged']=$startupBefore -ceq $startupAfter
    if(-not $report.startup_registry_unchanged){$report.errors+='User Run registry unexpectedly changed'}
    $report['finished_utc']=[DateTime]::UtcNow.ToString('o')
    $report.passed=$report.errors.Count -eq 0 -and $report.real_input_cycles.Count -eq $(if($StorageFaults){14}else{10}) -and $report.normal_exits.Count -eq $(if($StorageFaults){7}else{5}) -and $report.storage_faults.Count -eq $(if($StorageFaults){4}else{0})
    $report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8
    Write-Host ('Settings smoke report: '+(Join-Path $runDir 'report.json'))
}
if(-not $report.passed){exit 1}
