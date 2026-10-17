#Requires -Version 7.0
param(
    [string]$ExePath=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
    [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/shell-apps'),
    [ValidateRange(20,100)][int]$Cycles=20
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
$shell=New-Object -ComObject Shell.Application
$report=[ordered]@{
    started_utc=[DateTime]::UtcNow.ToString('o');exe_path=$ExePath;exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash
    script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;native_helper_sha256=(Get-FileHash -LiteralPath $nativePath).Hash;controls_helper_sha256=(Get-FileHash -LiteralPath $controlsPath).Hash
    config_dir=$configDir;requested_cycles=$Cycles;applications=@();errors=@();normal_exit=$false;passed=$false
    scope='GUI command capture/restore only on newly created Explorer/Terminal windows; no keyboard/mouse injection, no Explorer restart or shared-host process termination.'
    limitations=@('Single display/current DPI; ordinary windows only, not administrator/maximized/fullscreen or physical multi-display tests.','Terminal uses installed user settings and a new single-tab window; no terminal settings file is rewritten.','Explorer and Terminal may share host processes with user windows; closure is per verified test HWND, not per process name.')
}
$process=$null;$settings=[IntPtr]::Zero;$hostWindow=[IntPtr]::Zero;$runs=[Collections.Generic.List[object]]::new()
$startupBefore=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Wait-ShellApp([scriptblock]$condition,[string]$description,[int]$seconds=15){$deadline=[DateTime]::UtcNow.AddSeconds($seconds);do{if(& $condition){return};Start-Sleep -Milliseconds 50}while([DateTime]::UtcNow -lt $deadline);throw ('Timeout: '+$description)}
function Title-ShellApp([IntPtr]$handle){$text=[Text.StringBuilder]::new(32768);[PinApplication]::GetWindowTextW($handle,$text,$text.Capacity)|Out-Null;return $text.ToString()}
function Frame-ShellApp([IntPtr]$handle){$rect=[PinApplication+Rect]::new();if([PinApplication]::DwmGetWindowAttribute($handle,9,[ref]$rect,16) -ne 0){throw 'DWM frame query failed'};return @{left=$rect.Left;top=$rect.Top;right=$rect.Right;bottom=$rect.Bottom}}
function Error-ShellApp($a,$b){$maximum=0;foreach($edge in @('left','top','right','bottom')){$maximum=[Math]::Max($maximum,[Math]::Abs($a[$edge]-$b[$edge]))};return $maximum}
function Existing-ShellAppHandles {return @([PinRealKeys]::FindClass('CabinetWClass',0))+@([PinRealKeys]::FindClass('CASCADIA_HOSTING_WINDOW_CLASS',0))}
function Confirm-ShellApp($run){
    if(-not [PinApplication]::IsWindow($run.handle) -or $run.before.Contains($run.handle)){throw 'Window is missing or predates this test launch'}
    [uint32]$ownerPid=0;[PinApplication]::GetWindowThreadProcessId($run.handle,[ref]$ownerPid)|Out-Null
    $owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$ownerPid)
    if($ownerPid -ne $run.pid -or -not $owner -or $owner.ExecutablePath -ine $run.executable -or -not (Title-ShellApp $run.handle).Contains($run.title)){throw 'Test window identity/title changed; refusing mutation'}
    if($run.kind -eq 'Explorer'){
        if([IntPtr]$run.view.HWND -ne $run.handle -or $run.view.Document.Folder.Self.Path -ine $run.folder){throw 'Explorer view is no longer the exact newly created test folder'}
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
    $class=[Text.StringBuilder]::new(256);[PinApplication]::GetClassNameW($run.handle,$class,$class.Capacity)|Out-Null
    $proof=@{new_hwnd=$true;before_hwnds=@($run.before|ForEach-Object {$_.ToInt64()});unique_title=$run.title}
    if($run.kind -eq 'Explorer'){$proof['exact_folder']=$run.folder;$proof['com_hwnd']=[long]$run.view.HWND}else{$proof['child_script']=$run.child_script;$proof['child_executable']=$run.child_executable;$proof['child_pid']=$run.child_pid}
    return @{application=$run.kind;status='Passed';window=$run.handle.ToInt64();window_class=$class.ToString();pid=$run.pid;ownership=$proof;monitor=$monitor;dpi=[PinApplication]::GetDpiForWindow($run.handle);executable=$owner.ExecutablePath;version=(Get-Item -LiteralPath $owner.ExecutablePath).VersionInfo.ProductVersion;cycles=$Cycles;max_edge_error_px=($samples.max_edge_error_px|Measure-Object -Maximum).Maximum;samples=$samples;saved_app_identities=@($config.profiles[0].applications|Select-Object app_id,app_name);closed_normally=$false}
}
try{
    if([PinRealKeys]::FindClass('ScreenPin.Host',0).Length){throw 'Existing Screen Pin instance detected; no user window or config operated'}
    $process=Start-Process -FilePath $ExePath -ArgumentList '--background','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
    Wait-ShellApp {$hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$process.Id);$windows=[PinRealKeys]::FindClass('ScreenPin.Settings',$process.Id);if($hosts.Length -eq 1 -and $windows.Length -eq 1 -and [PinRealKeys]::Text($windows[0],138) -notin @('','正在处理…')){$script:hostWindow=$hosts[0];$script:settings=$windows[0];return $true};return $false} 'Screen Pin startup'
    $token=[Guid]::NewGuid().ToString('N')
    $folder=(New-Item -ItemType Directory -Path (Join-Path $runDir ('ScreenPin-Explorer-'+$token))).FullName
    $explorer=[pscustomobject]@{kind='Explorer';handle=[IntPtr]::Zero;pid=0;executable=(Join-Path $env:WINDIR 'explorer.exe');title=(Split-Path $folder -Leaf);folder=$folder;view=$null;before=@(Existing-ShellAppHandles);closed=$false}
    $runs.Add($explorer)
    $launcher=Start-Process -FilePath $explorer.executable -ArgumentList ('/n,/separate,"'+$folder+'"') -WindowStyle Hidden -PassThru
    Wait-ShellApp {
        foreach($view in @($shell.Windows())){try{if($view.FullName -ieq $explorer.executable -and $view.Document.Folder.Self.Path -ieq $folder -and -not $explorer.before.Contains([IntPtr]$view.HWND)){$explorer.view=$view;$explorer.handle=[IntPtr]$view.HWND;[uint32]$ownerPid=0;[PinApplication]::GetWindowThreadProcessId($explorer.handle,[ref]$ownerPid)|Out-Null;$explorer.pid=$ownerPid;return $true}}catch{continue}};return $false
    } 'new Explorer window for the exact owned folder'
    $result=Exercise-ShellApp $explorer
    Close-ShellApp $explorer;$result.closed_normally=$explorer.closed;$report.applications+=$result

    $terminalPackage=Get-AppxPackage -Name Microsoft.WindowsTerminal
    if(-not $terminalPackage){throw 'Windows Terminal package is unavailable'}
    $terminalExe=Join-Path $terminalPackage.InstallLocation 'WindowsTerminal.exe'
    $terminalAlias=Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    $taskScript=Join-Path $runDir 'terminal-fixture.ps1';$readyPath=Join-Path $runDir 'terminal-ready.json'
    $title='ScreenPin-Terminal-'+$token
    $body=@'
$ErrorActionPreference='Stop'
$Host.UI.RawUI.WindowTitle='__TITLE__'
@{pid=$PID;token='__TITLE__'}|ConvertTo-Json|Set-Content -LiteralPath '__READY__' -Encoding utf8
Write-Host 'Screen Pin isolated terminal test. This window can be closed.'
'@
    [IO.File]::WriteAllText($taskScript,$body.Replace('__TITLE__',$title).Replace('__READY__',$readyPath.Replace("'","''")),[Text.UTF8Encoding]::new($true))
    $shellExe=(Get-Command pwsh.exe).Source
    $terminal=[pscustomobject]@{kind='Terminal';handle=[IntPtr]::Zero;pid=0;executable=$terminalExe;title=$title;before=@(Existing-ShellAppHandles);child_pid=0;child_executable=$shellExe;child_script=$taskScript;closed=$false}
    $runs.Add($terminal)
    $launcher=Start-Process -FilePath $terminalAlias -ArgumentList '-w','new','new-tab','--title',$title,'--suppressApplicationTitle',('"'+$shellExe+'"'),'-NoLogo','-NoProfile','-NoExit','-File',('"'+$taskScript+'"') -WindowStyle Hidden -PassThru
    Wait-ShellApp {
        if(-not (Test-Path -LiteralPath $readyPath)){return $false}
        $ready=Get-Content -LiteralPath $readyPath -Raw|ConvertFrom-Json;if($ready.token -ne $title){throw 'Terminal readiness token mismatch'};$terminal.child_pid=[uint32]$ready.pid
        foreach($handle in [PinRealKeys]::FindClass('CASCADIA_HOSTING_WINDOW_CLASS',0)){if(-not $terminal.before.Contains($handle) -and (Title-ShellApp $handle).Contains($title)){$terminal.handle=$handle;[uint32]$ownerPid=0;[PinApplication]::GetWindowThreadProcessId($handle,[ref]$ownerPid)|Out-Null;$terminal.pid=$ownerPid;return $true}};return $false
    } 'new Terminal window and its explicit fixture shell' 25
    $result=Exercise-ShellApp $terminal;$result['package_version']=$terminalPackage.Version;$result['test_child_pid']=$terminal.child_pid
    Close-ShellApp $terminal;$result.closed_normally=$terminal.closed;$report.applications+=$result
}catch{$report.errors+=$_.Exception.Message}
finally{
    foreach($run in $runs){try{Close-ShellApp $run}catch{$report.errors+=('Window cleanup: '+$_.Exception.Message)}}
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
