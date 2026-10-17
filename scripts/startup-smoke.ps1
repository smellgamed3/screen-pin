#Requires -Version 7.0
param(
    [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/startup'),
    [string]$UiaProbePath=(Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe'),
    [ValidateRange(2,30)][int]$ExistingRuns=10,
    [ValidateRange(1,15)][int]$FirstRuns=5
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName
$UiaProbePath=(Get-Item -LiteralPath $UiaProbePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('startup-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$helpers=@((Join-Path $PSScriptRoot 'support/real-keys.cs'),(Join-Path $PSScriptRoot 'support/desktop-keyboard.cs'),(Join-Path $PSScriptRoot 'support/startup-native.cs'))
Add-Type -Path $helpers
$os=Get-CimInstance Win32_OperatingSystem
$driveId=[IO.Path]::GetPathRoot($ExePath).TrimEnd('\')
$diskInfo=@{drive=$driveId;filesystem=$null;disk_models=@();interfaces=@()}
if($driveId -match '^[A-Za-z]:$'){$logical=Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='"+$driveId+"'");$partitions=Get-CimAssociatedInstance -InputObject $logical -Association Win32_LogicalDiskToPartition;$devices=@($partitions|ForEach-Object {Get-CimAssociatedInstance -InputObject $_ -Association Win32_DiskDriveToDiskPartition});$diskInfo.filesystem=$logical.FileSystem;$diskInfo.disk_models=@($devices.Model);$diskInfo.interfaces=@($devices.InterfaceType)}
$sourceVersion=[regex]::Match((Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Cargo.toml') -Raw),'(?m)^version = "([^"]+)"').Groups[1].Value
$report=[ordered]@{
    started_utc=[DateTime]::UtcNow.ToString('o');exe_path=$ExePath;exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash
    helpers=@($helpers|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}});uia_probe_sha256=(Get-FileHash -LiteralPath $UiaProbePath).Hash
    source_package_version=$sourceVersion;binary_file_version=(Get-Item -LiteralPath $ExePath).VersionInfo.FileVersion
    environment=@{os=$os.Caption;version=$os.Version;architecture=$os.OSArchitecture;cpu=(Get-CimInstance Win32_Processor|Select-Object -First 1 -ExpandProperty Name);powershell=$PSVersionTable.PSVersion.ToString();disk=$diskInfo}
    requested_existing_runs=$ExistingRuns;requested_first_runs=$FirstRuns;existing=@();first=@();checks=@();normal_exits=@();errors=@();passed=$false
    definitions=@{
        timer='Stopwatch starts immediately before Start-Process; includes process launch, test polling and input/feedback observation overhead.'
        existing='Ordinary launch with an existing config, no --show/--background, until PID-owned Host icon HWND/uID=1 has a Shell_NotifyIconGetRect rectangle and both actual F9 restore and F10 no-op complete; hidden settings and unchanged config/backup required. Upper bound on readiness, budget 1000 ms.'
        first='Empty config, no --show/--background; first UI must appear automatically, accept Tab/Home/arrow selection of the owned fixture, then Tab/Space capture and persist its correct geometry. Budget 1500 ms includes successful capture confirmation.'
    }
    limitations=@('Single local desktop/current DPI; repeated cached launches, not cold boot or other machines.','Large fixture is private synthetic JSON (20 applications/60 title rules), not 20 concurrently running real applications.','Shell icon rectangle proves the registered icon can be located; does not require pinned visibility or measure rendered pixels.','Initial public UIA focus applies only to the owned fixture, before timed launches; any later observed external foreground switch aborts input.','First-use automation is functional/timing evidence, not an independent new-user usability test.')
}
$process=$null;$hostWindow=[IntPtr]::Zero;$settings=[IntPtr]::Zero;$configDir='';$configPath='';$watch=$null;$iconMs=$null;$registrationMs=$null;$iconRect=$null
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-Start($condition,[string]$message){if(-not $condition){throw $message};$report.checks+=$message}
function Status-Start {[PinRealKeys]::Text($settings,138)}
function Hash-Start([string]$path){(Get-FileHash -LiteralPath $path).Hash}
function Read-Start {Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json}
function Copy-Start($value){return $value|ConvertTo-Json -Depth 24|ConvertFrom-Json}
function Wait-Start([scriptblock]$condition,[string]$description,[string]$foreground='fixture'){
    $wait=[Diagnostics.Stopwatch]::StartNew()
    do{
        if($foreground -eq 'fixture'){[PinRealKeys]::AssertForeground()}elseif($foreground -eq 'settings'){[PinDesktopKeyboard]::AssertForeground($settings,$process.Id)}
        try{if(& $condition){return}}catch{if($_.Exception.Message -notmatch 'Timed out reading own app result'){throw};$report['transient_status_reads']=1+$report.transient_status_reads}
        Start-Sleep -Milliseconds 5
    }while($wait.ElapsedMilliseconds -lt 8000)
    throw ('Timeout: '+$description)
}
function Confirm-Start {$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id);if(-not $owner -or $owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains('"'+$configDir+'"')){throw 'Launched process/config ownership changed'}}
function Focus-StartFixture {
    if([PinRealKeys]::GetForegroundWindow() -ne [PinRealKeys]::Fixture){
        $inputPath=Join-Path $runDir 'focus-input.json';$outputPath=Join-Path $runDir 'focus-output.json'
        ConvertTo-Json -InputObject @(@{handle=[PinRealKeys]::Fixture.ToInt64();id=0;page='activation'})|Set-Content -LiteralPath $inputPath -Encoding utf8
        $reader=Start-Process -FilePath $UiaProbePath -ArgumentList ('"'+$inputPath+'"'),('"'+$outputPath+'"'),$PID,'--focus' -WindowStyle Hidden -PassThru
        if(-not $reader.WaitForExit(15000)){$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$reader.Id);if($owner.ExecutablePath -ieq $UiaProbePath -and $owner.CommandLine.Contains($inputPath)){$reader.Kill();$reader.WaitForExit()};throw 'Owned initial UIA focus timed out'}
        if($reader.ExitCode -ne 0){throw 'Owned initial UIA focus failed'}
        Wait-Start {[PinRealKeys]::GetForegroundWindow() -eq [PinRealKeys]::Fixture} 'owned initial foreground' 'none'
    }
    [PinRealKeys]::AssertForeground()
}
function Start-Instance([string]$dir,[bool]$expectBackground,[bool]$suppressFirstUI=$false){
    Assert-Start ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) 'No existing instance competes with the timed launch'
    $script:configDir=$dir;$script:configPath=Join-Path $dir 'config.json';$script:hostWindow=[IntPtr]::Zero;$script:settings=[IntPtr]::Zero;$script:iconMs=$null;$script:registrationMs=$null;$script:iconRect=$null
    $launchArgs=@('--config-dir',('"'+$configDir+'"'));if($suppressFirstUI){$launchArgs+=@('--background')};$script:launchArguments=$launchArgs
    $script:watch=[Diagnostics.Stopwatch]::StartNew()
    $script:process=Start-Process -FilePath $ExePath -ArgumentList $launchArgs -WindowStyle Hidden -PassThru
    Wait-Start {
        $hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);$windows=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id)
        if($hosts.Count -eq 1){$script:hostWindow=$hosts[0]};if($windows.Count -eq 1){$script:settings=$windows[0]}
        if($hostWindow -eq [IntPtr]::Zero -or $settings -eq [IntPtr]::Zero){return $false}
        if($null -eq $script:iconMs){try{$rect=[PinDesktopKeyboard]::IconRect($hostWindow,$process.Id);if($rect.Right -gt $rect.Left -and $rect.Bottom -gt $rect.Top){$script:iconMs=$watch.Elapsed.TotalMilliseconds;$script:iconRect=$rect}}catch{if($_.Exception.Message -notmatch 'rectangle is unavailable'){throw}}}
        $registration=[PinRealKeys]::Text($settings,208)
        if($null -eq $script:registrationMs -and ([regex]::Matches($registration,'已注册')).Count -eq 2 -and $registration -notmatch '不可用'){$script:registrationMs=$watch.Elapsed.TotalMilliseconds}
        return $null -ne $script:iconMs -and $null -ne $script:registrationMs -and [PinRealKeys]::Responsive($hostWindow) -and (Status-Start) -notin @('','正在处理…')
    } 'owned icon, bindings and message loop ready' $(if($expectBackground){'fixture'}else{'none'})
}
function Stop-Instance {
    if($null -eq $process){return};$process.Refresh();if($process.HasExited){return};Confirm-Start
    if($hostWindow -eq [IntPtr]::Zero){$hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);if($hosts.Count -eq 1){$script:hostWindow=$hosts[0]}}
    if([PinDesktopKeyboard]::Owner($hostWindow) -eq $process.Id){[PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null}
    if(-not $process.WaitForExit(8000)){Confirm-Start;$process.Kill();$process.WaitForExit();throw 'Verified app required forced cleanup'}
    Assert-Start ($process.ExitCode -eq 0) 'Timed test instance exited normally';$report.normal_exits+=@{pid=$process.Id;exit_code=$process.ExitCode};$script:process=$null
}
function Press-StartUI([int]$key){[PinDesktopKeyboard]::Press($settings,$process.Id,$key,0);Start-Sleep -Milliseconds 10;[PinDesktopKeyboard]::AssertForeground($settings,$process.Id)}
function Tab-StartUI([int]$id){for($step=0;$step -lt 40;$step++){$previous=[PinDesktopKeyboard]::FocusId($settings,$process.Id);if($previous -eq $id){return};Press-StartUI 9;Wait-Start {[PinDesktopKeyboard]::FocusId($settings,$process.Id) -ne $previous} 'Tab has actually changed focus' 'settings'};throw ('First UI cannot Tab to '+$id)}
function Percentile-Start($values){$ordered=@($values|Sort-Object);return $ordered[[Math]::Ceiling($ordered.Count*0.95)-1]}
try{
    Assert-Start ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) 'No existing Screen Pin instance; isolated configurations only'
    $null=[PinRealKeys]::StartFixture();Focus-StartFixture
    $fixtureTitle='Screen Pin startup fixture '+[Guid]::NewGuid().ToString('N');[PinRealKeys]::FixtureTitle($fixtureTitle)
    $report.environment['dpi']=[PinRealKeys]::FixtureDpi();$report.environment['work_area']=[PinRealKeys]::Work()
    Assert-Start ([PinRealKeys]::Block(0x78)) 'Restore key is free before all timed launches';[PinRealKeys]::Unblock(0x78)
    Assert-Start ([PinRealKeys]::Block(0x79)) 'Remember key is free before all timed launches';[PinRealKeys]::Unblock(0x79)
    $seedDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'seed')).FullName
    Start-Instance $seedDir $true $true
    [PinRealKeys]::Chord(0x79)
    Wait-Start {(Status-Start) -match '^已记住'} 'seed real capture'
    $baselineFrame=[PinRealKeys]::Frame()
    [PinRealKeys]::SelectWindow($settings,$process.Id,$fixtureTitle)
    foreach($keyword in @('StartupAlpha','StartupBeta')){[PinRealKeys]::ControlText($settings,$process.Id,114,$keyword);[PinRealKeys]::Command($settings,$process.Id,115);Wait-Start {(Status-Start) -match '^已创建标题规则'} 'seed rule capture'}
    $seed=Read-Start;Stop-Instance
    $large=Copy-Start $seed
    $extra=Copy-Start $large.profiles[0].applications[0].rules[0];$extra.keyword='StartupGamma';$extra.preset.id='startup-'+[Guid]::NewGuid().ToString('N');$large.profiles[0].applications[0].rules+=@($extra)
    for($index=1;$index -lt 20;$index++){$app=Copy-Start $large.profiles[0].applications[0];$app.app_id='exe:d:\screen-pin-startup-fixtures\app-'+$index+'.exe';$app.app_name='Startup app '+$index;$app.default.id='startup-'+[Guid]::NewGuid().ToString('N');foreach($rule in $app.rules){$rule.preset.id='startup-'+[Guid]::NewGuid().ToString('N')};$large.profiles[0].applications+=@($app)}
    foreach($layout in @(@{name='small';data=$seed},@{name='daily-20';data=$large})){
        $dir=(New-Item -ItemType Directory -Path (Join-Path $runDir $layout.name)).FullName
        $text=$layout.data|ConvertTo-Json -Depth 24;[IO.File]::WriteAllText((Join-Path $dir 'config.json'),$text);[IO.File]::WriteAllText((Join-Path $dir 'config.backup.json'),$text)
        $report['layouts']+=@(@{name=$layout.name;directory=$dir;bytes=(Get-Item -LiteralPath (Join-Path $dir 'config.json')).Length;profiles=$layout.data.profiles.Count;applications=$layout.data.profiles[0].applications.Count;rules=@($layout.data.profiles[0].applications.rules).Count})
    }
    for($index=0;$index -lt $ExistingRuns;$index++){
        Focus-StartFixture;$expected=[PinRealKeys]::Move(490+($index%3)*35,350,580,410)
        Wait-Start {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$expected) -le 2} 'fixture displacement before launch'
        $name=if($index%2 -eq 0){'small'}else{'daily-20'};$dir=Join-Path $runDir $name
        $primaryHash=Hash-Start (Join-Path $dir 'config.json');$backupHash=Hash-Start (Join-Path $dir 'config.backup.json')
        Start-Instance $dir $true
        [PinRealKeys]::Chord(0x78)
        Wait-Start {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$baselineFrame) -le 2 -and (Status-Start) -match '^已恢复|^已符合预设'} 'startup real F9 confirmation'
        $restoreMs=$watch.Elapsed.TotalMilliseconds;$restoreStatus=Status-Start
        [PinRealKeys]::Chord(0x79)
        Wait-Start {(Status-Start) -match '^位置未变化'} 'startup real F10 confirmation'
        $completeMs=$watch.Elapsed.TotalMilliseconds
        $primaryAfter=Hash-Start $configPath;$backupAfter=Hash-Start (Join-Path $dir 'config.backup.json')
        $sample=@{case=$name;iteration=$index+1;arguments=$launchArguments;icon_observed_ms=$iconMs;bindings_reported_ms=$registrationMs;f9_confirmed_ms=$restoreMs;both_hotkeys_and_icon_ms=$completeMs;icon_rectangle=$iconRect;restore_status=$restoreStatus;remember_status=Status-Start;edge_error_px=[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$baselineFrame);settings_hidden=-not [PinDesktopKeyboard]::IsWindowVisible($settings);config_unchanged=$primaryAfter -eq $primaryHash;backup_unchanged=$backupAfter -eq $backupHash;config_hash_before=$primaryHash;config_hash_after=$primaryAfter;backup_hash_before=$backupHash;backup_hash_after=$backupAfter;within_budget=$completeMs -le 1000}
        $report.existing+=$sample
        Confirm-Start
        Assert-Start ($sample.settings_hidden -and $sample.config_unchanged -and $sample.backup_unchanged -and $sample.edge_error_px -le 2) ($name+': real startup actions preserve foreground, configuration and backup')
        Assert-Start $sample.within_budget ($name+': both actual hotkeys and owned icon confirmed within 1000 ms')
        Stop-Instance
    }
    for($index=0;$index -lt $FirstRuns;$index++){
        Focus-StartFixture;$dir=(New-Item -ItemType Directory -Path (Join-Path $runDir ('first-'+$index))).FullName
        Assert-Start (-not (Test-Path -LiteralPath (Join-Path $dir 'config.json'))) 'First launch starts with no configuration'
        Start-Instance $dir $false
        Wait-Start {[PinDesktopKeyboard]::IsWindowVisible($settings) -and [PinDesktopKeyboard]::GetForegroundWindow() -eq $settings} 'automatic first UI visibility/foreground' 'none'
        $visibleMs=$watch.Elapsed.TotalMilliseconds
        [PinDesktopKeyboard]::AssertForeground($settings,$process.Id)
        foreach($id in @(100,108,109,138)){Assert-Start ([PinStartupNative]::FullyVisible($settings,$process.Id,$id)) ('First UI control '+$id+' is fully visible')}
        $fixtureIndex=[PinStartupNative]::FixtureIndex($settings,$process.Id,$fixtureTitle)
        Assert-Start ($fixtureIndex -ge 0) 'Owned fixture is available on first UI without a manual refresh'
        Tab-StartUI 108;Press-StartUI 0x24
        Wait-Start {[PinStartupNative]::Selection($settings,$process.Id) -eq 0} 'Home has selected the first row' 'settings'
        for($step=0;$step -lt $fixtureIndex;$step++){Press-StartUI 0x28;Wait-Start {[PinStartupNative]::Selection($settings,$process.Id) -eq $step+1} 'Down has selected the next row' 'settings'}
        $report['last_selection']=@{expected=$fixtureIndex;actual=[PinStartupNative]::Selection($settings,$process.Id);enabled=[PinRealKeys]::Enabled($settings,$process.Id,111);focus=[PinDesktopKeyboard]::FocusId($settings,$process.Id)}
        Wait-Start {[PinStartupNative]::Selection($settings,$process.Id) -eq $fixtureIndex -and [PinRealKeys]::Enabled($settings,$process.Id,111)} 'selected fixture is acknowledged and capture enabled' 'settings'
        Assert-Start ([PinStartupNative]::Selection($settings,$process.Id) -eq $fixtureIndex -and [PinRealKeys]::Enabled($settings,$process.Id,111)) 'First UI accepts real keyboard selection and enables capture'
        $interactiveMs=$watch.Elapsed.TotalMilliseconds
        Tab-StartUI 111;Press-StartUI 0x20
        Wait-Start {(Status-Start) -match '^已记住'} 'first UI real Space capture persists' 'settings'
        $confirmedMs=$watch.Elapsed.TotalMilliseconds;$config=Read-Start;$placement=$config.profiles[0].applications[0].default.placement;$frame=[PinRealKeys]::Frame();$work=[PinRealKeys]::Work()
        $actual=@{left=$work.Left+$placement.rect.x*($work.Right-$work.Left);top=$work.Top+$placement.rect.y*($work.Bottom-$work.Top);right=$work.Left+($placement.rect.x+$placement.rect.width)*($work.Right-$work.Left);bottom=$work.Top+($placement.rect.y+$placement.rect.height)*($work.Bottom-$work.Top)}
        $errorPx=[Math]::Max([Math]::Max([Math]::Abs($actual.left-$frame.Left),[Math]::Abs($actual.top-$frame.Top)),[Math]::Max([Math]::Abs($actual.right-$frame.Right),[Math]::Abs($actual.bottom-$frame.Bottom)))
        $sample=@{iteration=$index+1;arguments=$launchArguments;automatic_visible_ms=$visibleMs;keyboard_selection_ms=$interactiveMs;capture_confirmed_ms=$confirmedMs;icon_observed_ms=$iconMs;fixture_index=$fixtureIndex;geometry_error_px=$errorPx;status=Status-Start;within_budget=$confirmedMs -le 1500}
        $report.first+=$sample
        Confirm-Start
        Assert-Start ($errorPx -le 2 -and $config.profiles[0].applications[0].app_id -eq $seed.profiles[0].applications[0].app_id) 'First UI captures the actual owned fixture geometry and application identity'
        Assert-Start $sample.within_budget 'Automatic first UI and completed keyboard capture fit within 1500 ms'
        Stop-Instance
    }
    Focus-StartFixture
    Assert-Start ([PinRealKeys]::Block(0x78)) 'Final exit releases restore key';[PinRealKeys]::Unblock(0x78)
    Assert-Start ([PinRealKeys]::Block(0x79)) 'Final exit releases remember key';[PinRealKeys]::Unblock(0x79)
    $report['existing_max_ms']=($report.existing.both_hotkeys_and_icon_ms|Measure-Object -Maximum).Maximum;$report['existing_p95_ms']=Percentile-Start $report.existing.both_hotkeys_and_icon_ms
    $report['first_max_ms']=($report.first.capture_confirmed_ms|Measure-Object -Maximum).Maximum;$report['first_p95_ms']=Percentile-Start $report.first.capture_confirmed_ms
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace;$report['failure_foreground_class']=[PinDesktopKeyboard]::Class([PinDesktopKeyboard]::GetForegroundWindow())}
finally{
    try{Stop-Instance}catch{$report.errors+=('Cleanup: '+$_.Exception.Message)}
    try{[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)}
    $report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
    if(-not $report.startup_registry_unchanged){$report.errors+='Startup registration changed'}
    $report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report.passed=$report.errors.Count -eq 0 -and $report.existing.Count -eq $ExistingRuns -and $report.first.Count -eq $FirstRuns -and $report.normal_exits.Count -eq (1+$ExistingRuns+$FirstRuns)
    $report|ConvertTo-Json -Depth 24|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8
    Write-Host ('Startup report: '+(Join-Path $runDir 'report.json'))
}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
