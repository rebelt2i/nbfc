# NBFC build script for Cursor / VS Code / CLI
# Requires: Visual Studio 2022 Build Tools + .NET Framework 4.8 targeting pack

param(
    [ValidateSet("DebugWindows", "ReleaseWindows", "DebugLinux", "ReleaseLinux")]
    [string]$Configuration = "ReleaseWindows",
    [switch]$Restore,
    [switch]$Installer,
    [switch]$Tests
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

$MSBuild = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
if (-not (Test-Path $MSBuild)) {
    $MSBuild = "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
}
if (-not (Test-Path $MSBuild)) {
    throw "MSBuild not found. Install Visual Studio 2022 Build Tools with .NET desktop development workload."
}

$NuGet = Join-Path $RepoRoot "tools\nuget.exe"
if (-not (Test-Path $NuGet)) {
    New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "tools") | Out-Null
    Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile $NuGet -UseBasicParsing
}

if ($Restore -or -not (Test-Path "$RepoRoot\packages\NLog.4.5.10")) {
    Write-Host "Restoring NuGet packages..." -ForegroundColor Cyan
    & $NuGet restore "$RepoRoot\NoteBookFanControl.sln" -ConfigFile "$RepoRoot\nuget.config" -NonInteractive
    if ($LASTEXITCODE -ne 0) { throw "NuGet restore failed." }
}

Write-Host "Building NBFC ($Configuration)..." -ForegroundColor Cyan

# Build via solution (handles per-project config mapping ReleaseWindows -> Release etc.)
# WiX installer projects may fail if WiX Toolset 3.14 is not installed; core apps still build.
& $MSBuild "$RepoRoot\NoteBookFanControl.sln" `
    /p:Configuration=$Configuration `
    /t:Build `
    /m `
    /v:minimal `
    /nologo

$expectedOutputs = @(
    "$RepoRoot\Core\NbfcCli\bin\$Configuration\nbfc.exe",
    "$RepoRoot\Core\NbfcService\bin\$Configuration\NbfcService.exe",
    "$RepoRoot\Windows\NbfcClient\bin\Release\NoteBookFanControl.exe"
)

$missing = @($expectedOutputs | Where-Object { -not (Test-Path $_) })
if ($missing.Count -gt 0) {
    foreach ($m in $missing) { Write-Host "Missing: $m" -ForegroundColor Red }
    throw "Build failed: expected outputs not found."
}

if ($Tests) {
    Write-Host "Building tests..." -ForegroundColor Cyan
    & $MSBuild "$RepoRoot\Tests\StagWare.FanControl.Tests\StagWare.FanControl.Tests.csproj" /p:Configuration=Release /t:Build /v:minimal /nologo
    if ($LASTEXITCODE -ne 0) { throw "Build failed: StagWare.FanControl.Tests" }
    & $MSBuild "$RepoRoot\Tests\StagWare.FanControl.Configurations.Tests\StagWare.FanControl.Configurations.Tests.csproj" /p:Configuration=Release /t:Build /v:minimal /nologo
    if ($LASTEXITCODE -ne 0) { throw "Build failed: StagWare.FanControl.Configurations.Tests" }
}

if ($Installer) {
    $wixTargets = "${env:ProgramFiles(x86)}\WiX Toolset v3.14\build\Wix.targets"
    if (-not (Test-Path $wixTargets)) {
        Write-Warning "WiX Toolset 3.14 not installed. Skipping installer. Install with: winget install WiXToolset.WiXToolset (requires admin)"
    }
    else {
        Write-Host "Building installer (WiX)..." -ForegroundColor Cyan
        & $MSBuild "$RepoRoot\Windows\Setup\DriverSetupWixAction\DriverSetupWixAction.csproj" /p:Configuration=$Configuration /t:Build /v:minimal /nologo
        & $MSBuild "$RepoRoot\Windows\Setup\NbfcSetup\NbfcSetup.wixproj" /p:Configuration=$Configuration /t:Build /v:minimal /nologo
    }
}

Write-Host ""
Write-Host "Build succeeded ($Configuration)" -ForegroundColor Green
Write-Host "  CLI:     Core\NbfcCli\bin\$Configuration\nbfc.exe"
Write-Host "  Service: Core\NbfcService\bin\$Configuration\NbfcService.exe"
Write-Host "  Client:  Windows\NbfcClient\bin\Release\NoteBookFanControl.exe"
