#Requires -Version 7.0
param(
    [string]$ExePath = (Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir = (Join-Path $PSScriptRoot ('../artifacts/application-smoke-' + [Guid]::NewGuid().ToString('N'))),
    [string]$BravePath = 'C:/Program Files/BraveSoftware/Brave-Browser/Application/brave.exe',
    [string]$CodePath = (Join-Path $env:LOCALAPPDATA 'Programs/Microsoft VS Code/Code.exe'),
    [switch]$ExtendedStates,
    [switch]$TemporaryDialogs,
    [switch]$Fullscreen,
    [switch]$HotkeyStates,
    [switch]$TitleRules,
    [ValidateRange(1,100)][int]$HotkeyCycles=50,
    [ValidateRange(0,100)][int]$PrecisionCycles=0
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$scriptHash=(Get-FileHash -LiteralPath $PSCommandPath).Hash
$ExePath = (Get-Item -LiteralPath $ExePath).FullName
$OutputDir = (New-Item -ItemType Directory -Path $OutputDir -Force).FullName
$configDir = (New-Item -ItemType Directory -Path (Join-Path $OutputDir ('config-' + [Guid]::NewGuid().ToString('N')))).FullName
$unique = [Guid]::NewGuid().ToString('N')
$startupBefore = [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
Add-Type -Path (Join-Path $PSScriptRoot 'support/application-native.cs')
if($TemporaryDialogs -or $Fullscreen -or $HotkeyStates -or $TitleRules){Add-Type -Path (Join-Path $PSScriptRoot 'support/application-input.cs')}
if($TitleRules){Add-Type -Path (Join-Path $PSScriptRoot 'support/real-keys.cs')}
$previousDpi = [PinApplication]::SetThreadDpiAwarenessContext([IntPtr](-4))
$process = $null
$ui = [IntPtr]::Zero
$hostWindow = [IntPtr]::Zero
$runs = [Collections.Generic.List[object]]::new()
$results = [Collections.Generic.List[object]]::new()
$inputCancelled=$false
function Read-Control([IntPtr]$handle) {
    $text=[Text.StringBuilder]::new(32768)
    [PinApplication]::SendText($handle,0x0d,[IntPtr]$text.Capacity,$text)|Out-Null
    $text.ToString()
}
function Window-Title([IntPtr]$handle) {
    $text=[Text.StringBuilder]::new(32768)
    [PinApplication]::GetWindowTextW($handle,$text,$text.Capacity)|Out-Null
    $text.ToString()
}
function Wait-Application([scriptblock]$condition,[string]$description,[int]$seconds=15) {
    $deadline=[DateTime]::UtcNow.AddSeconds($seconds)
    do { if(& $condition){return};Start-Sleep -Milliseconds 60 } while([DateTime]::UtcNow -lt $deadline)
    throw ('Timeout: '+$description)
}
function Click-Control([int]$id) {
    [PinApplication]::SendMessageW([PinApplication]::GetDlgItem($script:ui,$id),0xf5,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Wait-Application {(Read-Control ([PinApplication]::GetDlgItem($script:ui,138))) -ne '正在处理…'} ('button '+$id)
}
function Select-Target([string]$title) {
    $list=[PinApplication]::GetDlgItem($script:ui,108)
    $count=[PinApplication]::SendMessageW($list,0x18b,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()
    for($index=0;$index -lt $count;$index++) {
        $text=[Text.StringBuilder]::new(32768)
        [PinApplication]::SendText($list,0x189,[IntPtr]$index,$text)|Out-Null
        if($text.ToString().Contains($title)) {
            [PinApplication]::SendMessageW($list,0x186,[IntPtr]$index,[IntPtr]::Zero)|Out-Null
            [PinApplication]::SendMessageW($script:ui,0x111,[IntPtr](65536+108),$list)|Out-Null
            return
        }
    }
    throw 'The uniquely titled isolated window is absent from the eligible-window list.'
}
function Bounds-Application([IntPtr]$handle) {
    $rect=[PinApplication+Rect]::new()
    $status=[PinApplication]::DwmGetWindowAttribute($handle,9,[ref]$rect,16)
    if($status -ne 0){throw ('DWM bounds failed: '+$status)}
    [ordered]@{left=$rect.Left;top=$rect.Top;right=$rect.Right;bottom=$rect.Bottom}
}
function Confirm-ApplicationOwner($run) {
    if(-not [PinApplication]::IsWindow($run.handle)){throw 'The isolated window was closed.'}
    $ownerPid=0
    [PinApplication]::GetWindowThreadProcessId($run.handle,[ref]$ownerPid)|Out-Null
    if($ownerPid -ne $run.pid){throw 'Window owner changed; refusing to operate.'}
    $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$ownerPid)
    if(-not $owner -or $owner.ExecutablePath -ne $run.executable -or -not $owner.CommandLine.Contains($run.profile)){throw 'Application command line does not prove ownership of the isolated profile.'}
    if(-not (Window-Title $run.handle).Contains($run.title)){throw 'Unique isolated document title changed; refusing to operate.'}
    $owner
}
function Close-Application($run) {
    if($run.handle -eq [IntPtr]::Zero -or -not [PinApplication]::IsWindow($run.handle)){return}
    Confirm-ApplicationOwner $run|Out-Null
    if($TemporaryDialogs){$dialog=[PinApplicationInput]::Dialog($run.pid,$run.handle);if($dialog -ne [IntPtr]::Zero){Confirm-DialogOwner $run $dialog|Out-Null;[PinApplication]::PostMessageW($dialog,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null;Wait-Application {-not [PinApplication]::IsWindow($dialog)} 'cancel only owned temporary dialog'}}
    $ownedProcess=[Diagnostics.Process]::GetProcessById($run.pid)
    [PinApplication]::PostMessageW($run.handle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Wait-Application {-not [PinApplication]::IsWindow($run.handle)} ('close isolated '+$run.name)
    Wait-Application {$ownedProcess.Refresh();$ownedProcess.HasExited} ('exit isolated '+$run.name)
}
function Preset-Application($run) {
    $config=Get-Content -LiteralPath (Join-Path $configDir 'config.json') -Raw|ConvertFrom-Json
    $matches=@($config.profiles[0].applications|Where-Object {$_.app_id.EndsWith($run.executable.ToLowerInvariant())})
    if($matches.Count -ne 1){throw 'Cannot identify the single owned application preset'}
    return $matches[0].default
}
function Precision-Application($run){
    $samples=@();$configPath=Join-Path $configDir 'config.json'
    $baseline=Bounds-Application $run.handle
    for($cycle=1;$cycle -le $PrecisionCycles;$cycle++){
        Confirm-ApplicationOwner $run|Out-Null
        Click-Control 109;Select-Target $run.title;Click-Control 111
        if((Read-Control ([PinApplication]::GetDlgItem($ui,138))) -notmatch '已记住|位置未变化'){throw 'Precision capture did not report a successful save/no-op'}
        $hash=(Get-FileHash -LiteralPath $configPath).Hash
        [PinApplication]::SetWindowPos($run.handle,[IntPtr]::Zero,(560+($cycle%4)*17),(330+($cycle%3)*13),(850+($cycle%2)*20),600,0x4014)|Out-Null
        Start-Sleep -Milliseconds 90
        $moved=Bounds-Application $run.handle
        if((Bounds-Error $moved $baseline) -le 2){throw 'Precision displacement did not move the target'}
        $foreground=[PinApplication]::GetForegroundWindow()
        Click-Control 112
        $actual=Bounds-Application $run.handle;$errorPx=Bounds-Error $actual $baseline
        $status=Read-Control ([PinApplication]::GetDlgItem($ui,138))
        if($errorPx -gt 2 -or $status -notmatch '^已恢复|^已符合预设' -or [PinApplication]::GetForegroundWindow() -ne $foreground -or (Get-FileHash -LiteralPath $configPath).Hash -ne $hash){throw ('Precision cycle '+$cycle+' failed: '+$status+'; error='+$errorPx)}
        $samples+=@{cycle=$cycle;baseline=$baseline;actual=$actual;max_edge_error_px=$errorPx;foreground_preserved=$true;restore_no_write=$true}
    }
    return @{status='Passed';cycles=$PrecisionCycles;max_edge_error_px=($samples.max_edge_error_px|Measure-Object -Maximum).Maximum;samples=$samples;input_method='GUI capture/restore after explicit selection; baseline fixed across all cycles, no keyboard/mouse input.'}
}
function Assert-State($condition,[string]$message){if(-not $condition){throw $message};$script:stateChecks.Add($message)}
function Focus-Application($run){
    Confirm-ApplicationOwner $run|Out-Null
    [PinApplication]::SetForegroundWindow($run.handle)|Out-Null
    if([PinApplication]::GetForegroundWindow() -ne $run.handle){throw 'Windows foreground policy prevented owned-app activation; no keyboard/mouse input was attempted'}
    Start-Sleep -Milliseconds 200
}
function Bounds-Error($a,$b){$maximum=0;foreach($edge in @('left','top','right','bottom')){$maximum=[Math]::Max($maximum,[Math]::Abs($a[$edge]-$b[$edge]))};return $maximum}
function States-Application($run){
    $script:stateChecks=[Collections.Generic.List[string]]::new()
    Confirm-ApplicationOwner $run|Out-Null
    $normal=Bounds-Application $run.handle
    [PinApplication]::ShowWindow($run.handle,3)|Out-Null
    Wait-Application {[PinApplication]::IsZoomed($run.handle)} 'maximize owned app'
    Start-Sleep -Milliseconds 200
    $maximized=Bounds-Application $run.handle
    Click-Control 109;Select-Target $run.title;Click-Control 111
    Assert-State ([PinApplication]::IsZoomed($run.handle) -and (Preset-Application $run).placement.maximized) 'Maximized capture preserves the observed maximized state and stores it'
    [PinApplication]::ShowWindow($run.handle,9)|Out-Null
    Wait-Application {-not [PinApplication]::IsZoomed($run.handle)} 'restore owned app to normal'
    [PinApplication]::SetWindowPos($run.handle,[IntPtr]::Zero,550,370,870,610,0x4014)|Out-Null
    Start-Sleep -Milliseconds 200
    Focus-Application $run
    $hash=(Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash
    Click-Control 112
    Wait-Application {[PinApplication]::IsZoomed($run.handle)} 'restore saved maximized state'
    $maxError=Bounds-Error (Bounds-Application $run.handle) $maximized
    Assert-State ($maxError -le 2 -and [PinApplication]::GetForegroundWindow() -eq $run.handle) 'Maximized preset restores visible bounds and retains the foreground'
    Assert-State ((Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash -eq $hash) 'Maximized restore does not modify the preset'
    [PinApplication]::ShowWindow($run.handle,9)|Out-Null
    Wait-Application {-not [PinApplication]::IsZoomed($run.handle)} 'manual normal restore after maximum preset'
    Start-Sleep -Milliseconds 200
    $manual=Bounds-Application $run.handle;$manualError=Bounds-Error $manual $normal
    Assert-State ($manualError -le 2) 'Manual restore after the maximum preset returns to its captured normal rectangle'
    Click-Control 109;Select-Target $run.title;Click-Control 111
    Assert-State (-not (Preset-Application $run).placement.maximized) 'A later ordinary capture replaces the maximized state'
    [PinApplication]::ShowWindow($run.handle,3)|Out-Null
    Wait-Application {[PinApplication]::IsZoomed($run.handle)} 'maximize before normal preset restore'
    Focus-Application $run
    $hash=(Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash
    Click-Control 112
    Wait-Application {-not [PinApplication]::IsZoomed($run.handle)} 'normal preset exits maximum state'
    Start-Sleep -Milliseconds 200
    $normalError=Bounds-Error (Bounds-Application $run.handle) $normal
    Assert-State ($normalError -le 2 -and [PinApplication]::GetForegroundWindow() -eq $run.handle) 'Normal preset restores from maximized state without stealing foreground'
    Assert-State ((Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash -eq $hash) 'Normal-state restore does not rewrite the saved preset'
    [PinApplication]::ShowWindow($run.handle,6)|Out-Null
    Wait-Application {[PinApplication]::IsIconic($run.handle)} 'minimize owned app'
    Click-Control 109;Select-Target $run.title
    $hash=(Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash
    Click-Control 111
    Assert-State ((Read-Control ([PinApplication]::GetDlgItem($ui,138))) -match '已最小化' -and [PinApplication]::IsIconic($run.handle) -and (Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash -eq $hash) 'Minimized capture is refused without overwriting or unminimizing the target'
    Click-Control 112
    Assert-State ((Read-Control ([PinApplication]::GetDlgItem($ui,138))) -match '已最小化' -and [PinApplication]::IsIconic($run.handle) -and (Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash -eq $hash) 'Minimized restore is refused without overwriting or unminimizing the target'
    [PinApplication]::ShowWindow($run.handle,9)|Out-Null
    return @{status='Passed';checks=$stateChecks.ToArray();maximized_edge_error_px=$maxError;manual_normal_edge_error_px=$manualError;normal_from_maximum_edge_error_px=$normalError;input_method='Owned GUI commands and native state transitions; no keyboard or mouse injection.'}
}
function Confirm-DialogOwner($run,[IntPtr]$handle){
    Confirm-ApplicationOwner $run|Out-Null
    [uint32]$dialogPid=0;[PinApplication]::GetWindowThreadProcessId($handle,[ref]$dialogPid)|Out-Null
    $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$dialogPid)
    if(-not $owner -or $owner.ExecutablePath -ine $run.executable -or -not $owner.CommandLine.Contains($run.profile) -or ($dialogPid -ne $run.pid -and $owner.ParentProcessId -ne $run.pid) -or -not [PinApplicationInput]::Owned($handle,$dialogPid,$run.handle,$run.pid)){throw 'Dialog process is not the verified isolated application or its direct profile-owned utility child'}
    return $dialogPid
}
function Keys-Application($run,[IntPtr]$handle,[int]$key,[int]$modifiers=0,[bool]$allowDialog=$false){
    Confirm-ApplicationOwner $run|Out-Null
    $ownerPid=if($handle -eq $run.handle){$run.pid}else{Confirm-DialogOwner $run $handle}
    [PinApplicationInput]::Chord($handle,$ownerPid,$run.handle,$run.pid,[ushort]$key,[uint32]$modifiers,$allowDialog)
}
function Wait-HotApplication($run,[scriptblock]$condition,[string]$description){
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{
        [PinApplicationInput]::AssertForeground($run.handle,$run.pid,$run.handle,$run.pid)
        if(& $condition){return}
        Start-Sleep -Milliseconds 10
    }while($watch.ElapsedMilliseconds -lt 4000)
    throw ('Real hotkey timeout: '+$description)
}
function Remember-HotApplication($run){
    $path=Join-Path $configDir 'config.json';$before=(Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).revision
    Keys-Application $run $run.handle 0x79 3
    Wait-HotApplication $run { (Get-Content -LiteralPath $path -Raw|ConvertFrom-Json).revision -gt $before -and (Read-Control ([PinApplication]::GetDlgItem($ui,138))) -match '^已记住' } 'changed F10 persistence'
}
function Restore-HotApplication($run,$expected,[string]$scenario,[string]$scope='应用默认'){
    Confirm-ApplicationOwner $run|Out-Null
    $path=Join-Path $configDir 'config.json';$hash=(Get-FileHash -LiteralPath $path).Hash
    # Refresh completes through an owned GUI command before timing, so feedback
    # from the previous successful restore cannot satisfy the next sample.
    Click-Control 109
    if((Read-Control ([PinApplication]::GetDlgItem($ui,138))) -match '^已恢复|^已符合预设'){throw 'Restore feedback was not cleared before the new real input'}
    $before=Bounds-Application $run.handle
    if((Bounds-Error $before $expected) -le 2){throw 'No actual displacement before real restore'}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Keys-Application $run $run.handle 0x78 3
    Wait-HotApplication $run { (Bounds-Error (Bounds-Application $run.handle) $expected) -le 2 -and (Read-Control ([PinApplication]::GetDlgItem($ui,138))) -match '^已恢复|^已符合预设' } $scenario
    $elapsed=$watch.Elapsed.TotalMilliseconds
    $actual=Bounds-Application $run.handle;$status=Read-Control ([PinApplication]::GetDlgItem($ui,138))
    Assert-State ($status.Contains($scope) -and (Get-FileHash -LiteralPath $path).Hash -eq $hash) ($scenario+': actual F9 uses '+$scope+' without writing')
    return @{scenario=$scenario;before=$before;expected=$expected;actual=$actual;edge_error_px=Bounds-Error $actual $expected;completion_ms=$elapsed;foreground_preserved=$true;config_unchanged=$true;feedback=$status}
}
function HotkeyStates-Application($run){
    $script:stateChecks=[Collections.Generic.List[string]]::new();$samples=@()
    Focus-Application $run
    Confirm-ApplicationOwner $run|Out-Null
    if(-not [PinApplication]::SetWindowPos($run.handle,[IntPtr]::Zero,230,200,980,650,0x4014)){throw 'Initial owned hotkey placement failed'}
    Start-Sleep -Milliseconds 180
    $normal=Bounds-Application $run.handle;Remember-HotApplication $run
    Assert-State (-not (Preset-Application $run).placement.maximized) 'Actual F10 saves ordinary state'
    for($cycle=1;$cycle -le $HotkeyCycles;$cycle++){
        Confirm-ApplicationOwner $run|Out-Null
        [PinApplicationInput]::AssertForeground($run.handle,$run.pid,$run.handle,$run.pid)
        if(-not [PinApplication]::SetWindowPos($run.handle,[IntPtr]::Zero,(760+($cycle%3)*30),(450+($cycle%2)*30),820,580,0x4014)){throw 'Owned hotkey displacement failed'}
        Wait-HotApplication $run {(Bounds-Error (Bounds-Application $run.handle) $normal) -gt 20} 'actual displacement'
        Start-Sleep -Milliseconds 100
        $samples+=Restore-HotApplication $run $normal ('ordinary-'+$cycle)
    }
    [PinApplication]::ShowWindow($run.handle,3)|Out-Null
    Wait-HotApplication $run {[PinApplication]::IsZoomed($run.handle)} 'maximize owned app';Start-Sleep -Milliseconds 180
    $maximum=Bounds-Application $run.handle;Remember-HotApplication $run
    Assert-State ([PinApplication]::IsZoomed($run.handle) -and (Preset-Application $run).placement.maximized) 'Actual maximized F10 stores maximum state without restoring the window'
    [PinApplication]::ShowWindow($run.handle,9)|Out-Null
    Wait-HotApplication $run {-not [PinApplication]::IsZoomed($run.handle)} 'return owned app to ordinary state'
    [PinApplication]::SetWindowPos($run.handle,[IntPtr]::Zero,780,490,820,580,0x4014)|Out-Null
    Start-Sleep -Milliseconds 180
    $samples+=Restore-HotApplication $run $maximum 'maximized'
    Assert-State ([PinApplication]::IsZoomed($run.handle)) 'Actual F9 restores maximum state'
    [PinApplication]::ShowWindow($run.handle,9)|Out-Null
    Wait-HotApplication $run {-not [PinApplication]::IsZoomed($run.handle)} 'manual normal restore';Start-Sleep -Milliseconds 180
    $manual=Bounds-Application $run.handle;$manualError=Bounds-Error $manual $normal
    Assert-State ($manualError -le 2) 'Manual restore after actual maximum F9 retains the originally captured ordinary rectangle'
    Remember-HotApplication $run
    Assert-State (-not (Preset-Application $run).placement.maximized) 'Actual F10 replaces maximum state with ordinary state'
    [PinApplication]::ShowWindow($run.handle,3)|Out-Null
    Wait-HotApplication $run {[PinApplication]::IsZoomed($run.handle)} 'maximize before ordinary restore';Start-Sleep -Milliseconds 180
    $samples+=Restore-HotApplication $run $normal 'ordinary-from-maximum'
    Assert-State (-not [PinApplication]::IsZoomed($run.handle)) 'Actual F9 exits maximum state into the ordinary preset'
    $ordinary=@($samples|Where-Object scenario -like 'ordinary-*'|Where-Object scenario -ne 'ordinary-from-maximum')
    $sorted=@($ordinary.completion_ms|Sort-Object);$p95=$sorted[[Math]::Ceiling($sorted.Count*0.95)-1]
    Assert-State ($ordinary.Count -eq $HotkeyCycles -and $p95 -le 300) 'Requested actual ordinary restore samples complete within the p95 300 ms budget'
    return @{status='Passed';checks=$stateChecks.ToArray();restores=$samples;ordinary_cycles=$ordinary.Count;ordinary_completion_p95_ms=$p95;max_edge_error_px=($samples.edge_error_px|Measure-Object -Maximum).Maximum;manual_normal_edge_error_px=$manualError;input_method='Real foreground-checked SendInput Ctrl+Alt+F10/F9; native state transitions and displacement; GUI refresh clears stale feedback before each actual restore.';latency_definition='Stopwatch before the validated key wrapper until both visible DWM bounds and new explicit success feedback match; includes process ownership validation and 10 ms polling overhead, not an isolated Win32 dispatch duration.'}
}
function App-TitleApplication($run){
    $config=Get-Content -LiteralPath (Join-Path $configDir 'config.json') -Raw|ConvertFrom-Json
    $apps=@($config.profiles[0].applications|Where-Object {$_.app_id.EndsWith($run.executable.ToLowerInvariant())})
    if($apps.Count -ne 1){throw 'Expected one owned title-rule application'}
    return $apps[0]
}
function Match-ApplicationTitle([string]$caption,[string]$variant){
    $alpha=$caption -match 'RuleAlpha';$beta=$caption -match 'RuleBeta'
    switch($variant){'Default'{return -not $alpha -and -not $beta};'RuleAlpha'{return $alpha -and -not $beta};'RuleBeta'{return $beta -and -not $alpha};'RuleAlpha RuleBeta'{return $alpha -and $beta}}
    throw 'Unexpected title variant'
}
function Set-ApplicationTitle($run,[string]$variant){
    Confirm-ApplicationOwner $run|Out-Null
    $before=Window-Title $run.handle;$path=$run.rule_documents[$variant]
    if(-not $path -or -not (Test-Path -LiteralPath $path)){throw 'Title navigation must use an existing owned test document'}
    $key=if($run.name -eq 'Brave'){0x4c}else{0x50}
    $text=if($run.name -eq 'Brave'){[Uri]::new($path).AbsoluteUri}else{$path}
    Keys-Application $run $run.handle $key 1
    Start-Sleep -Milliseconds 180
    Keys-Application $run $run.handle 0x41 1
    Confirm-ApplicationOwner $run|Out-Null
    [PinApplicationInput]::Text($run.handle,$run.pid,$run.handle,$run.pid,$text)
    Start-Sleep -Milliseconds 300
    Keys-Application $run $run.handle 0x0d
    Wait-HotApplication $run {(Window-Title $run.handle).Contains($run.title) -and (Match-ApplicationTitle (Window-Title $run.handle) $variant)} 'actual owned document navigation/title change'
    Confirm-ApplicationOwner $run|Out-Null
    return @{variant=$variant;document=$path;before=$before;after=Window-Title $run.handle;hwnd=$run.handle.ToInt64()}
}
function Move-TitleApplication($run,[int]$x,[int]$y,[int]$width,[int]$height){
    Confirm-ApplicationOwner $run|Out-Null
    [PinApplicationInput]::AssertForeground($run.handle,$run.pid,$run.handle,$run.pid)
    if(-not [PinApplication]::SetWindowPos($run.handle,[IntPtr]::Zero,$x,$y,$width,$height,0x4014)){throw 'Owned title-case displacement failed'}
    Start-Sleep -Milliseconds 180
    [PinApplicationInput]::AssertForeground($run.handle,$run.pid,$run.handle,$run.pid)
    return Bounds-Application $run.handle
}
function TitleRules-Application($run){
    $script:stateChecks=[Collections.Generic.List[string]]::new();$titles=@();$restores=@()
    Focus-Application $run
    $defaultFrame=Bounds-Application $run.handle;$defaultBefore=(App-TitleApplication $run).default|ConvertTo-Json -Depth 16 -Compress
    $run.rule_documents['Default']=$run.document
    foreach($variant in @('RuleAlpha','RuleBeta','RuleAlpha RuleBeta')){
        $extension=if($run.name -eq 'Brave'){'.html'}else{'.txt'}
        $path=Join-Path $OutputDir ($run.title+' '+$variant+$extension)
        $content=if($run.name -eq 'Brave'){'<!doctype html><meta charset="utf-8"><title>'+$run.title+' '+$variant+'</title><p>Owned title-rule document.</p>'}else{'Owned title-rule document. No user content.'}
        [IO.File]::WriteAllText($path,$content);$run.rule_documents[$variant]=$path
    }
    foreach($case in @(@{variant='RuleAlpha';keyword='rUlEaLpHa';x=300;y=210;width=1060;height=730},@{variant='RuleBeta';keyword='RuleBeta';x=450;y=300;width=1000;height=640})){
        $titles+=Set-ApplicationTitle $run $case.variant
        $frame=Move-TitleApplication $run $case.x $case.y $case.width $case.height
        if($case.variant -eq 'RuleAlpha'){$alphaFrame=$frame}else{$betaFrame=$frame}
        Click-Control 109;Select-Target $run.title
        [PinRealKeys]::ControlText($ui,$process.Id,114,$case.keyword);Click-Control 115
        if((Read-Control ([PinApplication]::GetDlgItem($ui,138))) -notmatch '^已创建标题规则'){throw 'Owned title-rule capture failed'}
    }
    $app=App-TitleApplication $run
    Assert-State ($app.rules.Count -eq 2 -and $app.rules[0].keyword -ceq 'rUlEaLpHa' -and ($app.default|ConvertTo-Json -Depth 16 -Compress) -ceq $defaultBefore) 'Two title rules preserve the shared default and explicit creation order'
    $original=($app|ConvertTo-Json -Depth 24)|ConvertFrom-Json
    foreach($case in @(@{variant='RuleAlpha';expected=$alphaFrame;scope='rUlEaLpHa'},@{variant='RuleBeta';expected=$betaFrame;scope='RuleBeta'},@{variant='RuleAlpha RuleBeta';expected=$alphaFrame;scope='rUlEaLpHa'},@{variant='Default';expected=$defaultFrame;scope='应用默认'})){
        $titles+=Set-ApplicationTitle $run $case.variant
        $null=Move-TitleApplication $run 800 500 820 580
        $restores+=Restore-HotApplication $run $case.expected ('title-'+$case.variant) $case.scope
    }
    $titles+=Set-ApplicationTitle $run 'RuleBeta';$updatedBeta=Move-TitleApplication $run 620 370 950 620
    Remember-HotApplication $run;$app=App-TitleApplication $run;$status=Read-Control ([PinApplication]::GetDlgItem($ui,138))
    Assert-State ($status.Contains('RuleBeta') -and $app.rules[1].preset.id -eq $original.rules[1].preset.id -and ($app.rules[0]|ConvertTo-Json -Depth 16 -Compress) -ceq ($original.rules[0]|ConvertTo-Json -Depth 16 -Compress) -and ($app.default|ConvertTo-Json -Depth 16 -Compress) -ceq $defaultBefore) 'Actual Beta F10 changes only its existing rule, preserving Alpha and the shared default'
    $null=Move-TitleApplication $run 800 500 820 580;$restores+=Restore-HotApplication $run $updatedBeta 'updated-Beta' 'RuleBeta'
    $betaBeforeOverlap=$app.rules[1]|ConvertTo-Json -Depth 16 -Compress
    $titles+=Set-ApplicationTitle $run 'RuleAlpha RuleBeta';$updatedAlpha=Move-TitleApplication $run 610 280 1040 680
    Remember-HotApplication $run;$app=App-TitleApplication $run;$status=Read-Control ([PinApplication]::GetDlgItem($ui,138))
    Assert-State ($status.Contains('rUlEaLpHa') -and $app.rules[0].preset.id -eq $original.rules[0].preset.id -and ($app.rules[1]|ConvertTo-Json -Depth 16 -Compress) -ceq $betaBeforeOverlap -and ($app.default|ConvertTo-Json -Depth 16 -Compress) -ceq $defaultBefore) 'Actual dual-match F10 updates the same first rule chosen by F9, preserving Beta and the shared default'
    $null=Move-TitleApplication $run 800 500 820 580;$restores+=Restore-HotApplication $run $updatedAlpha 'updated-overlap-first' 'rUlEaLpHa'
    $savedRules=$app.rules|ConvertTo-Json -Depth 20 -Compress
    $titles+=Set-ApplicationTitle $run 'Default';$updatedDefault=Move-TitleApplication $run 560 310 1020 700
    Remember-HotApplication $run;$app=App-TitleApplication $run;$status=Read-Control ([PinApplication]::GetDlgItem($ui,138))
    Assert-State ($status.Contains('应用默认') -and $app.default.id -eq $original.default.id -and ($app.rules|ConvertTo-Json -Depth 20 -Compress) -ceq $savedRules) 'Actual fallback F10 changes only the shared default and preserves both title rules'
    $null=Move-TitleApplication $run 800 500 820 580;$restores+=Restore-HotApplication $run $updatedDefault 'updated-default' '应用默认'
    return @{status='Passed';checks=$stateChecks.ToArray();titles=$titles;restores=$restores;before=$original;after=$app;input_method='Owned real Ctrl+L / Ctrl+P, Unicode path entry and Enter open actual local documents in the same window; rules are created through owned GUI controls; restore/update use real foreground-checked Ctrl+Alt+F9/F10.'}
}
function Dialog-Application($run){
    $script:stateChecks=[Collections.Generic.List[string]]::new()
    $script:dialogTrace=@()
    Focus-Application $run
    Start-Sleep -Milliseconds 2000
    Keys-Application $run $run.handle 0x4f 1 $true
    $script:appDialog=[IntPtr]::Zero
    Wait-Application {$script:appDialog=[PinApplicationInput]::Dialog($run.pid,$run.handle);$script:appDialog -ne [IntPtr]::Zero} 'owned real application open-file dialog'
    $dialogPid=Confirm-DialogOwner $run $appDialog
    [PinApplicationInput]::AssertForeground($appDialog,$dialogPid,$run.handle,$run.pid)
    # Common file dialogs may resize while the initial folder/UI is loading.
    # Require both windows to settle before measuring any hotkey side effect.
    $script:dialogLastParent=Bounds-Application $run.handle;$script:dialogLastFrame=Bounds-Application $appDialog;$script:dialogStable=0
    Wait-Application {
        [PinApplicationInput]::AssertForeground($appDialog,$dialogPid,$run.handle,$run.pid)
        $parentNow=Bounds-Application $run.handle;$dialogNow=Bounds-Application $appDialog
        if((Bounds-Error $parentNow $script:dialogLastParent) -eq 0 -and (Bounds-Error $dialogNow $script:dialogLastFrame) -eq 0){$script:dialogStable++}else{$script:dialogStable=0}
        $script:dialogLastParent=$parentNow;$script:dialogLastFrame=$dialogNow
        $script:dialogStable -ge 10
    } 'owned file dialog geometry to settle'
    $before=Bounds-Application $run.handle;$dialogBefore=Bounds-Application $appDialog
    $hash=(Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash
    foreach($key in @(0x79,0x78)){
        Click-Control 109
        [PinApplicationInput]::AssertForeground($appDialog,$dialogPid,$run.handle,$run.pid)
        Keys-Application $run $appDialog $key 3
        Wait-Application {(Read-Control ([PinApplication]::GetDlgItem($ui,138))) -match '临时对话框|依附于其他窗口'} 'honest dialog refusal'
        $script:dialogTrace+=@{key=$key;parent_before=$before;parent_after=Bounds-Application $run.handle;dialog_before=$dialogBefore;dialog_after=Bounds-Application $appDialog;feedback=Read-Control ([PinApplication]::GetDlgItem($ui,138))}
        Assert-State ([PinApplication]::GetForegroundWindow() -eq $appDialog -and (Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash -eq $hash) ('Dialog real hotkey '+$key+' refuses without config writes or foreground change')
        Assert-State ((Bounds-Error (Bounds-Application $run.handle) $before) -eq 0 -and (Bounds-Error (Bounds-Application $appDialog) $dialogBefore) -eq 0) ('Dialog real hotkey '+$key+' moves neither dialog nor parent')
    }
    Confirm-DialogOwner $run $appDialog|Out-Null
    [PinApplication]::PostMessageW($appDialog,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Wait-Application {-not [PinApplication]::IsWindow($appDialog)} 'cancel owned real file dialog'
    Focus-Application $run
    Click-Control 109;Select-Target $run.title
    Assert-State ([PinApplication]::IsWindowEnabled([PinApplication]::GetDlgItem($ui,111))) 'Main window remains configurable after its dialog is cancelled'
    return @{status='Passed';checks=$stateChecks.ToArray();trace=$dialogTrace;dialog_handle=$appDialog.ToInt64();dialog_pid=$dialogPid;parent_pid=$run.pid;input_method='Owned foreground Ctrl+O and real Ctrl+Alt+F10/F9; cancel via WM_CLOSE; no file chosen.'}
}
function Fullscreen-Application($run){
    $script:stateChecks=[Collections.Generic.List[string]]::new()
    Focus-Application $run
    Start-Sleep -Milliseconds 2000
    Keys-Application $run $run.handle 0x7a
    $monitor=[PinApplication+Monitor]::new();$monitor.Size=[Runtime.InteropServices.Marshal]::SizeOf($monitor)
    if(-not [PinApplication]::GetMonitorInfoW([PinApplication]::MonitorFromWindow($run.handle,2),[ref]$monitor)){throw 'Fullscreen monitor query failed'}
    $screen=@{left=$monitor.Bounds.Left;top=$monitor.Bounds.Top;right=$monitor.Bounds.Right;bottom=$monitor.Bounds.Bottom}
    Wait-Application {(Bounds-Error (Bounds-Application $run.handle) $screen) -le 2} 'owned real fullscreen state'
    Start-Sleep -Milliseconds 200
    $before=Bounds-Application $run.handle;$isZoomed=[PinApplication]::IsZoomed($run.handle)
    $hash=(Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash
    foreach($key in @(0x79,0x78)){
        Click-Control 109
        Keys-Application $run $run.handle $key 3
        Wait-Application {(Read-Control ([PinApplication]::GetDlgItem($ui,138))) -match '全屏'} 'honest fullscreen refusal'
        Assert-State ((Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash -eq $hash -and (Bounds-Error (Bounds-Application $run.handle) $before) -eq 0 -and [PinApplication]::GetForegroundWindow() -eq $run.handle) ('Fullscreen real hotkey '+$key+' refuses without moving, rewriting or refocusing')
    }
    Keys-Application $run $run.handle 0x7a
    Wait-Application {(Bounds-Error (Bounds-Application $run.handle) $screen) -gt 2} 'exit own real fullscreen'
    return @{status='Passed';checks=$stateChecks.ToArray();is_zoomed_while_fullscreen=$isZoomed;input_method='Owned foreground real F11 fullscreen toggle and Ctrl+Alt+F10/F9.'}
}
try {
    if($TemporaryDialogs -or $Fullscreen -or $HotkeyStates -or $TitleRules){
        $script:existingInputHost=$false
        [PinApplication]::EnumWindows({param($handle,$data) $class=[Text.StringBuilder]::new(128);[PinApplication]::GetClassNameW($handle,$class,128)|Out-Null;if($class.ToString() -eq 'ScreenPin.Host'){$script:existingInputHost=$true};return $true},[IntPtr]::Zero)|Out-Null
        if($script:existingInputHost){throw 'Existing Screen Pin instance detected; real application input is cancelled before launch'}
    }
    $process=Start-Process -FilePath $ExePath -ArgumentList '--show','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    Wait-Application {
        [PinApplication]::EnumWindows({param($handle,$data)
            $ownerPid=0;[PinApplication]::GetWindowThreadProcessId($handle,[ref]$ownerPid)|Out-Null
            if($ownerPid -eq $process.Id){$class=[Text.StringBuilder]::new(128);[PinApplication]::GetClassNameW($handle,$class,128)|Out-Null;if($class.ToString() -eq 'ScreenPin.Settings'){$script:ui=$handle};if($class.ToString() -eq 'ScreenPin.Host'){$script:hostWindow=$handle}}
            return $true
        },[IntPtr]::Zero)|Out-Null
        $ui -ne [IntPtr]::Zero -and (Read-Control ([PinApplication]::GetDlgItem($ui,138))) -notin @('','正在处理…')
    } 'Screen Pin initial refresh'
    if($TemporaryDialogs -or $Fullscreen -or $HotkeyStates -or $TitleRules){$status=Read-Control ([PinApplication]::GetDlgItem($ui,208));if(([regex]::Matches($status,'已注册')).Count -ne 2 -or $status -match '不可用'){throw 'Owned Screen Pin does not have both hotkeys registered; no application input sent'}}
    foreach($spec in @(@{name='Brave';path=$BravePath},@{name='VSCode';path=$CodePath})) {
        $script:dialogTrace=@()
        $result=[ordered]@{application=$spec.name;status='Skipped';reason='';checks=@()}
        $run=$null
        try {
            if(-not (Test-Path -LiteralPath $spec.path)){$result.reason='Executable unavailable';continue}
            $executable=Get-Item -LiteralPath $spec.path
            $result.version=$executable.VersionInfo.ProductVersion
            $result.executable=$executable.FullName
            $profile=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ($spec.name+'-profile-'+$unique))).FullName
            $title='ScreenPinAppSmoke-'+$unique+'-'+$spec.name
            $result.profile=$profile
            $result.unique_title=$title
            if($spec.name -eq 'Brave') {
                $document=Join-Path $OutputDir ($title+'.html')
                '<!doctype html><html><head><meta charset="utf-8"><title>'+ $title +'</title></head><body><h1>Screen Pin isolated application test</h1><p>This local test document can be closed.</p></body></html>'|Set-Content -LiteralPath $document -Encoding utf8
                $arguments=@(('--user-data-dir="'+$profile+'"'),'--no-first-run','--no-default-browser-check','--new-window',('"'+[Uri]::new($document).AbsoluteUri+'"'))
            } else {
                $document=Join-Path $OutputDir ($title+'.txt')
                'Screen Pin isolated application test. This document is never edited.'|Set-Content -LiteralPath $document -Encoding utf8
                $extensions=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('extensions-'+$unique))).FullName
                $settingsDirectory=(New-Item -ItemType Directory -Path (Join-Path $profile 'User')).FullName
                @{'workbench.startupEditor'='none';'window.restoreWindows'='none';'update.mode'='none';'telemetry.telemetryLevel'='off';'security.workspace.trust.enabled'=$false}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $settingsDirectory 'settings.json') -Encoding utf8
                $arguments=@(('--user-data-dir="'+$profile+'"'),('--extensions-dir="'+$extensions+'"'),'--disable-extensions','--skip-welcome','--skip-release-notes','--new-window',('"'+$document+'"'))
            }
            $launched=Start-Process -FilePath $executable.FullName -ArgumentList $arguments -WindowStyle Hidden -PassThru
            $run=[pscustomobject]@{name=$spec.name;executable=$executable.FullName;profile=$profile;title=$title;handle=[IntPtr]::Zero;pid=0;launcher=$launched;document=$document;rule_documents=@{}}
            $runs.Add($run)
            $script:isolatedWindow=[IntPtr]::Zero
            $script:isolatedPid=0
            try {
                Wait-Application {
                    [PinApplication]::EnumWindows({param($handle,$data)
                        if((Window-Title $handle).Contains($title)) {
                            $ownerPid=0;[PinApplication]::GetWindowThreadProcessId($handle,[ref]$ownerPid)|Out-Null
                            $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$ownerPid)
                            if($owner.ExecutablePath -eq $executable.FullName -and $owner.CommandLine.Contains($profile)){$script:isolatedWindow=$handle;$script:isolatedPid=$ownerPid}
                        };return $true
                    },[IntPtr]::Zero)|Out-Null
                    $script:isolatedWindow -ne [IntPtr]::Zero
                } ('uniquely owned '+$spec.name+' document window') 25
            } catch {$result.reason=$_.Exception.Message;continue}
            $run.handle=$script:isolatedWindow
            $run.pid=$script:isolatedPid
            $owner=Confirm-ApplicationOwner $run
            [PinApplication]::ShowWindow($run.handle,9)|Out-Null
            Wait-Application {-not [PinApplication]::IsZoomed($run.handle)} 'normal window state'
            $monitor=[PinApplication+Monitor]::new()
            $monitor.Size=[Runtime.InteropServices.Marshal]::SizeOf($monitor)
            if(-not [PinApplication]::GetMonitorInfoW([PinApplication]::MonitorFromWindow($run.handle,2),[ref]$monitor)){throw 'Monitor query failed'}
            $initialX=$monitor.Work.Left+120
            $initialY=$monitor.Work.Top+100
            $initialWidth=[Math]::Min(1100,$monitor.Work.Right-$monitor.Work.Left-180)
            $initialHeight=[Math]::Min(760,$monitor.Work.Bottom-$monitor.Work.Top-160)
            [PinApplication]::SetWindowPos($run.handle,[IntPtr]::Zero,$initialX,$initialY,$initialWidth,$initialHeight,0x4014)|Out-Null
            Start-Sleep -Milliseconds 300
            Confirm-ApplicationOwner $run|Out-Null
            Click-Control 109
            Select-Target $title
            if(-not [PinApplication]::IsWindowEnabled([PinApplication]::GetDlgItem($ui,111))){throw 'Remember button is disabled for the owned application window'}
            $before=Bounds-Application $run.handle
            Click-Control 111
            $rememberFeedback=Read-Control ([PinApplication]::GetDlgItem($ui,138))
            if($rememberFeedback -notmatch '已记住|已更新|已保存|无变化'){throw ('Unexpected remember feedback: '+$rememberFeedback)}
            Confirm-ApplicationOwner $run|Out-Null
            [PinApplication]::SetWindowPos($run.handle,[IntPtr]::Zero,($initialX+210),($initialY+90),($initialWidth-160),($initialHeight-100),0x4014)|Out-Null
            Start-Sleep -Milliseconds 180
            $moved=Bounds-Application $run.handle
            if($before.left -eq $moved.left -and $before.top -eq $moved.top -and $before.right -eq $moved.right -and $before.bottom -eq $moved.bottom){throw 'The isolated target did not move; restore would not be a valid test'}
            $foreground=[PinApplication]::GetForegroundWindow()
            Click-Control 112
            $restored=Bounds-Application $run.handle
            $restoreFeedback=Read-Control ([PinApplication]::GetDlgItem($ui,138))
            $focusUnchanged=[PinApplication]::GetForegroundWindow() -eq $foreground
            $errors=[ordered]@{}
            foreach($edge in @('left','top','right','bottom')){$errors[$edge]=[Math]::Abs($restored[$edge]-$before[$edge])}
            if(($errors.Values|Where-Object {$_ -gt 2}).Count -gt 0){throw ('DWM edge errors exceed 2 physical pixels: '+($errors|ConvertTo-Json -Compress))}
            if($restoreFeedback -notmatch '已恢复|已符合'){throw ('Unexpected restore feedback: '+$restoreFeedback)}
            if(-not $focusUnchanged){throw 'Restore or status feedback changed the foreground window'}
            $result=[ordered]@{application=$spec.name;status='Passed';version=$executable.VersionInfo.ProductVersion;executable=$executable.FullName;pid=$run.pid;handle=$run.handle.ToInt64();command_line=$owner.CommandLine;profile=$profile;unique_title=$title;monitor=$monitor;dpi=[PinApplication]::GetDpiForWindow($run.handle);before=$before;moved=$moved;restored=$restored;physical_edge_errors=$errors;remember_feedback=$rememberFeedback;restore_feedback=$restoreFeedback;foreground_unchanged=$focusUnchanged;checks=@('isolated profile and process ownership verified','selected GUI capture','target was actually moved','DWM edges restored within 2 physical pixels','success feedback confirmed','foreground unchanged')}
            if($PrecisionCycles){$result['precision']=Precision-Application $run}
            if($ExtendedStates){$result['extended_states']=States-Application $run}
            if($HotkeyStates){$result['hotkey_states']=HotkeyStates-Application $run}
            if($TitleRules){$result['title_rules']=TitleRules-Application $run}
            if($TemporaryDialogs){$result['temporary_dialog']=Dialog-Application $run}
            if($Fullscreen){$result['fullscreen']=Fullscreen-Application $run}
        } catch {
            $result.status='Failed';$result.reason=$_.Exception.Message
            if($TemporaryDialogs -or $Fullscreen -or $HotkeyStates -or $TitleRules){$script:inputCancelled=$true}
            if(($TemporaryDialogs -or $Fullscreen -or $HotkeyStates -or $TitleRules) -and $run -and $run.pid){
                $result['input_diagnostics']=[PinApplicationInput]::Snapshot($run.pid)
                if($dialogTrace){$result['dialog_trace']=$dialogTrace}
                try{
                    Confirm-ApplicationOwner $run|Out-Null
                    $rect=[PinApplication+Rect]::new();[PinApplication]::GetWindowRect($run.handle,[ref]$rect)|Out-Null
                    $bitmap=[Drawing.Bitmap]::new($rect.Right-$rect.Left,$rect.Bottom-$rect.Top);$graphics=[Drawing.Graphics]::FromImage($bitmap);$dc=$graphics.GetHdc()
                    [PinApplication]::PrintWindow($run.handle,$dc,2)|Out-Null;$graphics.ReleaseHdc($dc)
                    $imagePath=Join-Path $OutputDir ($run.name+'-failure.png');$bitmap.Save($imagePath,[Drawing.Imaging.ImageFormat]::Png)
                    $graphics.Dispose();$bitmap.Dispose();$result['failure_image']=$imagePath
                }catch{$result['image_error']=$_.Exception.Message}
            }
        }
        finally {
            if($run -and $run.handle -ne [IntPtr]::Zero){try{Close-Application $run;$result.cleanup='Normal WM_CLOSE; owned main process exited'}catch{$result.cleanup=$_.Exception.Message;$result.status='Failed'}}
            $results.Add($result)
        }
        if($inputCancelled){break}
    }
} finally {
    foreach($run in $runs){if($run.handle -ne [IntPtr]::Zero -and [PinApplication]::IsWindow($run.handle)){try{Close-Application $run}catch{Write-Warning $_.Exception.Message}}}
    if($process -and -not $process.HasExited -and $hostWindow -ne [IntPtr]::Zero){
        $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id)
        if($owner.ExecutablePath -eq $ExePath -and $owner.CommandLine.Contains($configDir)){
            [PinApplication]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null
            Wait-Application {$process.Refresh();$process.HasExited} 'Screen Pin exit'
        }else{throw 'Screen Pin ownership changed; refusing cleanup command'}
    }
    [PinApplication]::SetThreadDpiAwarenessContext($previousDpi)|Out-Null
}
$startupAfter=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
$ownedProfiles=@($results|ForEach-Object {$_.profile}|Where-Object {$_})
$cleanupDeadline=[DateTime]::UtcNow.AddSeconds(8)
do {
    $remaining=@(Get-CimInstance Win32_Process|Where-Object {$commandLine=$_.CommandLine;$commandLine -and @($ownedProfiles|Where-Object {$commandLine.Contains($_)}).Count -gt 0}|Select-Object ProcessId,ExecutablePath)
    if($remaining.Count -eq 0){break}
    Start-Sleep -Milliseconds 50
} while([DateTime]::UtcNow -lt $cleanupDeadline)
$os=Get-CimInstance Win32_OperatingSystem
$report=[ordered]@{executed=[DateTimeOffset]::Now.ToString('o');screen_pin_executable=$ExePath;screen_pin_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;config=$configDir;system=@{caption=$os.Caption;version=$os.Version;build=$os.BuildNumber;architecture=$os.OSArchitecture};applications=$results.ToArray();screen_pin_exited=$process.HasExited;hkcu_startup_unchanged=($startupBefore -ceq $startupAfter);limitations=@('one physical display and current DPI only','ordinary application windows only; no elevated app tested','independent app profiles; existing user sessions were not operated','machine has development tools; this does not prove clean-machine deployment')}
$report['remaining_owned_application_processes']=$remaining
$report['cleanup_check_scope']='Owned main-process exit plus a post-close command-line scan for the unique isolated user-data directories; no process-name termination.'
$report['extended_states_requested']=$ExtendedStates.IsPresent
$report['script_sha256']=$scriptHash
$report['native_helper_sha256']=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'support/application-native.cs')).Hash
$report['precision_cycles_requested']=$PrecisionCycles
if($ExtendedStates){$report.limitations=@('one physical display/current DPI; default taskbar configuration only','ordinary/maximized/minimized states through GUI commands, not real hotkey input','no fullscreen/dialog/elevated app test','independent profiles; no pre-existing user window operated','machine has development tools; does not prove clean-machine deployment')}
$report['temporary_dialog_requested']=$TemporaryDialogs.IsPresent
$report['fullscreen_requested']=$Fullscreen.IsPresent
$report['hotkey_states_requested']=$HotkeyStates.IsPresent
$report['title_rules_requested']=$TitleRules.IsPresent
if($TitleRules){$report['controls_helper_sha256']=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'support/real-keys.cs')).Hash}
$report['hotkey_cycles_requested']=if($HotkeyStates){$HotkeyCycles}else{0}
$report['input_cancelled']=$inputCancelled
if($TemporaryDialogs -or $Fullscreen -or $HotkeyStates -or $TitleRules){$report['input_helper_sha256']=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'support/application-input.cs')).Hash;$report.limitations=@('one physical display/current DPI and default taskbar configuration only','only the requested GUI and real hotkey state/dialog/fullscreen cases; no elevated app tested','Ctrl+O requests the owned common file dialog; no file is selected','input is checked against owned foreground/class/PID immediately before and after; observed user switching cancels later input','machine has development tools; does not prove clean-machine deployment')}
$report['passed']=$results.Count -eq 2 -and @($results|Where-Object {$_.status -ne 'Passed'}).Count -eq 0 -and $report.screen_pin_exited -and $report.hkcu_startup_unchanged -and $remaining.Count -eq 0
$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $OutputDir 'application-smoke.json') -Encoding utf8
$report|ConvertTo-Json -Depth 12
if(-not $report.passed){exit 1}
