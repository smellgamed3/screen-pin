param([switch]$Offline)

$ErrorActionPreference = 'Stop'
$screenPinRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $screenPinRoot
try {
    $screenPinCargoArgs = @('--locked')
    if ($Offline) { $screenPinCargoArgs += '--offline' }

    & cargo fmt --all -- --check
    if ($LASTEXITCODE -ne 0) { throw 'Formatting check failed' }
    & cargo clippy @screenPinCargoArgs --all-targets -- -D warnings
    if ($LASTEXITCODE -ne 0) { throw 'Clippy failed' }
    & cargo test @screenPinCargoArgs --all-targets
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
    & cargo build @screenPinCargoArgs --release --bin screen-pin
    if ($LASTEXITCODE -ne 0) { throw 'Release build failed' }

    $screenPinMetadata = (& cargo metadata @screenPinCargoArgs --no-deps --format-version 1 | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read package metadata' }
    $screenPinVersion = $screenPinMetadata.packages[0].version
    $screenPinPackageName = "ScreenPin-$screenPinVersion-windows-x64"
    $screenPinStage = Join-Path $screenPinRoot "dist\$screenPinPackageName"
    New-Item -ItemType Directory -Path $screenPinStage -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $screenPinRoot 'target\release\screen-pin.exe') -Destination (Join-Path $screenPinStage 'screen-pin.exe') -Force
    Copy-Item -LiteralPath (Join-Path $screenPinRoot 'packaging\README.txt') -Destination (Join-Path $screenPinStage 'README.txt') -Force
    $screenPinZip = Join-Path $screenPinRoot "dist\$screenPinPackageName.zip"
    $screenPinInputs = @((Join-Path $screenPinStage 'screen-pin.exe'), (Join-Path $screenPinStage 'README.txt'))
    Compress-Archive -LiteralPath $screenPinInputs -DestinationPath $screenPinZip -Force
    Get-FileHash -LiteralPath $screenPinZip -Algorithm SHA256 | Format-List Path, Hash
}
finally { Pop-Location }
