#Requires -Version 7.0
param(
 [Parameter(Mandatory)][string]$ExePath,
 [Parameter(Mandatory)][string]$OutputDir,
 [Parameter(Mandatory)][string]$UiaProbePath
)
$ErrorActionPreference='Stop'
if(-not $env:SCREEN_PIN_FIXTURE_GUEST -or $env:COMPUTERNAME -eq $env:SCREEN_PIN_FIXTURE_HOST -or -not [Security.Principal.WindowsIdentity]::GetCurrent().Name.EndsWith('\WDAGUtilityAccount',[StringComparison]::OrdinalIgnoreCase)){throw 'UIA diagnostic requires the explicitly isolated guest driver'}
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir 'uia-diagnostic') -Force).FullName
$managedProbe=Join-Path $PSScriptRoot 'support/managed-uia-probe.ps1'
$report=[ordered]@{exe_sha256=(Get-FileHash $ExePath).Hash;native_probe_sha256=(Get-FileHash $UiaProbePath).Hash;managed_probe_sha256=(Get-FileHash $managedProbe).Hash;checks=@();samples=@();errors=@();passed=$false;scope='Same owned fixture, separate native and managed reader processes. No focus action or property fallback; failure of either client remains a diagnostic failure.'}
Add-Type -Path (Join-Path $PSScriptRoot 'support/real-keys.cs')
function Run-UiaReader([string]$Program,[string[]]$Arguments){
 $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$Program;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 foreach($argument in $Arguments){$info.ArgumentList.Add($argument)}
 $reader=[Diagnostics.Process]::Start($info)
 try{
  $stdout=$reader.StandardOutput.ReadToEndAsync();$stderr=$reader.StandardError.ReadToEndAsync()
  if(-not $reader.WaitForExit(10000)){$reader.Kill();$null=$reader.WaitForExit(2000);throw 'UIA diagnostic reader exceeded ten seconds'}
  if(-not $stdout.Wait(2000) -or -not $stderr.Wait(2000)){throw 'UIA diagnostic reader output did not close'}
  return @{exit_code=$reader.ExitCode;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
 }finally{$reader.Dispose()}
}
try{
 $window=[PinRealKeys]::StartFixture();$inputPath=Join-Path $runDir 'input.json'
 ConvertTo-Json -InputObject @(@{handle=$window.ToInt64();id=0;page='fixture'})|Set-Content -LiteralPath $inputPath -Encoding utf8
 foreach($delay in @(0,300,1000)){
  Start-Sleep -Milliseconds $delay
  $nativeOutput=Join-Path $runDir ('native-'+$delay+'.json');$managedOutput=Join-Path $runDir ('managed-'+$delay+'.json')
  $native=Run-UiaReader $UiaProbePath @($inputPath,$nativeOutput,[string]$PID)
  $managed=Run-UiaReader (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile','-File',$managedProbe,'-InputPath',$inputPath,'-OutputPath',$managedOutput,'-ExpectedPid',[string]$PID)
  $sample=@{delay=$delay;window=$window.ToInt64();owner_pid=$PID;native=$native;managed=$managed}
  if(Test-Path -LiteralPath $nativeOutput){$native.controls=@(Get-Content -LiteralPath $nativeOutput -Raw|ConvertFrom-Json)}
  if(Test-Path -LiteralPath $managedOutput){$managed.controls=@(Get-Content -LiteralPath $managedOutput -Raw|ConvertFrom-Json)}
  $report.samples+=@($sample)
 }
 foreach($test in @(@{name='wrong-owner';owner=0;input=$inputPath},@{name='invalid-hwnd';owner=$PID;input=(Join-Path $runDir 'invalid-input.json')})){
  if($test.name -eq 'invalid-hwnd'){ConvertTo-Json -InputObject @(@{handle=0;id=0;page='invalid'})|Set-Content -LiteralPath $test.input -Encoding utf8}
  $output=Join-Path $runDir ($test.name+'.json')
  $negative=Run-UiaReader (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile','-File',$managedProbe,'-InputPath',$test.input,'-OutputPath',$output,'-ExpectedPid',[string]$test.owner)
  if($negative.exit_code -eq 0 -or (Test-Path -LiteralPath $output) -or $negative.stderr -notmatch 'Control HWND no longer belongs'){throw ('Managed UIA identity guard failed: '+$test.name)}
  $report.checks+=('Managed UIA rejects '+$test.name+' without output')
 }
 $report.passed=$report.samples.Count -eq 3 -and @($report.samples|Where-Object {$_.native.exit_code -ne 0 -or $_.managed.exit_code -ne 0 -or $_.managed.controls.Count -ne 1 -or $_.managed.controls[0].provider_pid -ne $PID}).Count -eq 0
 if(-not $report.passed){$report.errors+='Native or managed UIA reader did not report the owned fixture'}
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{
 try{[PinRealKeys]::StopFixture()}catch{$report.errors+=$_.Exception.Message}
 $report.passed=$report.passed -and $report.errors.Count -eq 0
 $report|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $runDir 'report.json') -Encoding utf8
}
if(-not $report.passed){exit 1}
