#Requires -Version 7.0
param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [ValidateRange(20, 500)][int]$Cycles = 100,
    [string]$UiaProbePath = (Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe')
)
$ErrorActionPreference = 'Stop'
$resolvedExe = (Resolve-Path -LiteralPath $ExePath).ProviderPath
$runDir = Join-Path ([IO.Path]::GetFullPath($OutputDir)) ('hotkey-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$configDir = Join-Path $runDir 'config'
[IO.Directory]::CreateDirectory($configDir) | Out-Null
$configPath = Join-Path $configDir 'config.json'
$reportPath = Join-Path $runDir 'report.json'
Add-Type -Path (Join-Path $PSScriptRoot 'support/real-keys.cs')

$report = [ordered]@{
    schema_version = 1
    started_utc = [DateTime]::UtcNow.ToString('o')
    scope = 'Real SendInput Ctrl+Alt+F10/F9 end-to-end on only the newly created fixture in a fresh isolated configuration; no WM_HOTKEY messages are injected.'
    exe_path = $resolvedExe
    exe_sha256 = (Get-FileHash -LiteralPath $resolvedExe -Algorithm SHA256).Hash.ToLowerInvariant()
    script_sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    helper_sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'support/real-keys.cs') -Algorithm SHA256).Hash.ToLowerInvariant()
    os_version = [Environment]::OSVersion.Version.ToString()
    config_dir = $configDir
    requested_cycles = $Cycles
    completed_cycles = 0
    input_method = 'SendInput keyboard sequences with foreground/ownership checks immediately before and after each sequence; no AttachThreadInput, injected Alt workaround, or foreground-policy bypass.'
    latency_definition = 'Stopwatch immediately before the validated SendInput wrapper until first polled DWM visible rectangle within two physical pixels; polls every five milliseconds. Includes desktop scheduling and test polling overhead.'
    restore_samples_ms = @()
    restore_p95_ms = $null
    completion_feedback_samples_ms = @()
    completion_feedback_p95_ms = $null
    completion_feedback_definition = 'Same stopwatch as visible-frame latency, continued until hidden configuration result text explicitly reports restored/already-correct; previous F10 persisted-success feedback has already been observed, so an old restore result cannot satisfy this wait.'
    successful_completion_feedback_cycles = 0
    last_success_result = $null
    max_edge_error_px = 0
    unconfigured_restore_verified = $false
    no_change_update_verified = $false
    long_hold_norepeat_verified = $false
    long_hold_definition = 'Hold Ctrl+Alt+F10, wait for the first persisted update, move only the fixture while keys remain down, then send 25 further F10 key-down events without key-up. One final update, unchanged saved placement, and unchanged success result establish suppression of repeated down events.'
    foreground_preserved = $false
    process_id = $null
    private_start_bytes = $null
    private_after_cycles_bytes = $null
    private_growth_bytes = $null
    cpu_delta_ms = $null
    normal_exit = $false
    exit_code = $null
    forced_cleanup = $false
    errors = @()
    feedback_read_timeouts = 0
    passed = $false
    limitations = @('One local desktop/display configuration and one synthetic standard Win32 fixture; does not validate real app compatibility, cross-DPI/multi-monitor p95, UAC, hardware typematic delivery, independent usability, or clean-machine installation.', 'Counter CPU/private-memory deltas are observations, not a leak proof or absolute CPU-instruction counts.', 'Foreground cannot be atomically locked together with Windows input dispatch; any observed mismatch aborts the run immediately, with only injected held-key releases permitted during emergency cleanup.')
}
$process = $null
$hostWindow = [IntPtr]::Zero
$settingsWindow = [IntPtr]::Zero

function Confirm-KeyProcess {
    $process.Refresh()
    if ($process.HasExited) { throw 'Isolated app exited unexpectedly.' }
    $actual = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $process.Id)
    if (-not $actual -or $actual.ExecutablePath -ine $resolvedExe -or
        -not $actual.CommandLine.Contains('"' + $configDir + '"') -or -not $actual.CommandLine.Contains('--background')) {
        throw 'Isolated executable/arguments no longer match; refusing process control.'
    }
}
function Key-Config { try { return [PinRealKeys]::ReadConfig($configPath)|ConvertFrom-Json } catch { return $null } }
function Key-Status { return [PinRealKeys]::Text($settingsWindow, 138) }
function Wait-Key([scriptblock]$Condition, [string]$Description, [int]$Timeout = 4000) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        [PinRealKeys]::AssertForeground()
        try {
            if (& $Condition) { [PinRealKeys]::AssertForeground(); return }
        } catch {
            if ($_.Exception.Message -notmatch 'Timed out reading own app result') { throw }
            $report.feedback_read_timeouts++
        }
        Start-Sleep -Milliseconds 5
    } while ($watch.ElapsedMilliseconds -lt $Timeout)
    throw ('Timed out: ' + $Description + '; app status: ' + (Key-Status))
}
function Move-KeyFixture([int]$X,[int]$Y,[int]$Width,[int]$Height) {
    $expected = [PinRealKeys]::Move($X,$Y,$Width,$Height)
    Wait-Key { [PinRealKeys]::EdgeError([PinRealKeys]::Frame(), $expected) -le 2 } 'owned fixture position'
    Start-Sleep -Milliseconds 25
    [PinRealKeys]::AssertForeground()
    return [PinRealKeys]::Frame()
}
function Stop-KeyApp {
    if ($null -eq $process) { return }
    $process.Refresh()
    if ($process.HasExited) { return }
    Confirm-KeyProcess
    [uint32]$owner = 0
    [PinRealKeys]::GetWindowThreadProcessId($hostWindow,[ref]$owner) | Out-Null
    if ($owner -ne $process.Id) { throw 'Exit host no longer belongs to the isolated process.' }
    if (-not [PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)) { throw 'Could not post normal exit.' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do { $process.Refresh();if($process.HasExited){$report.normal_exit=$true;$report.exit_code=$process.ExitCode;return};Start-Sleep -Milliseconds 30 } while($watch.ElapsedMilliseconds -lt 8000)
    Confirm-KeyProcess
    Stop-Process -InputObject $process -Force
    $report.forced_cleanup=$true
    throw 'Normal exit timed out; only the verified isolated process was forcibly cleaned up.'
}

try {
    if ([PinRealKeys]::FindClass('ScreenPin.Host',0).Length -ne 0) { throw 'An existing Screen Pin instance owns global hotkeys; no process was terminated and no input was sent.' }
    $process=Start-Process -FilePath $resolvedExe -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    $report.process_id=$process.Id
    $startup=[Diagnostics.Stopwatch]::StartNew()
    do {
        $hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id)
        $settings=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id)
        if($hosts.Length -eq 1 -and $settings.Length -eq 1 -and [PinRealKeys]::Responsive($hosts[0])){$hostWindow=$hosts[0];$settingsWindow=$settings[0];break}
        Start-Sleep -Milliseconds 20
    } while($startup.ElapsedMilliseconds -lt 8000)
    if($hostWindow -eq [IntPtr]::Zero){throw 'Own host/settings message loop not ready.'}
    Confirm-KeyProcess
    $keyStatus=[PinRealKeys]::Text($settingsWindow,208)
    if(([regex]::Matches($keyStatus,'已注册')).Count -ne 2 -or $keyStatus -match '未注册|不可用|失败|冲突'){throw ('Global hotkeys are not both available: '+$keyStatus)}
    $fixture=[PinRealKeys]::StartFixture()
    Start-Sleep -Milliseconds 120
    if([PinRealKeys]::GetForegroundWindow() -ne $fixture){
        $focusInput=Join-Path $runDir 'focus-input.json';$focusOutput=Join-Path $runDir 'focus-output.json'
        ConvertTo-Json -InputObject @(@{page='activation';id=0;handle=$fixture.ToInt64()})|Set-Content -LiteralPath $focusInput -Encoding utf8
        & $UiaProbePath $focusInput $focusOutput $PID --focus
        $report['uia_initial_focus_result']=$LASTEXITCODE
        if($LASTEXITCODE -ne 0){throw 'Public UIA activation could not focus the owned fixture.'}
        Start-Sleep -Milliseconds 100
    }
    [PinRealKeys]::AssertForeground()
    $work=[PinRealKeys]::Work()
    $report.fixture_work_area=$work
    $report.fixture_dpi=[PinRealKeys]::FixtureDpi()
    $workWidth=$work.Right-$work.Left;$workHeight=$work.Bottom-$work.Top
    $width=[Math]::Min(760,[int]($workWidth*0.6));$height=[Math]::Min(520,[int]($workHeight*0.6))
    $first=Move-KeyFixture ($work.Left+80) ($work.Top+90) $width $height
    $initial=Key-Config
    [PinRealKeys]::Chord(0x78)
    Wait-Key { (Key-Status) -match '尚未配置' } 'unconfigured F9 feedback'
    $after=Key-Config
    if($after.revision -ne $initial.revision -or [PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$first) -gt 2){throw 'Unconfigured F9 changed configuration or moved the fixture.'}
    $report.unconfigured_restore_verified=$true
    $process.Refresh();$report.private_start_bytes=$process.PrivateMemorySize64;$cpuStart=$process.TotalProcessorTime.TotalMilliseconds
    $samples=[Collections.Generic.List[double]]::new()
    $completionSamples=[Collections.Generic.List[double]]::new()
    $runWatch=[Diagnostics.Stopwatch]::StartNew();$lastProgress=0
    for($cycle=0;$cycle -lt $Cycles;$cycle++){
        $target=Move-KeyFixture ($work.Left+80+($cycle%5)*19) ($work.Top+90+($cycle%3)*17) ($width+($cycle%2)*12) ($height+($cycle%4)*8)
        $before=Key-Config
        [PinRealKeys]::Chord(0x79)
        Wait-Key { $current=Key-Config; $current -and $current.revision -gt $before.revision -and (Key-Status) -match '已记住' } 'F10 persisted capture'
        $saved=Key-Config
        if($saved.profiles[0].applications.Count -ne 1 -or -not $saved.profiles[0].applications[0].default){throw 'F10 did not create/update only the fixture application default.'}
        $displaced=Move-KeyFixture ($work.Left+[int]($workWidth*0.45)) ($work.Top+[int]($workHeight*0.35)) ([Math]::Max(300,$width-90)) ([Math]::Max(250,$height-70))
        if([PinRealKeys]::EdgeError($displaced,$target) -le 2){throw 'Fixture displacement did not establish a real restore test.'}
        $latency=[Diagnostics.Stopwatch]::StartNew()
        [PinRealKeys]::Chord(0x78)
        Wait-Key { [PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$target) -le 2 } 'real F9 restored DWM frame'
        $samples.Add($latency.Elapsed.TotalMilliseconds)
        Wait-Key { (Key-Status) -match '^已恢复|^已符合预设' } 'F9 completion feedback'
        $completionSamples.Add($latency.Elapsed.TotalMilliseconds)
        $report.successful_completion_feedback_cycles=$cycle+1
        $report.last_success_result=Key-Status
        $report.restore_samples_ms=$samples.ToArray()
        $report.completion_feedback_samples_ms=$completionSamples.ToArray()
        $report.max_edge_error_px=[Math]::Max($report.max_edge_error_px,[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$target))
        $report.completed_cycles=$cycle+1
        if($runWatch.Elapsed.TotalSeconds-$lastProgress -ge 20){Write-Host ('Real SendInput cycles complete: '+($cycle+1)+'/'+$Cycles);$lastProgress=$runWatch.Elapsed.TotalSeconds}
    }
    $process.Refresh();$report.private_after_cycles_bytes=$process.PrivateMemorySize64;$report.private_growth_bytes=$process.PrivateMemorySize64-$report.private_start_bytes;$report.cpu_delta_ms=$process.TotalProcessorTime.TotalMilliseconds-$cpuStart
    $report.restore_samples_ms=$samples.ToArray();$sorted=@($samples.ToArray()|Sort-Object);$report.restore_p95_ms=$sorted[[Math]::Ceiling($sorted.Length*0.95)-1]
    $sortedCompletion=@($completionSamples.ToArray()|Sort-Object);$report.completion_feedback_p95_ms=$sortedCompletion[[Math]::Ceiling($sortedCompletion.Length*0.95)-1]
    $before=Key-Config
    [PinRealKeys]::Chord(0x79)
    Wait-Key { (Key-Status) -match '位置未变化' } 'unchanged F10 feedback'
    $report.no_change_update_verified=(Key-Config).revision -eq $before.revision
    if(-not $report.no_change_update_verified){throw 'Identical F10 changed the persisted revision.'}

    $holdTarget=Move-KeyFixture ($work.Left+110) ($work.Top+125) ($width+25) ($height+20)
    $before=Key-Config
    [PinRealKeys]::BeginHold()
    try {
        Wait-Key { $current=Key-Config;$current -and $current.revision -gt $before.revision -and (Key-Status) -match '已记住' } 'initial held F10 capture'
        $firstHold=Key-Config;$firstHoldJson=$firstHold.profiles[0].applications[0].default|ConvertTo-Json -Depth 10 -Compress
        $holdStatus=Key-Status
        $null=Move-KeyFixture ($work.Left+300) ($work.Top+220) ($width-60) ($height-40)
        for($repeat=0;$repeat -lt 25;$repeat++){[PinRealKeys]::RepeatHeld();Start-Sleep -Milliseconds 40;[PinRealKeys]::AssertForeground()}
    } finally { [PinRealKeys]::ReleaseHeldKeys() }
    Start-Sleep -Milliseconds 120
    [PinRealKeys]::AssertForeground()
    $lastHold=Key-Config;$lastHoldJson=$lastHold.profiles[0].applications[0].default|ConvertTo-Json -Depth 10 -Compress
    $report.long_hold_norepeat_verified=$lastHold.revision -eq $firstHold.revision -and $lastHoldJson -eq $firstHoldJson -and (Key-Status) -eq $holdStatus
    if(-not $report.long_hold_norepeat_verified){throw 'Repeated held F10 events were not suppressed.'}
    [PinRealKeys]::Chord(0x78)
    Wait-Key { [PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$holdTarget) -le 2 } 'restore initial held capture after ignored repeats'
    $report.foreground_preserved=$true
    $report.final_config_autostart=(Key-Config).settings.autostart
    if($report.final_config_autostart){throw 'Isolated configuration unexpectedly enabled auto-start.'}
    Stop-KeyApp
} catch {
    $report.errors += $_.Exception.Message
    $report['failure_stack']=$_.ScriptStackTrace
    try {$report['failure_observation']=@{status=(Key-Status);configuration=(Key-Config);foreground=[PinRealKeys]::GetForegroundWindow().ToInt64();fixture=[PinRealKeys]::Fixture.ToInt64()}}catch{$report['failure_observation_error']=$_.Exception.Message}
}
finally {
    try {[PinRealKeys]::ReleaseHeldKeys();[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)}
    try {Stop-KeyApp}catch{$report.errors+=('App cleanup: '+$_.Exception.Message)}
    $report.finished_utc=[DateTime]::UtcNow.ToString('o')
    $report.passed=$report.errors.Count -eq 0 -and $report.completed_cycles -eq $Cycles -and $report.successful_completion_feedback_cycles -eq $Cycles -and $report.restore_p95_ms -le 300 -and $report.completion_feedback_p95_ms -le 300 -and $report.max_edge_error_px -le 2 -and $report.unconfigured_restore_verified -and $report.no_change_update_verified -and $report.long_hold_norepeat_verified -and $report.foreground_preserved -and $report.normal_exit -and $report.exit_code -eq 0 -and -not $report.forced_cleanup
    $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $reportPath -Encoding utf8
    Write-Host ('Hotkey smoke report: '+$reportPath)
}
if(-not $report.passed){exit 1}
