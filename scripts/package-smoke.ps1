#Requires -Version 7.0
param(
 [string]$ZipPath=(Join-Path $PSScriptRoot '../dist/ScreenPin-0.1.0-windows-x64.zip'),
 [string]$ReferenceExe=(Join-Path $PSScriptRoot '../target/release/screen-pin.exe'),
 [string]$FixturePath=(Join-Path $PSScriptRoot '../target/debug/desktop_probe.exe'),
 [string]$OutputDir=(Join-Path $PSScriptRoot '../artifacts/packages')
)
$ErrorActionPreference='Stop'
$ZipPath=(Get-Item -LiteralPath $ZipPath).FullName
$ReferenceExe=(Get-Item -LiteralPath $ReferenceExe).FullName
$runDir=(New-Item -ItemType Directory -Path (Join-Path $OutputDir ('package-'+[Guid]::NewGuid().ToString('N'))) -Force).FullName
$extract=Join-Path $runDir 'extracted'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive=[IO.Compression.ZipFile]::OpenRead($ZipPath)
try{$entries=@($archive.Entries|ForEach-Object FullName|Sort-Object)}finally{$archive.Dispose()}
if(($entries -join '|') -ne 'README.txt|screen-pin.exe'){throw 'The ZIP must contain exactly the executable and README at its root.'}
Expand-Archive -LiteralPath $ZipPath -DestinationPath $extract
$exe=Join-Path $extract 'screen-pin.exe'
$referenceHash=(Get-FileHash -LiteralPath $ReferenceExe).Hash
$extractedHash=(Get-FileHash -LiteralPath $exe).Hash
if($referenceHash -ne $extractedHash){throw 'The extracted executable differs from the tested Release build.'}
$evidence=Join-Path $runDir 'evidence'
& (Join-Path $PSScriptRoot 'ui-smoke.ps1') -ExePath $exe -FixturePath $FixturePath -OutputDir $evidence|Out-Null
$gui=Get-Content -Raw -LiteralPath (Join-Path $evidence 'gui-smoke.json')|ConvertFrom-Json
$remaining=@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -and $_.ExecutablePath.StartsWith($runDir,[StringComparison]::OrdinalIgnoreCase)}|Select-Object ProcessId,ExecutablePath)
$report=[ordered]@{executed=[DateTimeOffset]::Now.ToString('o');zip=$ZipPath;zip_sha256=(Get-FileHash -LiteralPath $ZipPath).Hash;files=$entries;release_exe_sha256=$referenceHash;extracted_exe_sha256=$extractedHash;gui_assertions=$gui.passed.Count;process_exited=$gui.process_exited;remaining_owned_processes=$remaining;passed=($gui.process_exited -and $gui.passed.Count -gt 0 -and $remaining.Count -eq 0)}
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $runDir 'package-verification.json') -Encoding utf8
$report|ConvertTo-Json -Depth 6
if(-not $report.passed){exit 1}
