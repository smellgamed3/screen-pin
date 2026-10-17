#Requires -Version 7.0
param(
 [string]$FixturePath=(Join-Path $PSScriptRoot 'support/terminal-title-fixture.ps1'),
 [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/terminal-fixtures'),
 [switch]$WithTerminal
)
$ErrorActionPreference='Stop'
$FixturePath=(Get-Item -LiteralPath $FixturePath).FullName
$shellExe=(Get-Command pwsh.exe).Source
$root=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('fixture-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$report=[ordered]@{started_utc=[DateTime]::UtcNow.ToString('o');script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;fixture_sha256=(Get-FileHash -LiteralPath $FixturePath).Hash;shell_version=$PSVersionTable.PSVersion.ToString();checks=@();cases=@();errors=@();passed=$false;scope='Private standalone PowerShell child scripts and request/ack/error files; no Screen Pin, Terminal user window, keyboard input or global setting change. Only verified own indefinite child processes are terminated during cleanup.';limitations=@('This checks fixture error propagation and file protocol; it does not reproduce or explain the historical intermittent Terminal acknowledgement timeout.','Full Terminal integration is verified separately using the same fixture source.')}
$children=[Collections.Generic.List[object]]::new()
$integrationProcess=$null
$report['with_terminal']=$WithTerminal.IsPresent
if($WithTerminal){$report.scope='Private standalone PowerShell children and the actual shell-app integration test. Blocks only the acknowledgement path under its private output directory. The integration test uses owned Screen Pin and shell windows, real guarded hotkeys and normal window cleanup; standalone indefinite children are terminated only after identity verification. No user-window mutation or global setting change.'}
function Assert-TF($value,[string]$message){if(-not $value){throw $message};$report.checks+=$message}
function Read-TF([string]$path){if(-not (Test-Path -LiteralPath $path -PathType Leaf)){return $null};try{return Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}catch{return $null}}
function Wait-TF([scriptblock]$test,[string]$name){$deadline=[DateTime]::UtcNow.AddSeconds(4);do{if(& $test){return};Start-Sleep -Milliseconds 15}while([DateTime]::UtcNow -lt $deadline);throw ('Timeout: '+$name)}
function Start-TF([string]$name){
 $dir=(New-Item -ItemType Directory -Path (Join-Path $root $name)).FullName
 $run=[pscustomobject]@{name=$name;token=('ScreenPin-Fixture-'+[Guid]::NewGuid().ToString('N'));ready=(Join-Path $dir 'ready.json');command=(Join-Path $dir 'command.json');ack=(Join-Path $dir 'ack.json');fault=(Join-Path $dir 'fault.json');stderr=(Join-Path $dir 'stderr.txt');process=$null;cleanup_verified=$false}
 $args=@('-NoLogo','-NoProfile','-NoExit','-File',('"'+$FixturePath+'"'),'-Token',$run.token,'-ReadyPath',('"'+$run.ready+'"'),'-CommandPath',('"'+$run.command+'"'),'-AckPath',('"'+$run.ack+'"'),'-ErrorPath',('"'+$run.fault+'"'))
 $run.process=Start-Process -FilePath $shellExe -ArgumentList $args -WindowStyle Hidden -RedirectStandardError $run.stderr -PassThru;$children.Add($run)
 Wait-TF {$d=Read-TF $run.ready;return $d -and $d.token -eq $run.token -and $d.pid -eq $run.process.Id} ('owned readiness '+$name)
 return $run
}
function Send-TF($run,[string]$sequence,[string]$title,[string]$token=''){if(-not $token){$token=$run.token};[IO.File]::WriteAllText($run.command,(@{token=$token;sequence=$sequence;title=$title}|ConvertTo-Json))}
function Ack-TF($run,[string]$sequence){Wait-TF {$d=Read-TF $run.ack;return $d -and $d.sequence -eq $sequence} ('ack '+$sequence);return Read-TF $run.ack}
try{
 # Minimized failure: an acknowledged command cannot write its acknowledgement.
 $fault=Start-TF 'blocked-ack';New-Item -ItemType Directory -Path $fault.ack|Out-Null
 $sequence=[Guid]::NewGuid().ToString('N');$title=$fault.token+' RuleAlpha';$watch=[Diagnostics.Stopwatch]::StartNew();Send-TF $fault $sequence $title
 Wait-TF {(Read-TF $fault.fault) -ne $null} 'structured child failure instead of generic title timeout'
 $d=Read-TF $fault.fault
 Assert-TF ($d.token -eq $fault.token -and $d.pid -eq $fault.process.Id -and $d.sequence -eq $sequence) 'Fault belongs to the exact owned child and command'
 Assert-TF ($d.phase -eq 'writing-ack' -and $d.message -and $d.exception_type) 'Actual acknowledgement write failure reports its phase and exception'
 Assert-TF ($d.last_sequence -eq '' -and -not (Test-Path -LiteralPath $fault.ack -PathType Leaf)) 'Failed acknowledgement is not published as success'
 $report.cases+=@{name=$fault.name;fault=$d;observed_ms=$watch.Elapsed.TotalMilliseconds}
 $normal=Start-TF 'normal';$acks=@()
 for($i=0;$i -lt 20;$i++){$sequence=[Guid]::NewGuid().ToString('N');$title=$normal.token+' Rule'+$i;Send-TF $normal $sequence $title;$a=Ack-TF $normal $sequence;Assert-TF ($a.pid -eq $normal.process.Id -and $a.title -eq $title) 'Actual title command is acknowledged by its exact owned child';$acks+=$a}
 Assert-TF (-not (Test-Path -LiteralPath $normal.fault)) 'Normal title changes do not create a fault report'
 $before=(Get-FileHash -LiteralPath $normal.ack).Hash
 Send-TF $normal $sequence ($normal.token+' changed duplicate');Start-Sleep -Milliseconds 180
 Assert-TF ((Get-FileHash -LiteralPath $normal.ack).Hash -eq $before) 'Already acknowledged sequence is not re-applied'
 Send-TF $normal ([Guid]::NewGuid().ToString('N')) ($normal.token+' wrong-token') 'DifferentFixture';Start-Sleep -Milliseconds 180
 Assert-TF ((Get-FileHash -LiteralPath $normal.ack).Hash -eq $before) 'A command for another fixture is ignored'
 [IO.File]::WriteAllText($normal.command,'{"token":');Start-Sleep -Milliseconds 180
 Assert-TF ((Get-FileHash -LiteralPath $normal.ack).Hash -eq $before -and -not (Test-Path -LiteralPath $normal.fault)) 'Partial command publication preserves the previous acknowledgement'
 $sequence=[Guid]::NewGuid().ToString('N');$title=$normal.token+' recovered';Send-TF $normal $sequence $title;$a=Ack-TF $normal $sequence
 Assert-TF ($a.pid -eq $normal.process.Id -and $a.title -eq $title) 'A complete subsequent command remains usable after a partial write'
 $report.cases+=@{name=$normal.name;acknowledgements=$acks;final_ack=$a}
 if($WithTerminal){
  # Affect only the private fixture path, without a fault-injection hook in the application.
  $shellScript=(Get-Item -LiteralPath (Join-Path $PSScriptRoot 'shell-apps-smoke.ps1')).FullName
  $integrationDir=(New-Item -ItemType Directory -Path (Join-Path (Join-Path $PSScriptRoot '../artifacts') ('tfi-'+[Guid]::NewGuid().ToString('N')))).FullName
  $stdout=Join-Path $root 'integration-stdout.txt';$stderr=Join-Path $root 'integration-stderr.txt'
  $integrationProcess=Start-Process -FilePath $shellExe -ArgumentList '-NoProfile','-File',('"'+$shellScript+'"'),'-OutputDir',('"'+$integrationDir+'"'),'-HotkeyStates','-TitleRules' -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
  $report['integration_child']=@{pid=$integrationProcess.Id;script=$shellScript;output_dir=$integrationDir}
  $injected=$false;$deadline=[DateTime]::UtcNow.AddSeconds(90)
  while(-not $integrationProcess.HasExited -and [DateTime]::UtcNow -lt $deadline){
   if(-not $injected){$ready=@(Get-ChildItem -LiteralPath $integrationDir -Filter terminal-ready.json -Recurse);if($ready.Count -eq 1){$ackPath=Join-Path $ready[0].DirectoryName 'terminal-title-ack.json';$commandPath=Join-Path $ready[0].DirectoryName 'terminal-title-command.json';if(Test-Path -LiteralPath $ackPath){throw 'Ack already exists; fault injection was too late'};if(Test-Path -LiteralPath $commandPath){throw 'Command already exists; fault injection was too late'};New-Item -ItemType Directory -Path $ackPath|Out-Null;$injected=$true}}
   Start-Sleep -Milliseconds 20
  }
  if(-not $integrationProcess.HasExited){throw 'Actual shell-app fault test exceeded its time budget; child cleanup requires inspection'}
  Assert-TF ($injected -and $integrationProcess.ExitCode -ne 0) 'Actual shell-app test rejects the blocked fixture acknowledgement'
  $files=@(Get-ChildItem -LiteralPath $integrationDir -Filter report.json -Recurse);Assert-TF ($files.Count -eq 1) 'Actual shell-app failure retains a single complete report'
  $result=Read-TF $files[0].FullName;$diagnostic=@($result.terminal_diagnostics)
  Assert-TF (($result.errors -join ' ') -match 'Terminal fixture failed during writing-ack' -and ($result.errors -join ' ') -notmatch 'Hotkey timeout') 'Parent reports the actual fixture phase instead of a generic timeout'
  Assert-TF ($result.normal_exit -and $result.startup_registry_unchanged -and $diagnostic.Count -eq 1 -and $diagnostic[0].child_identity_matches) 'Failure diagnostics precede normal owned-app cleanup and preserve Run state'
  Assert-TF ($diagnostic[0].command.value.sequence -eq $diagnostic[0].fault.value.sequence -and $diagnostic[0].fault.value.phase -eq 'writing-ack') 'Failure snapshot relates the pending command to its exact child exception'
  $report['integration']=@{report=$files[0].FullName;exit_code=$integrationProcess.ExitCode;fault_injected=$true;shell_script_sha256=(Get-FileHash -LiteralPath $shellScript).Hash}
 }
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{
 foreach($run in $children){try{if(-not $run.process.HasExited){$owner=Get-CimInstance Win32_Process -Filter ('ProcessId='+$run.process.Id);if(-not $owner -or $owner.ExecutablePath -ine $shellExe -or -not $owner.CommandLine.Contains($FixturePath) -or -not $owner.CommandLine.Contains($run.token)){throw 'Owned child cleanup identity mismatch'};$run.process.Kill();$run.process.WaitForExit()};$run.cleanup_verified=$true}catch{$report.errors+=('Cleanup: '+$_.Exception.Message)}}
 if($integrationProcess -and -not $integrationProcess.HasExited){$report.errors+='The shell-app integration child is still running; its own cleanup must finish before another GUI test starts'}
 $report['child_cleanup']=@($children|ForEach-Object{@{name=$_.name;pid=$_.process.Id;verified=$_.cleanup_verified;exited=$_.process.HasExited}});$report.passed=$report.errors.Count -eq 0 -and $report.cases.Count -eq 2 -and @($children|Where-Object {-not $_.cleanup_verified}).Count -eq 0;$report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $root 'report.json') -Encoding utf8;Write-Host ('Terminal fixture report: '+(Join-Path $root 'report.json'))
}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
