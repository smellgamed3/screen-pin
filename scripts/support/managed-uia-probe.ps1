#Requires -Version 7.0
param(
 [Parameter(Mandatory)][string]$InputPath,
 [Parameter(Mandatory)][string]$OutputPath,
 [Parameter(Mandatory)][uint32]$ExpectedPid
)
$ErrorActionPreference='Stop'
try{
 Add-Type -Path (Join-Path $PSScriptRoot 'desktop-keyboard.cs')
 Add-Type -AssemblyName UIAutomationClient
 $controls=@(Get-Content -LiteralPath $InputPath -Raw -Encoding utf8|ConvertFrom-Json)
 $samples=@()
 foreach($control in $controls){
  $handle=[IntPtr][long]$control.handle
  if($ExpectedPid -eq 0 -or -not [PinDesktopKeyboard]::IsWindow($handle) -or [PinDesktopKeyboard]::Owner($handle) -ne $ExpectedPid){throw 'Control HWND no longer belongs to the isolated app'}
  $element=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
  $current=$element.Current
  if($current.ProcessId -ne $ExpectedPid -or $current.NativeWindowHandle -ne $handle.ToInt64()){throw 'Managed UIA provider process or HWND does not match the isolated app'}
  if(-not [PinDesktopKeyboard]::IsWindow($handle) -or [PinDesktopKeyboard]::Owner($handle) -ne $ExpectedPid -or $element.Current.ProcessId -ne $ExpectedPid){throw 'UIA target ownership changed during inspection'}
  $samples+=@{page=$control.page;id=$control.id;handle=$handle.ToInt64();provider_pid=$current.ProcessId;name=$current.Name;type=$current.ControlType.Id;enabled=$current.IsEnabled;access_key=$current.AccessKey;client='System.Windows.Automation.AutomationElement'}
 }
 ConvertTo-Json -InputObject @($samples) -Depth 6|Set-Content -LiteralPath $OutputPath -Encoding utf8
}catch{[Console]::Error.WriteLine('Managed UIA probe: '+$_.Exception.Message);exit 1}
