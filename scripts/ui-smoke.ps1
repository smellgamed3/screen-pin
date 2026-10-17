#Requires -Version 7.0
param(
 [string]$ExePath = (Join-Path $PSScriptRoot '../target/debug/screen-pin.exe'),
 [string]$FixturePath = '',
 [string]$ConfigDir = '',
 [string]$OutputDir = (Join-Path $PSScriptRoot '../artifacts')
)
$ErrorActionPreference = 'Stop'
$ExePath = (Get-Item -LiteralPath $ExePath).FullName
if (-not $FixturePath) { $FixturePath = Join-Path (Split-Path -Parent $ExePath) 'desktop_probe.exe' }
$FixturePath = (Get-Item -LiteralPath $FixturePath).FullName
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PinSmoke {
 public delegate bool EnumProc(IntPtr hwnd, IntPtr data);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr data);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd,StringBuilder name,int length);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hwnd,StringBuilder name,int length);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern bool SetWindowTextW(IntPtr hwnd,string value);
 [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr hwnd,int id);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int width,int height,uint flags);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd,IntPtr dc,uint flags);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd,int command);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
 [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp);
 [DllImport("user32.dll",EntryPoint="SendMessageW",CharSet=CharSet.Unicode)] public static extern IntPtr SendText(IntPtr hwnd,uint msg,IntPtr wp,StringBuilder lp);
 [DllImport("user32.dll",EntryPoint="SendMessageW",CharSet=CharSet.Unicode)] public static extern IntPtr SendString(IntPtr hwnd,uint msg,IntPtr wp,string lp);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr CreateWindowExW(uint ex,string cls,string title,uint style,int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr param);
 [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr hwnd);
 [DllImport("user32.dll")] static extern bool PeekMessage(out Message msg,IntPtr hwnd,uint first,uint last,uint remove);
 [DllImport("user32.dll")] static extern bool TranslateMessage(ref Message msg);
 [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref Message msg);
 public static void Pump(){Message m;while(PeekMessage(out m,IntPtr.Zero,0,0,1)){TranslateMessage(ref m);DispatchMessage(ref m);}}
 public struct Rect{public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential)] struct Message{public IntPtr hwnd;public uint msg;public UIntPtr wp;public IntPtr lp;public uint time;public int x,y;public uint privateValue;}
}
'@
$artifacts = (New-Item -ItemType Directory -Path $OutputDir -Force).FullName
if (-not $ConfigDir) { $ConfigDir = Join-Path $artifacts ('gui-smoke-' + [Guid]::NewGuid().ToString('N')) }
$configDir = (New-Item -ItemType Directory -Path $ConfigDir -Force).FullName
$configPath = Join-Path $configDir 'config.json'
if (Test-Path -LiteralPath $configPath) { throw 'UI smoke requires a new ConfigDir; existing user configuration will not be changed.' }
$results = [Collections.Generic.List[string]]::new()
$process = $null
$target = [IntPtr]::Zero
$hostWindow = [IntPtr]::Zero
$fixture = $null
$fixtureWindow = [IntPtr]::Zero
$originalExePath = $ExePath
$primaryConfigPath = $configPath
$startupRegistryBefore = [Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
function Assert-Pin($condition,$message){if(-not $condition){throw $message};$script:results.Add($message)}
function Read-PinText([IntPtr]$handle){$text=[Text.StringBuilder]::new(32768);[PinSmoke]::SendText($handle,0x0d,[IntPtr]$text.Capacity,$text)|Out-Null;return $text.ToString()}
function Wait-Pin([scriptblock]$condition,[string]$description){$deadline=[DateTime]::UtcNow.AddSeconds(8);do{[PinSmoke]::Pump();if(& $condition){return};Start-Sleep -Milliseconds 30}while([DateTime]::UtcNow -lt $deadline);throw ('Timeout: '+$description)}
function Click-Pin([int]$id){[PinSmoke]::SendMessageW([PinSmoke]::GetDlgItem($script:ui,$id),0xf5,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null;Wait-Pin { (Read-PinText ([PinSmoke]::GetDlgItem($script:ui,138))) -ne '正在处理…' } ('button '+$id)}
function Select-PinList([int]$id,[int]$index){$control=[PinSmoke]::GetDlgItem($script:ui,$id);[PinSmoke]::SendMessageW($control,0x186,[IntPtr]$index,[IntPtr]::Zero)|Out-Null;[PinSmoke]::SendMessageW($script:ui,0x111,[IntPtr](65536+$id),$control)|Out-Null}
function Select-PinWindow([string]$title){$list=[PinSmoke]::GetDlgItem($script:ui,108);$count=[PinSmoke]::SendMessageW($list,0x18b,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32();for($index=0;$index -lt $count;$index++){$text=[Text.StringBuilder]::new(32768);[PinSmoke]::SendText($list,0x189,[IntPtr]$index,$text)|Out-Null;if($text.ToString().Contains($title)){Select-PinList 108 $index;return}};throw ('Missing isolated target '+$title)}
function Confirm-PinMigration([bool]$accept){
 [PinSmoke]::PostMessageW([PinSmoke]::GetDlgItem($script:ui,140),0xf5,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
 $script:migrationDialog=[IntPtr]::Zero
 Wait-Pin {[PinSmoke]::EnumWindows({param($handle,$data) $ownerPid=0;[PinSmoke]::GetWindowThreadProcessId($handle,[ref]$ownerPid)|Out-Null;if($ownerPid -eq $script:process.Id){$class=[Text.StringBuilder]::new(128);[PinSmoke]::GetClassName($handle,$class,128)|Out-Null;if($class.ToString() -eq '#32770' -and (Read-PinText $handle) -eq '迁移应用预设'){$script:migrationDialog=$handle}};return $true},[IntPtr]::Zero)|Out-Null;$script:migrationDialog -ne [IntPtr]::Zero} 'migration confirmation dialog'
 $description=Read-PinText ([PinSmoke]::GetDlgItem($script:migrationDialog,65535))
 Assert-Pin ($description -match '全部 2 条标题规则' -and $description.Contains('新应用：')) 'Migration confirmation describes the whole application scope and destination'
 [PinSmoke]::SendMessageW([PinSmoke]::GetDlgItem($script:migrationDialog, $(if($accept){6}else{7})),0xf5,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
 Wait-Pin {(Read-PinText ([PinSmoke]::GetDlgItem($script:ui,138))) -ne '正在处理…'} 'migration result'
}
function Save-PinImage([string]$name){Start-Sleep -Milliseconds 120;[PinSmoke]::Pump();$rect=[PinSmoke+Rect]::new();[PinSmoke]::GetWindowRect($script:ui,[ref]$rect)|Out-Null;$bitmap=[Drawing.Bitmap]::new($rect.Right-$rect.Left,$rect.Bottom-$rect.Top);$graphics=[Drawing.Graphics]::FromImage($bitmap);$dc=$graphics.GetHdc();[PinSmoke]::PrintWindow($script:ui,$dc,2)|Out-Null;$graphics.ReleaseHdc($dc);$bitmap.Save((Join-Path $script:artifacts $name),[Drawing.Imaging.ImageFormat]::Png);$graphics.Dispose();$bitmap.Dispose()}
function Config-Pin{Get-Content -Raw -LiteralPath $script:configPath | ConvertFrom-Json}
function Confirm-PinOwner{
 $nativeProcess=Get-CimInstance Win32_Process -Filter ('ProcessId='+$script:process.Id)
 if(-not $nativeProcess -or $nativeProcess.ExecutablePath -ne $script:ExePath -or -not $nativeProcess.CommandLine.Contains($script:configDir)){throw 'Process ownership does not match the isolated executable/configuration; refusing to send cleanup commands.'}
}
try{
 $target=[PinSmoke]::CreateWindowExW(0,'STATIC','Screen Pin GUI smoke target',0x10cf0000,80,100,520,380,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero)
 Assert-Pin ($target -ne [IntPtr]::Zero) 'Created isolated ordinary target window'
 $process=Start-Process -FilePath $ExePath -ArgumentList '--show','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
 $process.Id | Set-Content (Join-Path $artifacts 'gui-smoke.pid')
 $script:ui=[IntPtr]::Zero
 Wait-Pin {
  [PinSmoke]::EnumWindows({param($handle,$data) $ownerPid=0;[PinSmoke]::GetWindowThreadProcessId($handle,[ref]$ownerPid)|Out-Null;if($ownerPid -eq $process.Id){$class=[Text.StringBuilder]::new(128);[PinSmoke]::GetClassName($handle,$class,128)|Out-Null;if($class.ToString() -eq 'ScreenPin.Settings'){$script:ui=$handle};if($class.ToString() -eq 'ScreenPin.Host'){$script:hostWindow=$handle}};return $true},[IntPtr]::Zero)|Out-Null
  $script:ui -ne [IntPtr]::Zero -and [PinSmoke]::IsWindowVisible($script:ui) -and (Read-PinText ([PinSmoke]::GetDlgItem($script:ui,138))) -notin @('','正在处理…')
 } 'settings and initial refresh ready'
 Confirm-PinOwner
 Assert-Pin ([PinSmoke]::IsWindowVisible($ui)) 'First explicit launch shows the settings window'
 Assert-Pin (-not [PinSmoke]::IsWindowVisible([PinSmoke]::GetDlgItem($ui,132))) 'Advanced editor is collapsed before selecting a preset'
 Save-PinImage 'ui-main-empty.png'
 $list=[PinSmoke]::GetDlgItem($ui,108)
 $count=[PinSmoke]::SendMessageW($list,0x18b,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32()
 $targetIndex=-1
 for($index=0;$index -lt $count;$index++){$text=[Text.StringBuilder]::new(32768);[PinSmoke]::SendText($list,0x189,[IntPtr]$index,$text)|Out-Null;if($text.ToString().Contains('Screen Pin GUI smoke target')){$targetIndex=$index;break}}
 Assert-Pin ($targetIndex -ge 0) 'Eligible target appears in the window list'
 Select-PinList 108 $targetIndex
 Assert-Pin ([PinSmoke]::IsWindowEnabled([PinSmoke]::GetDlgItem($ui,111))) 'Selecting a target enables the actual remember button'
 Click-Pin 111
 Assert-Pin ((Config-Pin).profiles[0].applications.Count -eq 1) 'GUI remember creates the selected application default'
 $saved=[PinSmoke+Rect]::new();[PinSmoke]::GetWindowRect($target,[ref]$saved)|Out-Null
 [PinSmoke]::SetWindowPos($target,[IntPtr]::Zero,700,180,300,250,0x14)|Out-Null
 $foregroundBeforeRestore=[PinSmoke]::GetForegroundWindow()
 Click-Pin 112
 Assert-Pin ([PinSmoke]::GetForegroundWindow() -eq $foregroundBeforeRestore) 'Restore and its temporary status popup leave the foreground window unchanged'
 Wait-Pin {$actual=[PinSmoke+Rect]::new();[PinSmoke]::GetWindowRect($target,[ref]$actual)|Out-Null;[Math]::Abs($actual.Left-$saved.Left)-le 2 -and [Math]::Abs($actual.Top-$saved.Top)-le 2 -and [Math]::Abs($actual.Right-$saved.Right)-le 2 -and [Math]::Abs($actual.Bottom-$saved.Bottom)-le 2} 'GUI restore actual bounds'
 Assert-Pin ((Read-PinText ([PinSmoke]::GetDlgItem($ui,138))) -match '已恢复|已符合') 'GUI restore verifies and reports the selected target result'
 [PinSmoke]::SendString([PinSmoke]::GetDlgItem($ui,114),0x0c,[IntPtr]::Zero,'GUI smoke')|Out-Null
 $previewRevision=(Config-Pin).revision
 Assert-Pin ((Read-PinText ([PinSmoke]::GetDlgItem($ui,139))) -match '新规则.*胜出') 'Typing a matching new keyword previews the appended rule winner'
 Assert-Pin ((Config-Pin).revision -eq $previewRevision) 'Keyword preview does not write configuration'
 Click-Pin 115
 Assert-Pin ((Config-Pin).profiles[0].applications[0].rules[0].keyword -eq 'GUI smoke') ('GUI capture creates an explicit title rule: '+(Read-PinText ([PinSmoke]::GetDlgItem($ui,138))))
 Select-PinList 117 1
 Assert-Pin ([PinSmoke]::IsWindowVisible([PinSmoke]::GetDlgItem($ui,132))) 'Selecting a preset expands the editor'
 $beforeRevision=(Config-Pin).revision
 Click-Pin 132
 Assert-Pin ((Config-Pin).revision -eq $beforeRevision) 'Saving an unchanged rounded editor preserves exact placement and config revision'
 [PinSmoke]::SendString([PinSmoke]::GetDlgItem($ui,122),0x0c,[IntPtr]::Zero,'12.5')|Out-Null
 Click-Pin 132
 Assert-Pin ((Config-Pin).profiles[0].applications[0].default.placement.rect.x -eq 0.125) 'Percentage editor saves the intended placement'
 Click-Pin 136
 Assert-Pin ((Config-Pin).profiles[0].applications[0].default.placement.rect.x -ne 0.125) 'GUI undo restores the immediately preceding preset contents'
 [PinSmoke]::SendString([PinSmoke]::GetDlgItem($ui,114),0x0c,[IntPtr]::Zero,'smoke target')|Out-Null
 Assert-Pin ((Read-PinText ([PinSmoke]::GetDlgItem($ui,139))) -match '存在重叠.*GUI smoke.*胜出') 'Overlapping keyword preview identifies the earlier winning rule'
 Click-Pin 115
 Select-PinList 117 1
 Click-Pin 134
 Assert-Pin ((Config-Pin).profiles[0].applications[0].rules[0].keyword -eq 'smoke target') 'Rule ordering uses the current config revision after unrelated edits'
 Save-PinImage 'ui-main-selected.png'
 [PinSmoke]::SendMessageW($ui,0x115,[IntPtr]7,[IntPtr]::Zero)|Out-Null
 Save-PinImage 'ui-main-editor.png'
 $fixture=Start-Process -FilePath $FixturePath -ArgumentList '--fixture' -WindowStyle Hidden -PassThru
 Wait-Pin {[PinSmoke]::EnumWindows({param($handle,$data) $ownerPid=0;[PinSmoke]::GetWindowThreadProcessId($handle,[ref]$ownerPid)|Out-Null;if($ownerPid -eq $fixture.Id){$class=[Text.StringBuilder]::new(128);[PinSmoke]::GetClassName($handle,$class,128)|Out-Null;if($class.ToString() -eq 'ScreenPinDesktopProbeFixture'){$script:fixtureWindow=$handle}};return $true},[IntPtr]::Zero)|Out-Null;$script:fixtureWindow -ne [IntPtr]::Zero} 'new application fixture'
 $fixtureTitle='Screen Pin UI migration fixture '+$fixture.Id
 [PinSmoke]::SendString($fixtureWindow,0x0c,[IntPtr]::Zero,$fixtureTitle)|Out-Null
 [PinSmoke]::ShowWindow($fixtureWindow,4)|Out-Null
 Click-Pin 109
 Select-PinWindow $fixtureTitle
 Assert-Pin ([PinSmoke]::IsWindowEnabled([PinSmoke]::GetDlgItem($ui,140))) 'Application migration is available for the selected old preset and new target process'
 $beforeMigration=Config-Pin
 $oldAppId=$beforeMigration.profiles[0].applications[0].app_id
 $oldPresetId=$beforeMigration.profiles[0].applications[0].default.id
 $oldRules=@($beforeMigration.profiles[0].applications[0].rules | ForEach-Object {$_.preset.id})
 Confirm-PinMigration $false
 Assert-Pin ((Config-Pin).revision -eq $beforeMigration.revision) 'Cancelling application migration preserves the complete config'
 Confirm-PinMigration $true
 $migrated=(Config-Pin).profiles[0].applications[0]
 Assert-Pin ($migrated.app_id -ne $oldAppId -and $migrated.app_id.EndsWith($FixturePath.ToLowerInvariant())) 'Migration binds to the selected isolated application identity'
 Assert-Pin ($migrated.default.id -eq $oldPresetId -and (($migrated.rules | ForEach-Object {$_.preset.id}) -join ',') -eq ($oldRules -join ',')) 'Migration preserves the application default and every existing title rule'
 Select-PinWindow 'Screen Pin GUI smoke target'
 Click-Pin 111
 Select-PinList 117 3
 Select-PinWindow $fixtureTitle
 $collisionRevision=(Config-Pin).revision
 Click-Pin 140
 Assert-Pin ((Config-Pin).revision -eq $collisionRevision -and (Read-PinText ([PinSmoke]::GetDlgItem($ui,138))) -match '已有预设') 'Application migration refuses an existing destination instead of merging silently'
 Select-PinList 117 2
 Click-Pin 133
 [PinSmoke]::SendString($fixtureWindow,0x0c,[IntPtr]::Zero,($fixtureTitle+' smoke target'))|Out-Null
 Click-Pin 109
 Select-PinWindow $fixtureTitle
 Assert-Pin ((Read-PinText ([PinSmoke]::GetDlgItem($ui,111))) -match '更新特定规则') 'The normal remember action still updates a matching title rule when the default is absent'
 Assert-Pin ([PinSmoke]::IsWindowVisible([PinSmoke]::GetDlgItem($ui,142)) -and [PinSmoke]::IsWindowEnabled([PinSmoke]::GetDlgItem($ui,142))) 'A secondary explicit default capture appears only for an application with rules but no default'
 $preservedRules=@((Config-Pin).profiles[0].applications[0].rules | ForEach-Object {$_.preset.id})
 Click-Pin 142
 Assert-Pin ($null -ne (Config-Pin).profiles[0].applications[0].default -and (((Config-Pin).profiles[0].applications[0].rules | ForEach-Object {$_.preset.id}) -join ',') -eq ($preservedRules -join ',')) 'Explicit default capture creates the missing default and preserves all title rules'
 Assert-Pin (-not [PinSmoke]::IsWindowVisible([PinSmoke]::GetDlgItem($ui,142))) 'The secondary default capture disappears once the application default exists'
 Click-Pin 101
 Save-PinImage 'ui-settings.png'
 Click-Pin 102
 Save-PinImage 'ui-association.png'
 [PinSmoke]::PostMessageW($ui,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
 Wait-Pin {-not [PinSmoke]::IsWindowVisible($ui)} 'close hides settings'
 Assert-Pin (-not $process.HasExited) 'Closing the configuration window keeps the tray process running'
 $second=Start-Process -FilePath $ExePath -ArgumentList '--show','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
 Wait-Pin {$second.Refresh();$second.HasExited -and [PinSmoke]::IsWindowVisible($ui)} 'second launch activates first instance'
 Assert-Pin ($second.ExitCode -eq 0) 'Repeated launch activates the existing instance and exits cleanly'
 [PinSmoke]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null
 Wait-Pin {$process.Refresh();$process.HasExited} 'tray exit releases process'
 Assert-Pin ($process.ExitCode -eq 0) 'Normal tray exit completes successfully'
 # Exercise startup diagnostics using a uniquely copied executable and a local
 # config that declares autostart. Launch/inspection must never change HKCU Run.
 $warningConfigDir=(New-Item -ItemType Directory -Path (Join-Path $artifacts ('startup-warning-'+[Guid]::NewGuid().ToString('N')))).FullName
 $warningSeed=Config-Pin
 $warningSeed.settings.autostart=$true
 $warningSeed|ConvertTo-Json -Depth 30|Set-Content -LiteralPath (Join-Path $warningConfigDir 'config.json') -Encoding utf8
 $warningExecutable=Join-Path $warningConfigDir 'ScreenPinStartupWarningFixture.exe'
 Copy-Item -LiteralPath $ExePath -Destination $warningExecutable
 $ExePath=$warningExecutable
 $configDir=$warningConfigDir
 $configPath=Join-Path $configDir 'config.json'
 $ui=[IntPtr]::Zero
 $hostWindow=[IntPtr]::Zero
 $process=Start-Process -FilePath $ExePath -ArgumentList '--show','--config-dir',('"'+$configDir+'"') -WindowStyle Hidden -PassThru
 Wait-Pin {[PinSmoke]::EnumWindows({param($handle,$data) $ownerPid=0;[PinSmoke]::GetWindowThreadProcessId($handle,[ref]$ownerPid)|Out-Null;if($ownerPid -eq $process.Id){$class=[Text.StringBuilder]::new(128);[PinSmoke]::GetClassName($handle,$class,128)|Out-Null;if($class.ToString() -eq 'ScreenPin.Settings'){$script:ui=$handle};if($class.ToString() -eq 'ScreenPin.Host'){$script:hostWindow=$handle}};return $true},[IntPtr]::Zero)|Out-Null;$ui -ne [IntPtr]::Zero -and (Read-PinText ([PinSmoke]::GetDlgItem($ui,138))) -notin @('','正在处理…')} 'startup warning fixture ready'
 Confirm-PinOwner
 Click-Pin 101
 Assert-Pin ([PinSmoke]::IsWindowVisible([PinSmoke]::GetDlgItem($ui,214)) -and (Read-PinText ([PinSmoke]::GetDlgItem($ui,214))) -match '启动.*修复') 'A relocated executable displays its missing or mismatched startup registration'
 Assert-Pin ((Read-PinText ([PinSmoke]::GetDlgItem($ui,207))) -match '修复开机启动路径') 'Startup diagnostics provide an explicit repair action in Settings'
 Save-PinImage 'ui-startup-warning.png'
 [PinSmoke]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null
 Wait-Pin {$process.Refresh();$process.HasExited} 'startup warning fixture exit'
 $startupRegistryAfter=[Microsoft.Win32.Registry]::GetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run','ScreenPin',$null)
 Assert-Pin ($startupRegistryBefore -ceq $startupRegistryAfter) 'Inspecting startup diagnostics leaves the real user startup registry value unchanged'
 $report=[ordered]@{executed=[DateTimeOffset]::Now.ToString('o');executable=$originalExePath;config=$primaryConfigPath;startup_warning_config=$configPath;process_exited=$process.HasExited;passed=$results.ToArray();screenshots=@('ui-main-empty.png','ui-main-selected.png','ui-main-editor.png','ui-settings.png','ui-association.png','ui-startup-warning.png')}
 $report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $artifacts 'gui-smoke.json') -Encoding utf8
 $report|ConvertTo-Json -Depth 6
}finally{
 if($process -and -not $process.HasExited -and $hostWindow -ne [IntPtr]::Zero){Confirm-PinOwner;[PinSmoke]::PostMessageW($hostWindow,0x111,[IntPtr]403,[IntPtr]::Zero)|Out-Null;Wait-Pin {$process.Refresh();$process.HasExited} 'cleanup exit'}
 if($target -ne [IntPtr]::Zero){[PinSmoke]::DestroyWindow($target)|Out-Null}
 if($fixture -and -not $fixture.HasExited -and $fixtureWindow -ne [IntPtr]::Zero){$fixtureOwner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$fixture.Id);if($fixtureOwner.ExecutablePath -eq $FixturePath -and $fixtureOwner.CommandLine.Contains('--fixture')){[PinSmoke]::PostMessageW($fixtureWindow,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null;Wait-Pin {$fixture.Refresh();$fixture.HasExited} 'fixture cleanup exit'}else{throw 'Fixture process identity mismatch; refusing cleanup'} }
}
