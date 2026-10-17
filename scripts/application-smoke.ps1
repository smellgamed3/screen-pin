#Requires -Version 7.0
param(
    [string]$ExePath = (Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir = (Join-Path $PSScriptRoot ('../artifacts/application-smoke-' + [Guid]::NewGuid().ToString('N'))),
    [string]$BravePath = 'C:/Program Files/BraveSoftware/Brave-Browser/Application/brave.exe',
    [string]$CodePath = (Join-Path $env:LOCALAPPDATA 'Programs/Microsoft VS Code/Code.exe')
)
$ErrorActionPreference = 'Stop'
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
$previousDpi = [PinApplication]::SetThreadDpiAwarenessContext([IntPtr](-4))
$process = $null
$ui = [IntPtr]::Zero
$hostWindow = [IntPtr]::Zero
$runs = [Collections.Generic.List[object]]::new()
$results = [Collections.Generic.List[object]]::new()
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
    $ownedProcess=[Diagnostics.Process]::GetProcessById($run.pid)
    [PinApplication]::PostMessageW($run.handle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Wait-Application {-not [PinApplication]::IsWindow($run.handle)} ('close isolated '+$run.name)
    Wait-Application {$ownedProcess.Refresh();$ownedProcess.HasExited} ('exit isolated '+$run.name)
}
try {
    $process=Start-Process -FilePath $ExePath -ArgumentList '--show','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    Wait-Application {
        [PinApplication]::EnumWindows({param($handle,$data)
            $ownerPid=0;[PinApplication]::GetWindowThreadProcessId($handle,[ref]$ownerPid)|Out-Null
            if($ownerPid -eq $process.Id){$class=[Text.StringBuilder]::new(128);[PinApplication]::GetClassNameW($handle,$class,128)|Out-Null;if($class.ToString() -eq 'ScreenPin.Settings'){$script:ui=$handle};if($class.ToString() -eq 'ScreenPin.Host'){$script:hostWindow=$handle}}
            return $true
        },[IntPtr]::Zero)|Out-Null
        $ui -ne [IntPtr]::Zero -and (Read-Control ([PinApplication]::GetDlgItem($ui,138))) -notin @('','正在处理…')
    } 'Screen Pin initial refresh'
    foreach($spec in @(@{name='Brave';path=$BravePath},@{name='VSCode';path=$CodePath})) {
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
                $arguments=@(('--user-data-dir="'+$profile+'"'),('--extensions-dir="'+$extensions+'"'),'--disable-extensions','--new-window',('"'+$document+'"'))
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
        } catch {$result.status='Failed';$result.reason=$_.Exception.Message}
        finally {
            if($run -and $run.handle -ne [IntPtr]::Zero){try{Close-Application $run;$result.cleanup='Normal WM_CLOSE; owned main process exited'}catch{$result.cleanup=$_.Exception.Message;$result.status='Failed'}}
            $results.Add($result)
        }
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
$os=Get-CimInstance Win32_OperatingSystem
$report=[ordered]@{executed=[DateTimeOffset]::Now.ToString('o');screen_pin_executable=$ExePath;screen_pin_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;config=$configDir;system=@{caption=$os.Caption;version=$os.Version;build=$os.BuildNumber;architecture=$os.OSArchitecture};applications=$results.ToArray();screen_pin_exited=$process.HasExited;hkcu_startup_unchanged=($startupBefore -ceq $startupAfter);limitations=@('one physical display and current DPI only','ordinary application windows only; no elevated app tested','independent app profiles; existing user sessions were not operated','machine has development tools; this does not prove clean-machine deployment')}
$report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $OutputDir 'application-smoke.json') -Encoding utf8
$report|ConvertTo-Json -Depth 12
if(($results|Where-Object {$_.status -eq 'Failed'}).Count -gt 0 -or -not $report.hkcu_startup_unchanged){exit 1}
