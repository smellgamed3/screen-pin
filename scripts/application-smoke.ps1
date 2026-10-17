#Requires -Version 7.0
param(
    [string]$ExePath = (Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir = (Join-Path $PSScriptRoot ('../artifacts/application-smoke-' + [Guid]::NewGuid().ToString('N'))),
    [string]$BravePath = 'C:/Program Files/BraveSoftware/Brave-Browser/Application/brave.exe',
    [string]$CodePath = (Join-Path $env:LOCALAPPDATA 'Programs/Microsoft VS Code/Code.exe'),
    [switch]$ExtendedStates,
    [switch]$TemporaryDialogs,
    [switch]$Fullscreen
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$scriptHash=(Get-FileHash -LiteralPath $PSCommandPath).Hash
$ExePath = (Get-Item -LiteralPath $ExePath).FullName
$OutputDir = (New-Item -ItemType Directory -Path $OutputDir -Force).FullName
$configDir = (New-Item -ItemType Directory -Path (Join-Path $OutputDir ('config-' + [Guid]::NewGuid().ToString('N')))).FullName
$unique = [Guid]::NewGuid().ToString('N')
$startupBefore = [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PinApplication {
 public delegate bool EnumProc(IntPtr hwnd,IntPtr data);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback,IntPtr data);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hwnd,StringBuilder text,int length);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hwnd,StringBuilder text,int length);
 [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hwnd,int id);
 [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd,IntPtr dc,uint flags);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd,int command);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
 [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
 [DllImport("user32.dll",EntryPoint="SendMessageW",CharSet=CharSet.Unicode)] public static extern IntPtr SendText(IntPtr hwnd,uint msg,IntPtr wp,StringBuilder text);
 [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd,uint attr,out Rect rect,uint size);
 [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hwnd,uint flags);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr monitor,ref Monitor info);
 [StructLayout(LayoutKind.Sequential)] public struct Rect {public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct Monitor {public uint Size;public Rect Bounds,Work;public uint Flags;[MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string Device;}
}
'@
if($TemporaryDialogs -or $Fullscreen){Add-Type -Path (Join-Path $PSScriptRoot 'support/application-input.cs')}
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
    if($TemporaryDialogs -or $Fullscreen){
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
    if($TemporaryDialogs -or $Fullscreen){$status=Read-Control ([PinApplication]::GetDlgItem($ui,208));if(([regex]::Matches($status,'已注册')).Count -ne 2 -or $status -match '不可用'){throw 'Owned Screen Pin does not have both hotkeys registered; no application input sent'}}
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
            $run=[pscustomobject]@{name=$spec.name;executable=$executable.FullName;profile=$profile;title=$title;handle=[IntPtr]::Zero;pid=0;launcher=$launched}
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
            if($ExtendedStates){$result['extended_states']=States-Application $run}
            if($TemporaryDialogs){$result['temporary_dialog']=Dialog-Application $run}
            if($Fullscreen){$result['fullscreen']=Fullscreen-Application $run}
        } catch {
            $result.status='Failed';$result.reason=$_.Exception.Message
            if($TemporaryDialogs -or $Fullscreen){$script:inputCancelled=$true}
            if(($TemporaryDialogs -or $Fullscreen) -and $run -and $run.pid){
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
if($ExtendedStates){$report.limitations=@('one physical display/current DPI; default taskbar configuration only','ordinary/maximized/minimized states through GUI commands, not real hotkey input','no fullscreen/dialog/elevated app test','independent profiles; no pre-existing user window operated','machine has development tools; does not prove clean-machine deployment')}
$report['temporary_dialog_requested']=$TemporaryDialogs.IsPresent
$report['fullscreen_requested']=$Fullscreen.IsPresent
$report['input_cancelled']=$inputCancelled
if($TemporaryDialogs -or $Fullscreen){$report['input_helper_sha256']=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'support/application-input.cs')).Hash;$report.limitations=@('one physical display/current DPI and default taskbar configuration only','only the requested ordinary/state/dialog/fullscreen cases; no elevated app tested','Ctrl+O requests the owned common file dialog; no file is selected','input is checked against owned foreground/class/PID immediately before and after; observed user switching cancels later input','machine has development tools; does not prove clean-machine deployment')}
$report['passed']=$results.Count -eq 2 -and @($results|Where-Object {$_.status -ne 'Passed'}).Count -eq 0 -and $report.screen_pin_exited -and $report.hkcu_startup_unchanged -and $remaining.Count -eq 0
$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $OutputDir 'application-smoke.json') -Encoding utf8
$report|ConvertTo-Json -Depth 12
if(-not $report.passed){exit 1}
