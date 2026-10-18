#Requires -Version 7.0
param(
 [Parameter(Mandatory)][string]$ExePath,
 [Parameter(Mandatory)][string]$OutputDir,
 [string]$ChildFixture
)
$ErrorActionPreference='Stop'
# This driver changes foreground only inside a fresh, explicitly opted-in guest.
$guestId=[Guid]::Empty
if(-not [Guid]::TryParse($env:SCREEN_PIN_FIXTURE_GUEST,[ref]$guestId) -or
 [string]::IsNullOrEmpty($env:SCREEN_PIN_FIXTURE_HOST) -or
 $env:COMPUTERNAME -eq $env:SCREEN_PIN_FIXTURE_HOST -or
 -not [Security.Principal.WindowsIdentity]::GetCurrent().Name.EndsWith('\WDAGUtilityAccount',[StringComparison]::OrdinalIgnoreCase)) {
 throw 'Edit-mode input verifier requires the isolated Sandbox fixture environment'
}
if($ChildFixture){
 Add-Type -Path (Join-Path $PSScriptRoot 'support/real-keys.cs')
 $fixture=[PinRealKeys]::StartFixture();[PinRealKeys]::FixtureTitle('Edit target Beta')
 @{hwnd=$fixture.ToInt64();pid=$PID}|ConvertTo-Json|Set-Content -LiteralPath $ChildFixture
 $deadline=[DateTime]::UtcNow.AddSeconds(85)
 [uint32]$fixtureOwner=0
 while([PinRealKeys]::GetWindowThreadProcessId($fixture,[ref]$fixtureOwner) -ne 0 -and $fixtureOwner -eq $PID -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
 [PinRealKeys]::StopFixture();exit 0
}
$editNative=@'
public static class PinEditChecks {
 [DllImport("user32.dll")]static extern IntPtr GetDlgItem(IntPtr h,int id);
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")]static extern IntPtr GetWindowLongPtrW(IntPtr h,int index);
 [DllImport("user32.dll")]static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
 [DllImport("user32.dll")]static extern IntPtr SendMessageTimeoutW(IntPtr h,uint m,IntPtr w,IntPtr l,uint flags,uint timeout,out UIntPtr result);
 [DllImport("user32.dll")]static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")]static extern bool PostMessageW(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")]static extern bool GetWindowRect(IntPtr h,out PinRealKeys.Rect r);
 [DllImport("dwmapi.dll")]static extern int DwmGetWindowAttribute(IntPtr h,int attr,out PinRealKeys.Rect r,int size);
 [DllImport("user32.dll")]public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 static void Owner(IntPtr h,uint expected){uint pid;GetWindowThreadProcessId(h,out pid);if(pid!=expected||expected==0)throw new InvalidOperationException("Owned edit-mode window changed identity");}
 public static bool Topmost(IntPtr h,uint pid){Owner(h,pid);return (GetWindowLongPtrW(h,-20).ToInt64()&8)!=0;}
 public static bool Visible(IntPtr h,uint pid){Owner(h,pid);return IsWindowVisible(h);}
 public static bool Minimized(IntPtr h,uint pid){Owner(h,pid);return IsIconic(h);}
 public static void Click(IntPtr h,uint pid,int id){Owner(h,pid);UIntPtr result;if(SendMessageTimeoutW(GetDlgItem(h,id),0xf5,IntPtr.Zero,IntPtr.Zero,0x23,1000,out result)==IntPtr.Zero)throw new InvalidOperationException("Owned edit-mode button timed out");}
 public static void Move(IntPtr h,uint pid,int x,int y,int width,int height){Owner(h,pid);if(!SetWindowPos(h,IntPtr.Zero,x,y,width,height,0x14))throw new InvalidOperationException("Owned target move failed");}
 public static PinRealKeys.Rect Frame(IntPtr h,uint pid){Owner(h,pid);PinRealKeys.Rect r;if(DwmGetWindowAttribute(h,9,out r,Marshal.SizeOf(typeof(PinRealKeys.Rect)))!=0)throw new InvalidOperationException("Owned frame query failed");return r;}
 public static PinRealKeys.Rect Bounds(IntPtr h,uint pid){Owner(h,pid);PinRealKeys.Rect r;if(!GetWindowRect(h,out r))throw new InvalidOperationException("Owned bounds query failed");return r;}
 public static void SystemCommand(IntPtr h,uint pid,int command){Owner(h,pid);if(!PostMessageW(h,0x112,new IntPtr(command),IntPtr.Zero))throw new InvalidOperationException("Owned system command failed");}
 public static void Close(IntPtr h,uint pid){Owner(h,pid);PostMessageW(h,0x10,IntPtr.Zero,IntPtr.Zero);}
 public static string Text(IntPtr h,uint pid,int id){Owner(h,pid);return PinRealKeys.Text(h,id);}
 public static void ExitHost(IntPtr h,uint pid){Owner(h,pid);PostMessageW(h,0x111,new IntPtr(403),IntPtr.Zero);}
}
'@
Add-Type -TypeDefinition ((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'support/real-keys.cs') -Raw)+$editNative)
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('edit-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$configDir=(New-Item -ItemType Directory -Path (Join-Path $runDir 'config') -Force).FullName
$ExePath=(Get-Item -LiteralPath $ExePath).FullName
$report=[ordered]@{exe_sha256=(Get-FileHash -LiteralPath $ExePath).Hash;script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;started_utc=[DateTime]::UtcNow.ToString('o');checks=@();errors=@();passed=$false;scope='New owned fixture processes, real foreground changes and native GUI buttons in a fresh guest; private config only. No host input or physical multi-monitor claim.'}
$app=$null;$second=$null;$ui=[IntPtr]::Zero;$hostWindow=[IntPtr]::Zero
function Assert-Edit($condition,[string]$message){if(-not $condition){throw $message};$report.checks+=$message}
function Wait-Edit([scriptblock]$condition,[string]$message){$limit=[DateTime]::UtcNow.AddSeconds(5);do{if(& $condition){return};Start-Sleep -Milliseconds 25}while([DateTime]::UtcNow -lt $limit);throw ('Timeout: '+$message)}
function Field-Edit([int]$id){[PinEditChecks]::Text($ui,$app.Id,$id)}
function Config-Edit {if(Test-Path -LiteralPath (Join-Path $configDir 'config.json')){[PinRealKeys]::ReadConfig((Join-Path $configDir 'config.json'))|ConvertFrom-Json}}
function Activate-Edit([IntPtr]$window,[int]$owner){[PinRealKeys]::ActivateGuestWindow($window,$owner);Wait-Edit {[PinRealKeys]::GetForegroundWindow() -eq $window} 'owned foreground'}
function Observe-Edit([string]$title){Wait-Edit {(Field-Edit 146) -match [regex]::Escape($title) -and [PinRealKeys]::Enabled($ui,$app.Id,111)} ('live target '+$title)}
function Geometry-Edit([IntPtr]$window,[int]$owner){$r=[PinEditChecks]::Frame($window,$owner);$position='位置 ('+$r.Left+', '+$r.Top+')';$size='大小 '+($r.Right-$r.Left)+' × '+($r.Bottom-$r.Top)+' px';Wait-Edit {(Field-Edit 147).Contains($position) -and (Field-Edit 147).Contains($size)} 'live physical frame';return $r}
function Snapshot-Edit {
 Add-Type -AssemblyName System.Drawing
 $r=[PinEditChecks]::Bounds($ui,$app.Id);$bitmap=[Drawing.Bitmap]::new($r.Right-$r.Left,$r.Bottom-$r.Top);$graphics=[Drawing.Graphics]::FromImage($bitmap);$dc=$graphics.GetHdc()
 try{if(-not [PinEditChecks]::PrintWindow($ui,$dc,2)){throw 'Owned panel screenshot failed'}}finally{$graphics.ReleaseHdc($dc)}
 try{$bitmap.Save((Join-Path $runDir 'edit-mode.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
}
try {
 $first=[PinRealKeys]::StartFixture();[PinRealKeys]::FixtureTitle('Edit target Alpha')
 $childPath=Join-Path $runDir 'beta.json'
 $second=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',('"'+$PSCommandPath+'"'),'-ExePath',('"'+$ExePath+'"'),'-OutputDir',('"'+$OutputDir+'"'),'-ChildFixture',('"'+$childPath+'"')) -WindowStyle Hidden -PassThru
 Wait-Edit {Test-Path -LiteralPath $childPath} 'second owned fixture ready'
 $beta=Get-Content -LiteralPath $childPath -Raw|ConvertFrom-Json;$betaWindow=[IntPtr][long]$beta.hwnd
 $app=Start-Process -FilePath $ExePath -ArgumentList @('--config-dir',('"'+$configDir+'"'),'--show') -RedirectStandardError (Join-Path $runDir 'app-stderr.txt') -PassThru
 Wait-Edit {$script:found=[PinRealKeys]::FindClass('ScreenPin.Settings',$app.Id);$found.Count -eq 1} 'own app ready';$ui=$found[0]
 Wait-Edit {$script:hosts=[PinRealKeys]::FindClass('ScreenPin.Host',$app.Id);$hosts.Count -eq 1 -and [PinRealKeys]::Enabled($ui,$app.Id,109)} 'own app idle';$hostWindow=$hosts[0]
 Activate-Edit $ui $app.Id
 $original=[PinEditChecks]::Bounds($ui,$app.Id)
 [PinRealKeys]::ControlText($ui,$app.Id,202,'Ctrl+Alt+F7')
 [PinEditChecks]::Click($ui,$app.Id,145)
 Assert-Edit ([PinEditChecks]::Topmost($ui,$app.Id)) 'Edit mode adds topmost without making the target modal'
 [PinEditChecks]::Move($first,$PID,800,120,620,430)
 Activate-Edit $first $PID;Observe-Edit 'Edit target Alpha';$saved=Geometry-Edit $first $PID
 Assert-Edit ([PinRealKeys]::GetForegroundWindow() -eq $first) 'Observation keeps the external app in foreground'
 Assert-Edit ((Config-Edit).profiles[0].applications.Count -eq 0) 'Observation creates no application preset'
 Activate-Edit $ui $app.Id;Observe-Edit 'Edit target Alpha'
 [PinEditChecks]::Click($ui,$app.Id,111);Wait-Edit {(Field-Edit 138) -match '^已记住'} 'remember through retained target'
 Assert-Edit ((Config-Edit).profiles[0].applications[0].default -ne $null) 'Remember button saves retained external target'
 Assert-Edit ((Field-Edit 202) -eq 'Ctrl+Alt+F7') 'Live updates and save preserve uncommitted settings input'
 $hash=(Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash
 [PinEditChecks]::Move($first,$PID,900,220,540,350);$null=Geometry-Edit $first $PID
 [PinEditChecks]::Click($ui,$app.Id,112);Wait-Edit {[PinRealKeys]::EdgeError([PinEditChecks]::Frame($first,$PID),$saved) -le 2} 'restore via retained target'
 Assert-Edit ((Get-FileHash -LiteralPath (Join-Path $configDir 'config.json')).Hash -eq $hash) 'Restore changes no config bytes'
 Assert-Edit ([PinRealKeys]::GetForegroundWindow() -eq $ui) 'Restore leaves focus on the app button'
 Activate-Edit $betaWindow $second.Id;Observe-Edit 'Edit target Beta';$null=Geometry-Edit $betaWindow $second.Id
 Assert-Edit ([PinEditChecks]::Topmost($ui,$app.Id)) 'Screen Pin stays topmost while another app is active'
 for($switch=0;$switch -lt 5;$switch++){Activate-Edit $first $PID;Observe-Edit 'Edit target Alpha';Activate-Edit $betaWindow $second.Id;Observe-Edit 'Edit target Beta'}
 Assert-Edit ($true) 'Ten consecutive target changes follow the actual foreground'
 Activate-Edit $ui $app.Id;Observe-Edit 'Edit target Beta'
 [PinEditChecks]::Move($betaWindow,$second.Id,850,250,580,360);$betaSaved=Geometry-Edit $betaWindow $second.Id
 [PinEditChecks]::Click($ui,$app.Id,111);Wait-Edit {(Field-Edit 138) -match '^已记住'} 'second target remember'
 Assert-Edit ([PinRealKeys]::EdgeError([PinEditChecks]::Frame($first,$PID),$saved) -le 2) 'Switching targets never moves the previous target'
 [PinEditChecks]::Move($betaWindow,$second.Id,1000,400,510,320);$null=Geometry-Edit $betaWindow $second.Id
 [PinEditChecks]::Click($ui,$app.Id,112);Wait-Edit {[PinRealKeys]::EdgeError([PinEditChecks]::Frame($betaWindow,$second.Id),$betaSaved) -le 2} 'second target restore'
 Assert-Edit ([PinRealKeys]::EdgeError([PinEditChecks]::Frame($first,$PID),$saved) -le 2) 'Restore affects only the latest target'
 $revision=(Config-Edit).revision
 [PinEditChecks]::SystemCommand($betaWindow,$second.Id,0xf020)
 Wait-Edit {[PinEditChecks]::Minimized($betaWindow,$second.Id)} 'minimize target'
 Wait-Edit {-not [PinRealKeys]::Enabled($ui,$app.Id,111)} 'minimized target disabled'
 [PinRealKeys]::Command($ui,$app.Id,111)
 Assert-Edit ((Config-Edit).revision -eq $revision) 'Minimized target cannot overwrite its preset'
 [PinEditChecks]::SystemCommand($betaWindow,$second.Id,0xf120)
 Wait-Edit {-not [PinEditChecks]::Minimized($betaWindow,$second.Id)} 'target restored before the next activation'
 Activate-Edit $first $PID;Observe-Edit 'Edit target Alpha'
 [PinRealKeys]::FixtureTitle('Edit target Alpha renamed');Observe-Edit 'Alpha renamed'
 Assert-Edit ($true) 'Window-title changes appear without manual refresh'
 Activate-Edit $ui $app.Id
 [PinEditChecks]::Close($first,$PID)
 Wait-Edit {-not [PinRealKeys]::Enabled($ui,$app.Id,111)} 'closed target disabled'
 Assert-Edit ($true) 'Closing the retained window removes the actionable target'
 Activate-Edit $betaWindow $second.Id;Observe-Edit 'Edit target Beta'
 Activate-Edit $ui $app.Id
 [PinEditChecks]::Move($betaWindow,$second.Id,1000,400,510,320);$null=Geometry-Edit $betaWindow $second.Id
 [PinRealKeys]::ChordToOwnedSettings($ui,$app.Id,0x78)
 Wait-Edit {[PinRealKeys]::EdgeError([PinEditChecks]::Frame($betaWindow,$second.Id),$betaSaved) -le 2 -and (Field-Edit 138) -match '^已恢复|^已符合'} 'real hotkey from edit panel'
 Assert-Edit ([PinRealKeys]::GetForegroundWindow() -eq $ui) 'Real panel hotkey restores the retained target without stealing focus'
 Snapshot-Edit
 $cpuStart=$app.TotalProcessorTime.TotalMilliseconds;$cpuWatch=[Diagnostics.Stopwatch]::StartNew();Start-Sleep -Seconds 5;$app.Refresh()
 $report['edit_idle_cpu_percent_one_core']=100*($app.TotalProcessorTime.TotalMilliseconds-$cpuStart)/$cpuWatch.Elapsed.TotalMilliseconds
 Assert-Edit ($report.edit_idle_cpu_percent_one_core -le 5) 'Idle edit-mode observation remains under five percent of one CPU core'
 $panel=[PinEditChecks]::Bounds($ui,$app.Id)
 Assert-Edit (($panel.Right-$panel.Left) -le 1000) 'The edit panel stays compact during repeated activation'
 [PinEditChecks]::Click($ui,$app.Id,145)
 Assert-Edit (-not [PinEditChecks]::Topmost($ui,$app.Id)) 'Leaving edit mode removes topmost'
 $restored=[PinEditChecks]::Bounds($ui,$app.Id)
 Assert-Edit (($original.Right-$original.Left) -eq ($restored.Right-$restored.Left) -and ($original.Bottom-$original.Top) -eq ($restored.Bottom-$restored.Top)) 'Leaving edit mode restores the previous panel size'
 Assert-Edit ((Field-Edit 202) -eq 'Ctrl+Alt+F7') 'Entering and leaving edit mode keeps settings drafts'
 [PinEditChecks]::Click($ui,$app.Id,145)
 [PinEditChecks]::SystemCommand($ui,$app.Id,0xf020)
 Wait-Edit {[PinEditChecks]::Minimized($ui,$app.Id) -and -not [PinEditChecks]::Topmost($ui,$app.Id)} 'minimizing ends edit mode'
 Assert-Edit ($true) 'Minimizing the panel ends topmost observation'
 [PinEditChecks]::SystemCommand($ui,$app.Id,0xf120)
 Wait-Edit {-not [PinEditChecks]::Minimized($ui,$app.Id)} 'panel restored'
 Activate-Edit $ui $app.Id
 [PinEditChecks]::Click($ui,$app.Id,145)
 [PinEditChecks]::Close($ui,$app.Id)
 Wait-Edit {-not [PinEditChecks]::Visible($ui,$app.Id)} 'tray hide'
 Assert-Edit (-not [PinEditChecks]::Topmost($ui,$app.Id)) 'Hiding to tray ends topmost observation'
 [PinEditChecks]::ExitHost($hostWindow,$app.Id)
 Assert-Edit ($app.WaitForExit(3000) -and $app.ExitCode -eq 0) 'App exits normally after edit-mode cleanup'
 $report['normal_exit']=$true
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace;try{$report['observation']=@{target=Field-Edit 146;geometry=Field-Edit 147;status=Field-Edit 138;foreground=[PinRealKeys]::GetForegroundWindow().ToInt64();alpha=$first.ToInt64();beta=$betaWindow.ToInt64();screen_pin=$ui.ToInt64()}}catch{}}
finally{
 try{[PinRealKeys]::StopFixture()}catch{$report.errors+=$_.Exception.Message}
 if($second -and -not $second.HasExited){try{[PinEditChecks]::Close($betaWindow,$second.Id);if(-not $second.WaitForExit(2000)){$second.Kill()}}catch{$report.errors+=$_.Exception.Message}}
 if($app -and -not $app.HasExited){try{[PinEditChecks]::ExitHost($hostWindow,$app.Id);if(-not $app.WaitForExit(2000)){$report.errors+='Forced cleanup required';$app.Kill();$app.WaitForExit()}}catch{$report.errors+=$_.Exception.Message;if(-not $app.HasExited){$app.Kill();$app.WaitForExit()}}}
 $report.passed=$report.errors.Count -eq 0 -and $report.normal_exit;$report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8
}
if(-not $report.passed){exit 1}
