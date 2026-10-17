#Requires -Version 7.0
param(
    [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/races'),
    [string]$UiaProbePath=(Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe')
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName
$UiaProbePath=(Get-Item -LiteralPath $UiaProbePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('race-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'config')).FullName
$configPath=Join-Path $configDir 'config.json'
$helperPaths=@((Join-Path $PSScriptRoot 'support/real-keys.cs'),(Join-Path $PSScriptRoot 'support/application-native.cs'),(Join-Path $PSScriptRoot 'support/race-sentinel.cs'))
foreach($path in $helperPaths){Add-Type -Path $path}
$report=[ordered]@{
    started_utc=[DateTime]::UtcNow.ToString('o');exe_path=$ExePath;exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash
    script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;helpers=@($helperPaths|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}})
    config_dir=$configDir;checks=@();cases=@();errors=@();normal_exit=$false;passed=$false
    scope='Real F9 on owned primary fixture, prove busy before deliberate switch to an independent owned sentinel; fixture delay/close/rebuild uses its private messages. No WM_HOTKEY injection or user window mutation.'
    limitations=@('One local desktop/current DPI; standard fixtures, not all real application timing or physical hotplug cases.','Replacement uses the same process/class/title; actual numeric HWND reuse is recorded, not forced or claimed.','Posted placement may arrive late on the original target; absence of a success result does not imply cancellation.','Foreground and input cannot be locked atomically; an observed external switch cancels further input.')
}
$process=$null;$settings=[IntPtr]::Zero;$hostWindow=[IntPtr]::Zero
$sentinelTitle='Screen Pin race sentinel '+[Guid]::NewGuid().ToString('N')
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-Race($condition,[string]$message){if(-not $condition){throw $message};$report.checks+=$message}
function Read-Race {Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json}
function Hash-Race {(Get-FileHash -LiteralPath $configPath).Hash}
function Status-Race {[PinRealKeys]::Text($settings,138)}
function Frame-Race([IntPtr]$handle){$value=[PinApplication+Rect]::new();if([PinApplication]::DwmGetWindowAttribute($handle,9,[ref]$value,16) -ne 0){throw 'DWM frame query failed'};return @{left=$value.Left;top=$value.Top;right=$value.Right;bottom=$value.Bottom}}
function Class-Race([IntPtr]$handle){$value=[Text.StringBuilder]::new(256);[PinApplication]::GetClassNameW($handle,$value,$value.Capacity)|Out-Null;return $value.ToString()}
function Title-Race([IntPtr]$handle){$value=[Text.StringBuilder]::new(32768);[PinApplication]::GetWindowTextW($handle,$value,$value.Capacity)|Out-Null;return $value.ToString()}
function Error-Race($a,$b){$errorPx=0;foreach($edge in @('left','top','right','bottom')){$errorPx=[Math]::Max($errorPx,[Math]::Abs($a[$edge]-$b[$edge]))};return $errorPx}
function Wait-Race([scriptblock]$condition,[string]$description,[string]$foreground='primary',[int]$timeout=4000){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{
        if($foreground -eq 'primary'){[PinRealKeys]::AssertForeground()}elseif($foreground -eq 'sentinel'){[PinRaceSentinel]::AssertForeground()}
        if(& $condition){return};Start-Sleep -Milliseconds 5
    }while($watch.ElapsedMilliseconds -lt $timeout)
    throw ('Timeout: '+$description+'; '+(Status-Race))
}
function Confirm-RaceProcess {
    $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
    if(-not $owner -or $owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains('"'+$configDir+'"')){throw 'Test app process/config ownership changed'}
}
function Command-Race([int]$id){Confirm-RaceProcess;[PinRealKeys]::Command($settings,$process.Id,$id);Wait-Race {(Status-Race) -ne '正在处理…'} ('command '+$id) 'sentinel'}
function Move-RacePrimary([int]$x,[int]$y){$expected=[PinRealKeys]::Move($x,$y,520,360);Wait-Race {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$expected) -le 2} 'primary displacement';return Frame-Race ([PinRealKeys]::Fixture)}
function Activate-RacePrimary {
    [PinRaceSentinel]::AssertForeground()
    [PinApplication]::SetForegroundWindow([PinRealKeys]::Fixture)|Out-Null
    Wait-Race {$current=[PinRealKeys]::GetForegroundWindow();if($current -ne [IntPtr]::Zero -and $current -ne [PinRaceSentinel]::Window -and $current -ne [PinRealKeys]::Fixture){throw 'External foreground switch observed; further input cancelled'};$current -eq [PinRealKeys]::Fixture} 'intentional primary activation' 'none' 500
    [PinRealKeys]::AssertForeground()
}
function Issue-Race([int]$operation,[int]$delay,[bool]$duplicateRemember=$false){
    $script:raceStartedTicks=[Diagnostics.Stopwatch]::GetTimestamp()
    [PinRealKeys]::Schedule($operation,$delay)
    Wait-Race {-not [PinRealKeys]::Responsive([PinRealKeys]::Fixture)} 'confirmed primary pause'
    [PinRealKeys]::Chord(0x78)
    Wait-Race {-not [PinRealKeys]::Enabled($settings,$process.Id,109)} 'real restore occupies operation slot'
    $script:busyTicks=[Diagnostics.Stopwatch]::GetTimestamp();$script:busyRememberRejected=$false
    Assert-Race $true 'Real restore was submitted before the intentional foreground switch'
    if($duplicateRemember){
        [PinRealKeys]::Chord(0x79)
        Wait-Race {(Status-Race) -match '^正在处理上一项'} 'busy real F10 refusal'
        $script:busyRememberRejected=$true
        Assert-Race $true 'Real F10 while busy is explicitly refused'
    }
    [PinRealKeys]::AssertForeground();[PinRaceSentinel]::Activate([PinRealKeys]::Fixture)
    $script:switchedTicks=[Diagnostics.Stopwatch]::GetTimestamp()
}
function Trace-Race($result,[string]$configHash){
    Wait-Race {[PinRealKeys]::ActionAppliedTicks() -gt 0} 'fixture transition timestamp' 'sentinel'
    $applied=[PinRealKeys]::ActionAppliedTicks();$scale=1000.0/[Diagnostics.Stopwatch]::Frequency
    Assert-Race ($script:busyTicks -lt $script:switchedTicks -and $script:switchedTicks -lt $applied) 'Busy was observed before the foreground switch, and switch preceded the fixture transition'
    $result['busy_after_ms']=($script:busyTicks-$script:raceStartedTicks)*$scale
    $result['foreground_switched_after_ms']=($script:switchedTicks-$script:raceStartedTicks)*$scale
    $result['fixture_transition_after_ms']=($applied-$script:raceStartedTicks)*$scale
    $result['busy_real_remember_refused']=$script:busyRememberRejected
    $result['fixture_saw_busy_before_transition']=[PinRealKeys]::ActionSawBusy() -eq 1
    if($result.case -in @('destroy-and-rebuild','target-closed')){Assert-Race $result.fixture_saw_busy_before_transition 'The fixture directly observed the operation slot busy immediately before destruction'}
    $result['config_hash_before']=$configHash;$result['config_hash_after']=Hash-Race
    $result['sentinel_before']=$sentinelBaseline;$result['sentinel_after']=Frame-Race ([PinRaceSentinel]::Window)
}
function Await-RaceResult {
    $watch=[Diagnostics.Stopwatch]::StartNew();$responses=0
    do{
        [PinRaceSentinel]::AssertForeground()
        if(-not [PinRealKeys]::Responsive($hostWindow) -or -not [PinRealKeys]::Responsive($settings)){throw 'Host/settings did not respond during the race'}
        $responses++
        if([PinRealKeys]::Enabled($settings,$process.Id,109) -and (Status-Race) -notmatch '^正在处理'){break}
        Start-Sleep -Milliseconds 5
    }while($watch.ElapsedMilliseconds -lt 2000)
    $status=Status-Race
    Assert-Race ($watch.ElapsedMilliseconds -lt 2000 -and [PinRealKeys]::Enabled($settings,$process.Id,109) -and $status -notmatch '^已恢复|^已符合预设') 'Interrupted restore releases the slot with an honest non-success result'
    return @{status=$status;observation_elapsed_ms=$watch.Elapsed.TotalMilliseconds;responsive_samples=$responses}
}
function Stop-RaceApp {
    if($null -eq $process){return};$process.Refresh();if($process.HasExited){return};Confirm-RaceProcess
    if($hostWindow -eq [IntPtr]::Zero){$hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);if($hosts.Length -eq 1){$script:hostWindow=$hosts[0]}else{$process.Kill();$process.WaitForExit();throw 'Verified test app had no exit host and was forcibly cleaned up'}}
    [uint32]$owner=0;[PinRealKeys]::GetWindowThreadProcessId($hostWindow,[ref]$owner)|Out-Null
    if($owner -ne $process.Id){throw 'Exit host ownership mismatch'}
    [PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null
    if(-not $process.WaitForExit(8000)){Confirm-RaceProcess;$process.Kill();$process.WaitForExit();throw 'Verified test app forcibly cleaned up after normal exit timeout'}
    $report.normal_exit=$process.ExitCode -eq 0;$script:process=$null
}
try{
    if([PinRealKeys]::FindClass('ScreenPin.Host',0).Length){throw 'Existing Screen Pin instance detected; no input or mutation made'}
    $process=Start-Process -FilePath $ExePath -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    $deadline=[DateTime]::UtcNow.AddSeconds(8)
    $ready=$false
    do{
        $hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);$windows=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id)
        if($hosts.Length -eq 1){$hostWindow=$hosts[0]};if($windows.Length -eq 1){$settings=$windows[0]}
        if($hostWindow -ne [IntPtr]::Zero -and $settings -ne [IntPtr]::Zero){try{if([PinRealKeys]::Text($settings,138) -notin @('','正在处理…')){$ready=$true;break}}catch{}}
        Start-Sleep -Milliseconds 20
    }while([DateTime]::UtcNow -lt $deadline)
    if(-not $ready){throw 'Test settings not ready'}
    Confirm-RaceProcess
    $status=[PinRealKeys]::Text($settings,208)
    Assert-Race (([regex]::Matches($status,'已注册')).Count -eq 2 -and $status -notmatch '不可用') 'Both real hotkeys are registered by the test instance'
    $primary=[PinRealKeys]::StartFixture();[PinRaceSentinel]::Start($sentinelTitle)
    if([PinRealKeys]::GetForegroundWindow() -ne $primary){$input=Join-Path $runDir 'focus-input.json';$output=Join-Path $runDir 'focus-output.json';ConvertTo-Json -InputObject @(@{handle=$primary.ToInt64();id=0;page='activation'})|Set-Content -LiteralPath $input -Encoding utf8;& $UiaProbePath $input $output $PID --focus;if($LASTEXITCODE -ne 0){throw 'Initial public UIA focus failed'}}
    [PinRealKeys]::AssertForeground();[PinRaceSentinel]::AssertOwned()
    [PinRealKeys]::ObserveActions($settings,$process.Id)
    $before=Read-Race;[PinRealKeys]::Chord(0x79)
    Wait-Race {(Read-Race).revision -gt $before.revision -and (Status-Race) -match '^已记住'} 'initial real F10 capture'
    $saved=Frame-Race $primary;$sentinelBaseline=Frame-Race ([PinRaceSentinel]::Window)

    $displaced=Move-RacePrimary 550 420;$hash=Hash-Race
    Issue-Race 0x8044 1200 $true
    $result=Await-RaceResult
    Wait-Race {[PinRealKeys]::Responsive($primary)} 'original target resumes' 'sentinel'
    Wait-Race {(Error-Race (Frame-Race $primary) $saved) -le 2} 'late original-target placement' 'sentinel'
    Assert-Race ((Error-Race (Frame-Race ([PinRaceSentinel]::Window)) $sentinelBaseline) -eq 0 -and (Hash-Race) -eq $hash) 'Foreground switch moves only the original target; sentinel and config remain unchanged'
    $result['case']='switch-with-late-original-placement';Trace-Race $result $hash
    $result['target_before']=$displaced;$result['target_after']=Frame-Race $primary;$report.cases+=$result

    Activate-RacePrimary
    $null=Move-RacePrimary 600 450;$hash=Hash-Race;$oldHandle=[PinRealKeys]::Fixture
    $oldClass=Class-Race $oldHandle;$oldTitle=Title-Race $oldHandle
    Issue-Race 0x8046 180
    $result=Await-RaceResult
    Wait-Race {[PinRealKeys]::Rebuilt()} 'same-process/class/title replacement' 'sentinel'
    $newHandle=[PinRealKeys]::Fixture
    [uint32]$newPid=0;[PinRealKeys]::GetWindowThreadProcessId($newHandle,[ref]$newPid)|Out-Null
    Assert-Race ((Class-Race $newHandle) -ceq $oldClass -and (Title-Race $newHandle) -ceq $oldTitle -and $newPid -eq $PID) 'Replacement has the same native class, title and process as the old target'
    Start-Sleep -Milliseconds 120;[PinRaceSentinel]::AssertForeground()
    $outer=[PinApplication+Rect]::new();[PinApplication]::GetWindowRect($newHandle,[ref]$outer)|Out-Null
    Assert-Race ($outer.Left -eq 850 -and $outer.Top -eq 760 -and $outer.Right -eq 1470 -and $outer.Bottom -eq 1190) 'Replacement retains its deliberately different initial rectangle'
    Assert-Race ((Error-Race (Frame-Race ([PinRaceSentinel]::Window)) $sentinelBaseline) -eq 0 -and (Hash-Race) -eq $hash) 'Rebuild does not redirect the stale operation to replacement or sentinel'
    $result['case']='destroy-and-rebuild';Trace-Race $result $hash
    $result['class']=$oldClass;$result['title']=$oldTitle;$result['process_id']=$newPid
    $result['old_hwnd']=$oldHandle.ToInt64();$result['replacement_hwnd']=$newHandle.ToInt64();$result['same_numeric_hwnd']=$oldHandle -eq $newHandle;$result['replacement_outer']=$outer;$report.cases+=$result

    Activate-RacePrimary
    $before=Read-Race;[PinRealKeys]::Chord(0x79)
    Wait-Race {(Read-Race).revision -gt $before.revision -and (Status-Race) -match '^已记住'} 'fresh replacement generation accepts real F10'
    $replacementSaved=Frame-Race $newHandle
    $null=Move-RacePrimary 620 420
    [PinRealKeys]::Chord(0x78)
    Wait-Race {(Error-Race (Frame-Race $newHandle) $replacementSaved) -le 2 -and (Status-Race) -match '^已恢复|^已符合预设'} 'fresh replacement restores'
    Assert-Race ((Error-Race (Frame-Race ([PinRaceSentinel]::Window)) $sentinelBaseline) -eq 0) 'Fresh generation remains usable without touching the sentinel'

    $null=Move-RacePrimary 580 390;$hash=Hash-Race;$closing=[PinRealKeys]::Fixture
    Issue-Race 0x8045 180
    $result=Await-RaceResult
    Wait-Race {-not [PinApplication]::IsWindow($closing)} 'target closed during restore' 'sentinel'
    Assert-Race ((Error-Race (Frame-Race ([PinRaceSentinel]::Window)) $sentinelBaseline) -eq 0 -and (Hash-Race) -eq $hash) 'Closing the queued target leaves the sentinel and config unchanged'
    $result['case']='target-closed';Trace-Race $result $hash
    $result['closed_hwnd']=$closing.ToInt64();$report.cases+=$result

    Command-Race 109
    [PinRealKeys]::SelectWindow($settings,$process.Id,$sentinelTitle)
    Command-Race 111
    Assert-Race ((Status-Race) -match '^已记住') 'Next explicit command can capture the surviving sentinel'
    [PinRaceSentinel]::AssertForeground();$hash=Hash-Race
    [PinApplication]::SetWindowPos([PinRaceSentinel]::Window,[IntPtr]::Zero,1000,600,510,360,0x4014)|Out-Null
    Wait-Race {(Error-Race (Frame-Race ([PinRaceSentinel]::Window)) $sentinelBaseline) -gt 20} 'sentinel displacement for follow-up restore' 'sentinel'
    Command-Race 112
    Assert-Race ((Error-Race (Frame-Race ([PinRaceSentinel]::Window)) $sentinelBaseline) -le 2 -and (Hash-Race) -eq $hash -and (Status-Race) -match '^已恢复|^已符合预设') 'Operation slot remains usable for another window after target closure'
    Stop-RaceApp
}catch{$report.errors+=$_.Exception.Message}
finally{
    try{Stop-RaceApp}catch{$report.errors+=('App cleanup: '+$_.Exception.Message)}
    try{[PinRealKeys]::StopFixture();[PinRaceSentinel]::Stop()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)}
    $report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
    if(-not $report.startup_registry_unchanged){$report.errors+='User Run registry unexpectedly changed'}
    $report['finished_utc']=[DateTime]::UtcNow.ToString('o')
    $report.passed=$report.errors.Count -eq 0 -and $report.cases.Count -eq 3 -and $report.normal_exit
    $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8
    Write-Host ('Race smoke report: '+(Join-Path $runDir 'report.json'))
}
if(-not $report.passed){exit 1}
