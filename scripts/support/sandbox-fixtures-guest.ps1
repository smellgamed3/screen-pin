#Requires -Version 5.1
param([string]$InputDir='C:\ScreenPinInput',[string]$OutputDir='C:\ScreenPinOutput')
$ErrorActionPreference='Stop'
$expected=Get-Content -LiteralPath (Join-Path $InputDir 'expected.json') -Raw -Encoding utf8|ConvertFrom-Json
$report=[ordered]@{run_id=$expected.run_id;started_utc=[DateTime]::UtcNow.ToString('o');mode='fixtures';checks=@();cases=@();errors=@();passed=$false;scope='Existing fixture verifiers run unmodified under a read-only PowerShell 7 test runtime in an isolated guest. Original release ZIP; no host input, global host setting changes, SDK installation, physical monitor or clean-machine prerequisite claim.'}
$driver=$null
function Check-Fixtures($condition,[string]$message){if(-not $condition){throw $message};$report.checks+=$message}
try{
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent();$computer=Get-CimInstance Win32_ComputerSystem
 Check-Fixtures ($expected.mode -eq 'fixtures' -and $InputDir -eq 'C:\ScreenPinInput' -and $OutputDir -eq 'C:\ScreenPinOutput' -and $identity.Name.EndsWith('\WDAGUtilityAccount',[StringComparison]::OrdinalIgnoreCase) -and $computer.Manufacturer -eq 'Microsoft Corporation' -and $computer.Model -eq 'Virtual Machine' -and $env:COMPUTERNAME -ne $expected.host_computer_name) 'Fixture suite is confined to the fresh guest'
 foreach($entry in $expected.files.PSObject.Properties){Check-Fixtures ((Get-FileHash -LiteralPath (Join-Path $InputDir $entry.Name)).Hash -eq $entry.Value) ('Fixture input hash matches: '+$entry.Name)}
 $toolRoot='C:\ScreenPinTools\PowerShell'
 foreach($entry in $expected.tool_hashes.PSObject.Properties){Check-Fixtures ((Get-FileHash -LiteralPath (Join-Path $toolRoot $entry.Name)).Hash -eq $entry.Value) ('Read-only test runtime hash matches: '+$entry.Name)}
 $report['environment']=@{user=$identity.Name;computer=$env:COMPUTERNAME;os=(Get-CimInstance Win32_OperatingSystem).Caption;build=[Environment]::OSVersion.Version.ToString();test_runtime=(Get-Item (Join-Path $toolRoot 'pwsh.exe')).VersionInfo.FileVersion}
 $zip=Join-Path $InputDir 'ScreenPin.zip';$report['zip_sha256']=(Get-FileHash -LiteralPath $zip).Hash
 Check-Fixtures ($report.zip_sha256 -eq $expected.zip_sha256) 'Fixture suite uses the original release ZIP'
 $appDir=Join-Path $env:LOCALAPPDATA ('ScreenPin-Fixtures-'+$expected.run_id);Expand-Archive -LiteralPath $zip -DestinationPath $appDir
 $exe=Join-Path $appDir 'screen-pin.exe';$report['exe_sha256']=(Get-FileHash -LiteralPath $exe).Hash
 Check-Fixtures ($report.exe_sha256 -eq $expected.exe_sha256) 'Fixture executable matches release'
 $probe=Join-Path $InputDir 'test-bins/accessibility_probe.exe'
 $report['uia_probe']=@{path=$probe;sha256=(Get-FileHash -LiteralPath $probe).Hash}
 $previousExe=$null
 if($expected.fixture_tests -contains 'upgrade'){
  $previousDir=Join-Path $appDir 'previous';Expand-Archive -LiteralPath (Join-Path $InputDir 'PreviousScreenPin.zip') -DestinationPath $previousDir;$previousExe=Join-Path $previousDir 'screen-pin.exe'
  Check-Fixtures ((Get-FileHash -LiteralPath $previousExe).Hash -eq $expected.previous_exe_sha256 -and $expected.previous_exe_sha256 -ne $expected.exe_sha256) 'Upgrade uses the distinct previous executable from its original ZIP'
 }
 $specs=@{
  hotkey=@('hotkey-smoke.ps1','-Cycles','100','-UiaProbePath',$probe)
  settings=@('settings-smoke.ps1','-StorageFaults','-UiaProbePath',$probe)
  'write-limit'=@('write-limit-smoke.ps1','-UiaProbePath',$probe)
  'settings-draft'=@('settings-draft-smoke.ps1','-UiaProbePath',$probe)
  'editor-race'=@('editor-race-smoke.ps1','-UiaProbePath',$probe)
  race=@('race-smoke.ps1','-UiaProbePath',$probe)
  startup=@('startup-smoke.ps1','-UiaProbePath',$probe)
  dialog=@('dialog-keyboard-smoke.ps1','-UiaProbePath',$probe)
  tray=@('tray-keyboard-smoke.ps1','-UiaProbePath',$probe)
  'uia-diagnostic'=@('uia-diagnostic-smoke.ps1','-UiaProbePath',$probe)
  upgrade=@('upgrade-smoke.ps1','-PreviousExe',$previousExe,'-PackagePath',$zip,'-UseDefaultConfigPath','-UiaProbePath',$probe)
 }
 Check-Fixtures (@($expected.fixture_tests).Count -gt 0) 'At least one fixture case requested'
 $localRoot=(New-Item -ItemType Directory -Path (Join-Path $env:LOCALAPPDATA ('ScreenPin-FixtureResults-'+$expected.run_id)) -Force).FullName
 $report['configuration_storage']='Guest local filesystem; completed evidence is copied to the output mapping after each driver exits.'
 foreach($name in $expected.fixture_tests){
  Check-Fixtures ($specs.ContainsKey($name)) ('Requested fixture case is allowlisted: '+$name)
  Check-Fixtures (@(Get-Process -Name screen-pin -ErrorAction SilentlyContinue).Count -eq 0) 'No app instance leaks between fixture cases'
  $caseDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('cases/'+$name)) -Force).FullName
  $localCase=(New-Item -ItemType Directory -Path (Join-Path $localRoot $name) -Force).FullName
  @{case=$name;phase='running';utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputDir 'fixture-progress.json') -Encoding utf8
  $spec=$specs[$name];$exeParameter=if($name -eq 'upgrade'){'-ReleaseExe'}else{'-ExePath'};$arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $InputDir ('scripts/'+$spec[0])),$exeParameter,$exe,'-OutputDir',$localCase)+@($spec|Select-Object -Skip 1)
  $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=Join-Path $toolRoot 'pwsh.exe';$info.Arguments=($arguments|ForEach-Object {'"'+$_+'"'}) -join ' ';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
  $info.EnvironmentVariables['SCREEN_PIN_FIXTURE_GUEST']=$expected.run_id;$info.EnvironmentVariables['SCREEN_PIN_FIXTURE_HOST']=$expected.host_computer_name
  $driver=[Diagnostics.Process]::new();$driver.StartInfo=$info;$watch=[Diagnostics.Stopwatch]::StartNew();$null=$driver.Start();$stdout=$driver.StandardOutput.ReadToEndAsync();$stderr=$driver.StandardError.ReadToEndAsync()
  if(-not $driver.WaitForExit(90000)){throw ('Fixture driver exceeded 90 seconds: '+$name)}
  foreach($file in Get-ChildItem -LiteralPath $localCase -Force){Copy-Item -LiteralPath $file.FullName -Destination $caseDir -Recurse}
  if(-not $stdout.Wait(2000) -or -not $stderr.Wait(2000)){throw ('Fixture output pipe remained open after driver exit: '+$name)}
  [IO.File]::WriteAllText((Join-Path $caseDir 'stdout.txt'),$stdout.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $caseDir 'stderr.txt'),$stderr.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
  $files=@(Get-ChildItem -LiteralPath $caseDir -Recurse -File -Filter report.json);$result=$null;if($files.Count -eq 1){$result=Get-Content -LiteralPath $files[0].FullName -Raw -Encoding utf8|ConvertFrom-Json}
  $resultHash=if($name -eq 'upgrade'){$result.current_sha256}else{$result.exe_sha256}
  $passed=$driver.ExitCode -eq 0 -and $files.Count -eq 1 -and $result.passed -and $resultHash -eq $expected.exe_sha256
  if($name -eq 'upgrade'){$passed=$passed -and $result.previous_sha256 -eq $expected.previous_exe_sha256 -and $result.package_sha256 -eq $expected.zip_sha256}
  $report.cases+=@{name=$name;script=$spec[0];exit_code=$driver.ExitCode;elapsed_ms=$watch.Elapsed.TotalMilliseconds;report=$(if($files.Count -eq 1){$files[0].FullName}else{$null});passed=$passed;errors=@($result.errors)}
  if(-not $passed){$report.errors+=('Fixture case failed: '+$name)}
 }
 foreach($entry in $expected.tool_hashes.PSObject.Properties){Check-Fixtures ((Get-FileHash -LiteralPath (Join-Path $toolRoot $entry.Name)).Hash -eq $entry.Value) ('Test runtime remained unchanged: '+$entry.Name)}
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{
 # The owning host stops only this fresh VM after the terminal report; a timed
 # out driver is never adopted by another run or allowed onto the host desktop.
 $report.passed=$report.errors.Count -eq 0 -and $report.cases.Count -eq @($expected.fixture_tests).Count -and @($report.cases|Where-Object {-not $_.passed}).Count -eq 0
 $report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutputDir 'guest-report.json') -Encoding utf8
}
if(-not $report.passed){exit 1}
