#Requires -Version 7.0
param(
    [Parameter(Mandatory=$true)][string]$PreviousExe,
    [string]$PackagePath=(Join-Path $PSScriptRoot '../dist/ScreenPin-0.1.0-windows-x64.zip'),
    [string]$ReleaseExe=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$UiaProbePath=(Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe'),
    [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/upgrade')
)
$ErrorActionPreference='Stop'
$PreviousExe=(Get-Item -LiteralPath $PreviousExe).FullName
$PackagePath=(Get-Item -LiteralPath $PackagePath).FullName
$ReleaseExe=(Get-Item -LiteralPath $ReleaseExe).FullName
$UiaProbePath=(Get-Item -LiteralPath $UiaProbePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('upgrade-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$installDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'program')).FullName
$configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'user-data')).FullName
$installedExe=Join-Path $installDir 'screen-pin.exe'
$configPath=Join-Path $configDir 'config.json'
$helperPath=Join-Path $PSScriptRoot 'support/real-keys.cs'
Add-Type -Path $helperPath
$report=[ordered]@{
    started_utc=[DateTime]::UtcNow.ToString('o');previous_exe=$PreviousExe;previous_sha256=(Get-FileHash -LiteralPath $PreviousExe).Hash
    package=$PackagePath;package_sha256=(Get-FileHash -LiteralPath $PackagePath).Hash;current_sha256=(Get-FileHash -LiteralPath $ReleaseExe).Hash
    script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;helper_sha256=(Get-FileHash -LiteralPath $helperPath).Hash
    install_dir=$installDir;config_dir=$configDir;passed_checks=@();restores=@();normal_exits=@();errors=@();passed=$false
    scope='Stop old build, overwrite only a fresh program directory from ZIP, start new build with the same external config, then restore old default and title rule through real SendInput.'
    limitations=@('Same-user, same-machine, schema-v1 development-build replacement; not an old-schema migration or clean-machine/system-restart test.','Uses an explicit isolated --config-dir instead of the daily LOCALAPPDATA folder.','Settings and rule creation use owned GUI commands; restore and capture use real input on only the new fixture.','Tray icon visibility and complete startup timing are not measured.')
}
$process=$null;$settings=[IntPtr]::Zero;$hostWindow=[IntPtr]::Zero
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-Upgrade($condition,[string]$message){if(-not $condition){throw $message};$report.passed_checks+=$message}
function Read-Upgrade {Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json}
function Hash-Upgrade([string]$path){(Get-FileHash -LiteralPath $path).Hash}
function Status-Upgrade {[PinRealKeys]::Text($settings,138)}
function Wait-Upgrade([scriptblock]$condition,[string]$description){$watch=[Diagnostics.Stopwatch]::StartNew();do{[PinRealKeys]::AssertForeground();if(& $condition){return};Start-Sleep -Milliseconds 15}while($watch.ElapsedMilliseconds -lt 6000);throw ('Timeout: '+$description+'; '+(Status-Upgrade))}
function Confirm-UpgradeOwner {
    $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
    if(-not $owner -or $owner.ExecutablePath -ine $installedExe -or -not $owner.CommandLine.Contains('"'+$configDir+'"')){throw 'Installed test process/configuration ownership mismatch'}
}
function Start-UpgradeApp {
    $script:process=Start-Process -FilePath $installedExe -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    $script:settings=[IntPtr]::Zero;$script:hostWindow=[IntPtr]::Zero;$watch=[Diagnostics.Stopwatch]::StartNew()
    do{$hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);$windows=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id);if($hosts.Length -eq 1 -and $windows.Length -eq 1 -and [PinRealKeys]::Responsive($hosts[0]) -and [PinRealKeys]::Text($windows[0],138) -notin @('','正在处理…')){$script:hostWindow=$hosts[0];$script:settings=$windows[0];break};Start-Sleep -Milliseconds 20}while($watch.ElapsedMilliseconds -lt 8000)
    if($settings -eq [IntPtr]::Zero){throw 'Installed test app did not become ready'}
    Confirm-UpgradeOwner
    $status=[PinRealKeys]::Text($settings,208)
    Assert-Upgrade (([regex]::Matches($status,'已注册')).Count -eq 2 -and $status -notmatch '不可用') 'Installed build has both configured hotkeys registered'
}
function Stop-UpgradeApp {
    if($null -eq $process){return};$process.Refresh();if($process.HasExited){return};Confirm-UpgradeOwner
    [uint32]$owner=0;[PinRealKeys]::GetWindowThreadProcessId($hostWindow,[ref]$owner)|Out-Null
    if($owner -ne $process.Id){throw 'Normal-exit host ownership mismatch'}
    if(-not [PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)){throw 'Normal exit post failed'}
    if(-not $process.WaitForExit(8000)){Confirm-UpgradeOwner;$process.Kill();$process.WaitForExit();throw 'Own app was forcibly cleaned up after normal exit timeout'}
    Assert-Upgrade ($process.ExitCode -eq 0) 'Installed test app exited normally'
    $report.normal_exits+=@{pid=$process.Id;exit_code=$process.ExitCode};$script:process=$null
}
function Command-Upgrade([int]$id){Confirm-UpgradeOwner;[PinRealKeys]::Command($settings,$process.Id,$id);Wait-Upgrade {(Status-Upgrade) -ne '正在处理…'} ('command '+$id)}
function Move-Upgrade([int]$x,[int]$y,[int]$width,[int]$height){$expected=[PinRealKeys]::Move($x,$y,$width,$height);Wait-Upgrade {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$expected) -le 2} 'fixture displacement';return [PinRealKeys]::Frame()}
function Restore-Upgrade($target,[string]$scenario){
    $before=Hash-Upgrade $configPath
    Assert-Upgrade ([PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$target) -gt 2) ($scenario+': fixture actually displaced')
    [PinRealKeys]::Chord(0x7a)
    Wait-Upgrade {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$target) -le 2 -and (Status-Upgrade) -match '^已恢复|^已符合预设'} $scenario
    $errorPx=[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$target)
    Assert-Upgrade ((Hash-Upgrade $configPath) -eq $before) ($scenario+': restore preserves persisted configuration')
    $report.restores+=@{scenario=$scenario;edge_error_px=$errorPx;feedback=Status-Upgrade}
}
try{
    if([PinRealKeys]::FindClass('ScreenPin.Host',0).Length){throw 'An existing Screen Pin instance is running; no input or changes made'}
    Assert-Upgrade ($report.previous_sha256 -ne $report.current_sha256) 'Old and new binaries have different content hashes'
    $archive=[IO.Compression.ZipFile]::OpenRead($PackagePath)
    try{$entries=@($archive.Entries|ForEach-Object {$_.FullName});Assert-Upgrade ($entries.Count -eq 2 -and 'screen-pin.exe' -cin $entries -and 'README.txt' -cin $entries) 'Upgrade ZIP contains exactly the two expected root files'}finally{$archive.Dispose()}
    Copy-Item -LiteralPath $PreviousExe -Destination $installedExe
    Start-UpgradeApp
    $fixture=[PinRealKeys]::StartFixture();Start-Sleep -Milliseconds 100
    if([PinRealKeys]::GetForegroundWindow() -ne $fixture){$inputPath=Join-Path $runDir 'focus-input.json';$outputPath=Join-Path $runDir 'focus-output.json';ConvertTo-Json -InputObject @(@{handle=$fixture.ToInt64();id=0;page='activation'})|Set-Content -LiteralPath $inputPath -Encoding utf8;& $UiaProbePath $inputPath $outputPath $PID --focus;if($LASTEXITCODE -ne 0){throw 'Initial public UIA fixture focus failed'}}
    [PinRealKeys]::AssertForeground();$work=[PinRealKeys]::Work()
    $defaultFrame=Move-Upgrade ($work.Left+130) ($work.Top+140) 750 530
    $before=Read-Upgrade;[PinRealKeys]::Chord(0x79)
    Wait-Upgrade {(Read-Upgrade).revision -gt $before.revision -and (Status-Upgrade) -match '^已记住'} 'old build default capture'
    $ruleFrame=Move-Upgrade ($work.Left+300) ($work.Top+230) 830 610
    Command-Upgrade 109
    [PinRealKeys]::SelectWindow($settings,$process.Id,'Screen Pin isolated real hotkey fixture')
    [PinRealKeys]::ControlText($settings,$process.Id,114,'isolated real hotkey fixture')
    Command-Upgrade 115
    Assert-Upgrade ((Read-Upgrade).profiles[0].applications[0].rules.Count -eq 1) 'Old build creates a distinct title-specific placement'
    Command-Upgrade 101
    [PinRealKeys]::ControlText($settings,$process.Id,202,'Ctrl+Alt+F11');[PinRealKeys]::ControlText($settings,$process.Id,204,'Ctrl+Alt+F12')
    Command-Upgrade 207
    Assert-Upgrade ((Status-Upgrade) -eq '设置已保存') 'Old build persists non-default hotkeys'
    $snapshot=Read-Upgrade;$primaryHash=Hash-Upgrade $configPath;$backupHash=Hash-Upgrade (Join-Path $configDir 'config.backup.json')
    $report['before_upgrade']=@{primary_hash=$primaryHash;backup_hash=$backupHash;profile_id=$snapshot.profiles[0].id;app_id=$snapshot.profiles[0].applications[0].app_id;default_id=$snapshot.profiles[0].applications[0].default.id;rule_id=$snapshot.profiles[0].applications[0].rules[0].preset.id}
    Stop-UpgradeApp
    $null=Move-Upgrade ($work.Left+640) ($work.Top+430) 450 350

    # Only this newly created program directory is overwritten; configuration
    # is a separate sibling and is never supplied to the archive extractor.
    $resolvedInstall=[IO.Path]::GetFullPath($installDir)
    if(-not $resolvedInstall.StartsWith($runDir+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Upgrade target escaped the owned run directory'}
    Expand-Archive -LiteralPath $PackagePath -DestinationPath $resolvedInstall -Force
    Assert-Upgrade ((Hash-Upgrade $installedExe) -eq $report.current_sha256) 'Overwritten installed EXE matches the current Release'
    Assert-Upgrade ((Hash-Upgrade $configPath) -eq $primaryHash -and (Hash-Upgrade (Join-Path $configDir 'config.backup.json')) -eq $backupHash) 'ZIP overwrite preserves primary and backup configuration bytes'
    Start-UpgradeApp
    Assert-Upgrade ((Hash-Upgrade $configPath) -eq $primaryHash -and (Hash-Upgrade (Join-Path $configDir 'config.backup.json')) -eq $backupHash) 'New-build startup preserves existing configuration and backup bytes'
    $status=[PinRealKeys]::Text($settings,208)
    Assert-Upgrade ($status -match '恢复 Ctrl\+Alt\+F11：已注册' -and $status -match '记住 Ctrl\+Alt\+F12：已注册') 'Upgraded build registers the saved custom mapping'
    Restore-Upgrade $ruleFrame 'old title rule after upgrade'
    Assert-Upgrade ((Status-Upgrade) -match '标题包含“isolated real hotkey fixture”') 'Upgraded restore identifies the matching old title rule'
    [PinRealKeys]::FixtureTitle('Screen Pin upgrade unmatched title '+[Guid]::NewGuid().ToString('N'))
    Restore-Upgrade $defaultFrame 'old app default after title fallback'
    Assert-Upgrade ((Status-Upgrade) -match '应用默认') 'Changed title falls back to the preserved shared default'
    $null=Move-Upgrade ($work.Left+450) ($work.Top+320) 790 570
    [PinRealKeys]::Chord(0x7b)
    Wait-Upgrade {(Read-Upgrade).revision -gt $snapshot.revision -and (Status-Upgrade) -match '^已记住'} 'upgraded real custom-key update'
    Command-Upgrade 401
    Wait-Upgrade {(Status-Upgrade) -match '已撤销'} 'upgraded undo'
    $afterUndo=Read-Upgrade
    Assert-Upgrade (($afterUndo.profiles[0].applications[0].default.placement|ConvertTo-Json -Depth 8 -Compress) -ceq ($snapshot.profiles[0].applications[0].default.placement|ConvertTo-Json -Depth 8 -Compress)) 'Upgraded update can be undone back to the exact old placement'
    Assert-Upgrade ($afterUndo.profiles[0].applications[0].default.id -eq $snapshot.profiles[0].applications[0].default.id -and $afterUndo.profiles[0].applications[0].rules[0].preset.id -eq $snapshot.profiles[0].applications[0].rules[0].preset.id) 'Preset identities survive upgrade, update and undo'
    Restore-Upgrade $defaultFrame 'restored old default after upgraded undo'
    Stop-UpgradeApp
    foreach($key in @(0x7a,0x7b)){Assert-Upgrade ([PinRealKeys]::Block([ushort]$key)) 'Upgraded normal exit releases its configured hotkey';[PinRealKeys]::Unblock([ushort]$key)}
}catch{$report.errors+=$_.Exception.Message}
finally{
    try{Stop-UpgradeApp}catch{$report.errors+=('App cleanup: '+$_.Exception.Message)}
    try{[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)}
    $report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
    if(-not $report.startup_registry_unchanged){$report.errors+='User Run registry unexpectedly changed'}
    $report['finished_utc']=[DateTime]::UtcNow.ToString('o')
    $report.passed=$report.errors.Count -eq 0 -and $report.restores.Count -eq 3 -and $report.normal_exits.Count -eq 2
    $report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8
    Write-Host ('Upgrade smoke report: '+(Join-Path $runDir 'report.json'))
}
if(-not $report.passed){exit 1}
