#Requires -Version 7.0
param(
    [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/tray-keyboard'),
    [string]$UiaProbePath=(Join-Path $PSScriptRoot '../target/debug/accessibility_probe.exe')
)
$ErrorActionPreference='Stop'
$ExePath=(Get-Item -LiteralPath $ExePath).FullName
$UiaProbePath=(Get-Item -LiteralPath $UiaProbePath).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('tray-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'config')).FullName
$configPath=Join-Path $configDir 'config.json'
$helpers=@((Join-Path $PSScriptRoot 'support/real-keys.cs'),(Join-Path $PSScriptRoot 'support/desktop-keyboard.cs'))
foreach($helper in $helpers){Add-Type -Path $helper}
Add-Type -AssemblyName UIAutomationClient
$report=[ordered]@{started_utc=[DateTime]::UtcNow.ToString('o');exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;helpers=@($helpers|ForEach-Object {@{path=$_;sha256=(Get-FileHash -LiteralPath $_).Hash}});config_dir=$configDir;checks=@();menus=@();navigation=@();errors=@();normal_exit=$false;passed=$false;scope='Per-case UIA setup focus of owned fixture only; real F10 capture, Win+B/arrow/Enter to tray, Shift+F10 and real keyboard menu navigation. No injected tray callback or WM_COMMAND for test actions.';limitations=@('Current Windows desktop/language/current DPI only; not a Narrator listening test.','Input ownership checks cannot atomically lock Windows foreground.','Cleanup uses owned messages if the tested keyboard exit fails; forced cleanup is never counted as a pass.')}
$process=$null;$hostWindow=[IntPtr]::Zero;$settings=[IntPtr]::Zero;$explorerPid=0
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-Tray($condition,[string]$message){if(-not $condition){throw $message};$report.checks+=$message}
function Wait-Tray([scriptblock]$condition,[string]$description){$watch=[Diagnostics.Stopwatch]::StartNew();do{if(& $condition){return};Start-Sleep -Milliseconds 20}while($watch.ElapsedMilliseconds -lt 6000);throw ('Timeout: '+$description)}
function Status-Tray {[PinRealKeys]::Text($settings,138)}
function Config-Tray {[PinRealKeys]::ReadConfig($configPath)|ConvertFrom-Json}
function Content-Tray($config){$copy=$config|ConvertTo-Json -Depth 20|ConvertFrom-Json;$copy.revision=0;foreach($profile in $copy.profiles){foreach($app in $profile.applications){if($null -ne $app.default){$app.default.revision=0};foreach($rule in $app.rules){$rule.preset.revision=0}}};return $copy|ConvertTo-Json -Depth 20 -Compress}
function Hash-Tray {(Get-FileHash -LiteralPath $configPath).Hash}
function Confirm-TrayProcess {$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.Id);if(-not $owner -or $owner.ExecutablePath -ine $ExePath -or -not $owner.CommandLine.Contains('"'+$configDir+'"')){throw 'Owned application identity changed'}}
function Focus-TrayFixture {
    $inputPath=Join-Path $runDir 'focus-input.json';$outputPath=Join-Path $runDir 'focus-output.json'
    ConvertTo-Json -InputObject @(@{handle=[PinRealKeys]::Fixture.ToInt64();id=0;page='activation'})|Set-Content -LiteralPath $inputPath -Encoding utf8
    & $UiaProbePath $inputPath $outputPath $PID --focus
    if($LASTEXITCODE -ne 0){throw 'Owned fixture initial focus failed'}
    Wait-Tray {[PinRealKeys]::GetForegroundWindow() -eq [PinRealKeys]::Fixture} 'fixture foreground'
    [PinRealKeys]::AssertForeground()
}
function Focused-Tray {return [System.Windows.Automation.AutomationElement]::FocusedElement}
function Overflow-Tray {
    $windows=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
    for($i=0;$i -lt $windows.Count;$i++){$current=$windows.Item($i).Current;if($current.ProcessId -eq $explorerPid -and $current.ClassName -in @('NotifyIconOverflowWindow','TopLevelWindowForOverflowXamlIsland') -and -not $current.IsOffscreen -and $current.BoundingRectangle.Width -gt 0){return $true}}
    return $false
}
function Assert-ShellFocus {
    $element=Focused-Tray;$current=$element.Current
    if($current.ProcessId -ne $explorerPid -or -not $current.HasKeyboardFocus){throw 'Focus left the verified Explorer notification area; input cancelled'}
    $walker=[System.Windows.Automation.TreeWalker]::RawViewWalker;$node=$element;$rootClass=''
    for($i=0;$i -lt 20 -and $null -ne $node;$i++){$c=$node.Current.ClassName;if($c -in @('Shell_TrayWnd','NotifyIconOverflowWindow','TopLevelWindowForOverflowXamlIsland')){$rootClass=$c;break};$node=$walker.GetParent($node)}
    $foreground=[PinDesktopKeyboard]::GetForegroundWindow()
    if(-not $rootClass -or [PinDesktopKeyboard]::Owner($foreground) -ne $explorerPid){throw ('Foreground/focus is not in the notification area; class='+[PinDesktopKeyboard]::Class($foreground))}
    return $element
}
function Press-Shell([int]$key,[int]$modifier=0){$null=Assert-ShellFocus;$foreground=[PinDesktopKeyboard]::GetForegroundWindow();[PinDesktopKeyboard]::Press($foreground,$explorerPid,$key,$modifier);Start-Sleep -Milliseconds 80}
function Own-TrayFocus {
    $element=Assert-ShellFocus;$current=$element.Current
    if(-not $current.Name.StartsWith('Screen Pin · 恢复 Ctrl+Alt+F9 · 记住 Ctrl+Alt+F10')){return $false}
    $icon=[PinDesktopKeyboard]::IconRect($hostWindow,$process.Id);$rect=$current.BoundingRectangle
    if($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0 -or [Math]::Abs(($rect.Left+$rect.Width/2)-($icon.Left+$icon.Right)/2) -gt 4 -or [Math]::Abs(($rect.Top+$rect.Height/2)-($icon.Top+$icon.Bottom)/2) -gt 4){throw 'Focused icon does not match the owned Shell_NotifyIconGetRect rectangle'}
    $report['icon_name']=$current.Name;$report['icon_rectangle']=@{left=$icon.Left;top=$icon.Top;right=$icon.Right;bottom=$icon.Bottom};return $true
}
function Open-TrayMenu {
    [PinRealKeys]::AssertForeground()
    [PinDesktopKeyboard]::Press([PinRealKeys]::Fixture,$PID,0x42,0x5b)
    Wait-Tray {$f=Focused-Tray;$f.Current.ProcessId -eq $explorerPid -and $f.Current.HasKeyboardFocus} 'Win+B enters notification area'
    $seen=@{};$openedOverflow=$false
    for($step=0;$step -lt 50;$step++){
        if(Own-TrayFocus){break}
        $element=Assert-ShellFocus;$current=$element.Current;$runtime=$element.GetRuntimeId() -join ','
        if($seen.ContainsKey($runtime)){throw 'Tray navigation cycled without reaching the owned icon'};$seen[$runtime]=$true
        $isOverflow=$current.ClassName -eq 'SystemTray.NormalButton' -and $current.Name -in @('显示隐藏的图标','Show hidden icons')
        $report.navigation+=@{step=$step;class=$current.ClassName;automation_id=$current.AutomationId;overflow=$isOverflow}
        if($isOverflow -and -not $openedOverflow){
            # A previous menu may leave the overflow flyout open while Win+B
            # focuses its toggle. Close that known flyout before reopening it.
            $wasOpen=Overflow-Tray;$report.navigation[-1]['overflow_open_before']=$wasOpen
            if($wasOpen){Press-Shell 0x0d;Wait-Tray {-not (Overflow-Tray)} 'existing overflow closes';Start-Sleep -Milliseconds 300;$null=Assert-ShellFocus}
            Press-Shell 0x0d
            Wait-Tray {$f=Assert-ShellFocus;($f.GetRuntimeId() -join ',') -ne $runtime} 'overflow receives actual keyboard focus'
            $openedOverflow=$true
        }else{Press-Shell 0x27}
    }
    Assert-Tray (Own-TrayFocus) 'Win+B and keyboard navigation reach the owned notification icon'
    Press-Shell 0x79 0x10
    Wait-Tray {[PinDesktopKeyboard]::Menu($hostWindow,$process.Id) -ne [IntPtr]::Zero} 'real Shift+F10 opens owned tray menu'
    [PinDesktopKeyboard]::AssertForeground($hostWindow,$process.Id)
    $items=[PinDesktopKeyboard]::Items($hostWindow,$process.Id);$report.menus+=,@($items)
    Assert-Tray ($items[0].id -eq 400 -and $items[1].id -eq 401 -and $items[4].id -eq 402 -and $items[5].id -eq 403) 'Actual keyboard-opened menu exposes open, undo and exit at the expected command IDs'
}
function Choose-Tray([uint32]$command){
    [PinDesktopKeyboard]::Press($hostWindow,$process.Id,0x24,0);Start-Sleep -Milliseconds 30
    for($i=0;$i -lt 6;$i++){$items=[PinDesktopKeyboard]::Items($hostWindow,$process.Id);if(@($items|Where-Object {$_.id -eq $command -and $_.highlighted -and $_.enabled}).Count -eq 1){[PinDesktopKeyboard]::EnterMenu($hostWindow,$process.Id,$command);return};[PinDesktopKeyboard]::Press($hostWindow,$process.Id,0x28,0);Start-Sleep -Milliseconds 30}
    throw 'Intended menu command could not be selected safely'
}
function Stop-Tray {
    if($null -eq $process){return};$process.Refresh();if($process.HasExited){return};Confirm-TrayProcess
    if([PinDesktopKeyboard]::Menu($hostWindow,$process.Id) -ne [IntPtr]::Zero -and [PinDesktopKeyboard]::GetForegroundWindow() -eq $hostWindow){[PinDesktopKeyboard]::Press($hostWindow,$process.Id,0x1b,0);Start-Sleep -Milliseconds 50}
    if($hostWindow -eq [IntPtr]::Zero){$hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);if($hosts.Count -eq 1){$script:hostWindow=$hosts[0]}}
    if($hostWindow -ne [IntPtr]::Zero -and [PinDesktopKeyboard]::Owner($hostWindow) -eq $process.Id){[PinRealKeys]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null}
    if(-not $process.WaitForExit(8000)){Confirm-TrayProcess;$process.Kill();$process.WaitForExit();throw 'Owned app required forced cleanup'}
}
try{
    Assert-Tray ([PinRealKeys]::FindClass('ScreenPin.Host',0).Count -eq 0) 'No existing Screen Pin instance'
    $desktop=[System.Windows.Automation.AutomationElement]::RootElement
    $taskbar=$desktop.FindFirst([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty,'Shell_TrayWnd'))
    if($null -eq $taskbar){throw 'Explorer taskbar not found'};$explorerPid=$taskbar.Current.ProcessId
    $explorer=Get-CimInstance Win32_Process -Filter ('ProcessId='+$explorerPid)
    Assert-Tray ($explorer.ExecutablePath -ieq (Join-Path $env:WINDIR 'explorer.exe')) 'Notification area belongs to the system Explorer executable'
    $process=Start-Process -FilePath $ExePath -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    Wait-Tray {$hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);$windows=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id);if($hosts.Count -eq 1){$script:hostWindow=$hosts[0]};if($windows.Count -eq 1){$script:settings=$windows[0]};if($hostWindow -ne [IntPtr]::Zero -and $settings -ne [IntPtr]::Zero){try{return (Status-Tray) -notin @('','正在处理…')}catch{}};return $false} 'application ready'
    Confirm-TrayProcess
    $null=[PinRealKeys]::StartFixture();Focus-TrayFixture
    $revision=(Config-Tray).revision;[PinRealKeys]::Chord(0x79)
    Wait-Tray {(Config-Tray).revision -gt $revision -and (Status-Tray) -match '^已记住'} 'real initial capture'
    $baseline=Config-Tray;$original=$baseline.profiles[0].applications[0].default
    $initialFrame=[PinRealKeys]::Frame()
    $report['before_update']=$baseline
    $null=[PinRealKeys]::Move(440,340,620,430);$revision=(Config-Tray).revision;[PinRealKeys]::Chord(0x79)
    Wait-Tray {(Config-Tray).revision -gt $revision -and (Status-Tray) -match '^已记住'} 'real overwrite capture'
    $updated=Config-Tray;$report['after_update']=$updated
    $updatedFrame=[PinRealKeys]::Frame()
    Assert-Tray (($updated.profiles[0].applications[0].default.placement|ConvertTo-Json -Depth 12 -Compress) -ne ($original.placement|ConvertTo-Json -Depth 12 -Compress)) 'Two real F10 updates create a meaningful undo target'
    Open-TrayMenu
    Assert-Tray ([PinDesktopKeyboard]::Items($hostWindow,$process.Id)[1].enabled) 'Undo is enabled in the actual tray menu after a hotkey update'
    Choose-Tray 401
    Wait-Tray {(Status-Tray) -match '^已撤销'} 'keyboard tray undo'
    $undone=Config-Tray;$report['after_undo']=$undone
    Assert-Tray ((Content-Tray $undone) -eq (Content-Tray $baseline) -and $undone.revision -gt $updated.revision -and $undone.profiles[0].applications[0].default.revision -gt $updated.profiles[0].applications[0].default.revision) 'Tray keyboard undo restores previous content and identity with advancing transaction revisions'
    Assert-Tray ([PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$updatedFrame) -eq 0) 'Preset undo leaves the actual window rectangle unchanged'
    Focus-TrayFixture;$hash=Hash-Tray;[PinRealKeys]::Chord(0x78)
    Wait-Tray {[PinRealKeys]::EdgeError([PinRealKeys]::Frame(),$initialFrame) -le 2 -and (Status-Tray) -match '^已恢复|^已符合预设'} 'real F9 uses the undone preset'
    Assert-Tray ((Hash-Tray) -eq $hash) 'Real F9 restores the original position after tray undo without writing configuration'
    Open-TrayMenu
    Assert-Tray (-not [PinDesktopKeyboard]::Items($hostWindow,$process.Id)[1].enabled) 'Consumed undo is disabled in the next actual tray menu'
    Choose-Tray 400
    Wait-Tray {[PinDesktopKeyboard]::GetForegroundWindow() -eq $settings} 'tray keyboard open activates settings'
    Assert-Tray $true 'Tray Open can be selected using keyboard input'
    $hash=Hash-Tray;[PinDesktopKeyboard]::Press($settings,$process.Id,0x73,0x12)
    Wait-Tray {-not [PinDesktopKeyboard]::IsWindowVisible($settings)} 'Alt+F4 hides settings'
    Assert-Tray (-not $process.HasExited -and -not [PinDesktopKeyboard]::IsWindowVisible($settings)) 'Closing settings hides the window and retains the tray instance'
    Focus-TrayFixture;Open-TrayMenu;Choose-Tray 403
    Assert-Tray ($process.WaitForExit(8000) -and $process.ExitCode -eq 0) 'Keyboard tray Exit terminates the owned instance normally'
    $report.normal_exit=$true
    Assert-Tray ((Hash-Tray) -eq $hash) 'Opening, closing and exiting do not modify the preset'
    Focus-TrayFixture
    Assert-Tray ([PinRealKeys]::Block(0x78) -and [PinRealKeys]::Block(0x79)) 'Keyboard exit releases both real hotkeys'
    [PinRealKeys]::Unblock(0x78);[PinRealKeys]::Unblock(0x79)
}catch{$report.errors+=$_.Exception.Message;$report['failure_foreground_class']=[PinDesktopKeyboard]::Class([PinDesktopKeyboard]::GetForegroundWindow());try{$f=Focused-Tray;$report['failure_focus']=@{class=$f.Current.ClassName;automation_id=$f.Current.AutomationId;pid=$f.Current.ProcessId}}catch{}}
finally{
    try{Stop-Tray}catch{$report.errors+=('Cleanup: '+$_.Exception.Message)}
    try{[PinRealKeys]::StopFixture()}catch{$report.errors+=('Fixture cleanup: '+$_.Exception.Message)}
    $report['startup_registry_unchanged']=$startupBefore -ceq [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
    if(-not $report.startup_registry_unchanged){$report.errors+='Startup registration changed'}
    $report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report.passed=$report.errors.Count -eq 0 -and $report.normal_exit
    $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8
    Write-Host ('Tray keyboard report: '+(Join-Path $runDir 'report.json'))
}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
