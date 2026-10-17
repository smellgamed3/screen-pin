param(
 [Parameter(Mandatory)][string]$Token,
 [Parameter(Mandatory)][string]$ReadyPath,
 [string]$CommandPath='',
 [Parameter(Mandatory)][string]$AckPath,
 [Parameter(Mandatory)][string]$ErrorPath
)
$ErrorActionPreference='Stop'
$phase='initializing';$lastSequence='';$command=$null
try{
 $Host.UI.RawUI.WindowTitle=$Token
 @{pid=$PID;token=$Token}|ConvertTo-Json|Set-Content -LiteralPath $ReadyPath -Encoding utf8
 Write-Host 'Screen Pin isolated terminal test. This window can be closed.'
 if($CommandPath){
  while($true){
   $phase='reading-command';$command=$null
   # The controller publishes in place; a partial read is retried without acknowledgement.
   if(Test-Path -LiteralPath $CommandPath){try{$command=Get-Content -LiteralPath $CommandPath -Raw|ConvertFrom-Json}catch{}}
   if($command -and $command.token -eq $Token -and $command.sequence -ne $lastSequence -and $command.title.StartsWith($Token)){
    $phase='setting-title';$Host.UI.RawUI.WindowTitle=$command.title
    $phase='writing-ack'
    @{sequence=$command.sequence;title=$command.title;pid=$PID}|ConvertTo-Json|Set-Content -LiteralPath $AckPath -Encoding utf8
    $lastSequence=$command.sequence
   }
   Start-Sleep -Milliseconds 50
  }
 }
}catch{
 $failure=@{pid=$PID;token=$Token;phase=$phase;sequence=$command.sequence;last_sequence=$lastSequence;message=$_.Exception.Message;exception_type=$_.Exception.GetType().FullName;stack=$_.ScriptStackTrace;utc=[DateTime]::UtcNow.ToString('o')}
 try{[IO.File]::WriteAllText($ErrorPath,($failure|ConvertTo-Json -Depth 5))}catch{[Console]::Error.WriteLine('Terminal fixture error record unavailable: '+$_.Exception.Message)}
 throw
}
