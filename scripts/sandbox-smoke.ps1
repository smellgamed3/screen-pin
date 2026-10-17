#Requires -Version 7.0
param(
 [string]$ZipPath=(Join-Path $PSScriptRoot '../dist/ScreenPin-0.1.0-windows-x64.zip'),
 [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/sandbox'),
 [switch]$Lifecycle
)
$ErrorActionPreference='Stop'
$ZipPath=(Get-Item -LiteralPath $ZipPath).FullName
$runId=[Guid]::NewGuid().ToString('D');$root=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('sandbox-'+$runId)) -Force).FullName
$inputDir=(New-Item -ItemType Directory -Path (Join-Path $root 'input')).FullName;$resultDir=(New-Item -ItemType Directory -Path (Join-Path $root 'result')).FullName
$report=[ordered]@{run_id=$runId;started_utc=[DateTime]::UtcNow.ToString('o');zip_sha256=(Get-FileHash -LiteralPath $ZipPath).Hash;script_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash;steps=@();errors=@();owned_session_created=$false;owned_session_stopped=$false;passed=$false;scope='A fresh Windows Sandbox only when no existing session is present; immutable input mapping, private output mapping, network/clipboard/media disabled. No feature enablement, elevation or guest development-tool installation.'}
$report['mode']=if($Lifecycle){'lifecycle'}else{'basic'}
$guestName=if($Lifecycle){'sandbox-lifecycle-guest.ps1'}else{'sandbox-guest-smoke.ps1'}
$wsb=$null;$connectProcess=$null;$startAttempted=$false
function Invoke-Sandbox([string[]]$arguments,[string]$name){$out=@(& $script:wsb @arguments 2>&1);$code=$LASTEXITCODE;$script:report.steps+=@{step=$name;arguments=$arguments;exit_code=$code;output=@($out|ForEach-Object ToString)};if($code -ne 0){throw ($name+' failed: '+($out -join ' '))};return ($out -join "`n")}
try{
 $command=Get-Command wsb.exe -ErrorAction SilentlyContinue
 if($command){$wsb=$command.Source}else{$pkg=Get-AppxPackage MicrosoftWindows.WindowsSandbox;if(-not $pkg){throw 'Windows Sandbox CLI is not installed'};$wsb=(Get-Item -LiteralPath (Join-Path $pkg.InstallLocation 'wsb.exe')).FullName}
 $os=Get-CimInstance Win32_OperatingSystem;$identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=[Security.Principal.WindowsPrincipal]::new($identity);$report['host_environment']=@{os=$os.Caption;build=$os.BuildNumber;powershell=$PSVersionTable.PSVersion.ToString();token_is_administrator=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)};$report['sandbox_cli']=@{path=$wsb;version=(Get-Item -LiteralPath $wsb).VersionInfo.FileVersion}
 $before=Invoke-Sandbox @('list','--raw') 'list-before'|ConvertFrom-Json
 if(@($before.WindowsSandboxEnvironments).Count -ne 0){throw 'An existing Sandbox session is present; no session was adopted or stopped'}
 Copy-Item -LiteralPath $ZipPath -Destination (Join-Path $inputDir 'ScreenPin.zip')
 foreach($name in @('real-keys.cs','application-native.cs','sandbox-guest-smoke.ps1')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('support/'+$name)) -Destination (Join-Path $inputDir $name)}
 if($Lifecycle){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('support/'+$guestName)) -Destination (Join-Path $inputDir $guestName)}
 Add-Type -AssemblyName System.IO.Compression.FileSystem;$archive=[IO.Compression.ZipFile]::OpenRead($ZipPath)
 try{$entry=$archive.GetEntry('screen-pin.exe');if(-not $entry){throw 'Release ZIP executable missing'};$stream=$entry.Open();$hash=[Security.Cryptography.SHA256]::Create();try{$exeHash=[Convert]::ToHexString($hash.ComputeHash($stream))}finally{$hash.Dispose();$stream.Dispose()}}finally{$archive.Dispose()}
 $report['exe_sha256']=$exeHash
 $inputHashes=@{};foreach($file in Get-ChildItem -LiteralPath $inputDir -File){$inputHashes[$file.Name]=(Get-FileHash -LiteralPath $file.FullName).Hash};$report['input_hashes']=$inputHashes
 @{run_id=$runId;zip_sha256=$report.zip_sha256;exe_sha256=$exeHash;files=$inputHashes;mode=$report.mode;host_computer_name=$env:COMPUTERNAME}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $inputDir 'expected.json') -Encoding utf8
 $escape=[Security.SecurityElement];$inputXml=$escape::Escape($inputDir);$resultXml=$escape::Escape($resultDir)
 $config="<Configuration><Networking>Disable</Networking><ClipboardRedirection>Disable</ClipboardRedirection><AudioInput>Disable</AudioInput><VideoInput>Disable</VideoInput><PrinterRedirection>Disable</PrinterRedirection><vGPU>Disable</vGPU><MappedFolders><MappedFolder><HostFolder>$inputXml</HostFolder><SandboxFolder>C:\ScreenPinInput</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder><MappedFolder><HostFolder>$resultXml</HostFolder><SandboxFolder>C:\ScreenPinOutput</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder></MappedFolders><LogonCommand><Command>powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\ScreenPinInput\$guestName</Command></LogonCommand></Configuration>"
 $config|Set-Content -LiteralPath (Join-Path $root 'test.wsb') -Encoding utf8
 $startAttempted=$true
 $null=Invoke-Sandbox @('start','--id',$runId,'--config',$config,'--raw') 'start-owned'
 $report.owned_session_created=$true
 $listed=Invoke-Sandbox @('list','--raw') 'list-owned';if($listed -notmatch [regex]::Escape($runId)){throw 'Requested fresh Sandbox ID was not present in the post-start listing'}
 $connectProcess=Start-Process -FilePath $wsb -ArgumentList 'connect','--id',$runId -WindowStyle Hidden -PassThru
 $report['connect_pid']=$connectProcess.Id
 $deadline=[DateTime]::UtcNow.AddMinutes(3);$guestFile=Join-Path $resultDir 'guest-report.json'
 while([DateTime]::UtcNow -lt $deadline){
  if(Test-Path -LiteralPath $guestFile){try{$guest=Get-Content -LiteralPath $guestFile -Raw|ConvertFrom-Json;if($guest.run_id -eq $runId -and $guest.finished_utc){break}}catch{}}
  Start-Sleep -Milliseconds 500
 }
 if(-not $guest -or -not $guest.finished_utc){throw 'Guest did not produce its terminal report within the configured time budget'}
 $report['guest_report']=$guestFile
 if(-not $guest.passed -or $guest.exe_sha256 -ne $exeHash -or $guest.zip_sha256 -ne $report.zip_sha256){throw ('Guest verification failed: '+($guest.errors -join ' '))}
 $report['guest_checks']=$guest.checks.Count
}catch{$report.errors+=$_.Exception.Message;$report['failure_stack']=$_.ScriptStackTrace}
finally{
 if($startAttempted -and -not $report.owned_session_created){try{$partial=Invoke-Sandbox @('list','--raw') 'list-after-start-failure';if($partial -match [regex]::Escape($runId)){$report.owned_session_created=$true}}catch{$report.errors+=('Start-state inspection: '+$_.Exception.Message)}}
 if($report.owned_session_created){try{$live=Invoke-Sandbox @('list','--raw') 'list-before-stop';if($live -match [regex]::Escape($runId)){$null=Invoke-Sandbox @('stop','--id',$runId,'--raw') 'stop-owned'};$after=Invoke-Sandbox @('list','--raw') 'list-after';$report.owned_session_stopped=$after -notmatch [regex]::Escape($runId)}catch{$report.errors+=('Sandbox cleanup: '+$_.Exception.Message)}}
 $report.passed=$report.errors.Count -eq 0 -and $report.owned_session_created -and $report.owned_session_stopped -and $report.guest_checks -gt 0;$report['finished_utc']=[DateTime]::UtcNow.ToString('o');$report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $root 'host-report.json') -Encoding utf8;Write-Host ('Sandbox report: '+(Join-Path $root 'host-report.json'))
}
if(-not $report.passed){$report.errors|Write-Output;exit 1}
