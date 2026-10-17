#Requires -Version 7.0
param(
    [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/shell-apps'),
    [ValidateRange(20,100)][int]$Cycles=20,
    [switch]$HotkeyStates,
    [switch]$TitleRules,
    [string]$UiaProbePath=(Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe')
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('shell-apps-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'config')).FullName
$configPath=Join-Path $configDir 'config.json'
$nativePath=Join-Path $PSScriptRoot 'support/application-native.cs'
$controlsPath=Join-Path $PSScriptRoot 'support/real-keys.cs'
Add-Type -Path $nativePath
Add-Type -Path $controlsPath
if($HotkeyStates -or $TitleRules){$inputPath=Join-Path $PSScriptRoot 'support/shell-input.cs';Add-Type -Path $inputPath;$UiaProbePath=(Get-Item -LiteralPath $UiaProbePath).FullName}
$shell=New-Object -ComObject Shell.Application
$report=[ordered]@{
    started_utc=[DateTime]::UtcNow.ToString('o');exe_path=$ExePath;exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash
    script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;native_helper_sha256=(Get-FileHash -LiteralPath $nativePath).Hash;controls_helper_sha256=(Get-FileHash -LiteralPath $controlsPath).Hash
    config_dir=$configDir;requested_cycles=$Cycles;applications=@();errors=@();normal_exit=$false;passed=$false
    scope='GUI baseline on newly created Explorer/Terminal windows, plus requested real SendInput state/title tests after ownership and foreground verification. No WM_HOTKEY injection, Explorer restart or shared-host process termination.'
    hotkey_states_requested=$HotkeyStates.IsPresent;title_rules_requested=$TitleRules.IsPresent
    limitations=@('Single display/current DPI; administrator/fullscreen, physical topology and mixed-DPI behavior remain unverified.','Terminal uses installed user settings and a new single-tab window; no terminal settings file is rewritten.','Explorer and Terminal may share host processes with user windows; closure is per verified test HWND, not per process name.','State changes use native APIs; title changes use owned Explorer folder navigation or the owned Terminal child shell, not physical keyboard commands.')
}
if($HotkeyStates -or $TitleRules){$report['input_helper_sha256']=(Get-FileHash -LiteralPath $inputPath).Hash;$report['uia_probe_sha256']=(Get-FileHash -LiteralPath $UiaProbePath).Hash}
$process=$null;$settings=[IntPtr]::Zero;$hostWindow=[IntPtr]::Zero;$runs=[Collections.Generic.List[object]]::new()
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Wait-ShellApp([scriptblock]$condition,[string]$description,[int]$seconds=15){$deadline=[DateTime]::UtcNow.AddSeconds($seconds);do{if(& $condition){return};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $deadline);throw ('Timeout: '+$description)}
function Title-ShellApp([IntPtr]$handle){$text=[Text.StringBuilder]::new(32768);[PinApplication]::GetWindowTextW($handle,$text,$text.Capacity)|Out-Null;return $text.ToString()}
function Read-FixtureFile([string]$path){
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return @{path=$path;exists=$false}}
    try{$file=Get-Item -LiteralPath $path;if($file.Length -gt 65536){return @{path=$path;exists=$true;bytes=$file.Length;error='Diagnostic file exceeds 64 KiB'}};return @{path=$path;exists=$true;bytes=$file.Length;last_write_utc=$file.LastWriteTimeUtc.ToString('o');value=(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json)}}catch{return @{path=$path;exists=$true;error=$_.Exception.Message}}
}
function Terminal-Diagnostics($run){
    $child=if($run.child_pid){Get-CimInstance Win32_Process -Filter ('ProcessId='+$run.child_pid)}else{$null}
    $identity=$child -and $child.ExecutablePath -ieq $run.child_executable -and $child.CommandLine.Contains($run.child_script)
    return @{observed_utc=[DateTime]::UtcNow.ToString('o');child_pid=$run.child_pid;child_exists=[bool]$child;child_identity_matches=[bool]$identity;caption=$(if($run.handle -ne [IntPtr]::Zero){Title-ShellApp $run.handle}else{''});ready=(Read-FixtureFile $run.ready_path);command=(Read-FixtureFile $run.title_command);ack=(Read-FixtureFile $run.title_ack);fault=(Read-FixtureFile $run.fixture_error)}
}
function Frame-ShellApp([IntPtr]$handle){$rect=[PinApplication+Rect]::new();if([PinApplication]::DwmGetWindowAttribute($handle,9,[ref]$rect,16) -ne 0){throw 'DWM frame query failed'};return @{left=$rect.Left;top=$rect.Top;right=$rect.Right;bottom=$rect.Bottom}}
function Error-ShellApp($a,$b){$maximum=0;foreach($edge in @('left','top','right','bottom')){$maximum=[Math]::Max($maximum,[Math]::Abs($a[$edge]-$b[$edge]))};return $maximum}
function Existing-ShellAppHandles {return @([PinRealKeys]::FindClass('CabinetWClass',0))+@([PinRealKeys]::FindClass('CASCADIA_HOSTING_WINDOW_CLASS',0))}
function Confirm-ShellApp($run){
    if(-not [PinApplication]::IsWindow($run.handle) -or $run.before.Contains($run.handle)){throw 'Window is missing or predates this test launch'}
    [uint32]$ownerPid=0;[PinApplication]::GetWindowThreadProcessId($run.handle,[ref]$ownerPid)|Out-Null
    $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$ownerPid)
    if($ownerPid -ne $run.pid -or -not $owner -or $owner.ExecutablePath -ine $run.executable -or -not (Title-ShellApp $run.handle).Contains($run.title)){throw 'Test window identity/title changed; refusing mutation'}
    if($run.kind -eq 'Explorer'){
        if([IntPtr]$run.view.HWND -ne $run.handle -or $run.view.Document.Folder.Self.Path -notin $run.allowed_folders){throw 'Explorer view is no longer an exact newly created test folder'}
    }else{
        $child=Get-CimInstance Win32_Process -Filter ('ProcessId='+$run.child_pid)
        if(-not $child -or $child.ExecutablePath -ine $run.child_executable -or -not $child.CommandLine.Contains($run.child_script)){throw 'Terminal test shell identity/script changed'}
    }
    return $owner
}
function Command-ShellApp([int]$id){
    $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
    if(-not $owner -or $owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains('"'+$configDir+'"')){throw 'Screen Pin test process/config ownership changed'}
    [PinRealKeys]::Command($settings,$process.Id,$id)
    Wait-ShellApp {[PinRealKeys]::Text($settings,138) -ne '正在处理…'} ('settings command '+$id)
}
function Close-ShellApp($run){
    if($run.handle -eq [IntPtr]::Zero -or -not [PinApplication]::IsWindow($run.handle)){return}
    Confirm-ShellApp $run|Out-Null
    if(-not [PinApplication]::PostMessageW($run.handle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)){throw 'Owned window close failed'}
    Wait-ShellApp {-not [PinApplication]::IsWindow($run.handle)} ('normal window close '+$run.kind)
    if($run.kind -eq 'Terminal'){Wait-ShellApp {-not (Get-CimInstance Win32_Process -Filter ('ProcessId='+$run.child_pid))} 'test terminal child exit'}
    $run.closed=$true
}
function Exercise-ShellApp($run){
    $owner=Confirm-ShellApp $run
    [PinApplication]::ShowWindow($run.handle,9)|Out-Null
    Wait-ShellApp {-not [PinApplication]::IsZoomed($run.handle) -and -not [PinApplication]::IsIconic($run.handle)} 'ordinary app state'
    $monitor=[PinApplication+Monitor]::new();$monitor.Size=[Runtime.InteropServices.Marshal]::SizeOf($monitor)
    if(-not [PinApplication]::GetMonitorInfoW([PinApplication]::MonitorFromWindow($run.handle,2),[ref]$monitor)){throw 'Monitor query failed'}
    [PinApplication]::SetWindowPos($run.handle,[IntPtr]::Zero,($monitor.Work.Left+110),($monitor.Work.Top+120),1040,720,0x4014)|Out-Null
    Start-Sleep -Milliseconds 300
    $baseline=Frame-ShellApp $run.handle;$samples=@()
    Command-ShellApp 109
    [PinRealKeys]::SelectWindow($settings,$process.Id,$run.title)
    for($cycle=1;$cycle -le $Cycles;$cycle++){
        Confirm-ShellApp $run|Out-Null
        Command-ShellApp 111
        $capture=[PinRealKeys]::Text($settings,138)
        if($capture -notmatch '已记住|位置未变化'){throw ('Capture was not successful: '+$capture)}
        $hash=(Get-FileHash -LiteralPath $configPath).Hash
        [PinApplication]::SetWindowPos($run.handle,[IntPtr]::Zero,($monitor.Work.Left+570+($cycle%3)*15),($monitor.Work.Top+350),780,550,0x4014)|Out-Null
        Start-Sleep -Milliseconds 90
        $moved=Frame-ShellApp $run.handle
        if((Error-ShellApp $moved $baseline) -le 2){throw 'Displacement did not establish an actual restore test'}
        $foreground=[PinApplication]::GetForegroundWindow()
        Command-ShellApp 112
        $actual=Frame-ShellApp $run.handle;$errorPx=Error-ShellApp $actual $baseline;$status=[PinRealKeys]::Text($settings,138)
        if($errorPx -gt 2 -or $status -notmatch '^已恢复|^已符合预设' -or [PinApplication]::GetForegroundWindow() -ne $foreground -or (Get-FileHash -LiteralPath $configPath).Hash -ne $hash){throw ('Cycle '+$cycle+' failed; error='+$errorPx+'; '+$status)}
        $samples+=@{cycle=$cycle;baseline=$baseline;moved=$moved;restored=$actual;max_edge_error_px=$errorPx;foreground_preserved=$true;restore_no_write=$true;capture_feedback=$capture;restore_feedback=$status}
    }
    $config=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
    $apps=@($config.profiles[0].applications|Where-Object {$_.app_name -ieq (Split-Path $owner.ExecutablePath -Leaf)})
    if($apps.Count -ne 1){throw 'Captured app identity is not unique in the private configuration'}
    $run.app_id=$apps[0].app_id
    $class=[Text.StringBuilder]::new(256);[PinApplication]::GetClassNameW($run.handle,$class,$class.Capacity)|Out-Null
    $proof=@{new_hwnd=$true;before_hwnds=@($run.before|ForEach-Object {$_.ToInt64()});unique_title=$run.title}
    if($run.kind -eq 'Explorer'){$proof['exact_folder']=$run.folder;$proof['com_hwnd']=[long]$run.view.HWND}else{$proof['child_script']=$run.child_script;$proof['child_executable']=$run.child_executable;$proof['child_pid']=$run.child_pid}
    return @{application=$run.kind;status='Passed';window=$run.handle.ToInt64();window_class=$class.ToString();pid=$run.pid;ownership=$proof;monitor=$monitor;dpi=[PinApplication]::GetDpiForWindow($run.handle);executable=$owner.ExecutablePath;version=(Get-Item -LiteralPath $owner.ExecutablePath).VersionInfo.ProductVersion;cycles=$Cycles;max_edge_error_px=($samples.max_edge_error_px|Measure-Object -Maximum).Maximum;samples=$samples;saved_app_identities=@($config.profiles[0].applications|Select-Object app_id,app_name);closed_normally=$false}
}
function Config-ShellApp {Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json}
function App-ShellApp($run){$apps=@((Config-ShellApp).profiles[0].applications|Where-Object app_id -eq $run.app_id);if($apps.Count -ne 1){throw 'Private application identity changed'};return $apps[0]}
function Hash-ShellApp {(Get-FileHash -LiteralPath $configPath).Hash}
function Status-ShellApp {[PinRealKeys]::Text($settings,138)}
function Focus-HotShellApp($run){
    Confirm-ShellApp $run|Out-Null
    $previous=[PinApplication]::GetForegroundWindow()
    if($previous -ne $run.handle){
        # Public UIA action is restricted to our own fixture, never a user app.
        $focusInput=Join-Path $runDir 'focus-input.json';$focusOutput=Join-Path $runDir 'focus-output.json'
        ConvertTo-Json -InputObject @(@{handle=[PinRealKeys]::Fixture.ToInt64();id=0;page='activation'})|Set-Content -LiteralPath $focusInput -Encoding utf8
        & $UiaProbePath $focusInput $focusOutput $PID --focus
        if($LASTEXITCODE -ne 0){throw 'Owned bootstrap UIA focus failed'}
        Wait-ShellApp {[PinApplication]::GetForegroundWindow() -eq [PinRealKeys]::Fixture} 'owned bootstrap foreground'
        [PinRealKeys]::AssertForeground();Confirm-ShellApp $run|Out-Null
        [PinApplication]::SetForegroundWindow($run.handle)|Out-Null
        $watch=[Diagnostics.Stopwatch]::StartNew()
        do{$current=[PinApplication]::GetForegroundWindow();if($current -eq $run.handle){break};if($current -ne [IntPtr]::Zero -and $current -ne [PinRealKeys]::Fixture){throw 'External foreground switch observed; input cancelled'};Start-Sleep -Milliseconds 2}while($watch.ElapsedMilliseconds -lt 500)
    }
    [PinShellInput]::AssertForeground($run.handle,$run.pid)
}
function Wait-HotShellApp($run,[scriptblock]$condition,[string]$description){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{[PinShellInput]::AssertForeground($run.handle,$run.pid);try{if(& $condition){return}}catch{if($_.Exception.Message -notmatch 'Timed out reading own app result'){throw}};Start-Sleep -Milliseconds 10}while($watch.ElapsedMilliseconds -lt 4000)
    throw ('Hotkey timeout: '+$description+'; '+(Status-ShellApp))
}
function Move-HotShellApp($run,[int]$x,[int]$y,[int]$width,[int]$height){
    Confirm-ShellApp $run|Out-Null;[PinShellInput]::AssertForeground($run.handle,$run.pid);$before=Frame-ShellApp $run.handle
    if(-not [PinApplication]::SetWindowPos($run.handle,[IntPtr]::Zero,$x,$y,$width,$height,0x4014)){throw 'Owned displacement failed'}
    Wait-HotShellApp $run {(Error-ShellApp (Frame-ShellApp $run.handle) $before) -gt 20} 'actual displacement';Start-Sleep -Milliseconds 140
    [PinShellInput]::AssertForeground($run.handle,$run.pid);return Frame-ShellApp $run.handle
}
function Remember-HotShellApp($run){
    Confirm-ShellApp $run|Out-Null;$before=(Config-ShellApp).revision
    [PinShellInput]::Chord($run.handle,$run.pid,0x79)
    Wait-HotShellApp $run {(Config-ShellApp).revision -gt $before -and (Status-ShellApp) -match '^已记住'} 'real F10 persistence'
    return Status-ShellApp
}
function Restore-HotShellApp($run,$expected,[string]$scope){
    Confirm-ShellApp $run|Out-Null;$hash=Hash-ShellApp;$before=Frame-ShellApp $run.handle
    [PinShellInput]::Chord($run.handle,$run.pid,0x78)
    Wait-HotShellApp $run {(Error-ShellApp (Frame-ShellApp $run.handle) $expected) -le 2 -and (Status-ShellApp) -match '^已恢复|^已符合预设'} 'real F9 geometry and completion'
    $status=Status-ShellApp
    if(-not $status.Contains($scope) -or (Hash-ShellApp) -ne $hash){throw 'Real restore chose the wrong scope or wrote configuration'}
    return @{before=$before;expected=$expected;actual=Frame-ShellApp $run.handle;edge_error_px=Error-ShellApp (Frame-ShellApp $run.handle) $expected;status=$status;config_hash_before=$hash;config_hash_after=Hash-ShellApp;foreground_preserved=$true}
}
function Exercise-HotStates($run){
    $checks=[Collections.Generic.List[string]]::new();$samples=@()
    Focus-HotShellApp $run
    $ordinary=Move-HotShellApp $run 230 200 980 650;$feedback=Remember-HotShellApp $run
    if((App-ShellApp $run).default.placement.maximized){throw 'Real ordinary F10 saved the wrong state'};$checks.Add('Real F10 saves ordinary state')
    $null=Move-HotShellApp $run 780 490 760 480;$samples+=Restore-HotShellApp $run $ordinary '应用默认';$checks.Add('Real ordinary F9 restores the saved rectangle without rewriting or refocusing')
    Confirm-ShellApp $run|Out-Null;[PinApplication]::ShowWindow($run.handle,3)|Out-Null
    Wait-HotShellApp $run {[PinApplication]::IsZoomed($run.handle)} 'maximize owned app';Start-Sleep -Milliseconds 180
    $maximum=Frame-ShellApp $run.handle;$feedback=Remember-HotShellApp $run
    if(-not [PinApplication]::IsZoomed($run.handle) -or -not (App-ShellApp $run).default.placement.maximized){throw 'Maximized capture altered the observed state'};$checks.Add('Real maximized F10 keeps the window maximized and saves maximum state')
    [PinApplication]::ShowWindow($run.handle,9)|Out-Null;Wait-HotShellApp $run {-not [PinApplication]::IsZoomed($run.handle)} 'manual normal state'
    $null=Move-HotShellApp $run 810 510 770 470;$samples+=Restore-HotShellApp $run $maximum '应用默认'
    if(-not [PinApplication]::IsZoomed($run.handle)){throw 'Saved maximum state was not restored'};$checks.Add('Real F9 restores maximized state and visible bounds')
    [PinApplication]::ShowWindow($run.handle,9)|Out-Null;Wait-HotShellApp $run {-not [PinApplication]::IsZoomed($run.handle)} 'manual restore after maximum preset';Start-Sleep -Milliseconds 180
    $manualError=Error-ShellApp (Frame-ShellApp $run.handle) $ordinary
    if($manualError -gt 2){throw 'Manual normal rectangle changed after maximum restore'};$checks.Add('Manual restore after the maximum preset returns to the captured normal rectangle')
    $feedback=Remember-HotShellApp $run
    if((App-ShellApp $run).default.placement.maximized){throw 'Normal recapture did not replace maximum state'};$checks.Add('Real F10 replaces the saved maximum state with ordinary state')
    [PinApplication]::ShowWindow($run.handle,3)|Out-Null;Wait-HotShellApp $run {[PinApplication]::IsZoomed($run.handle)} 'maximize before ordinary preset'
    $samples+=Restore-HotShellApp $run $ordinary '应用默认'
    if([PinApplication]::IsZoomed($run.handle)){throw 'Ordinary preset did not exit maximum state'};$checks.Add('Real F9 exits maximum state into the saved ordinary rectangle')
    Confirm-ShellApp $run|Out-Null;[PinApplication]::ShowWindow($run.handle,6)|Out-Null
    Wait-ShellApp {[PinApplication]::IsIconic($run.handle)} 'minimize owned app'
    Command-ShellApp 109;[PinRealKeys]::SelectWindow($settings,$process.Id,$run.title);$hash=Hash-ShellApp;$foreground=[PinApplication]::GetForegroundWindow()
    foreach($id in @(111,112)){Command-ShellApp $id;if((Status-ShellApp) -notmatch '已最小化' -or -not [PinApplication]::IsIconic($run.handle) -or (Hash-ShellApp) -ne $hash -or [PinApplication]::GetForegroundWindow() -ne $foreground){throw 'Minimized GUI command changed the target, config or foreground'};$checks.Add('Minimized GUI command '+$id+' is refused without writing, restoring or refocusing')}
    Confirm-ShellApp $run|Out-Null;[PinApplication]::ShowWindow($run.handle,9)|Out-Null
    Wait-ShellApp {-not [PinApplication]::IsIconic($run.handle)} 'recover owned ordinary state'
    return @{status='Passed';checks=$checks.ToArray();restores=$samples;manual_normal_edge_error_px=$manualError;input_method='Real Ctrl+Alt+F10/F9 on the verified owned foreground HWND; state transitions via native APIs. Minimized checks use explicit selected-window GUI commands.'}
}
function Match-ShellAppTitle([string]$caption,[string]$variant){return [bool]($caption -match 'RuleAlpha') -eq $variant.Contains('RuleAlpha') -and [bool]($caption -match 'RuleBeta') -eq $variant.Contains('RuleBeta')}
function Set-ShellAppTitle($run,[string]$variant){
    Confirm-ShellApp $run|Out-Null;[PinShellInput]::AssertForeground($run.handle,$run.pid)
    $before=Title-ShellApp $run.handle
    if($run.kind -eq 'Explorer'){
        $path=$run.rule_folders[$variant];$run.view.Navigate2($path)
        Wait-HotShellApp $run {try{$caption=Title-ShellApp $run.handle;return $run.view.Document.Folder.Self.Path -ieq $path -and $caption.Contains((Split-Path $path -Leaf)) -and (Match-ShellAppTitle $caption $variant)}catch{return $false}} 'owned folder navigation and title'
    }else{
        $sequence=[Guid]::NewGuid().ToString('N');$title=$run.title+$(if($variant -eq 'Default'){''}else{' '+$variant})
        [IO.File]::WriteAllText($run.title_command,(@{token=$run.title;sequence=$sequence;title=$title}|ConvertTo-Json))
        Wait-HotShellApp $run {
            $fault=Read-FixtureFile $run.fixture_error
            if($fault.exists -and $fault.value){
                if($fault.value.token -ne $run.title -or $fault.value.pid -ne $run.child_pid){throw 'Terminal fixture error identity mismatch'}
                throw ('Terminal fixture failed during '+$fault.value.phase+': '+$fault.value.message)
            }
            if(-not (Test-Path -LiteralPath $run.title_ack)){return $false}
            try{$ack=Get-Content -LiteralPath $run.title_ack -Raw|ConvertFrom-Json;$caption=Title-ShellApp $run.handle;return $ack.sequence -eq $sequence -and $ack.pid -eq $run.child_pid -and $caption.Contains($title) -and (Match-ShellAppTitle $caption $variant)}catch{return $false}
        } 'owned child shell title acknowledgement'
    }
    Confirm-ShellApp $run|Out-Null;return @{variant=$variant;before=$before;after=Title-ShellApp $run.handle;hwnd=$run.handle.ToInt64()}
}
function Exercise-TitleRules($run){
    Focus-HotShellApp $run;$checks=[Collections.Generic.List[string]]::new();$titles=@();$restores=@();$defaultFrame=Frame-ShellApp $run.handle;$defaultBefore=(App-ShellApp $run).default|ConvertTo-Json -Depth 12 -Compress
    $titles+=Set-ShellAppTitle $run 'RuleAlpha';$alphaFrame=Move-HotShellApp $run 300 210 1060 730
    Command-ShellApp 109;[PinRealKeys]::SelectWindow($settings,$process.Id,$run.title);[PinRealKeys]::ControlText($settings,$process.Id,114,'rUlEaLpHa');Command-ShellApp 115
    if((Status-ShellApp) -notmatch '^已创建标题规则'){throw 'Alpha rule setup failed'}
    $titles+=Set-ShellAppTitle $run 'RuleBeta';$betaFrame=Move-HotShellApp $run 450 300 1000 640
    Command-ShellApp 109;[PinRealKeys]::SelectWindow($settings,$process.Id,$run.title);[PinRealKeys]::ControlText($settings,$process.Id,114,'RuleBeta');Command-ShellApp 115
    $app=App-ShellApp $run
    if($app.rules.Count -ne 2 -or $app.rules[0].keyword -cne 'rUlEaLpHa' -or ($app.default|ConvertTo-Json -Depth 12 -Compress) -ne $defaultBefore){throw 'Title rule setup altered default or order'};$checks.Add('Two explicit title rules preserve the application default and creation order')
    $original=($app|ConvertTo-Json -Depth 20)|ConvertFrom-Json
    foreach($case in @(@{variant='RuleAlpha';expected=$alphaFrame;scope='rUlEaLpHa'},@{variant='RuleBeta';expected=$betaFrame;scope='RuleBeta'},@{variant='RuleAlpha RuleBeta';expected=$alphaFrame;scope='rUlEaLpHa'},@{variant='Default';expected=$defaultFrame;scope='应用默认'})){
        $titles+=Set-ShellAppTitle $run $case.variant;$null=Move-HotShellApp $run 800 500 720 440;$restores+=Restore-HotShellApp $run $case.expected $case.scope;$checks.Add('Real title '+$case.variant+' restores '+$case.scope+' without writing or refocusing')
    }
    $titles+=Set-ShellAppTitle $run 'RuleBeta';$updatedBeta=Move-HotShellApp $run 620 370 950 620;$feedback=Remember-HotShellApp $run;$app=App-ShellApp $run
    if(-not $feedback.Contains('RuleBeta') -or $app.rules[1].preset.id -ne $original.rules[1].preset.id -or ($app.rules[0]|ConvertTo-Json -Depth 12 -Compress) -ne ($original.rules[0]|ConvertTo-Json -Depth 12 -Compress) -or ($app.default|ConvertTo-Json -Depth 12 -Compress) -ne $defaultBefore){throw 'Real F10 title update changed another scope'};$checks.Add('Real F10 on Beta updates only the existing matching rule, preserving Alpha and the shared default')
    $null=Move-HotShellApp $run 800 500 720 440;$restores+=Restore-HotShellApp $run $updatedBeta 'RuleBeta'
    $beforeFallback=App-ShellApp $run;$savedRules=$beforeFallback.rules|ConvertTo-Json -Depth 20 -Compress
    $titles+=Set-ShellAppTitle $run 'Default';$updatedDefault=Move-HotShellApp $run 560 310 1020 700;$feedback=Remember-HotShellApp $run;$app=App-ShellApp $run
    if(-not $feedback.Contains('应用默认') -or $app.default.id -ne $original.default.id -or ($app.rules|ConvertTo-Json -Depth 20 -Compress) -ne $savedRules){throw 'Fallback real F10 changed title rules or default identity'};$checks.Add('Real F10 after title fallback updates only the existing application default and preserves both rules')
    $null=Move-HotShellApp $run 800 500 720 440;$restores+=Restore-HotShellApp $run $updatedDefault '应用默认'
    return @{status='Passed';checks=$checks.ToArray();titles=$titles;restores=$restores;before=$original;after=$app;input_method='Rule creation uses owned GUI commands; title changes use actual Explorer navigation or console title updates; all scope restore/update assertions use real F9/F10.'}
}
try{
    if([PinRealKeys]::FindClass('ScreenPin.Host',0).Length){throw 'Existing Screen Pin instance detected; no user window or config operated'}
    $process=Start-Process -FilePath $ExePath -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    Wait-ShellApp {
        if($process.HasExited){throw 'Screen Pin exited before startup readiness'}
        $hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id)
        if($hosts.Length -eq 1){$script:hostWindow=$hosts[0]}
        $windows=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id)
        if($windows.Length -ne 1){return $false}
        $script:settings=$windows[0]
        if(-not [PinRealKeys]::Enabled($settings,$process.Id,138)){return $false}
        try{return [PinRealKeys]::Text($settings,138) -notin @('','正在处理…')}
        catch{if($_.Exception.Message -notlike '*Timed out reading own app result*'){throw};return $false}
    } 'Screen Pin startup'
    $token=[Guid]::NewGuid().ToString('N')
    if($HotkeyStates -or $TitleRules){$null=[PinRealKeys]::StartFixture()}
    $folder=(New-Item -ItemType Directory -Path (Join-Path $runDir ('ScreenPin-Explorer-'+$token))).FullName
    $ruleFolders=@{Default=$folder};$allowedFolders=@($folder)
    if($TitleRules){foreach($variant in @('RuleAlpha','RuleBeta','RuleAlpha RuleBeta')){$path=(New-Item -ItemType Directory -Path (Join-Path $folder ((Split-Path $folder -Leaf)+' '+$variant))).FullName;$ruleFolders[$variant]=$path;$allowedFolders+=@($path)}}
    $explorer=[pscustomobject]@{kind='Explorer';handle=[IntPtr]::Zero;pid=0;executable=(Join-Path $env:WINDIR 'explorer.exe');title=(Split-Path $folder -Leaf);folder=$folder;allowed_folders=$allowedFolders;rule_folders=$ruleFolders;view=$null;before=@(Existing-ShellAppHandles);closed=$false;app_id=''}
    $runs.Add($explorer)
    $launcher=Start-Process -FilePath $explorer.executable -ArgumentList ('/n,/separate,"'+$folder+'"') -WindowStyle Hidden -PassThru
    Wait-ShellApp {
        foreach($view in @($shell.Windows())){try{if($view.FullName -ieq $explorer.executable -and $view.Document.Folder.Self.Path -ieq $folder -and -not $explorer.before.Contains([IntPtr]$view.HWND)){$explorer.view=$view;$explorer.handle=[IntPtr]$view.HWND;[uint32]$ownerPid=0;[PinApplication]::GetWindowThreadProcessId($explorer.handle,[ref]$ownerPid)|Out-Null;$explorer.pid=$ownerPid;return $true}}catch{continue}};return $false
    } 'new Explorer window for the exact owned folder'
    $result=Exercise-ShellApp $explorer
    if($HotkeyStates){$result['hotkey_states']=Exercise-HotStates $explorer}
    if($TitleRules){$result['title_rules']=Exercise-TitleRules $explorer}
    Close-ShellApp $explorer;$result.closed_normally=$explorer.closed;$report.applications+=$result

    $terminalPackage=Get-AppxPackage -Name Microsoft.WindowsTerminal
    if(-not $terminalPackage){throw 'Windows Terminal package is unavailable'}
    $terminalExe=Join-Path $terminalPackage.InstallLocation 'WindowsTerminal.exe'
    $terminalAlias=Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    $taskScript=Join-Path $runDir 'terminal-fixture.ps1';$readyPath=Join-Path $runDir 'terminal-ready.json';$titleCommand=Join-Path $runDir 'terminal-title-command.json';$titleAck=Join-Path $runDir 'terminal-title-ack.json';$fixtureError=Join-Path $runDir 'terminal-fixture-error.json'
    $title='ScreenPin-Terminal-'+$token
    $fixtureSource=Join-Path $PSScriptRoot 'support/terminal-title-fixture.ps1'
    Copy-Item -LiteralPath $fixtureSource -Destination $taskScript
    $report['terminal_fixture_sha256']=(Get-FileHash -LiteralPath $taskScript).Hash
    $shellExe=(Get-Command pwsh.exe).Source
    $terminal=[pscustomobject]@{kind='Terminal';handle=[IntPtr]::Zero;pid=0;executable=$terminalExe;title=$title;before=@(Existing-ShellAppHandles);child_pid=0;child_executable=$shellExe;child_script=$taskScript;closed=$false;app_id='';title_command=$titleCommand;title_ack=$titleAck;ready_path=$readyPath;fixture_error=$fixtureError}
    $runs.Add($terminal)
    $titleMode=if($TitleRules){'--useApplicationTitle'}else{'--suppressApplicationTitle'}
    $terminalArgs=@('-w','new','new-tab','--title',$title,$titleMode,('"'+$shellExe+'"'),'-NoLogo','-NoProfile','-NoExit','-File',('"'+$taskScript+'"'),'-Token',$title,'-ReadyPath',('"'+$readyPath+'"'),'-AckPath',('"'+$titleAck+'"'),'-ErrorPath',('"'+$fixtureError+'"'))
    if($TitleRules){$terminalArgs+=@('-CommandPath',('"'+$titleCommand+'"'))}
    $launcher=Start-Process -FilePath $terminalAlias -ArgumentList $terminalArgs -WindowStyle Hidden -PassThru
    Wait-ShellApp {
        if(-not (Test-Path -LiteralPath $readyPath)){return $false}
        $ready=Get-Content -LiteralPath $readyPath -Raw|ConvertFrom-Json;if($ready.token -ne $title){throw 'Terminal readiness token mismatch'};$terminal.child_pid=[uint32]$ready.pid
        foreach($handle in [PinRealKeys]::FindClass('CASCADIA_HOSTING_WINDOW_CLASS',0)){if(-not $terminal.before.Contains($handle) -and (Title-ShellApp $handle).Contains($title)){$terminal.handle=$handle;[uint32]$ownerPid=0;[PinApplication]::GetWindowThreadProcessId($handle,[ref]$ownerPid)|Out-Null;$terminal.pid=$ownerPid;return $true}};return $false
    } 'new Terminal window and its explicit fixture shell' 25
    $result=Exercise-ShellApp $terminal;$result['package_version']=$terminalPackage.Version;$result['test_child_pid']=$terminal.child_pid
    if($HotkeyStates){$result['hotkey_states']=Exercise-HotStates $terminal}
    if($TitleRules){$result['title_rules']=Exercise-TitleRules $terminal}
    Close-ShellApp $terminal;$result.closed_normally=$terminal.closed;$report.applications+=$result
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace;$report['terminal_diagnostics']=@($runs|Where-Object kind -eq 'Terminal'|ForEach-Object {Terminal-Diagnostics $_})}
finally{
    foreach($run in $runs){try{Close-ShellApp $run}catch{$report.errors+=('Window cleanup: '+$_.Exception.Message)}}
    if($HotkeyStates -or $TitleRules){try{[PinRealKeys]::StopFixture()}catch{$report.errors+=('Bootstrap cleanup: '+$_.Exception.Message)}}
    if($process -and -not $process.HasExited){try{
        $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
        if(-not $owner -or $owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains('"'+$configDir+'"')){throw 'Screen Pin cleanup ownership mismatch'}
        [PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null
        if(-not $process.WaitForExit(8000)){throw 'Screen Pin normal exit timed out'}
        $report.normal_exit=$process.ExitCode -eq 0
    }catch{$report.errors+=('App cleanup: '+$_.Exception.Message)}}
    $report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
    if(-not $report.startup_registry_unchanged){$report.errors+='User Run registry unexpectedly changed'}
    $report['finished_utc']=[DateTime]::UtcNow.ToString('o')
    $os=Get-CimInstance Win32_OperatingSystem
    $report['system']=@{caption=$os.Caption;version=$os.Version;build=$os.BuildNumber;architecture=$os.OSArchitecture}
    $report.passed=$report.errors.Count -eq 0 -and $report.applications.Count -eq 2 -and $report.normal_exit -and @($runs|Where-Object {-not $_.closed}).Count -eq 0
    $report|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8
    Write-Host ('Shell application report: '+(Join-Path $runDir 'report.json'))
}
if(-not $report.passed){exit 1}
